import Testing
@testable import HanziKit

@Suite("Pinyin tone marks")
struct ToneMarkTests {
    // The exact cases from the Windows version's pinyin_logic.py.
    @Test(arguments: [
        ("ma", 1, "mā"), ("na", 2, "ná"), ("na", 3, "nǎ"), ("bu", 4, "bù"),
        ("shuang", 1, "shuāng"), ("niu", 3, "niǔ"), ("tue", 4, "tuè"), ("lv", 3, "lǚ"),
    ])
    func windowsParity(syllable: String, tone: Int, expected: String) {
        #expect(Pinyin.applyTone(tone, to: syllable) == expected)
    }

    @Test(arguments: [
        ("gui", 4, "guì"), ("liu", 2, "liú"), ("you", 3, "yǒu"), ("zhou", 1, "zhōu"),
        ("guo", 2, "guó"), ("xiong", 2, "xióng"), ("lve", 4, "lüè"), ("nu:", 3, "nǚ"),
        ("Zhong", 1, "Zhōng"), ("Er", 4, "Èr"), ("lü", 2, "lǘ"), ("e", 2, "é"),
        ("ng", 2, "ńg"), ("m", 2, "ḿ"), ("ma", 5, "ma"), ("lv", 5, "lü"),
    ])
    func standardPlacement(syllable: String, tone: Int, expected: String) {
        #expect(Pinyin.applyTone(tone, to: syllable) == expected)
    }

    @Test func retoningReplacesExistingMark() {
        #expect(Pinyin.applyTone(3, to: "mā") == "mǎ")
        #expect(Pinyin.applyTone(1, to: "Lǚ") == "Lǖ")
    }

    @Test func outputIsPrecomposed() {
        // One scalar per marked vowel, so one Backspace removes it.
        #expect(Pinyin.applyTone(1, to: "ma").unicodeScalars.count == 2)
        #expect(Pinyin.applyTone(3, to: "lv").unicodeScalars.count == 2)
    }

    @Test func stripAndDetectTone() {
        #expect(Pinyin.stripTones("Lǚ zhōng") == "Lü zhong")
        #expect(Pinyin.tone(ofMarked: "xué") == 2)
        #expect(Pinyin.tone(ofMarked: "ma") == 5)
        #expect(Pinyin.tone(ofMarked: "lǜ") == 4)
    }
}

@Suite("CC-CEDICT pinyin")
struct NumberedPinyinTests {
    @Test(arguments: [
        ("xue2 xi2", "xuéxí"),
        ("Xi1 an1", "Xī'ān"),
        ("tian1 e2", "tiān'é"),
        ("nu:3 er2", "nǚ'ér"),
        ("lu:4", "lǜ"),
        ("yi1 dian3 r5", "yīdiǎnr"),
        ("zhe4 ge5", "zhège"),
        ("ka3 la1 O K", "kǎlāOK"),
    ])
    func joinedDisplay(numbered: String, expected: String) {
        #expect(Pinyin.display(numbered) == expected)
    }

    @Test func spacedDisplayAndTones() {
        #expect(Pinyin.display("ni3 hao3", joined: false) == "nǐ hǎo")
        let parsed = Pinyin.parseNumbered("ni3 hao3 · A")
        #expect(parsed.map(\.tone) == [3, 3, 0, 0])
    }

    @Test func comparisonKeyMatchesAcrossSources() {
        #expect(Pinyin.comparisonKey("xue2 xi2") == "xuexi")
        #expect(Pinyin.comparisonKey("xuéxí") == "xuexi")
        #expect(Pinyin.comparisonKey("zhègè") == Pinyin.comparisonKey("zhe4 ge5"))
        #expect(Pinyin.comparisonKey("dá'àn") == Pinyin.comparisonKey("da2 an4"))
        #expect(Pinyin.comparisonKey("lu:4") == "lv")
    }
}

@Suite("Syllables")
struct SyllableTests {
    @Test func inventoryIncludesWindowsMissingSyllables() {
        for syllable in ["shei", "dei", "zhei", "kei", "lv", "nve", "a", "er", "zhuang"] {
            #expect(Pinyin.isSyllable(syllable), "\(syllable)")
        }
        #expect(!Pinyin.isSyllable("win"))
        #expect(Pinyin.isSyllable("Lǚ"))
    }

    @Test func syllabifyPrefersFewerSyllables() {
        #expect(Pinyin.syllabify("xian") == ["xian"])
        #expect(Pinyin.syllabify("zhongguo") == ["zhong", "guo"])
        #expect(Pinyin.syllabify("Zhōngguo") == ["Zhōng", "guo"])
        #expect(Pinyin.syllabify("chapter") == nil)
    }
}

@Suite("Tone typing")
struct ToneTypingTests {
    @Test(arguments: [
        ("ma", 1, 2, "mā"),
        ("lv", 3, 2, "lǚ"),
        ("xian", 1, 4, "xiān"),
        ("zhōngguo", 2, 3, "guó"),
        ("mā", 3, 2, "mǎ"),
        ("Shei", 2, 4, "Shéi"),
        ("nihao", 3, 3, "hǎo"),
    ])
    func replaces(run: String, tone: Int, deleteCount: Int, insert: String) {
        #expect(ToneTyping.replacement(forRun: run, tone: tone) == .init(deleteCount: deleteCount, insert: insert))
    }

    @Test(arguments: ["chapter", "test", "win", "hello", "abc", "", "md", "h"])
    func leavesOrdinaryTextAlone(run: String) {
        #expect(ToneTyping.replacement(forRun: run, tone: 1) == nil)
    }

    @Test func ignoresInvalidTones() {
        #expect(ToneTyping.replacement(forRun: "ma", tone: 5) == nil)
        #expect(ToneTyping.replacement(forRun: "ma", tone: 0) == nil)
    }
}

@Suite("Tone typing, keystroke by keystroke")
struct ToneTypingStateTests {
    /// Simulates typing into a text field: "⌫" is Backspace, a space ends the word.
    private func type(_ keys: String) -> String {
        var state = ToneTypingState()
        var text = ""
        for key in keys {
            if key == "⌫" {
                state.backspace()
                if !text.isEmpty { text.removeLast() }
            } else if let digit = key.wholeNumberValue, (1...4).contains(digit) {
                if let edit = state.tone(digit) {
                    text.removeLast(edit.deleteCount)
                    text += edit.insert
                } else {
                    text.append(key)
                }
            } else {
                state.type(key)
                text.append(key)
            }
        }
        return text
    }

    @Test(arguments: [
        ("ma1", "mā"),
        ("ni3hao3", "nǐhǎo"),
        ("zhong1guo2", "zhōngguó"),
        ("Xi1an1", "Xīān"),          // a toned syllable is a boundary (the review's bug: was "Xiān")
        ("ji1e4", "jīè"),
        ("li4an4", "lìàn"),
        ("pi2ao3", "píǎo"),
        ("ma13", "mǎ"),              // re-tone straight after
        ("lv4", "lǜ"),
        ("maa⌫1", "mā"),
        ("chapter1", "chapter1"),
        ("win10", "win10"),
        ("hello wo3", "hello wǒ"),
        ("nihao3", "nihǎo"),
    ])
    func sequences(keys: String, expected: String) {
        #expect(type(keys) == expected)
    }
}
