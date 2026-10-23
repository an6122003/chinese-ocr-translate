import AppKit
import AVFoundation
import HanziKit
import Observation
import SwiftUI

/// Owns the app's services and implements every user-facing action.
@Observable
final class AppController {
    static let shared = AppController()

    let settings = AppSettings.shared
    let history = HistoryStore.shared
    private(set) var dictionary: HanziDictionary?
    private(set) var dictionaryError: String?
    /// Actions whose shortcut macOS refused to register.
    private(set) var hotkeyFailures: Set<HotKeyCenter.Action> = []
    private(set) var isToneTypingActive = false
    /// The tab shown in the Settings window.
    var settingsTab: SettingsTab = .general

    @ObservationIgnored private(set) var services: LookupServices!
    @ObservationIgnored let capturer = CaptureController()
    @ObservationIgnored private(set) var panels: PanelController!
    @ObservationIgnored private let typer = PinyinTyper()
    @ObservationIgnored private var windows: [String: NSWindow] = [:]

    // MARK: Start-up

    /// `interactive: false` is used for headless rendering (no hotkeys, tone typing or welcome window).
    func start(interactive: Bool = true) {
        loadDictionary()
        services = LookupServices(settings: settings, dictionary: dictionary)
        panels = PanelController(settings: settings)
        panels.onCaptureAgain = { [weak self] in self?.capture(delay: .milliseconds(150)) }

        // A robotic Eloquence/novelty voice saved by an earlier version is dropped.
        if let id = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id), Speaker.isNovelty(voice) {
            settings.voiceIdentifier = nil
        }
        settings.onElevenLabsAccountChange = { [weak self] in self?.applySpeechSettings() }
        applySpeechSettings()

        capturer.willCapture = { [weak self] in self?.panels.closeUnpinned() }
        capturer.onSelection = { [weak self] selection in self?.handle(selection) }
        capturer.onPermissionMissing = { [weak self] in self?.showScreenRecordingHelp() }
        capturer.onFailure = { [weak self] error in self?.showCaptureFailure(error) }

        guard interactive else { return }
        registerHotkeys()
        if settings.toneTypingEnabled { setToneTyping(true) }
        Log.app.notice("""
            Started. Screen Recording (OCR): \(Permissions.hasScreenRecording ? "granted" : "MISSING", privacy: .public); \
            Accessibility: \(Permissions.hasAccessibility ? "granted" : "missing", privacy: .public); \
            OCR shortcut \(self.settings.captureShortcut?.displayString ?? "none", privacy: .public), \
            selection shortcut \(self.settings.translateSelectionShortcut?.displayString ?? "none", privacy: .public); \
            refused shortcuts: \(self.hotkeyFailures.map(\.rawValue).sorted().description, privacy: .public)
            """)
        if !settings.hasCompletedOnboarding || !Permissions.hasScreenRecording {
            showWelcome()
        }
    }

    private func loadDictionary() {
        guard let url = Bundle.main.url(forResource: "hanzi", withExtension: "sqlite") else {
            dictionaryError = "The dictionary file is missing from the app bundle."
            Log.app.error("hanzi.sqlite not found in bundle")
            return
        }
        do {
            dictionary = try HanziDictionary(url: url)
        } catch {
            dictionaryError = error.localizedDescription
            Log.app.error("Dictionary failed to open: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hands the current voice settings (engine, keys, voices, speed) to the speaker.
    func applySpeechSettings() {
        let speaker = Speaker.shared
        speaker.engine = settings.speechEngine
        speaker.azure = settings.azureConfig
        speaker.elevenLabs = settings.elevenLabsConfig
        speaker.voiceIdentifier = settings.voiceIdentifier
        speaker.rate = Float(settings.speechRate)
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        var failures: Set<HotKeyCenter.Action> = []
        let center = HotKeyCenter.shared
        if !center.set(settings.captureShortcut, for: .capture, handler: { [weak self] in self?.capturer.toggle() }) {
            failures.insert(.capture)
        }
        if !center.set(settings.translateSelectionShortcut, for: .translateSelection, handler: { [weak self] in self?.translateSelection() }) {
            failures.insert(.translateSelection)
        }
        if !center.set(settings.lookUpShortcut, for: .lookUp, handler: { [weak self] in self?.showLookUpPanel() }) {
            failures.insert(.lookUp)
        }
        if !center.set(settings.toneTypingShortcut, for: .toggleToneTyping, handler: { [weak self] in
            guard let self else { return }
            self.setToneTyping(!self.settings.toneTypingEnabled)
        }) {
            failures.insert(.toggleToneTyping)
        }
        hotkeyFailures = failures
        StatusMenu.shared.refresh()
    }

    // MARK: Actions

    /// Freezes the screen for selection. A delay lets a menu or window close first.
    func capture(delay: Duration = .zero) {
        capturer.start(delay: delay)
    }

    /// Looks up the text selected in the frontmost app.
    func translateSelection() {
        guard Permissions.hasAccessibility else {
            showAccessibilityHelp()
            return
        }
        // Accessibility first, synchronously on the main thread (not inside a task).
        if let text = SelectionReader.accessibilitySelection() {
            lookUp(text, source: .selection, near: nil)
            return
        }
        Task {
            do {
                let text = try await SelectionReader.copiedSelection()
                lookUp(text, source: .selection, near: nil)
            } catch SelectionReader.Failure.needsAccessibility {
                showAccessibilityHelp()
            } catch {
                NSSound.beep()
                showToast("Select some Chinese text first, then press \(settings.translateSelectionShortcut?.displayString ?? "the shortcut").")
            }
        }
    }

    func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        lookUp(text, source: .clipboard, near: nil)
    }

    /// An empty panel to type or paste into.
    func showLookUpPanel() {
        let model = LookupModel(source: .typed, services: services)
        model.startTyping()
        attachHistory(to: model)
        panels.show(model, near: nil)
    }

    /// Shows a result panel for `text`.
    func lookUp(_ text: String, source: LookupModel.Source, near anchor: CGRect?) {
        let model = LookupModel(source: source, services: services, status: .recognizing)
        attachHistory(to: model)
        panels.show(model, near: anchor)
        model.begin { await $0.setText(text) }
    }

    private func handle(_ selection: OverlaySelection) {
        guard let image = selection.snapshot.crop(selection.rect) else { return }
        let model = LookupModel(source: .screen, services: services, status: .recognizing)
        model.screenRegion = (selection.rect, selection.snapshot.screen)
        attachHistory(to: model)
        panels.show(model, near: selection.screenRect)

        var keepLine: ((CGRect) -> Bool)?
        if let lasso = selection.lasso {
            let rect = selection.rect
            // Keep lines whose centre lies inside the circled area.
            keepLine = { box in
                lasso.contains(CGPoint(x: rect.minX + box.midX * rect.width, y: rect.minY + box.midY * rect.height))
            }
        }
        model.begin { await $0.recognize(image, keepLine: keepLine) }
    }

    private func attachHistory(to model: LookupModel) {
        model.onTextChange = { [weak self] model in
            guard let self, self.settings.keepHistory, model.analysis.containsChinese, !model.isFollowUpdate else { return }
            self.history.record(text: model.text, pinyin: model.analysis.pinyinText,
                                translation: model.translatedText, source: model.source.label)
        }
    }

    // MARK: Tone typing

    func setToneTyping(_ enabled: Bool) {
        if enabled {
            if typer.start() {
                settings.toneTypingEnabled = true
            } else {
                settings.toneTypingEnabled = true // remember the wish; it starts once permission is granted
                showAccessibilityHelp()
            }
        } else {
            typer.stop()
            settings.toneTypingEnabled = false
        }
        isToneTypingActive = typer.isRunning
        StatusMenu.shared.refresh()
    }

    // MARK: Windows

    /// Shows or hides the Dock icon to match Settings.
    func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // A policy change sends the app to the background; keep the Settings window in front.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate()
            windows["settings"]?.makeKeyAndOrderFront(nil)
        }
    }

    /// Clicking the Dock icon: bring HanLens's windows forward, or open Settings when none is open.
    func reopen() {
        let open = windows.values.filter(\.isVisible)
        guard !open.isEmpty else { return showSettings() }
        NSApp.activate()
        open.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        showWindow(id: "settings", title: "HanLens Settings") { SettingsView(app: self) }
    }

    func showHistory() {
        showWindow(id: "history", title: "History", resizable: true) {
            HistoryView(store: self.history) { [weak self] text in self?.lookUp(text, source: .typed, near: nil) }
        }
    }

    func showWelcome() {
        showWindow(id: "welcome", title: "Welcome to HanLens") {
            WelcomeView(app: self) { [weak self] in self?.closeWindow(id: "welcome") }
        }
    }

    private func showWindow<Content: View>(id: String, title: String, resizable: Bool = false, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = resizable ? [] : [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        if resizable { window.setContentSize(NSSize(width: 640, height: 520)) }
        window.center()
        window.setFrameAutosaveName("HanLens.\(id)")
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows[id] = nil
                if id == "welcome" { self?.settings.hasCompletedOnboarding = true }
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow(id: String) {
        windows[id]?.close()
    }

    // MARK: Help & errors

    private func showScreenRecordingHelp() {
        Log.capture.notice("Screen Recording permission missing")
        showWelcome()
        Permissions.requestScreenRecording()
    }

    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow Accessibility access"
        alert.informativeText = "To read selected text and type pinyin tones, turn on HanLens in System Settings › Privacy & Security › Accessibility.\n\nTip: Services › Look Up in HanLens (in any app's right-click menu) works without this permission."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }

    private func showCaptureFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't capture the screen"
        alert.informativeText = "\(error.localizedDescription)\n\nIf you just allowed Screen Recording, relaunch HanLens."
        alert.addButton(withTitle: "Relaunch HanLens")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: Permissions.relaunch()
        case .alertSecondButtonReturn: Permissions.openScreenRecordingSettings()
        default: break
        }
    }

    /// A small transient message near the mouse.
    func showToast(_ message: String) {
        Toast.show(message)
    }
}
