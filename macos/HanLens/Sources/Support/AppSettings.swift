import AppKit
import HanziKit
import Observation

/// User preferences, persisted in UserDefaults (`com.nguyenan.HanLens`).
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults
    /// False for throwaway settings (previews), which must not read or write the user's keys.
    @ObservationIgnored private let usesKeychain: Bool

    init(defaults: UserDefaults = .standard, usesKeychain: Bool = true) {
        self.defaults = defaults
        self.usesKeychain = usesKeychain
        captureShortcut = Self.loadCombo(defaults, "captureShortcut", default: .defaultCapture)
        translateSelectionShortcut = Self.loadCombo(defaults, "translateSelectionShortcut", default: .defaultTranslateSelection)
        lookUpShortcut = Self.loadCombo(defaults, "lookUpShortcut", default: nil)
        toneTypingShortcut = Self.loadCombo(defaults, "toneTypingShortcut", default: nil)
        translationEngine = TranslationEngine(rawValue: defaults.string(forKey: "translationEngine") ?? "") ?? .google
        targetLanguage = TargetLanguage(rawValue: defaults.string(forKey: "targetLanguage") ?? "") ?? .vietnamese
        showHanViet = defaults.object(forKey: "showHanViet") as? Bool ?? true
        showPinyin = defaults.object(forKey: "showPinyin") as? Bool ?? true
        toneColors = defaults.object(forKey: "toneColors") as? Bool ?? true
        showEnglish = defaults.object(forKey: "showEnglish") as? Bool ?? true
        autoCopyRecognizedText = defaults.object(forKey: "autoCopyRecognizedText") as? Bool ?? false
        autoSpeak = defaults.object(forKey: "autoSpeak") as? Bool ?? false
        showInDock = Self.showsInDock(defaults)
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 0.45
        speechEngine = SpeechEngine(rawValue: defaults.string(forKey: "speechEngine") ?? "") ?? .azure
        azureKey = usesKeychain ? Keychain.string(for: "azure-speech-key") ?? "" : ""
        azureRegion = defaults.string(forKey: "azureRegion") ?? "southeastasia"
        azureMandarinVoice = defaults.string(forKey: "azureMandarinVoice") ?? "zh-CN-XiaoxiaoNeural"
        azureTaiwanVoice = defaults.string(forKey: "azureTaiwanVoice") ?? "zh-TW-HsiaoChenNeural"
        elevenLabsKey = usesKeychain ? Keychain.string(for: "elevenlabs-api-key") ?? "" : ""
        elevenLabsVoiceID = defaults.string(forKey: "elevenLabsVoiceID") ?? ""
        elevenLabsVoiceName = defaults.string(forKey: "elevenLabsVoiceName") ?? ""
        elevenLabsModel = defaults.string(forKey: "elevenLabsModel") ?? "eleven_multilingual_v2"
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
        toneTypingEnabled = defaults.object(forKey: "toneTypingEnabled") as? Bool ?? false
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        panelWidth = defaults.object(forKey: "panelWidth") as? Double ?? 500
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        if usesKeychain, let json = Keychain.string(for: Self.elevenLabsTokenItem),
           let token = try? JSONDecoder().decode(ElevenLabsToken.self, from: Data(json.utf8)) {
            attachElevenLabsAccount(token)
        }
    }

    // MARK: Shortcuts

    var captureShortcut: KeyCombo? { didSet { Self.saveCombo(defaults, captureShortcut, "captureShortcut") } }
    var translateSelectionShortcut: KeyCombo? {
        didSet { Self.saveCombo(defaults, translateSelectionShortcut, "translateSelectionShortcut") }
    }
    var lookUpShortcut: KeyCombo? { didSet { Self.saveCombo(defaults, lookUpShortcut, "lookUpShortcut") } }
    var toneTypingShortcut: KeyCombo? { didSet { Self.saveCombo(defaults, toneTypingShortcut, "toneTypingShortcut") } }

    // MARK: Translation & display

    var translationEngine: TranslationEngine { didSet { defaults.set(translationEngine.rawValue, forKey: "translationEngine") } }
    var targetLanguage: TargetLanguage { didSet { defaults.set(targetLanguage.rawValue, forKey: "targetLanguage") } }
    var showHanViet: Bool { didSet { defaults.set(showHanViet, forKey: "showHanViet") } }
    var showPinyin: Bool { didSet { defaults.set(showPinyin, forKey: "showPinyin") } }
    var toneColors: Bool { didSet { defaults.set(toneColors, forKey: "toneColors") } }
    var showEnglish: Bool { didSet { defaults.set(showEnglish, forKey: "showEnglish") } }

    // MARK: Behaviour

    var autoCopyRecognizedText: Bool { didSet { defaults.set(autoCopyRecognizedText, forKey: "autoCopyRecognizedText") } }
    var autoSpeak: Bool { didSet { defaults.set(autoSpeak, forKey: "autoSpeak") } }
    /// A Dock icon (and a place in ⌘Tab) as well as the menu bar item.
    var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }

    /// Read at launch, before the app finishes starting, to choose the activation policy.
    nonisolated static func showsInDock(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "showInDock") as? Bool ?? true
    }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    var speechEngine: SpeechEngine { didSet { defaults.set(speechEngine.rawValue, forKey: "speechEngine") } }

    // MARK: Cloud voices (keys are stored in the Keychain)

    var azureKey: String { didSet { if usesKeychain { Keychain.set(azureKey, for: "azure-speech-key") } } }
    var azureRegion: String { didSet { defaults.set(azureRegion, forKey: "azureRegion") } }
    var azureMandarinVoice: String { didSet { defaults.set(azureMandarinVoice, forKey: "azureMandarinVoice") } }
    var azureTaiwanVoice: String { didSet { defaults.set(azureTaiwanVoice, forKey: "azureTaiwanVoice") } }
    var elevenLabsKey: String { didSet { if usesKeychain { Keychain.set(elevenLabsKey, for: "elevenlabs-api-key") } } }
    var elevenLabsVoiceID: String { didSet { defaults.set(elevenLabsVoiceID, forKey: "elevenLabsVoiceID") } }
    var elevenLabsVoiceName: String { didSet { defaults.set(elevenLabsVoiceName, forKey: "elevenLabsVoiceName") } }
    var elevenLabsModel: String { didSet { defaults.set(elevenLabsModel, forKey: "elevenLabsModel") } }

    var azureConfig: AzureSpeechConfig? {
        azureKey.isEmpty ? nil : AzureSpeechConfig(key: azureKey, region: azureRegion,
                                                   mandarinVoice: azureMandarinVoice, taiwanVoice: azureTaiwanVoice)
    }

    var elevenLabsConfig: ElevenLabsConfig? {
        elevenLabsAuth.map { ElevenLabsConfig(auth: $0, voiceID: elevenLabsVoiceID, modelID: elevenLabsModel) }
    }

    /// The signed-in account if there is one, else the API key.
    var elevenLabsAuth: ElevenLabsAuth? {
        if let elevenLabsAccount { return .account(elevenLabsAccount) }
        return elevenLabsKey.isEmpty ? nil : .apiKey(elevenLabsKey)
    }

    // MARK: ElevenLabs sign-in (tokens are stored in the Keychain)

    /// The account signed in with “Sign in with ElevenLabs”.
    private(set) var elevenLabsAccount: ElevenLabsAccount?
    var isSignedInToElevenLabs: Bool { elevenLabsAccount != nil }
    /// Called when the sign-in starts or ends — also when ElevenLabs ends it — so the speaker can be updated.
    @ObservationIgnored var onElevenLabsAccountChange: (() -> Void)?

    func signInToElevenLabs(with token: ElevenLabsToken) {
        if usesKeychain { Self.store(token) }
        attachElevenLabsAccount(token)
        onElevenLabsAccountChange?()
    }

    /// Signs out here, and on the server in the background.
    func signOutOfElevenLabs() {
        guard let account = elevenLabsAccount else { return }
        endElevenLabsSignIn()
        Task { await ElevenLabsOAuth.revoke(await account.token) }
    }

    /// The signed-in look, without an account (for the settings renderer).
    func showSignedInPreview() {
        attachElevenLabsAccount(ElevenLabsToken(accessToken: "preview", refreshToken: nil, expiresAt: .distantFuture, scope: ""),
                                refresher: { $0 })
    }

    private func attachElevenLabsAccount(_ token: ElevenLabsToken, refresher: @escaping ElevenLabsAccount.Refresher = ElevenLabsOAuth.refresh) {
        let usesKeychain = usesKeychain
        elevenLabsAccount = ElevenLabsAccount(token: token, refresher: refresher) { [weak self] token in
            if let token {
                if usesKeychain { Self.store(token) }
            } else {
                Task { @MainActor in self?.endElevenLabsSignIn() }
            }
        }
    }

    private func endElevenLabsSignIn() {
        guard elevenLabsAccount != nil else { return }
        elevenLabsAccount = nil
        if usesKeychain { Keychain.set(nil, for: Self.elevenLabsTokenItem) }
        onElevenLabsAccountChange?()
    }

    nonisolated private static let elevenLabsTokenItem = "elevenlabs-oauth-token"

    nonisolated private static func store(_ token: ElevenLabsToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        Keychain.set(String(decoding: data, as: UTF8.self), for: elevenLabsTokenItem)
    }
    var voiceIdentifier: String? { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    var toneTypingEnabled: Bool { didSet { defaults.set(toneTypingEnabled, forKey: "toneTypingEnabled") } }
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    var panelWidth: Double { didSet { defaults.set(panelWidth, forKey: "panelWidth") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    // MARK: Persistence helpers

    private static func loadCombo(_ defaults: UserDefaults, _ key: String, default fallback: KeyCombo?) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        if data.isEmpty { return nil } // explicitly cleared
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? fallback
    }

    private static func saveCombo(_ defaults: UserDefaults, _ combo: KeyCombo?, _ key: String) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(Data(), forKey: key)
        }
    }
}
