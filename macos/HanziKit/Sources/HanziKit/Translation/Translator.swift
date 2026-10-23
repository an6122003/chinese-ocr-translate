import Foundation
import Translation

/// Which service produced a translation.
public enum TranslationEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case google
    case apple

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: "Google Translate"
        case .apple: "Apple (on-device)"
        }
    }
}

public struct TranslationOutput: Sendable, Equatable {
    public var text: String
    public var engine: TranslationEngine
}

public enum TranslationFailure: LocalizedError, Sendable {
    case emptyInput
    case badResponse
    case offlineModelMissing
    case allEnginesFailed([String])

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "Nothing to translate."
        case .badResponse: "The translation service returned an unexpected response."
        case .offlineModelMissing: "The on-device Chinese → Vietnamese model isn't downloaded yet."
        case .allEnginesFailed(let reasons): "Translation failed: " + reasons.joined(separator: "; ")
        }
    }
}

/// Target languages supported by the UI.
public enum TargetLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case vietnamese = "vi"
    case english = "en"

    public var id: String { rawValue }
    public var displayName: String { self == .vietnamese ? "Tiếng Việt" : "English" }
}

/// Translates Chinese text with Google (online) and/or Apple's Translation framework (on-device),
/// falling back from one to the other.
public struct ChineseTranslator: Sendable {
    public var preferred: TranslationEngine
    public var allowFallback: Bool
    public var google: GoogleTranslator
    public var apple: AppleTranslator

    public init(preferred: TranslationEngine = .google, allowFallback: Bool = true,
                google: GoogleTranslator = GoogleTranslator(), apple: AppleTranslator = AppleTranslator()) {
        self.preferred = preferred
        self.allowFallback = allowFallback
        self.google = google
        self.apple = apple
    }

    public func translate(_ text: String, to target: TargetLanguage) async throws -> TranslationOutput {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationFailure.emptyInput }
        let traditional = CJK.looksTraditional(text) ?? false

        let order: [TranslationEngine] = allowFallback
            ? [preferred] + TranslationEngine.allCases.filter { $0 != preferred }
            : [preferred]
        var reasons: [String] = []
        for engine in order {
            do {
                try Task.checkCancellation()
                switch engine {
                case .google:
                    // Non-Chinese text (an English caption picked up by OCR) is auto-detected instead.
                    let source = CJK.containsHan(text) ? (traditional ? "zh-TW" : "zh-CN") : "auto"
                    let result = try await google.translate(text, from: source, to: target.rawValue)
                    return TranslationOutput(text: result, engine: .google)
                case .apple:
                    let result = try await apple.translate(text, traditional: traditional, to: target.rawValue)
                    return TranslationOutput(text: result, engine: .apple)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append("\(engine.displayName): \(error.localizedDescription)")
            }
        }
        throw TranslationFailure.allEnginesFailed(reasons)
    }
}

// MARK: - Google

/// Google Translate via the public `translate_a/single?client=gtx` endpoint (no API key).
/// The Windows version used deep_translator's HTML scraping, which no longer returns results.
public struct GoogleTranslator: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func translate(_ text: String, from source: String = "auto", to target: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            .init(name: "client", value: "gtx"), .init(name: "sl", value: source),
            .init(name: "tl", value: target), .init(name: "dt", value: "t"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("q=" + Self.formEncode(text)).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationFailure.badResponse
        }
        return try Self.parse(data)
    }

    /// Strict application/x-www-form-urlencoded value encoding (only unreserved characters stay literal).
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Response shape: `[[["dịch 1","nguồn 1",…],["dịch 2","nguồn 2",…]], null, "zh-CN", …]`.
    static func parse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any]
        else { throw TranslationFailure.badResponse }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { throw TranslationFailure.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple

/// Apple's on-device Translation framework. Works offline once the language pair is downloaded
/// (the app offers the download in Settings).
public struct AppleTranslator: Sendable {
    public init() {}

    public static func sourceLanguage(traditional: Bool) -> Locale.Language {
        Locale.Language(identifier: traditional ? "zh-Hant" : "zh-Hans")
    }

    /// Whether the Chinese → `target` model is installed, downloadable, or unsupported.
    public static func status(to target: String, traditional: Bool = false) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: sourceLanguage(traditional: traditional),
                                            to: Locale.Language(identifier: target))
    }

    public func translate(_ text: String, traditional: Bool, to target: String) async throws -> String {
        let source = Self.sourceLanguage(traditional: traditional)
        let targetLanguage = Locale.Language(identifier: target)
        guard await Self.status(to: target, traditional: traditional) == .installed else {
            throw TranslationFailure.offlineModelMissing
        }
        let session = TranslationSession(installedSource: source, target: targetLanguage)
        return try await session.translate(text).targetText
    }
}
