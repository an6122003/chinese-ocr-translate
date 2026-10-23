import SwiftUI

/// First-run guide: permissions, shortcuts, and a "try it" button.
struct WelcomeView: View {
    let app: AppController
    var onClose: () -> Void

    @State private var hasScreenRecording = Permissions.hasScreenRecording
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var askedForScreenRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to HanLens").font(.title.weight(.semibold))
                    Text("Circle any Chinese text on your Mac to see pinyin, Hán Việt and a Vietnamese translation.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("1 · Allow access").font(.headline)
                PermissionRow(title: "Screen Recording (required)",
                              detail: "So HanLens can read the text you select on screen. Nothing is recorded or uploaded.",
                              granted: hasScreenRecording,
                              request: {
                                  askedForScreenRecording = true
                                  Permissions.requestScreenRecording()
                              },
                              relaunch: { Permissions.relaunch() })
                if askedForScreenRecording && !hasScreenRecording {
                    Text("After switching HanLens on in System Settings, click Relaunch if macOS asks you to quit & reopen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
                PermissionRow(title: "Accessibility (optional)",
                              detail: "For translating selected text with ⌃⌥X and for typing pinyin tones (ma1 → mā).",
                              granted: hasAccessibility,
                              request: {
                                  Permissions.requestAccessibility()
                                  Permissions.openAccessibilitySettings()
                              },
                              relaunch: nil)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("2 · Use it anywhere").font(.headline)
                shortcutLine(app.settings.captureShortcut?.displayString ?? "—",
                             "OCR any Chinese on screen — even text you can't select (images, videos, PDFs, games): drag a box, circle it, or click a highlighted line.")
                shortcutLine(app.settings.translateSelectionShortcut?.displayString ?? "—",
                             "Translate the text you've selected in any app.")
                shortcutLine("Space", "In the result: read aloud. Click a word for meanings, characters and examples.")
                shortcutLine("Esc", "Close. Drag a result panel to keep it open (it pins itself).")
            }

            HStack {
                Text(app.settings.showInDock ? "HanLens lives in the Dock and the menu bar (文)." : "HanLens lives in the menu bar (文).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") { app.showSettings() }
                Button("Try It Now") {
                    onClose()
                    app.capture(delay: .milliseconds(350))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasScreenRecording)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            while !Task.isCancelled {
                // Only while HanLens is in front: after granting in System Settings you come back here anyway.
                if NSApp.isActive {
                    hasScreenRecording = Permissions.hasScreenRecording
                    hasAccessibility = Permissions.hasAccessibility
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func shortcutLine(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(keys)
                .font(.callout.monospaced().weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .frame(minWidth: 64, alignment: .leading)
            Text(text).font(.callout)
        }
    }
}
