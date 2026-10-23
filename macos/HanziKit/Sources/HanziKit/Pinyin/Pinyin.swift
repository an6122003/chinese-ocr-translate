import Foundation

/// Pinyin utilities: tone-mark placement, CC-CEDICT numbered pinyin → display pinyin,
/// and syllable validation/segmentation (used by the system-wide tone-typing feature).
public enum Pinyin {

    // MARK: - Syllable inventory

    /// Every standard Mandarin syllable, toneless, written with "v" for "ü".
    /// (The Windows version's list missed a few common ones such as shei 谁, dei 得, zhei 这.)
    public static let syllables: Set<String> = Set("""
        a ai an ang ao
        ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        ca cai can cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong chou chu
        chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        e ei en eng er
        fa fan fang fei fen feng fiao fo fou fu
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv lve
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nun nuo nv nve
        o ou
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu
        shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
        ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        wa wai wan wang wei wen weng wo wu
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
        za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou
        zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Longest syllable length ("zhuang", "shuang", "chuang").
    static let maxSyllableLength = 6

    public static func isSyllable(_ text: String) -> Bool {
        syllables.contains(lookupKey(text))
    }

    // MARK: - Tone marks

    /// Combining diacritics for tones 1–4 (macron, acute, caron, grave).
    private static let toneMarks: [Int: Character] = [1: "\u{0304}", 2: "\u{0301}", 3: "\u{030C}", 4: "\u{0300}"]
    private static let toneScalars: [Unicode.Scalar: Int] = [
        "\u{0304}": 1, "\u{0301}": 2, "\u{030C}": 3, "\u{0300}": 4,
    ]

    /// Applies `tone` (1–4; anything else = neutral) to a syllable such as "lv", "Zhong", "nu:" or "mā".
    /// Placement follows the standard rule: a/e take the mark, then the "o" of "ou",
    /// otherwise the last vowel (so "liu" → liú, "gui" → guì). Existing marks are replaced.
    public static func applyTone(_ tone: Int, to syllable: String) -> String {
        let base = Array(normalizeUmlaut(stripTones(syllable)))
        guard let mark = toneMarks[tone] else { return String(base) }
        let lower = base.map { Character($0.lowercased()) }

        var target: Int?
        if let i = lower.firstIndex(of: "a") ?? lower.firstIndex(of: "e") {
            target = i
        } else if let i = lower.indices.first(where: { lower[$0] == "o" && $0 + 1 < lower.count && lower[$0 + 1] == "u" }) {
            target = i
        } else if let i = lower.lastIndex(where: { "iouü".contains($0) }) {
            target = i
        } else if let first = lower.first, first == "m" || first == "n" {
            target = 0 // syllabic nasals: ḿ, ń, ňg…
        }
        guard let t = target else { return String(base) }

        var result = base
        result.insert(mark, at: t + 1)
        return String(result).precomposedStringWithCanonicalMapping
    }

    /// Removes tone diacritics but keeps the ü diaeresis: "Lǚ" → "Lü", "zhōng" → "zhong".
    public static func stripTones(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars where toneScalars[scalar] == nil {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// The tone (1–4) carried by a tone-marked syllable, or 5 when it has none.
    public static func tone(ofMarked syllable: String) -> Int {
        for scalar in syllable.decomposedStringWithCanonicalMapping.unicodeScalars {
            if let tone = toneScalars[scalar] { return tone }
        }
        return 5
    }

    /// "u:" / "v" → "ü" (case preserving).
    static func normalizeUmlaut(_ text: String) -> String {
        guard text.contains(where: { "vVu:U".contains($0) }) else { return text }
        return text
            .replacingOccurrences(of: "u:", with: "ü")
            .replacingOccurrences(of: "U:", with: "Ü")
            .replacingOccurrences(of: "v", with: "ü")
            .replacingOccurrences(of: "V", with: "Ü")
    }

    /// Lower-case, toneless, "v"-for-"ü" key used for syllable lookups: "Lǚ" → "lv".
    static func lookupKey(_ text: String) -> String {
        stripTones(text).lowercased()
            .replacingOccurrences(of: "u:", with: "v")
            .replacingOccurrences(of: "ü", with: "v")
    }

    // MARK: - CC-CEDICT numbered pinyin

    /// One display syllable. `tone` is 1–5 for real syllables and 0 for other tokens ("·", ",", "A").
    public struct Syllable: Hashable, Sendable {
        public var text: String
        public var tone: Int
        public var isSyllable: Bool { tone > 0 }
    }

    /// Parses CC-CEDICT pinyin such as "xue2 xi2", "Xi1 an1", "lu:4", "yi1 dian3 r5" or "A A zhi4".
    public static func parseNumbered(_ numbered: String) -> [Syllable] {
        numbered.split(separator: " ").map { token in
            guard let last = token.last, let tone = last.wholeNumberValue, (1...5).contains(tone), token.count > 1 else {
                return Syllable(text: String(token), tone: 0)
            }
            let body = String(token.dropLast())
            guard body.allSatisfy({ $0.isLetter || $0 == ":" }) else { return Syllable(text: String(token), tone: 0) }
            return Syllable(text: applyTone(tone, to: body), tone: tone)
        }
    }

    /// Display form of CC-CEDICT pinyin: "xue2 xi2" → "xuéxí" (joined, with apostrophes like "Xī'ān")
    /// or "xué xí" (spaced).
    public static func display(_ numbered: String, joined: Bool = true) -> String {
        render(parseNumbered(numbered), joined: joined)
    }

    /// Renders parsed syllables; when joined, inserts the apostrophe before a/o/e-initial syllables.
    public static func render(_ syllables: [Syllable], joined: Bool) -> String {
        guard joined else { return syllables.map(\.text).joined(separator: " ") }
        var out = ""
        var previousWasSyllable = false
        for syllable in syllables {
            if syllable.isSyllable {
                if previousWasSyllable, let first = stripTones(syllable.text).lowercased().first, "aoe".contains(first) {
                    out += "'"
                }
                out += syllable.text
                previousWasSyllable = true
            } else {
                if syllable.text == "," { out += ", " } else { out += syllable.text }
                previousWasSyllable = false
            }
        }
        return out
    }

    /// Toneless, space-free, lower-case form used to compare readings from different sources:
    /// "xue2 xi2" → "xuexi", "xuéxí" → "xuexi", "lu:4" → "lv".
    public static func comparisonKey(_ reading: String) -> String {
        var text = reading
        if text.contains(where: \.isNumber) {
            // Numbered (CC-CEDICT) pinyin: the erhua suffix "r5" is written "ér" by Apple's transcription.
            text = text.split(separator: " ").map { token in
                let letters = token.filter { !$0.isNumber }
                return letters.lowercased() == "r" ? "er" : String(letters)
            }.joined()
        }
        return lookupKey(text).filter { $0.isLetter }
    }

    // MARK: - Segmentation (for tone typing)

    /// Splits a run of letters into syllables using as few syllables as possible
    /// ("xian" → ["xian"], "zhongguo" → ["zhong", "guo"]). Returns nil if the run isn't pure pinyin.
    public static func syllabify(_ run: String) -> [String]? {
        let chars = Array(run)
        let keys = chars.map { lookupKey(String($0)) }
        let n = chars.count
        guard n > 0 else { return [] }
        // best[i] = fewest syllables covering chars[0..<i]; back[i] = start of the last syllable.
        var best = [Int](repeating: .max, count: n + 1)
        var back = [Int](repeating: -1, count: n + 1)
        best[0] = 0
        for end in 1...n {
            for length in 1...min(maxSyllableLength, end) {
                let start = end - length
                guard best[start] != .max, syllables.contains(keys[start..<end].joined()) else { continue }
                if best[start] + 1 < best[end] {
                    best[end] = best[start] + 1
                    back[end] = start
                }
            }
        }
        guard best[n] != .max else { return nil }
        var parts: [String] = []
        var end = n
        while end > 0 {
            let start = back[end]
            parts.append(String(chars[start..<end]))
            end = start
        }
        return parts.reversed()
    }
}

/// Logic behind "type ma1 → mā" anywhere. Pure and UI-free so it can be unit-tested.
public enum ToneTyping {

    public struct Replacement: Equatable, Sendable {
        /// How many characters before the caret must be deleted.
        public var deleteCount: Int
        /// Text to type in their place.
        public var insert: String
    }

    /// Given the characters typed since the last word boundary and a tone digit (1–4),
    /// returns the edit that turns the final syllable into its tone-marked form, or nil to let the digit through.
    ///
    /// The whole run must be valid pinyin, which avoids false positives on ordinary text
    /// ("chapter1", "test2", "win10" are left alone) while "zhōngguo" + 2 → "zhōngguó" still works.
    /// An already-marked syllable can be re-toned ("mā" + 3 → "mǎ").
    public static func replacement(forRun run: String, tone: Int) -> Replacement? {
        guard (1...4).contains(tone) else { return nil }
        let chars = Array(run)
        let n = chars.count
        guard n > 0, chars.allSatisfy(isPinyinLetter) else { return nil }
        let keys = chars.map { Pinyin.lookupKey(String($0)) }

        // segmentable[i] == true when chars[0..<i] splits into valid syllables.
        var segmentable = [Bool](repeating: false, count: n + 1)
        segmentable[0] = true
        for end in 1...n {
            for length in 1...min(Pinyin.maxSyllableLength, end) where segmentable[end - length] {
                if Pinyin.syllables.contains(keys[(end - length)..<end].joined()) {
                    segmentable[end] = true
                    break
                }
            }
        }
        guard segmentable[n] else { return nil }

        // Prefer the longest final syllable: "xian" + 1 → "xiān", not "xi" + "ān".
        for length in stride(from: min(Pinyin.maxSyllableLength, n), through: 1, by: -1) {
            let start = n - length
            guard segmentable[start], Pinyin.syllables.contains(keys[start..<n].joined()) else { continue }
            let syllable = String(chars[start..<n])
            return Replacement(deleteCount: length, insert: Pinyin.applyTone(tone, to: syllable))
        }
        return nil
    }

    /// Letters that can appear inside a pinyin run (ASCII letters, ü and tone-marked vowels).
    public static func isPinyinLetter(_ character: Character) -> Bool {
        if character.isASCII { return character.isLetter }
        let base = Pinyin.stripTones(String(character)).lowercased()
        return ["a", "e", "i", "o", "u", "ü", "m", "n"].contains(base)
    }
}

/// The keystroke-by-keystroke state behind tone typing.
///
/// A syllable that has received its tone is a boundary: later letters start a new syllable, so "Xi1an1" gives
/// "Xīān" (not "Xiān"). Typing another digit straight after a toned syllable re-tones it ("ma1" then "3" → "mǎ").
public struct ToneTypingState: Sendable, Equatable {
    /// Letters typed since the last boundary.
    public private(set) var run = ""
    /// The syllable just tone-marked, while nothing has been typed after it.
    public private(set) var lastToned: String?

    public init() {}

    public mutating func reset() {
        run = ""
        lastToned = nil
    }

    /// A typed character: pinyin letters extend the run; anything else ends the word.
    public mutating func type(_ character: Character) {
        guard character.isLetter, ToneTyping.isPinyinLetter(character) else {
            reset()
            return
        }
        run.append(character)
        if run.count > 40 { run.removeFirst(run.count - 40) }
        lastToned = nil
    }

    public mutating func backspace() {
        if run.isEmpty {
            lastToned = nil
        } else {
            run.removeLast()
        }
    }

    /// A tone digit: returns the edit to make (and swallow the digit), or nil to let the digit through,
    /// which also ends the word.
    public mutating func tone(_ tone: Int) -> ToneTyping.Replacement? {
        if run.isEmpty, let toned = lastToned {
            guard let replacement = ToneTyping.replacement(forRun: toned, tone: tone) else {
                reset()
                return nil
            }
            lastToned = replacement.insert
            return replacement
        }
        guard let replacement = ToneTyping.replacement(forRun: run, tone: tone) else {
            reset()
            return nil
        }
        run = ""
        lastToned = replacement.insert
        return replacement
    }
}
