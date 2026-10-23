import AVFoundation
import Foundation
import Observation

/// Where speech comes from.
public enum SpeechEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Microsoft Azure neural voices (Xiaoxiao, Yunxi…) — needs an Azure Speech key.
    case azure
    /// ElevenLabs voices (native Mandarin voices from its library) — needs an ElevenLabs sign-in or API key.
    case elevenLabs
    /// Google's free online voice.
    case natural
    /// Apple voices installed on this device (offline; quality depends on which voices are downloaded).
    case system

    public var id: String { rawValue }
}

/// Mandarin text-to-speech, plus the range currently being spoken (used to highlight words karaoke-style).
@MainActor
@Observable
public final class Speaker: NSObject {
    public static let shared = Speaker()

    /// Range (in UTF-16 units of the spoken string) being spoken, nil when idle.
    public private(set) var spokenRange: NSRange?
    public private(set) var isSpeaking = false
    /// The text currently being spoken (so views can tell whether a range refers to them).
    public private(set) var spokenText: String?

    public var engine: SpeechEngine = .natural
    /// Credentials and voices for the cloud engines (set by the app; nil = not configured).
    public var azure: AzureSpeechConfig?
    public var elevenLabs: ElevenLabsConfig?
    /// The most recent cloud-voice failure, e.g. a rejected key (cleared after a successful request).
    public private(set) var lastError: String?
    /// Preferred Apple voice; nil picks the best installed Mandarin voice.
    public var voiceIdentifier: String?
    /// Speed on AVSpeech's scale, where 0.5 is normal.
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    // Apple voices
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Callbacks are matched by utterance identity, so a cancelled utterance can't end a newer one.
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?
    /// Offset of the utterance inside `spokenText` (non-zero when the Apple voice takes over mid-way).
    @ObservationIgnored private var utteranceOffset = 0

    // Natural (online) voice
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playback: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private let audioCache = NSCache<NSString, CachedAudio>()

    override public init() {
        super.init()
        synthesizer.delegate = self
        audioCache.countLimit = 200
    }

    public func speak(_ text: String, slow: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        spokenText = text
        isSpeaking = true
        if engine == .system {
            speakWithAppleVoice(text, slow: slow, from: 0)
        } else {
            speakOnline(text, slow: slow, providers: providerChain())
        }
    }

    /// The chosen cloud voice (if configured), then Google; an Apple voice is the last resort.
    private func providerChain() -> [Provider] {
        var chain: [Provider] = []
        if engine == .azure, let azure, !azure.key.isEmpty { chain.append(.azure) }
        if engine == .elevenLabs, let elevenLabs, !elevenLabs.voiceID.isEmpty { chain.append(.elevenLabs) }
        chain.append(.google)
        return chain
    }

    enum Provider: String, Sendable {
        case azure, elevenLabs, google

        var name: String {
            switch self {
            case .azure: "Azure"
            case .elevenLabs: "ElevenLabs"
            case .google: "Google"
            }
        }

        /// Google's endpoint takes ~200 characters; the others take long passages (fewer seams in the prosody).
        var chunkLimit: Int { self == .google ? 180 : 600 }
    }

    public func stop() {
        onlineTask?.cancel()
        onlineTask = nil
        stopPlayback()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        currentUtterance = nil
        isSpeaking = false
        spokenRange = nil
        spokenText = nil
    }

    // MARK: - Online voices

    private func speakOnline(_ text: String, slow: Bool, providers: [Provider], from offset: Int = 0) {
        guard let provider = providers.first else {
            speakWithAppleVoice(text, slow: slow, from: offset)
            return
        }
        let remainder = offset > 0 ? (text as NSString).substring(from: offset) : text
        let chunks = Self.chunks(of: remainder, limit: provider.chunkLimit).map {
            Chunk(text: $0.text, range: NSRange(location: $0.range.location + offset, length: $0.range.length))
        }
        let traditional = CJK.looksTraditional(text) == true
        onlineTask = Task { [weak self] in
            guard let self else { return }
            var next: Task<Result<SpeechAudio, any Error>, Never>? = Task {
                await self.audio(for: chunks[0].text, provider: provider, traditional: traditional, slow: slow)
            }
            for (index, chunk) in chunks.enumerated() {
                guard let pending = next else { return }
                let result = await pending.value
                // Fetch the following chunk while this one plays.
                next = index + 1 < chunks.count
                    ? Task { await self.audio(for: chunks[index + 1].text, provider: provider, traditional: traditional, slow: slow) }
                    : nil
                guard !Task.isCancelled, self.spokenText == text else { return }
                guard case .success(let audio) = result, let player = try? AVAudioPlayer(data: audio.data) else {
                    // This service failed (no network, bad key, quota…): the next one continues from here.
                    if case .failure(let error) = result, provider != .google {
                        self.lastError = "\(provider.name): \(error.localizedDescription)"
                    }
                    next?.cancel()
                    self.speakOnline(text, slow: slow, providers: Array(providers.dropFirst()), from: chunk.range.location)
                    return
                }
                if provider != .google { self.lastError = nil }
                await self.play(player, chunk: chunk, rate: self.playerRate(provider: provider, slow: slow),
                                characterTimes: audio.characterStartTimes)
                guard !Task.isCancelled, self.spokenText == text else { return }
            }
            self.finish()
        }
    }

    /// Speed as a multiple of normal (the AVSpeech rate scale has 0.5 as normal).
    private var speedFactor: Double { Double(rate / AVSpeechUtteranceDefaultSpeechRate) }

    /// The speed requested from the service itself (natural-sounding), per provider.
    private func serverSpeed(provider: Provider, slow: Bool) -> Double {
        let desired = speedFactor * (slow ? 0.7 : 1)
        switch provider {
        case .azure: return min(2, max(0.5, desired))
        case .elevenLabs: return min(1.2, max(0.7, desired))
        case .google: return 1
        }
    }

    /// Whatever the service couldn't do itself is made up for at playback.
    private func playerRate(provider: Provider, slow: Bool) -> Float {
        switch provider {
        case .google:
            return Float(min(2, max(0.5, speedFactor * (slow ? 0.85 : 1))))
        case .azure, .elevenLabs:
            let desired = speedFactor * (slow ? 0.7 : 1)
            return Float(min(2, max(0.5, desired / serverSpeed(provider: provider, slow: slow))))
        }
    }

    /// Cached audio for one chunk.
    private func audio(for text: String, provider: Provider, traditional: Bool, slow: Bool) async -> Result<SpeechAudio, any Error> {
        let speed = serverSpeed(provider: provider, slow: slow)
        let voice: String
        switch provider {
        case .azure: voice = (traditional ? azure?.taiwanVoice : azure?.mandarinVoice) ?? ""
        case .elevenLabs: voice = "\(elevenLabs?.voiceID ?? "")/\(elevenLabs?.modelID ?? "")"
        case .google: voice = traditional ? "zh-TW" : "zh-CN"
        }
        let key = "\(provider.rawValue)|\(voice)|\(speed)|\(slow)|\(text)" as NSString
        if let cached = audioCache.object(forKey: key) { return .success(cached.audio) }
        do {
            let audio: SpeechAudio
            switch provider {
            case .azure:
                guard let azure else { throw CloudVoiceError.missingKey }
                audio = try await AzureSpeech.synthesize(text, voice: voice, speed: speed, config: azure)
            case .elevenLabs:
                guard let elevenLabs else { throw CloudVoiceError.missingKey }
                audio = try await ElevenLabsSpeech.synthesize(text, speed: speed, config: elevenLabs)
            case .google:
                guard let data = await Self.fetchAudio(text, language: voice, slow: slow) else { throw CloudVoiceError.badResponse }
                audio = SpeechAudio(data: data, characterStartTimes: nil)
            }
            audioCache.setObject(CachedAudio(audio), forKey: key)
            return .success(audio)
        } catch {
            return .failure(error)
        }
    }

    /// Google Translate's text-to-speech endpoint (the voice behind its speaker button).
    nonisolated static func fetchAudio(_ text: String, language: String, slow: Bool) async -> Data? {
        var components = URLComponents(string: "https://translate.google.com/translate_tts")!
        components.queryItems = [
            URLQueryItem(name: "ie", value: "UTF-8"), URLQueryItem(name: "client", value: "tw-ob"),
            URLQueryItem(name: "tl", value: language), URLQueryItem(name: "q", value: text),
        ] + (slow ? [URLQueryItem(name: "ttsspeed", value: "0.24")] : [])
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 512
        else { return nil }
        return data
    }

    /// Plays one chunk to the end (or until stopped), highlighting words as it goes.
    private func play(_ player: AVAudioPlayer, chunk: Chunk, rate: Float, characterTimes: [TimeInterval]?) async {
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        self.player = player
        let weights = Self.timingWeights(chunk.text)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHighlight(chunk: chunk, weights: weights, characterTimes: characterTimes) }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps highlighting while a menu is open
        progressTimer = timer
        await withCheckedContinuation { continuation in
            playback = continuation
            if !player.play() { resumePlayback() }
        }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateHighlight(chunk: Chunk, weights: [(utf16Offset: Int, utf16Length: Int, end: Double)],
                                 characterTimes: [TimeInterval]?) {
        guard let player, player.duration > 0, !weights.isEmpty else { return }
        let unit: (utf16Offset: Int, utf16Length: Int, end: Double)?
        if let characterTimes, characterTimes.count == weights.count {
            // Exact timing from the service (ElevenLabs): the last character that has started.
            let index = characterTimes.lastIndex { $0 <= player.currentTime } ?? 0
            unit = weights[index]
        } else {
            // Estimate: Google's audio starts with a short pause; aim slightly ahead so highlights don't lag.
            guard let total = weights.last?.end, total > 0 else { return }
            let progress = min(1, max(0, (player.currentTime - 0.12) / max(player.duration - 0.25, 0.1))) * total
            unit = weights.first { $0.end >= progress }
        }
        guard let unit else { return }
        let range = NSRange(location: chunk.range.location + unit.utf16Offset, length: unit.utf16Length)
        if spokenRange != range { spokenRange = range }
    }

    private func resumePlayback() {
        playback?.resume()
        playback = nil
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        resumePlayback()
    }

    // MARK: Chunking & timing

    struct Chunk: Sendable {
        let text: String
        /// Location in the full text, in UTF-16 units.
        let range: NSRange
    }

    /// Splits text into pieces the online voice accepts (≤ ~180 characters), preferably at sentence ends,
    /// then at commas.
    nonisolated static func chunks(of text: String, limit: Int = 180) -> [Chunk] {
        var chunks: [Chunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.endIndex
            if text.distance(from: start, to: text.endIndex) > limit {
                let window = start..<text.index(start, offsetBy: limit)
                let sentenceEnd = text[window].lastIndex { "。！？!?；;\n…".contains($0) }
                let clauseEnd = text[window].lastIndex { "，、,：:".contains($0) }
                if let cut = sentenceEnd ?? clauseEnd, cut > start {
                    end = text.index(after: cut)
                } else {
                    end = window.upperBound
                }
            }
            let piece = String(text[start..<end])
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(Chunk(text: piece, range: NSRange(start..<end, in: text)))
            }
            start = end
        }
        return chunks.isEmpty ? [Chunk(text: text, range: NSRange(text.startIndex..., in: text))] : chunks
    }

    /// Approximate speaking time per character (a syllable each; pauses at punctuation; Latin words shorter),
    /// as cumulative weights — used to estimate which word is being spoken.
    nonisolated static func timingWeights(_ text: String) -> [(utf16Offset: Int, utf16Length: Int, end: Double)] {
        var result: [(Int, Int, Double)] = []
        var offset = 0
        var total = 0.0
        for character in text {
            let weight: Double
            if CJK.isHan(character) {
                weight = 1
            } else if CJK.isCJKPunctuation(character) || ",.;:!?".contains(character) {
                weight = "。！？.!?".contains(character) ? 1.2 : 0.6
            } else if character.isWhitespace {
                weight = 0.1
            } else {
                weight = 0.35
            }
            total += weight
            let length = character.utf16.count
            result.append((offset, length, total))
            offset += length
        }
        return result
    }

    // MARK: - Apple voices

    private func speakWithAppleVoice(_ text: String, slow: Bool, from utf16Offset: Int) {
        let remaining = utf16Offset > 0 ? String((text as NSString).substring(from: utf16Offset)) : text
        let utterance = AVSpeechUtterance(string: remaining)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.bestVoice(for: text)
        utterance.rate = slow ? max(AVSpeechUtteranceMinimumSpeechRate, rate * 0.7) : rate
        utterance.preUtteranceDelay = 0
        currentUtterance = ObjectIdentifier(utterance)
        utteranceOffset = utf16Offset
        synthesizer.speak(utterance)
    }

    /// Apple's old Eloquence voices (Eddy, Flo, Grandma…) and the novelty voices sound robotic in Chinese;
    /// they're never chosen automatically or offered in Settings.
    nonisolated public static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.hasPrefix("com.apple.eloquence.") || voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    /// Installed Mandarin (mainland, Taiwan) and Cantonese voices worth using, best first:
    /// Premium > Enhanced > compact > super-compact, mainland Mandarin first.
    nonisolated public static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 30
            case .enhanced: return 20
            default: return voice.identifier.contains("super-compact") ? 0 : 10
            }
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { ($0.language.hasPrefix("zh") || $0.language.hasPrefix("yue")) && !isNovelty($0) }
            .sorted { lhs, rhs in
                if rank(lhs) != rank(rhs) { return rank(lhs) > rank(rhs) }
                if lhs.language != rhs.language { return lhs.language == "zh-CN" }
                return lhs.name < rhs.name
            }
    }

    /// Whether a Premium or Enhanced Mandarin voice is installed (Apple's natural-sounding voices).
    nonisolated public static var hasHighQualityAppleVoice: Bool {
        chineseVoices().contains { $0.language.hasPrefix("zh") && $0.quality != .default }
    }

    /// The best voice for the text's script: zh-TW for traditional text, zh-CN otherwise.
    nonisolated public static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let language = CJK.looksTraditional(text) == true ? "zh-TW" : "zh-CN"
        let voices = chineseVoices()
        return voices.first { $0.language == language }
            ?? voices.first { $0.language.hasPrefix("zh") }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                              utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.currentUtterance == id else { return }
            self.spokenRange = NSRange(location: characterRange.location + self.utteranceOffset, length: characterRange.length)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if self.currentUtterance == id { self.finish() }
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if self.currentUtterance == id { self.finish() }
        }
    }
}

extension Speaker: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.player = nil
            self.resumePlayback()
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

/// NSCache needs a class.
final class CachedAudio: Sendable {
    let audio: SpeechAudio
    init(_ audio: SpeechAudio) { self.audio = audio }
}
