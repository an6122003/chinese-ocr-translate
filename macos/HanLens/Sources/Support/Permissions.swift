import AppKit
import ApplicationServices
import CoreGraphics

/// The two macOS privacy permissions HanLens can use.
enum Permissions {
    /// Needed to capture the screen for OCR.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Needed for pinyin tone typing and for reading/copying the selection in other apps.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// The first time, shows macOS's own permission prompt. macOS only shows that prompt once, so later
    /// requests open System Settings › Screen & System Audio Recording instead.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "askedForScreenRecording") {
            openScreenRecordingSettings()
            return false
        }
        defaults.set(true, forKey: "askedForScreenRecording")
        return CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't touch).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// Relaunches the app (macOS often only applies a fresh Screen Recording grant after a restart).
    static func relaunch() {
        // Give this instance a moment to quit before the new one checks for duplicates.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
