import AVFoundation
import Foundation
import Testing
@testable import HanziKit

@Suite("Speech")
struct SpeakerTests {
    @Test func shortTextIsOneChunk() {
        let chunks = Speaker.chunks(of: "你好！")
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "你好！")
        #expect(chunks[0].range == NSRange(location: 0, length: 3))
    }

    @Test func longTextSplitsAtSentenceEndsAndCoversEverything() {
        let sentence = "我们今天去图书馆学习中文，然后一起吃饭。"
        let text = String(repeating: sentence, count: 15)
        let chunks = Speaker.chunks(of: text, limit: 60)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 60 })
        #expect(chunks.dropLast().allSatisfy { $0.text.hasSuffix("。") })
        #expect(chunks.map(\.text).joined() == text)
        // Ranges are contiguous UTF-16 ranges of the original text.
        var location = 0
        for chunk in chunks {
            #expect(chunk.range.location == location)
            #expect((text as NSString).substring(with: chunk.range) == chunk.text)
            location += chunk.range.length
        }
    }

    @Test func timingWeightsGrowWithSyllablesAndPauses() {
        let weights = Speaker.timingWeights("你好，世界。")
        #expect(weights.count == 6)
        #expect(zip(weights, weights.dropFirst()).allSatisfy { $0.end < $1.end })
        #expect(weights[0].end == 1)                 // one syllable
        #expect(weights[2].end - weights[1].end < 1)  // the comma is a short pause
    }

    @Test func roboticVoicesAreNeverChosen() {
        let voices = Speaker.chineseVoices()
        #expect(!voices.contains(where: Speaker.isNovelty))
        if let best = Speaker.bestVoice(for: "你好") {
            #expect(!Speaker.isNovelty(best))
        }
    }

    /// End to end against Google (skipped quietly when offline): the response decodes as audio.
    @Test func naturalVoiceAudioDecodes() async throws {
        guard let data = await Speaker.fetchAudio("你好，我们一起学习中文吧。", language: "zh-CN", slow: false) else { return }
        let player = try AVAudioPlayer(data: data)
        #expect(player.duration > 1)
    }
}

@Suite("Cloud voices")
struct CloudVoiceTests {
    private func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func httpStatusesMapToClearErrors() {
        #expect(throws: CloudVoiceError.unauthorized) { try CloudVoiceError.check(response(401), Data()) }
        #expect(throws: CloudVoiceError.quotaExceeded) { try CloudVoiceError.check(response(429), Data()) }
        let body = Data(#"{"detail":{"status":"voice_not_found","message":"A voice with that ID does not exist."}}"#.utf8)
        #expect(throws: CloudVoiceError.http(400, "A voice with that ID does not exist.")) { try CloudVoiceError.check(response(400), body) }
        #expect(throws: Never.self) { try CloudVoiceError.check(response(200), Data()) }
    }

    @Test func ssmlTextIsEscaped() {
        #expect(AzureSpeech.xmlEscaped("<你好> & '再见'") == "&lt;你好&gt; &amp; &apos;再见&apos;")
    }

    @Test func elevenLabsAlignmentMapsToCharacters() {
        let alignment: [String: Any] = [
            "characters": ["你", "好", "！"],
            "character_start_times_seconds": [0.0, 0.21, 0.42],
            "character_end_times_seconds": [0.21, 0.42, 0.5],
        ]
        #expect(ElevenLabsSpeech.characterTimes(alignment, text: "你好！") == [0.0, 0.21, 0.42])
        #expect(ElevenLabsSpeech.characterTimes(alignment, text: "你好") == nil) // misaligned → estimate instead
        #expect(ElevenLabsSpeech.characterTimes(nil, text: "你好！") == nil)
    }

    @Test func azureRegionsAreUnique() {
        #expect(Set(AzureSpeech.regions).count == AzureSpeech.regions.count)
        #expect(AzureSpeech.regions.first == "southeastasia")
    }

    @Test func azureVoiceLabels() {
        let voice = AzureVoice(shortName: "zh-CN-XiaoxiaoNeural", localName: "晓晓", gender: "Female", locale: "zh-CN")
        #expect(voice.label == "Xiaoxiao 晓晓 · Female")
    }
}
