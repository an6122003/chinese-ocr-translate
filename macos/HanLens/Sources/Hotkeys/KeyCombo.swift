import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus modifier flags.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Device-independent `NSEvent.ModifierFlags` raw value (⌘ ⌥ ⌃ ⇧ only).
    var modifiers: UInt

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(KeyCombo.relevantModifiers).rawValue
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Option-only (or ⌥⇧) shortcuts were blocked in macOS 15.0–15.1 and are still reported flaky.
    var isOptionOnly: Bool {
        let flags = modifierFlags
        return flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
    }

    var isValidGlobalShortcut: Bool {
        let flags = modifierFlags
        let hasPrimaryModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        return hasPrimaryModifier || KeyCombo.functionKeyCodes.contains(Int(keyCode))
    }

    // MARK: Display

    /// "⌃⌥S"
    var displayString: String { modifierSymbols + keyName }

    var modifierSymbols: String {
        let flags = modifierFlags
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    var keyName: String {
        if let special = KeyCombo.specialKeyNames[Int(keyCode)] { return special }
        return KeyCombo.characterForKeyCode(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// The character the key produces on the current keyboard layout (so AZERTY users see the right letter).
    /// `carbonModifiers` (e.g. `cmdKey`) asks what it types with those modifiers held.
    static func characterForKeyCode(_ keyCode: UInt32, carbonModifiers: UInt32 = 0) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), (carbonModifiers >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    // MARK: Defaults

    /// ⌃⌥S — scan text on screen (the Windows version used Alt+S).
    static let defaultCapture = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option])
    /// ⌃⌥X — translate the selected text (the Windows version used Alt+X).
    static let defaultTranslateSelection = KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.control, .option])
}
