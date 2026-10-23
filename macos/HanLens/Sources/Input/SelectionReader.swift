import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Gets the text selected in the frontmost app.
///
/// 1. Accessibility (`AXSelectedText`) — instant and leaves the clipboard alone; works in most native apps.
/// 2. Otherwise simulates ⌘C and restores the previous clipboard contents afterwards
///    (browsers, Electron apps, PDFs…).
enum SelectionReader {
    enum Failure: Error {
        case needsAccessibility
        case nothingSelected
    }

    /// The selection via the Accessibility API — call synchronously on the main thread (Apple's AX client
    /// warns, and can deadlock, when called from inside a Swift concurrency task).
    static func accessibilitySelection() -> String? {
        guard Permissions.hasAccessibility else { return nil }
        guard let text = axSelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        Log.input.debug("Selection via Accessibility (\(text.count) chars)")
        return text
    }

    /// The selection via a simulated ⌘C (clipboard restored afterwards), for apps that don't expose it to AX.
    static func copiedSelection() async throws -> String {
        guard Permissions.hasAccessibility else { throw Failure.needsAccessibility }
        if let text = await copySelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.input.debug("Selection via ⌘C (\(text.count) chars)")
            return text
        }
        throw Failure.nothingSelected
    }

    // MARK: Accessibility

    private static func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement // swiftlint:disable:this force_cast
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Copy fallback

    private static func copySelection() async -> String? {
        // Wait (briefly) until the hotkey's modifiers are released, or the app would see ⌃⌥⌘C.
        for _ in 0..<25 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskCommand, .maskShift]) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        let startCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = copyKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        var copied: String?
        for _ in 0..<50 { // up to ~1 s
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != startCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != startCount {
            saved.restore(to: pasteboard)
        }
        return copied
    }

    /// The key that types "c" while ⌘ is held on the current layout (differs on Dvorak, AZERTY…).
    private static func copyKeyCode() -> CGKeyCode {
        for code in 0..<128 where KeyCombo.characterForKeyCode(UInt32(code), carbonModifiers: UInt32(cmdKey))?.lowercased() == "c" {
            return CGKeyCode(code)
        }
        return CGKeyCode(kVK_ANSI_C)
    }
}

/// A copy of everything on the pasteboard, so it can be put back after borrowing it.
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
