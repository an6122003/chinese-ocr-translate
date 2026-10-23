import Foundation

/// Why a cloud voice request failed.
public enum CloudVoiceError: LocalizedError, Sendable, Equatable {
    case missingKey
    case noVoice
    case unauthorized
    case missingPermission(String)
    case signInRejected
    case signInExpired
    case quotaExceeded
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No key or sign-in is set up."
        case .noVoice: "Choose a voice first."
        case .unauthorized: "The key was rejected — check the key (and region)."
        case .missingPermission(let message): message
        case .signInRejected: "ElevenLabs didn't accept the sign-in — sign out and in again, or use an API key."
        case .signInExpired: "The ElevenLabs sign-in has expired — sign in again in Settings › Speech."
        case .quotaExceeded: "The account's quota or rate limit has been reached."
        case .http(let code, let message): "The service returned HTTP \(code)\(message.isEmpty ? "" : ": \(message)")."
        case .badResponse: "The service returned an unexpected response."
        }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudVoiceError.badResponse }
        switch http.statusCode {
        case 200: return
        case 401, 403:
            let detail = serverDetail(data)
            if detail.status == "missing_permissions", let message = detail.message {
                throw CloudVoiceError.missingPermission(message)
            }
            throw CloudVoiceError.unauthorized
        case 402, 429: throw CloudVoiceError.quotaExceeded
        default:
            let message = serverDetail(data).message ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw CloudVoiceError.http(http.statusCode, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The status code and message of an error body: {"detail": {...}} at ElevenLabs, {"error": {...}} elsewhere.
    static func serverDetail(_ data: Data) -> (status: String?, message: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        if let detail = json["detail"] as? [String: Any] { return (detail["status"] as? String, detail["message"] as? String) }
        if let error = json["error"] as? [String: Any] { return (error["code"] as? String, error["message"] as? String) }
        return (nil, json["message"] as? String)
    }
}

/// Synthesized speech: MP3 data and, when the service provides it, when each character starts.
public struct SpeechAudio: Sendable {
    public let data: Data
    /// Start time (seconds) of each Character of the input text, when known.
    public let characterStartTimes: [TimeInterval]?
}

// MARK: - Microsoft Azure

/// Settings for Azure AI Speech (the Xiaoxiao/Yunxi… neural voices). The free F0 tier includes 500,000
/// characters a month.
public struct AzureSpeechConfig: Sendable, Equatable {
    public var key: String
    public var region: String
    public var mandarinVoice: String
    public var taiwanVoice: String

    public init(key: String, region: String, mandarinVoice: String, taiwanVoice: String) {
        self.key = key
        self.region = region
        self.mandarinVoice = mandarinVoice
        self.taiwanVoice = taiwanVoice
    }
}

public struct AzureVoice: Sendable, Hashable, Identifiable, Codable {
    public let shortName: String
    public let localName: String
    public let gender: String
    public let locale: String
    public var id: String { shortName }

    public init(shortName: String, localName: String, gender: String, locale: String) {
        self.shortName = shortName
        self.localName = localName
        self.gender = gender
        self.locale = locale
    }

    /// "Xiaoxiao 晓晓 · Female"
    public var label: String {
        let name = shortName.split(separator: "-").last.map { String($0).replacingOccurrences(of: "Neural", with: "") } ?? shortName
        return "\(name) \(localName == name ? "" : localName) · \(gender)".replacingOccurrences(of: "  ", with: " ")
    }
}

public enum AzureSpeech {
    /// Regions with the Speech service; Southeast Asia (Singapore) is closest to Vietnam.
    public static let regions = [
        "southeastasia", "eastasia", "japaneast", "japanwest", "koreacentral", "australiaeast", "centralindia",
        "jioindiawest", "eastus", "eastus2", "centralus", "northcentralus", "southcentralus", "westcentralus",
        "westus", "westus2", "westus3", "canadacentral", "brazilsouth", "westeurope", "northeurope", "uksouth",
        "francecentral", "germanywestcentral", "italynorth", "norwayeast", "swedencentral", "switzerlandnorth",
        "switzerlandwest", "uaenorth", "qatarcentral", "southafricanorth",
    ]

    /// The region a key belongs to. Azure answers 401 when a key is used in another region — the most common
    /// setup mistake — so try them all at once (listing voices costs no characters).
    public static func region(for key: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for region in regions {
                group.addTask {
                    let config = AzureSpeechConfig(key: key, region: region, mandarinVoice: "", taiwanVoice: "")
                    return (try? await voices(config: config)) == nil ? nil : region
                }
            }
            for await case let region? in group {
                group.cancelAll()
                return region
            }
            return nil
        }
    }

    /// A short list shown before a key is entered (the full list is fetched from the service afterwards).
    public static let recommendedVoices: [AzureVoice] = [
        AzureVoice(shortName: "zh-CN-XiaoxiaoNeural", localName: "晓晓", gender: "Female", locale: "zh-CN"),
        AzureVoice(shortName: "zh-CN-XiaoyiNeural", localName: "晓伊", gender: "Female", locale: "zh-CN"),
        AzureVoice(shortName: "zh-CN-XiaochenNeural", localName: "晓辰", gender: "Female", locale: "zh-CN"),
        AzureVoice(shortName: "zh-CN-YunxiNeural", localName: "云希", gender: "Male", locale: "zh-CN"),
        AzureVoice(shortName: "zh-CN-YunjianNeural", localName: "云健", gender: "Male", locale: "zh-CN"),
        AzureVoice(shortName: "zh-CN-YunyangNeural", localName: "云扬", gender: "Male", locale: "zh-CN"),
        AzureVoice(shortName: "zh-TW-HsiaoChenNeural", localName: "曉臻", gender: "Female", locale: "zh-TW"),
        AzureVoice(shortName: "zh-TW-HsiaoYuNeural", localName: "曉雨", gender: "Female", locale: "zh-TW"),
        AzureVoice(shortName: "zh-TW-YunJheNeural", localName: "雲哲", gender: "Male", locale: "zh-TW"),
    ]

    public static func synthesize(_ text: String, voice: String, speed: Double, config: AzureSpeechConfig) async throws -> SpeechAudio {
        guard !config.key.isEmpty else { throw CloudVoiceError.missingKey }
        guard let url = URL(string: "https://\(config.region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw CloudVoiceError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue(config.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-96kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("HanLens", forHTTPHeaderField: "User-Agent")
        let locale = voice.split(separator: "-").prefix(2).joined(separator: "-")
        let percent = Int(((speed - 1) * 100).rounded())
        let rate = (percent >= 0 ? "+" : "") + "\(percent)%"
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(locale)'>"
            + "<voice name='\(voice)'><prosody rate='\(rate)'>\(xmlEscaped(text))</prosody></voice></speak>"
        request.httpBody = Data(ssml.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudVoiceError.check(response, data)
        guard data.count > 256 else { throw CloudVoiceError.badResponse }
        return SpeechAudio(data: data, characterStartTimes: nil)
    }

    /// Chinese voices available in the configured region (Mandarin, Taiwanese Mandarin, Cantonese, dialects).
    public static func voices(config: AzureSpeechConfig) async throws -> [AzureVoice] {
        guard !config.key.isEmpty else { throw CloudVoiceError.missingKey }
        guard let url = URL(string: "https://\(config.region).tts.speech.microsoft.com/cognitiveservices/voices/list") else {
            throw CloudVoiceError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(config.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudVoiceError.check(response, data)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CloudVoiceError.badResponse }
        return items.compactMap { item -> AzureVoice? in
            guard let shortName = item["ShortName"] as? String, let locale = item["Locale"] as? String,
                  locale.hasPrefix("zh") || locale.hasPrefix("yue") || locale.hasPrefix("wuu") else { return nil }
            return AzureVoice(shortName: shortName, localName: item["LocalName"] as? String ?? "",
                              gender: item["Gender"] as? String ?? "", locale: locale)
        }
        .sorted { ($0.locale, $0.shortName) < ($1.locale, $1.shortName) }
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - ElevenLabs

public struct ElevenLabsConfig: Sendable, Equatable {
    public var auth: ElevenLabsAuth
    public var voiceID: String
    public var modelID: String

    public init(auth: ElevenLabsAuth, voiceID: String, modelID: String) {
        self.auth = auth
        self.voiceID = voiceID
        self.modelID = modelID
    }
}

/// The account's plan and credit use in the current billing period.
public struct ElevenLabsUsage: Sendable, Equatable {
    public let tier: String
    public let used: Int
    public let limit: Int
    public let resetsAt: Date?
}

public struct ElevenLabsVoice: Sendable, Hashable, Identifiable {
    public let voiceID: String
    public let name: String
    public let detail: String
    /// Set for voices from the shared Voice Library (needed to add them to the account).
    public let publicOwnerID: String?
    public let previewURL: URL?
    public let isAddedByUser: Bool
    /// One of ElevenLabs' built-in voices — English speakers, so their Chinese has an accent.
    public var isPremade = false
    public var id: String { voiceID }
}

public enum ElevenLabsSpeech {
    public static let models: [(id: String, name: String)] = [
        ("eleven_multilingual_v2", "Multilingual v2 — most consistent"),
        ("eleven_v4", "Eleven v4 — newest, most expressive"),
        ("eleven_v4_turbo", "Eleven v4 Turbo — faster"),
        ("eleven_flash_v2_5", "Flash v2.5 — fastest, half the credits"),
    ]

    static let base = "https://api.elevenlabs.io/v1"

    public static func synthesize(_ text: String, speed: Double, config: ElevenLabsConfig) async throws -> SpeechAudio {
        guard !config.voiceID.isEmpty else { throw CloudVoiceError.noVoice }
        guard let url = URL(string: "\(base)/text-to-speech/\(config.voiceID)/with-timestamps?output_format=mp3_44100_128") else {
            throw CloudVoiceError.badResponse
        }
        var body: [String: Any] = [
            "text": text,
            "model_id": config.modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": min(1.2, max(0.7, speed))],
        ]
        // language_code pins Mandarin (avoids kanji-only text being read as Japanese); v2 doesn't accept it.
        if config.modelID != "eleven_multilingual_v2" { body["language_code"] = "zh" }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request, auth: config.auth)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = json["audio_base64"] as? String, let audio = Data(base64Encoded: base64), audio.count > 256
        else { throw CloudVoiceError.badResponse }
        return SpeechAudio(data: audio, characterStartTimes: characterTimes(json["alignment"] as? [String: Any], text: text))
    }

    /// Per-Character start times, when the alignment lines up with the text.
    static func characterTimes(_ alignment: [String: Any]?, text: String) -> [TimeInterval]? {
        guard let alignment, let characters = alignment["characters"] as? [String],
              let starts = alignment["character_start_times_seconds"] as? [Double],
              characters.count == starts.count, characters.joined() == text, characters.count == text.count
        else { return nil }
        return starts
    }

    /// Voices in the user's account. A sign-in isn't allowed to list them, so it gets the premade voices instead.
    public static func myVoices(auth: ElevenLabsAuth) async throws -> [ElevenLabsVoice] {
        let json: [String: Any]
        if case .account = auth {
            json = try await getJSON("\(base)/voices", auth: nil)
        } else {
            json = try await getJSON("\(base)/voices", auth: auth)
        }
        let voices = json["voices"] as? [[String: Any]] ?? []
        return voices.compactMap { voice in
            guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String else { return nil }
            let labels = voice["labels"] as? [String: Any] ?? [:]
            let detail = [labels["accent"] as? String, labels["language"] as? String, voice["category"] as? String]
                .compactMap { $0 }.joined(separator: " · ")
            return ElevenLabsVoice(voiceID: id, name: name, detail: detail, publicOwnerID: nil,
                                   previewURL: (voice["preview_url"] as? String).flatMap(URL.init(string:)), isAddedByUser: true,
                                   isPremade: voice["category"] as? String == "premade")
        }
    }

    /// Popular native Mandarin voices from the shared Voice Library. The library is public; with credentials the
    /// answer also says which voices the account has already added.
    public static func mandarinLibraryVoices(auth: ElevenLabsAuth?) async throws -> [ElevenLabsVoice] {
        let library = "\(base)/shared-voices?language=zh"
        if let auth, let json = try? await getJSON(library + "&page_size=40&sort=usage_character_count_1y", auth: auth) {
            return libraryVoices(json)
        }
        // Without an account that may browse the library, ElevenLabs returns only the top three voices per ordering,
        // so combine a few orderings.
        var seen = Set<String>()
        var voices: [ElevenLabsVoice] = []
        for sort in ["usage_character_count_1y", "cloned_by_count", "trending", "created_date"] {
            guard let json = try? await getJSON(library + "&page_size=3&sort=\(sort)", auth: nil) else { continue }
            voices += libraryVoices(json).filter { seen.insert($0.voiceID).inserted }
        }
        guard !voices.isEmpty else { throw CloudVoiceError.badResponse }
        return voices
    }

    private static func libraryVoices(_ json: [String: Any]) -> [ElevenLabsVoice] {
        let voices = json["voices"] as? [[String: Any]] ?? []
        return voices.compactMap { voice in
            guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String,
                  let owner = voice["public_owner_id"] as? String else { return nil }
            var detail = [voice["gender"] as? String, voice["accent"] as? String, voice["use_case"] as? String]
                .compactMap { $0?.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")
            // Some library voices charge a multiple of the normal credits — say so.
            if let rate = voice["rate"] as? Double, rate > 1 {
                detail += " · ×\(rate.formatted(.number.precision(.fractionLength(0...1)))) credits"
            }
            return ElevenLabsVoice(voiceID: id, name: name, detail: detail, publicOwnerID: owner,
                                   previewURL: (voice["preview_url"] as? String).flatMap(URL.init(string:)),
                                   isAddedByUser: voice["is_added_by_user"] as? Bool ?? false)
        }
    }

    /// Adds a shared library voice to the account; returns the voice ID to use.
    public static func add(_ voice: ElevenLabsVoice, auth: ElevenLabsAuth) async throws -> String {
        guard let owner = voice.publicOwnerID, let url = URL(string: "\(base)/voices/add/\(owner)/\(voice.voiceID)") else {
            return voice.voiceID
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["new_name": voice.name])
        let data = try await send(request, auth: auth)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["voice_id"] as? String ?? voice.voiceID
    }

    /// Plan and credits used this billing period.
    public static func usage(auth: ElevenLabsAuth) async throws -> ElevenLabsUsage {
        let json = try await getJSON("\(base)/user/subscription", auth: auth)
        guard let used = (json["character_count"] as? NSNumber)?.intValue,
              let limit = (json["character_limit"] as? NSNumber)?.intValue else { throw CloudVoiceError.badResponse }
        return ElevenLabsUsage(tier: json["tier"] as? String ?? "", used: used, limit: limit,
                               resetsAt: (json["next_character_count_reset_unix"] as? NSNumber)
                                   .map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    private static func getJSON(_ address: String, auth: ElevenLabsAuth?) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw CloudVoiceError.badResponse }
        let data = try await send(URLRequest(url: url, timeoutInterval: 15), auth: auth)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudVoiceError.badResponse }
        return json
    }

    /// Sends a request with the account's credentials (none: a public endpoint).
    private static func send(_ request: URLRequest, auth: ElevenLabsAuth?) async throws -> Data {
        var request = request
        switch auth {
        case .apiKey(let key):
            guard !key.isEmpty else { throw CloudVoiceError.missingKey }
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .account(let account):
            return try await send(request, account: account)
        case nil:
            break
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudVoiceError.check(response, data)
        return data
    }

    /// A signed-in account's request; a token refused before it expired gets one refresh and retry.
    private static func send(_ request: URLRequest, account: ElevenLabsAccount) async throws -> Data {
        func perform(_ token: String) async throws -> (Data, URLResponse) {
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await URLSession.shared.data(for: request)
        }
        let token = try await account.accessToken()
        var (data, response) = try await perform(token)
        if (response as? HTTPURLResponse)?.statusCode == 401, CloudVoiceError.serverDetail(data).status != "missing_permissions" {
            (data, response) = try await perform(try await account.accessToken(rejected: token))
        }
        do {
            try CloudVoiceError.check(response, data)
        } catch CloudVoiceError.unauthorized {
            throw CloudVoiceError.signInRejected
        }
        return data
    }
}
