import Foundation
import Testing
@testable import HanziKit

/// The dictionary built by `scripts/build_dictionary.py` (tests are skipped if it hasn't been built).
let dictionaryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Data/hanzi.sqlite")
let dictionaryIsBuilt = FileManager.default.fileExists(atPath: dictionaryURL.path)
let sharedDictionary: HanziDictionary? = try? HanziDictionary(url: dictionaryURL)

private func analyze(_ text: String) throws -> AnalyzedText {
    let dictionary = try #require(sharedDictionary)
    return TextAnalyzer(dictionary: dictionary).analyze(text)
}

private func words(_ analysis: AnalyzedText) -> [String] {
    analysis.segments.filter(\.isWord).map(\.text)
}

@Suite("Analyzer + dictionary", .enabled(if: dictionaryIsBuilt))
struct AnalyzerTests {
    @Test func segmentsAndReadsPolyphones() throws {
        let analysis = try analyze("银行行长说他很喜欢长城。")
        #expect(words(analysis) == ["银行", "行长", "说", "他", "很", "喜欢", "长城"])
        let readings = analysis.segments.filter(\.isWord).map(\.pinyin)
        #expect(readings == ["yínháng", "hángzhǎng", "shuō", "tā", "hěn", "xǐhuan", "Chángchéng"])
        let hanViet = analysis.segments.filter(\.isWord).map(\.hanVietText)
        #expect(hanViet[0] == "ngân hàng")
        #expect(hanViet[1] == "hàng trưởng")
        #expect(hanViet[6] == "trường thành")
    }

    @Test func everydaySentence() throws {
        let analysis = try analyze("我们今天去图书馆学习中文。")
        #expect(words(analysis) == ["我们", "今天", "去", "图书馆", "学习", "中文"])
        let library = try #require(analysis.segments.first { $0.text == "图书馆" })
        #expect(library.hanVietText == "đồ thư quán")
        #expect(library.bestEntry?.vietnamese.first == "thư viện")
        #expect(library.bestEntry?.hskLevel == 1)
        #expect(analysis.pinyinText == "Wǒmen jīntiān qù túshūguǎn xuéxí Zhōngwén.")
    }

    @Test func neutralTonesComeFromTheDictionary() throws {
        let analysis = try analyze("这个问题的答案你知道吗？")
        let readings = Dictionary(uniqueKeysWithValues: analysis.segments.filter(\.isWord).map { ($0.text, $0.pinyin) })
        #expect(readings["这个"] == "zhège")
        #expect(readings["答案"] == "dá'àn")
        #expect(readings["的"] == "de")
        #expect(readings["吗"] == "ma")
    }

    @Test func traditionalText() throws {
        let analysis = try analyze("我們今天去圖書館")
        #expect(words(analysis) == ["我們", "今天", "去", "圖書館"])
        #expect(analysis.segments.first { $0.text == "圖書館" }?.hanVietText == "đồ thư quán")
        #expect(analysis.segments.first { $0.text == "我們" }?.pinyin == "wǒmen")
    }

    @Test func singleCharacterUsesTheCommonReading() throws {
        let analysis = try analyze("行")
        let segment = try #require(analysis.segments.first)
        #expect(segment.pinyin == "xíng")
        #expect(segment.hanVietText == "hành")
    }

    @Test func mixedLatinText() throws {
        let analysis = try analyze("我用iPhone拍照")
        #expect(analysis.segments.map(\.text) == ["我", "用", "iPhone", "拍照"])
        #expect(analysis.segments[2].kind == .latin)
    }

    @Test func idiomsStayWhole() throws {
        let analysis = try analyze("这真是一石二鸟")
        #expect(words(analysis).contains("一石二鸟"))
    }

    /// Polyphones read from their grammatical role (Apple's part-of-speech tagger + context rules).
    @Test(arguments: [
        ("我还没吃饭呢", "还", "hái"),
        ("你还书了吗？", "还", "huán"),
        ("他长得很高", "长", "zhǎng"),
        ("头发也很长。", "长", "cháng"),
        ("傑西的長頭髮完全濕透了。", "長", "cháng"),
        ("要很長的時間才能恢復嗎？", "長", "cháng"),
        ("孩子长高了。", "长", "zhǎng"),
        ("我们得好好想一想。", "得", "děi"),
        ("他跑得很快。", "得", "de"),
        ("他得了第一名。", "得", "dé"),
        ("这么多菜我吃不了。", "了", "liǎo"),
        ("他睡着了。", "着", "zháo"),
        ("门开着。", "着", "zhe"),
        ("一只猫在睡觉。", "只", "zhī"),
        ("我只想喝水。", "只", "zhǐ"),
        ("这行字我看不清楚。", "行", "háng"),
        ("差不多就行了。", "行", "xíng"),
        ("请你重说一遍。", "重", "chóng"),
        ("这个箱子很重。", "重", "zhòng"),
        ("我请了三天假。", "假", "jià"),
    ])
    func polyphonesFollowGrammar(sentence: String, character: String, reading: String) throws {
        let analysis = try analyze(sentence)
        let segment = try #require(analysis.segments.last { $0.text == character })
        #expect(segment.pinyin == reading)
    }

    @Test func erhuaWordsStayWhole() throws {
        let analysis = try analyze("请问洗手间在哪儿？")
        let word = try #require(analysis.segments.first { $0.text == "哪儿" })
        #expect(word.pinyin == "nǎr")
    }

    @Test func hanVietSkipsNativeReadings() throws {
        // The Hán Việt word list gives the Nôm readings "húp" for 喝 and "đọc" for 讀; Thiều Chửu has hát / độc.
        #expect(try analyze("喝").segments.first?.hanVietText == "hát")
        #expect(try analyze("读书").segments.first?.hanVietText == "độc thư")
    }

    @Test func particlesAreNotMergedIntoWordsWithOtherReadings() throws {
        // 到了 is also a dictionary word (dàoliǎo, "finally"), but here 了 is the particle "le".
        let analysis = try analyze("他们是不是已经到了？")
        let le = try #require(analysis.segments.first { $0.text.contains("了") })
        #expect(le.text == "了")
        #expect(le.pinyin == "le")
        #expect(words(analysis).contains("到"))
    }

    @Test func examplesAndGrammar() throws {
        let dictionary = try #require(sharedDictionary)
        let examples = dictionary.examples(containing: "学习", limit: 3)
        #expect(examples.count == 3)
        #expect(examples.allSatisfy { $0.chinese.contains("学习") || $0.chinese.contains("學習") })
        #expect(dictionary.hasGrammarPage("把"))
        #expect(!dictionary.hasGrammarPage("图书馆"))
    }

    @Test func duplicateReadingsAreMerged() throws {
        let dictionary = try #require(sharedDictionary)
        let entries = dictionary.entries(for: "了解")
        #expect(entries.count == 1)
        #expect(entries.first?.hskLevel == 4)
    }

    @Test func characterData() throws {
        let dictionary = try #require(sharedDictionary)
        #expect(dictionary.hanViet(for: "行").first == "hành")
        #expect(dictionary.hanViet(for: "行", pinyin: "háng") == "hàng")
        #expect(dictionary.hanViet(for: "学").first == "học")
        #expect(dictionary.mandarin(for: "了") == "le")
    }
}

@Suite("Definitions")
struct DefinitionTests {
    @Test func classifiersAndReferences() {
        #expect(DefinitionFormatter.clean("LT:家[jia1],個|个[ge4]") == "Lượng từ / CL: 家 jiā, 个 gè")
        #expect(DefinitionFormatter.clean("variant of 學|学[xue2]") == "variant of 学 (xué)")
        #expect(DefinitionFormatter.isCrossReference("variant of 學|学[xue2]"))
    }
}

@Suite("Short glosses")
struct GlossTests {
    @Test func parentheticalsAreDroppedButBracketsKept() {
        #expect(DefinitionFormatter.withoutParentheticals("anh ấy (dùng cho nam giới)") == "anh ấy")
        #expect(DefinitionFormatter.withoutParentheticals("(phó từ mức độ)") == "(phó từ mức độ)")
        #expect(DefinitionFormatter.withoutParentheticals("Taiwan pr. [xue2]") == "Taiwan pr. [xue2]")
    }
}
