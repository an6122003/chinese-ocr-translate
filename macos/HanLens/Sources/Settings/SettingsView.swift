import AVFoundation
import HanziKit
import ServiceManagement
import SwiftUI
import Translation

enum SettingsTab: String {
    case general, shortcuts, translation, speech, typing, about
}

struct SettingsView: View {
    @Bindable var app: AppController

    var body: some View {
        TabView(selection: $app.settingsTab) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutSettings(app: app)
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
            TranslationSettings(settings: app.settings)
                .tabItem { Label("Translation", systemImage: "character.bubble") }
                .tag(SettingsTab.translation)
            SpeechSettings(settings: app.settings, apply: app.applySpeechSettings)
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.speech)
            TypingSettings(app: app)
                .tabItem { Label("Pinyin Typing", systemImage: "keyboard") }
                .tag(SettingsTab.typing)
            AboutSettings(app: app)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let app: AppController
    @Bindable private var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecording = Permissions.hasScreenRecording
    @State private var hasAccessibility = Permissions.hasAccessibility

    init(app: AppController) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open HanLens at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(isOn: $settings.showInDock) {
                    Text("Show HanLens in the Dock")
                    Text("Right-click the Dock icon for the lookup actions. The 文 menu bar item stays either way.")
                }
                .onChange(of: settings.showInDock) { _, _ in app.applyDockVisibility() }
                Toggle("Copy recognized text to the clipboard", isOn: $settings.autoCopyRecognizedText)
                Toggle("Read Chinese aloud automatically", isOn: $settings.autoSpeak)
                Toggle("Keep a history of lookups", isOn: $settings.keepHistory)
            }
            Section("Permissions") {
                PermissionRow(title: "Screen Recording",
                              detail: "Needed to capture text on screen.",
                              granted: hasScreenRecording,
                              request: { Permissions.requestScreenRecording() },
                              relaunch: { Permissions.relaunch() })
                PermissionRow(title: "Accessibility",
                              detail: "Lets ⌃⌥X read the selected text, and powers pinyin tone typing.",
                              granted: hasAccessibility,
                              request: {
                                  Permissions.requestAccessibility()
                                  Permissions.openAccessibilitySettings()
                              },
                              relaunch: nil)
            }
        }
        .formStyle(.grouped)
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
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var request: () -> Void
    var relaunch: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: request)
                if let relaunch {
                    Button("Relaunch", action: relaunch)
                        .help("macOS sometimes applies a new Screen Recording permission only after a restart")
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    let app: AppController
    @Bindable private var settings: AppSettings

    init(app: AppController) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        Form {
            Section {
                row("OCR capture (circle to search)", "Reads any text on screen, even non-selectable: freeze, then drag, circle or click.",
                    $settings.captureShortcut, action: .capture)
                row("Translate selected text", "Looks up whatever text is selected in the frontmost app.",
                    $settings.translateSelectionShortcut, action: .translateSelection)
                row("Open look-up panel", "Type or paste Chinese to look it up.",
                    $settings.lookUpShortcut, action: .lookUp)
                row("Toggle pinyin tone typing", "Turns ma1 → mā typing on or off.",
                    $settings.toneTypingShortcut, action: .toggleToneTyping)
            } footer: {
                Text("Tip: you can also select text in any app and choose **Services › Look Up in HanLens** from the right-click menu — that works without any permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ detail: String, _ binding: Binding<KeyCombo?>, action: HotKeyCenter.Action) -> some View {
        let others = [settings.captureShortcut, settings.translateSelectionShortcut, settings.lookUpShortcut, settings.toneTypingShortcut]
            .compactMap { $0 }
            .filter { $0 != binding.wrappedValue }
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if app.hotkeyFailures.contains(action) {
                    Label("macOS refused this shortcut — another app may be using it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            ShortcutRecorder(combo: binding, taken: others) { app.registerHotkeys() }
        }
    }
}

// MARK: - Translation

private struct TranslationSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $settings.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Translation engine", selection: $settings.translationEngine) {
                    Text("Google Translate (online, best quality)").tag(TranslationEngine.google)
                    Text("Apple Translation (on-device, private)").tag(TranslationEngine.apple)
                }
                Text("If the chosen engine fails (for example when you're offline) HanLens automatically tries the other one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                OfflineModelRow(target: settings.targetLanguage)
            }
            Section("Display") {
                Toggle("Show pinyin above characters", isOn: $settings.showPinyin)
                Toggle("Colour pinyin by tone", isOn: $settings.toneColors)
                Toggle("Show Hán Việt readings", isOn: $settings.showHanViet)
                Toggle("Also show English definitions", isOn: $settings.showEnglish)
            }
        }
        .formStyle(.grouped)
    }
}

/// Status of Apple's on-device Chinese → target model, with a button that triggers the system download.
private struct OfflineModelRow: View {
    let target: TargetLanguage
    @State private var status: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var error: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline model: Chinese → \(target.displayName)")
                Text(detail).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            switch status {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .supported:
                Button("Download…") {
                    error = nil
                    if configuration == nil {
                        configuration = .init(source: Locale.Language(identifier: "zh-Hans"),
                                              target: Locale.Language(identifier: target.rawValue))
                    } else {
                        configuration?.invalidate()
                    }
                }
            default:
                ProgressView().controlSize(.small)
            }
        }
        .translationTask(configuration, action: Self.downloadModel { failure in
            await finishDownload(failure)
        })
        .task(id: target) { await refresh() }
    }

    private var detail: String {
        if let error { return error }
        switch status {
        case .installed: return "Translations work without an internet connection."
        case .supported: return "Download once (~ a few hundred MB) to translate offline with Apple's engine."
        case .unsupported: return "Not available on this Mac."
        case nil: return "Checking…"
        @unknown default: return ""
        }
    }

    private func refresh() async {
        status = await AppleTranslator.status(to: target.rawValue)
    }

    private func finishDownload(_ failure: String?) async {
        error = failure
        await refresh()
    }

    /// The translationTask action: shows the system download prompt for the language pair, then reports back.
    /// It runs off the main actor (`@concurrent`), so the session never crosses actors.
    private nonisolated static func downloadModel(then finish: @escaping @MainActor (String?) async -> Void)
        -> (TranslationSession) async -> Void {
        { @concurrent session in
            var failure: String?
            do {
                try await session.prepareTranslation()
            } catch {
                failure = error.localizedDescription
            }
            await finish(failure)
        }
    }
}

// MARK: - Speech

struct SpeechSettings: View {
    @Bindable var settings: AppSettings
    var apply: () -> Void
    @State private var appleVoices: [AVSpeechSynthesisVoice] = Speaker.chineseVoices()
    @State private var hasGoodAppleVoice = Speaker.hasHighQualityAppleVoice

    var body: some View {
        Form {
            Section("Voice service") {
                Picker("Service", selection: $settings.speechEngine) {
                    serviceRow("Microsoft Azure", "Xiaoxiao 晓晓, Yunxi 云希… — the neural voices heard in countless Chinese videos and apps. Free tier: 500,000 characters a month.")
                        .tag(SpeechEngine.azure)
                    serviceRow("ElevenLabs", "Native Mandarin voices from its voice library. Uses your plan's credits (about 1 per character).")
                        .tag(SpeechEngine.elevenLabs)
                    serviceRow("Google (free)", "No setup needed, but the voice sounds dated.")
                        .tag(SpeechEngine.natural)
                    serviceRow("Apple (offline)", hasGoodAppleVoice ? "Your best installed Chinese voice." : "Only basic voices are installed on this Mac.")
                        .tag(SpeechEngine.system)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            switch settings.speechEngine {
            case .azure: AzureVoiceSection(settings: settings, apply: apply)
            case .elevenLabs: ElevenLabsVoiceSection(settings: settings, apply: apply)
            default: EmptyView()
            }

            Section("Playback") {
                LabeledContent("Speed") {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $settings.speechRate, in: 0.3...0.65)
                        Image(systemName: "hare")
                    }
                }
                Picker("Offline voice", selection: $settings.voiceIdentifier) {
                    Text("Best installed").tag(String?.none)
                    ForEach(appleVoices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language) · \(quality(voice))")
                            .tag(Optional(voice.identifier))
                    }
                }
                .help("The Apple voice used when “Apple” is selected, or when online voices can't be reached")
                HStack {
                    if let error = Speaker.shared.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Test Voice") {
                        apply()
                        Speaker.shared.speak("你好！我们一起学习中文吧。")
                    }
                }
            }

            if !hasGoodAppleVoice, settings.speechEngine == .system {
                Section("Better offline voice") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For a natural voice that works offline, download a Chinese (China mainland) voice marked **Premium** or **Enhanced** in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Spoken Content Settings…") { Self.openSpokenContentSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.speechEngine) { _, _ in apply() }
        .onChange(of: settings.voiceIdentifier) { _, _ in apply() }
        .onChange(of: settings.speechRate) { _, _ in apply() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleVoices = Speaker.chineseVoices()
            hasGoodAppleVoice = Speaker.hasHighQualityAppleVoice
        }
    }

    private func serviceRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Basic"
        }
    }

    static func openSpokenContentSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                          "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// "Save & Test" result.
private enum VoiceTestStatus: Equatable {
    case idle, checking, ok, info(String), failed(String)

    @ViewBuilder var view: some View {
        switch self {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .info(let message):
            Text(message).foregroundStyle(.secondary).font(.caption).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AzureVoiceSection: View {
    @Bindable var settings: AppSettings
    var apply: () -> Void
    @State private var keyDraft = ""
    @State private var voices: [AzureVoice] = AzureSpeech.recommendedVoices
    @State private var status: VoiceTestStatus = .idle

    var body: some View {
        Section("Microsoft Azure") {
            SecureField("Speech key", text: $keyDraft, prompt: Text("Paste KEY 1 from the Azure portal"))
                .onSubmit { Task { await saveAndTest() } }
            Picker("Region", selection: $settings.azureRegion) {
                let regions = AzureSpeech.regions.contains(settings.azureRegion)
                    ? AzureSpeech.regions : [settings.azureRegion] + AzureSpeech.regions
                ForEach(regions, id: \.self) { Text($0).tag($0) }
            }
            .help("Found automatically when you save a key")
            Picker("Mandarin voice", selection: $settings.azureMandarinVoice) {
                ForEach(options(for: ["zh-CN"], selected: settings.azureMandarinVoice)) { Text($0.label).tag($0.shortName) }
            }
            Picker("Traditional-text voice", selection: $settings.azureTaiwanVoice) {
                ForEach(options(for: ["zh-TW", "zh-HK", "yue"], selected: settings.azureTaiwanVoice)) { Text($0.label).tag($0.shortName) }
            }
            HStack {
                Button("Save & Test") { Task { await saveAndTest() } }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                status.view
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Until a key is saved, HanLens uses the free Google voice. To get one, create a **Speech** resource with the **Free F0** pricing tier in the Azure portal, open it › **Keys and Endpoint** and copy **KEY 1** — the region is detected for you.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Create a Speech resource in the Azure portal",
                     destination: URL(string: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices")!)
            }
            .font(.caption)
        }
        .onAppear {
            keyDraft = settings.azureKey
            if !settings.azureKey.isEmpty { Task { await loadVoices() } }
        }
        .onChange(of: settings.azureRegion) { _, _ in
            apply()
            Task { await loadVoices() }
        }
        .onChange(of: settings.azureMandarinVoice) { _, _ in apply() }
        .onChange(of: settings.azureTaiwanVoice) { _, _ in apply() }
    }

    /// Voices for the given locales, always including the current selection.
    private func options(for locales: [String], selected: String) -> [AzureVoice] {
        var list = voices.filter { voice in locales.contains { voice.locale.hasPrefix($0) } }
        if !list.contains(where: { $0.shortName == selected }) {
            let locale = selected.split(separator: "-").prefix(2).joined(separator: "-")
            list.insert(AzureVoice(shortName: selected, localName: "", gender: "", locale: locale), at: 0)
        }
        return list
    }

    private func saveAndTest() async {
        settings.azureKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        apply()
        guard var config = settings.azureConfig else { return }
        status = .checking
        do {
            do {
                _ = try await AzureSpeech.synthesize("你好", voice: settings.azureMandarinVoice, speed: 1, config: config)
            } catch CloudVoiceError.unauthorized {
                // Usually a key from another region: find its region and try again there.
                guard let region = await AzureSpeech.region(for: config.key), region != config.region else {
                    throw CloudVoiceError.unauthorized
                }
                settings.azureRegion = region
                config.region = region
                apply()
                _ = try await AzureSpeech.synthesize("你好", voice: settings.azureMandarinVoice, speed: 1, config: config)
            }
            status = .ok
            await loadVoices()
            Speaker.shared.speak("你好！我们一起学习中文吧。")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func loadVoices() async {
        guard let config = settings.azureConfig, let fetched = try? await AzureSpeech.voices(config: config), !fetched.isEmpty else { return }
        voices = fetched
    }
}

private struct ElevenLabsVoiceSection: View {
    @Bindable var settings: AppSettings
    var apply: () -> Void
    private let signIn = ElevenLabsSignIn.shared
    @State private var keyDraft = ""
    @State private var showKeyField = false
    @State private var usage: ElevenLabsUsage?
    @State private var myVoices: [ElevenLabsVoice] = []
    @State private var library: [ElevenLabsVoice] = []
    @State private var libraryFailed = false
    @State private var showLibrary = false
    @State private var busyVoice: String?
    @State private var status: VoiceTestStatus = .idle
    @State private var preview: AVAudioPlayer?

    var body: some View {
        Section("ElevenLabs") {
            account
            Picker("Voice", selection: Binding(
                get: { settings.elevenLabsVoiceID },
                set: { id in
                    if let voice = library.first(where: { $0.voiceID == id }), !myVoices.contains(where: { $0.voiceID == id }) {
                        Task { await use(voice) }
                    } else {
                        settings.elevenLabsVoiceID = id
                        settings.elevenLabsVoiceName = myVoices.first { $0.voiceID == id }?.name ?? ""
                        apply()
                    }
                }
            )) {
                Text(settings.elevenLabsVoiceID.isEmpty ? "Choose a voice…" : settings.elevenLabsVoiceName).tag(settings.elevenLabsVoiceID)
                let others = { (voice: ElevenLabsVoice) in voice.voiceID != settings.elevenLabsVoiceID }
                let mine = myVoices.filter { !$0.isPremade && others($0) }
                let mandarin = library.filter { voice in others(voice) && !mine.contains { $0.voiceID == voice.voiceID } }
                if !mandarin.isEmpty {
                    Section("Native Mandarin voices") {
                        ForEach(mandarin) { voice in voiceLabel(voice).tag(voice.voiceID) }
                    }
                }
                if !mine.isEmpty {
                    Section("Your voices") {
                        ForEach(mine) { voice in voiceLabel(voice).tag(voice.voiceID) }
                    }
                }
                let premade = myVoices.filter { $0.isPremade && others($0) }
                if !premade.isEmpty {
                    Section("ElevenLabs voices — English speakers, accented in Chinese") {
                        ForEach(premade) { voice in voiceLabel(voice).tag(voice.voiceID) }
                    }
                }
            }
            DisclosureGroup("Preview native Mandarin voices", isExpanded: $showLibrary) {
                if library.isEmpty {
                    HStack(spacing: 8) {
                        if libraryFailed {
                            Text("Couldn't load the voice library.").font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await loadLibrary() } }
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Loading Mandarin voices…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(library.prefix(15)) { voice in libraryRow(voice) }
            }
            .onChange(of: showLibrary) { _, open in if open { Task { await loadLibrary() } } }
            Picker("Model", selection: $settings.elevenLabsModel) {
                ForEach(ElevenLabsSpeech.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            .onChange(of: settings.elevenLabsModel) { _, _ in apply() }
            HStack {
                Button(settings.isSignedInToElevenLabs ? "Test" : "Save & Test") { Task { await saveAndTest() } }
                    .disabled(!settings.isSignedInToElevenLabs && keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                status.view
                Spacer()
            }
            Text("About 1 credit per character (Flash: ½). Replays are cached, so hearing a word again costs nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            keyDraft = settings.elevenLabsKey
            showKeyField = !settings.elevenLabsKey.isEmpty
            if settings.elevenLabsAuth != nil { Task { await loadAccount() } }
            Task { await loadLibrary() }
        }
    }

    private func voiceLabel(_ voice: ElevenLabsVoice) -> Text {
        Text(voice.detail.isEmpty ? voice.name : "\(voice.name) — \(voice.detail)")
    }

    @ViewBuilder private var account: some View {
        if settings.isSignedInToElevenLabs {
            LabeledContent("Account") {
                HStack(spacing: 10) {
                    Text(usage.map(Self.describe) ?? "Signed in").foregroundStyle(.secondary)
                    Button("Sign Out") { signOut() }
                }
            }
        } else if signIn.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Continue in your browser…")
                Spacer()
                Button("Cancel") { signIn.cancel() }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button("Sign in with ElevenLabs…") { startSignIn() }
                    .buttonStyle(.borderedProminent)
                Text("Opens elevenlabs.io in your browser — no API key needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Or use an API key", isExpanded: $showKeyField) {
                SecureField("API key", text: $keyDraft, prompt: Text("elevenlabs.io › Developers › API Keys"))
                    .onSubmit { Task { await saveAndTest() } }
                if let usage {
                    LabeledContent("Credits") { Text(Self.describe(usage)).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func libraryRow(_ voice: ElevenLabsVoice) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name)
                Text(voice.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = voice.previewURL {
                Button {
                    Task { await play(url) }
                } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Preview")
            }
            Button(voice.voiceID == settings.elevenLabsVoiceID ? "In use" : "Use") {
                Task { await use(voice) }
            }
            .disabled(busyVoice != nil || voice.voiceID == settings.elevenLabsVoiceID)
        }
    }

    /// "Creator · 12,219 of 329,628 credits used"
    private static func describe(_ usage: ElevenLabsUsage) -> String {
        let plan = usage.tier.isEmpty ? "" : usage.tier.replacingOccurrences(of: "_", with: " ").capitalized + " · "
        return "\(plan)\(usage.used.formatted()) of \(usage.limit.formatted()) credits used"
    }

    private func startSignIn() {
        status = .idle
        signIn.start(settings: settings) { error in
            if let error {
                status = .failed(error)
            } else {
                apply()
                Task { await afterSignIn() }
            }
        }
    }

    private func afterSignIn() async {
        await loadAccount()
        if settings.elevenLabsVoiceID.isEmpty {
            status = .info("Signed in. Now choose a native Mandarin voice in the Voice menu.")
            showLibrary = true
        } else {
            await test()
        }
    }

    private func signOut() {
        settings.signOutOfElevenLabs()
        apply()
        usage = nil
        myVoices = []
        status = .idle
        keyDraft = settings.elevenLabsKey
        showKeyField = !keyDraft.isEmpty
        if settings.elevenLabsAuth != nil { Task { await loadAccount() } }
    }

    private func saveAndTest() async {
        if !settings.isSignedInToElevenLabs {
            settings.elevenLabsKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            apply()
        }
        status = .checking
        let voicesError = await loadAccount()
        guard !settings.elevenLabsVoiceID.isEmpty else {
            status = if let voicesError, myVoices.isEmpty {
                .failed("Couldn't load your voices: \(voicesError)")
            } else {
                .info("Now choose a native Mandarin voice in the Voice menu.")
            }
            showLibrary = true
            await loadLibrary()
            return
        }
        await test()
    }

    private func test() async {
        guard let config = settings.elevenLabsConfig else { return }
        status = .checking
        do {
            _ = try await ElevenLabsSpeech.synthesize("你好", speed: 1, config: config)
            status = .ok
            Speaker.shared.speak("你好！我们一起学习中文吧。")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func use(_ voice: ElevenLabsVoice) async {
        guard let auth = settings.elevenLabsAuth else {
            status = .failed("Sign in or enter an API key first.")
            return
        }
        busyVoice = voice.voiceID
        defer { busyVoice = nil }
        var id = voice.voiceID
        // A sign-in may not add voices to the account; it uses the library voice as it is.
        if !voice.isAddedByUser, case .apiKey = auth {
            do {
                id = try await ElevenLabsSpeech.add(voice, auth: auth)
            } catch CloudVoiceError.missingPermission {
                // This sign-in can't add voices to the account; try the library voice as it is.
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
        }
        settings.elevenLabsVoiceID = id
        settings.elevenLabsVoiceName = voice.name
        apply()
        await loadAccount()
        await test()
    }

    /// The account's voices and credits; returns why the voices couldn't be listed.
    @discardableResult
    private func loadAccount() async -> String? {
        guard let auth = settings.elevenLabsAuth else { return "Sign in or enter an API key." }
        // Only an API key may read the credit balance; a sign-in is limited to speech.
        async let credits: ElevenLabsUsage? = if case .apiKey = auth { try? await ElevenLabsSpeech.usage(auth: auth) } else { nil }
        var failure: String?
        do {
            myVoices = try await ElevenLabsSpeech.myVoices(auth: auth)
            if let current = myVoices.first(where: { $0.voiceID == settings.elevenLabsVoiceID }) {
                settings.elevenLabsVoiceName = current.name
            }
        } catch {
            failure = error.localizedDescription
        }
        usage = await credits
        return failure
    }

    private func loadLibrary() async {
        guard library.isEmpty else { return }
        libraryFailed = false
        if let voices = try? await ElevenLabsSpeech.mandarinLibraryVoices(auth: settings.elevenLabsAuth) {
            library = voices
        } else {
            libraryFailed = true
        }
    }

    private func play(_ url: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url), let player = try? AVAudioPlayer(data: data) else { return }
        Speaker.shared.stop()
        preview = player
        player.play()
    }
}

// MARK: - Pinyin typing

private struct TypingSettings: View {
    let app: AppController
    @Bindable private var settings: AppSettings
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var sample = ""

    init(app: AppController) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        Form {
            Section {
                Toggle("Type pinyin tones with numbers in any app", isOn: Binding(
                    get: { settings.toneTypingEnabled },
                    set: { app.setToneTyping($0) }
                ))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type a syllable, then 1–4:  **ma1 → mā · ma2 → má · ma3 → mǎ · ma4 → mà · lv3 → lǚ**")
                    Text("Works with the ABC/US keyboard layout. It stays out of the way while the Pinyin or Vietnamese input method is active, and ignores ordinary words (chapter1, test2).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.toneTypingEnabled {
                    TextField("Try it here: ni3hao3", text: $sample)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !hasAccessibility {
                Section {
                    PermissionRow(title: "Accessibility",
                                  detail: "Tone typing needs Accessibility access to see and replace keystrokes.",
                                  granted: hasAccessibility,
                                  request: {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }, relaunch: nil)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                if NSApp.isActive {
                    let granted = Permissions.hasAccessibility
                    if granted != hasAccessibility {
                        hasAccessibility = granted
                        if granted, settings.toneTypingEnabled { app.setToneTyping(true) }
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    let app: AppController

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HanLens").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            .foregroundStyle(.secondary)
                        Text("Circle Chinese anywhere on your Mac → pinyin, Hán Việt, Vietnamese.")
                            .font(.callout)
                    }
                }
                if let error = app.dictionaryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let count = app.dictionary?.metadata["entries"] {
                    LabeledContent("Dictionary", value: "\(count) entries, offline")
                }
            }
            Section("Data sources") {
                credit("CVDICT — Từ điển Trung–Việt", "Phong Phan · CC BY-SA 4.0", "https://github.com/ph0ngp/CVDICT")
                credit("CC-CEDICT", "MDBG · CC BY-SA 4.0 · CEDICT © 1997, 1998 Paul Andrew Denisowski",
                       "https://www.mdbg.net/chinese/dictionary?page=cc-cedict")
                credit("Hán Việt – pinyin word list", "© 2024 Phong Phan · MIT", "https://github.com/ph0ngp/hanviet-pinyin-wordlist")
                credit("Thiều Chửu, Hán Việt tự điển (1942)", "Public domain · digitized by catusf/tudien (CC0)", "https://github.com/catusf/tudien")
                credit("Example sentences", "Tatoeba contributors · CC BY 2.0 FR", "https://tatoeba.org")
                credit("Unicode Han Database (Unihan)", "© 1991–2026 Unicode, Inc. · Unicode License v3", "https://www.unicode.org/charts/unihan.html")
                credit("HSK 3.0 word list", "© 2023 Ivan Krasilnikov, © 2021 Shawky · MIT", "https://github.com/ivankra/hsk30")
                credit("Word frequencies", "jieba, © 2013 Sun Junyi · MIT", "https://github.com/fxsjy/jieba")
                credit("Grammar links", "Chinese Grammar Wiki (AllSet Learning), keyword list from Zhongwen",
                       "https://resources.allsetlearning.com/chinese/grammar/")
                HStack {
                    Text("The bundled dictionary database is an adaptation of CC BY-SA 4.0 data and is licensed CC BY-SA 4.0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Licences…") {
                        if let url = Bundle.main.url(forResource: "licenses", withExtension: nil) {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [Bundle.main.url(forResource: "LICENSES", withExtension: "md") ?? url])
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func credit(_ title: String, _ detail: String, _ url: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let link = URL(string: url) {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
            }
        }
    }
}
