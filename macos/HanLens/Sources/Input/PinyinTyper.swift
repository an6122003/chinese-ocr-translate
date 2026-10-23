import AppKit
import Carbon.HIToolbox
import HanziKit

/// System-wide pinyin tone typing: type "ma" then "1" and it becomes "mā" in any app.
///
/// Uses a keyboard event tap (needs the Accessibility permission) on its own thread, so keystrokes in other apps
/// never wait for HanLens' main thread. It only acts while a plain keyboard layout such as ABC is selected — never
/// while an input method (Pinyin, Vietnamese Telex…) is active, where digits mean something else.
nonisolated final class PinyinTyper: @unchecked Sendable {
    /// Marks events we post ourselves so the tap ignores them.
    private static let syntheticMarker: Int64 = 0x484E_4C53

    // Shared between the main thread and the tap thread; always accessed under `lock`.
    private let lock = NSLock()
    private var state = ToneTypingState()
    private var layoutIsPlain = true
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    // Only touched from the @MainActor start()/stop().
    private(set) var isRunning = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Starts listening. Returns false if Accessibility permission is missing or the tap can't be created.
    @MainActor @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Permissions.hasAccessibility else { return false }
        updateLayout()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(mask), callback: pinyinTapCallback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            lock.withLock {
                self.tap = tap
                self.runLoop = loop
            }
            ready.signal()
            CFRunLoopRun() // until stop() stops this run loop
        }
        thread.name = "HanLens pinyin tone typing"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard lock.withLock({ tap != nil }) else {
            Log.input.error("Couldn't create the keyboard event tap")
            return false
        }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (distributed, distributed.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                  object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLayout() }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.resetState()
            }),
        ]
        isRunning = true
        Log.input.info("Pinyin tone typing started")
        return true
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        lock.withLock {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let runLoop { CFRunLoopStop(runLoop) }
            tap = nil
            runLoop = nil
            state.reset()
        }
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        isRunning = false
        Log.input.info("Pinyin tone typing stopped")
    }

    private func resetState() {
        lock.withLock { state.reset() }
    }

    /// Text Input Sources must be queried on the main thread; the result is handed to the tap thread.
    @MainActor
    private func updateLayout() {
        var plain = true
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue()
            plain = CFEqual(type, kTISTypeKeyboardLayout)
        }
        lock.withLock {
            layoutIsPlain = plain
            state.reset()
        }
    }

    // MARK: Event handling (tap thread)

    /// Returns false when the event must be swallowed (a tone digit we turned into a tone mark).
    fileprivate func handle(_ eventType: CGEventType, _ event: CGEvent) -> Bool {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown, .rightMouseDown:
            resetState() // the caret probably moved
            return true
        case .keyDown:
            break
        default:
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return true }

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let character = typedCharacter(of: event)

        let replacement: ToneTyping.Replacement? = lock.withLock {
            if !layoutIsPlain || flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
                state.reset()
                return nil
            }
            if keyCode == kVK_Delete {
                state.backspace()
                return nil
            }
            guard let character else {
                state.reset()
                return nil
            }
            if let tone = character.wholeNumberValue, (1...4).contains(tone), character.isASCII {
                return state.tone(tone)
            }
            state.type(character)
            return nil
        }
        guard let replacement else { return true }
        apply(replacement)
        return false // swallow the digit
    }

    private func typedCharacter(of event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length == 1 else { return nil }
        return String(utf16CodeUnits: buffer, count: length).first
    }

    /// Deletes the plain syllable and types the tone-marked one in its place. Posted from the tap thread, in order,
    /// before the tap returns — so later keystrokes can't overtake them.
    private func apply(_ replacement: ToneTyping.Replacement) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<replacement.deleteCount {
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
        }
        let utf16 = Array(replacement.insert.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(down)
        post(up)
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cgSessionEventTap)
    }
}

/// Runs on the tap's own thread.
private nonisolated func pinyinTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let typer = Unmanaged<PinyinTyper>.fromOpaque(userInfo).takeUnretainedValue()
    return typer.handle(type, event) ? Unmanaged.passUnretained(event) : nil
}
