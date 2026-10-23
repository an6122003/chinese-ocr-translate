import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey — needs no Accessibility or Input Monitoring permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Action: UInt32, CaseIterable {
        case capture = 1
        case translateSelection
        case lookUp
        case toggleToneTyping
    }

    private var references: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    /// While a shortcut recorder is active, hotkeys are suspended so the keystroke can be recorded.
    private(set) var isSuspended = false

    /// Registers (or clears, when `combo` is nil) the hotkey for an action. Returns false if macOS refused it,
    /// usually because another app already owns the combination.
    @discardableResult
    func set(_ combo: KeyCombo?, for action: Action, handler: @escaping () -> Void) -> Bool {
        installEventHandler()
        unregister(action)
        handlers[action] = handler
        combos[action] = combo
        guard let combo, !isSuspended else { return true }
        return register(combo, for: action)
    }

    /// The desired shortcut per action (kept while suspended so `resume()` can restore them).
    private var combos: [Action: KeyCombo] = [:]

    private func register(_ combo: KeyCombo, for action: Action) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x484E_4C53) /* 'HNLS' */, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            Log.app.error("RegisterEventHotKey failed for \(combo.displayString, privacy: .public): \(status)")
            return false
        }
        references[action] = reference
        Log.app.info("Registered hotkey \(combo.displayString, privacy: .public) for action \(action.rawValue)")
        return true
    }

    private func unregister(_ action: Action) {
        if let reference = references.removeValue(forKey: action) {
            UnregisterEventHotKey(reference)
        }
    }

    /// Temporarily releases all hotkeys (while recording a new shortcut).
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for (_, reference) in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (action, combo) in combos { _ = register(combo, for: action) }
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended, let action = Action(rawValue: id) else { return }
        Log.app.debug("Hotkey fired for action \(id)")
        handlers[action]?()
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
    }
}

/// Carbon delivers hotkey events on the main thread.
private nonisolated func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == OSType(0x484E_4C53) else { return OSStatus(eventNotHandledErr) }
    let id = identifier.id
    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(id)
    }
    return noErr
}
