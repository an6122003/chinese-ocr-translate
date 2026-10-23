import AppKit
import HanziKit
import SwiftUI

/// Launch arguments for testing and screenshots without granting Screen Recording:
///
///     HanLens --lookup 学习中文
///     HanLens --overlay-image ~/Desktop/sample.png
///     HanLens --render-panel "银行行长说他很喜欢长城。" /tmp/panel.png [--dark] [--select 2]
///     HanLens --render-overlay ~/Desktop/sample.png /tmp/overlay.png
enum DebugLaunchOptions {
    /// Rendering modes run without the menu bar item, hotkeys or welcome window, then quit.
    static var isHeadless: Bool {
        ["--render-panel", "--render-overlay", "--render-speech-settings"].contains { CommandLine.arguments.contains($0) }
    }

    static func apply() {
        let arguments = CommandLine.arguments
        func value(after flag: String, offset: Int = 1) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + offset < arguments.count else { return nil }
            return arguments[index + offset]
        }

        if let text = value(after: "--lookup") {
            AppController.shared.lookUp(text, source: .typed, near: nil)
        }
        if let path = value(after: "--overlay-image"), let image = loadImage(path), let screen = NSScreen.main {
            AppController.shared.capturer.present(image: image, on: screen)
        }
        if let text = value(after: "--render-panel"), let output = value(after: "--render-panel", offset: 2) {
            let select = value(after: "--select").flatMap(Int.init)
            Task { await renderPanel(text: text, to: output, dark: arguments.contains("--dark"), selectWord: select) }
        }
        if let engine = value(after: "--render-speech-settings").flatMap(SpeechEngine.init(rawValue:)),
           let output = value(after: "--render-speech-settings", offset: 2) {
            Task {
                await renderSpeechSettings(engine: engine, to: output, dark: arguments.contains("--dark"),
                                           signedIn: arguments.contains("--signed-in"))
            }
        }
        if let path = value(after: "--render-overlay"), let output = value(after: "--render-overlay", offset: 2),
           let image = loadImage(path) {
            let mode = value(after: "--preview") ?? "hint"   // hint | hover | lasso | rect
            Task { await renderOverlay(image: image, to: output, mode: mode) }
        }
    }

    private static func loadImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders a result panel for `text` into a PNG, then quits.
    @MainActor
    private static func renderPanel(text: String, to output: String, dark: Bool, selectWord: Int?) async {
        let app = AppController.shared
        let model = LookupModel(source: .screen, services: app.services, status: .recognizing)
        model.speaksAutomatically = false
        await model.setText(text)
        // Give the translation a moment to arrive.
        for _ in 0..<50 where model.translation == .loading {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let selectWord {
            let words = model.analysis.segments.filter(\.isWord)
            if selectWord < words.count { model.selectedSegmentID = words[selectWord].id }
        }
        var height: CGFloat = 400
        let view = ResultView(model: model, maxHeight: 1400, onClose: {}, onHeightChange: { height = $0 }, onCaptureAgain: {})
        let hosting = NSHostingView(rootView: view)
        let width = CGFloat(app.settings.panelWidth)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI measure, then size the window to the reported height and render.
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(400))
            window.setContentSize(NSSize(width: width, height: height))
            hosting.layoutSubtreeIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(600))
        write(view: hosting, to: output)
        NSApp.terminate(nil)
    }

    /// Renders Settings › Speech with a throwaway settings store, so the real preferences are untouched.
    @MainActor
    private static func renderSpeechSettings(engine: SpeechEngine, to output: String, dark: Bool, signedIn: Bool) async {
        guard let defaults = UserDefaults(suiteName: "com.nguyenan.HanLens.preview") else { return }
        let settings = AppSettings(defaults: defaults, usesKeychain: false)
        settings.speechEngine = engine
        if signedIn { settings.showSignedInPreview() }
        let hosting = NSHostingView(rootView: SpeechSettings(settings: settings, apply: {}).frame(width: 580))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 580, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        window.setContentSize(hosting.fittingSize)
        try? await Task.sleep(for: .milliseconds(500))
        write(view: hosting, to: output)
        defaults.removePersistentDomain(forName: "com.nguyenan.HanLens.preview")
        NSApp.terminate(nil)
    }

    @MainActor
    private static func renderOverlay(image: CGImage, to output: String, mode: String) async {
        guard let screen = NSScreen.main else { return }
        let snapshot = DisplaySnapshot(screen: screen, image: image)
        let view = OverlayView(snapshot: snapshot)
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: view.frame.width, height: view.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        if let lines = try? await TextRecognizer().lines(in: image, minimumTextHeight: 0.004) {
            let size = view.bounds.size
            view.textLines = lines.filter { CJK.containsHan($0.text) }.map {
                CGRect(x: $0.box.minX * size.width, y: $0.box.minY * size.height, width: $0.box.width * size.width, height: $0.box.height * size.height)
            }
        }
        let lines = view.textLines
        switch mode {
        case "hover":
            if let line = lines.dropFirst(min(2, max(lines.count - 1, 0))).first {
                view.previewHover(at: CGPoint(x: line.midX, y: line.midY))
            }
        case "lasso", "rect":
            // Circle (or drag across) the first two detected lines.
            let target = lines.prefix(2).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -18)
            if !target.isNull {
                let points: [CGPoint]
                if mode == "lasso" {
                    points = stride(from: 0.0, through: 2 * Double.pi * 1.04, by: 0.06).map { angle in
                        CGPoint(x: target.midX + cos(angle) * target.width / 2 * (1 + 0.03 * sin(angle * 5)),
                                y: target.midY + sin(angle) * target.height / 2 * 1.15)
                    }
                } else {
                    points = stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                        CGPoint(x: target.minX + t * target.width, y: target.minY + t * target.height)
                    }
                }
                view.previewGesture(through: points)
            }
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(500))
        write(view: view, to: output)
        NSApp.terminate(nil)
    }

    @MainActor
    private static func write(view: NSView, to output: String) {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
        Log.app.info("Rendered \(url.path, privacy: .public)")
    }
}
