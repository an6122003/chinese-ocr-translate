import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// Other actions' shortcuts, to refuse duplicates.
    var taken: [KeyCombo] = []
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var id = UUID()

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? "Type shortcut…" : (combo?.displayString ?? "Record Shortcut"))
                        .font(combo == nil || isRecording ? .callout : .callout.monospaced().weight(.medium))
                        .frame(minWidth: 118)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                if combo != nil, !isRecording {
                    Button {
                        combo = nil
                        message = nil
                        onChange()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { if isRecording { stop() } }
        // Only one recorder at a time, and never left recording (with global hotkeys suspended) in the background.
        .onReceive(NotificationCenter.default.publisher(for: ShortcutRecorder.didStartRecording)) { note in
            if isRecording, note.object as? UUID != id { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isRecording { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stop() }
        }
    }

    static let didStartRecording = Notification.Name("HanLensShortcutRecorderDidStart")

    private func start() {
        NotificationCenter.default.post(name: Self.didStartRecording, object: id)
        isRecording = true
        message = nil
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stop()
            return
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            combo = nil
            stop()
            onChange()
            return
        default:
            break
        }
        let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: flags)
        guard candidate.isValidGlobalShortcut else {
            message = "Use at least one of ⌘ ⌥ ⌃ (e.g. ⌃⌥S)."
            NSSound.beep()
            return
        }
        guard !taken.contains(candidate) else {
            message = "\(candidate.displayString) is already used by another HanLens action."
            NSSound.beep()
            return
        }
        combo = candidate
        message = candidate.isOptionOnly
            ? "Option-only shortcuts can be unreliable on recent macOS versions; adding ⌃ or ⌘ is safer."
            : nil
        stop()
        onChange()
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.resume()
    }
}
