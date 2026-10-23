import Foundation
import NaturalLanguage

/// A piece of analyzed text: a Chinese word, or a run of punctuation/Latin/space.
public struct Segment: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case word, latin, punctuation, space, newline }

    public let id: Int
    public let text: String
    public let kind: Kind
    /// Location in the analyzed text, in UTF-16 units (matches speech-synthesis ranges).
    public let utf16Range: NSRange
    /// One tone-marked syllable per character for words; empty otherwise.
    public let syllables: [Pinyin.Syllable]
    /// One Hán Việt reading per character ("" when unknown).
    public let hanViet: [String]
    /// Dictionary entries, the one matching the chosen reading first.
    public let entries: [DictionaryEntry]

    public var isWord: Bool { kind == .word }
    public var pinyin: String { Pinyin.render(syllables, joined: true) }
    public var hanVietText: String { hanViet.filter { !$0.isEmpty }.joined(separator: " ") }
    public var bestEntry: DictionaryEntry? { entries.first }
}

/// The result of analyzing a piece of Chinese text.
public struct AnalyzedText: Sendable, Hashable {
    public let text: String
    public let segments: [Segment]

    public init(text: String, segments: [Segment]) {
        self.text = text
        self.segments = segments
    }

    public static let empty = AnalyzedText(text: "", segments: [])

    /// Distinct Chinese words in order of appearance.
    public var uniqueWords: [Segment] {
        var seen = Set<String>()
        return segments.filter { $0.isWord && seen.insert($0.text).inserted }
    }

    public var containsChinese: Bool { segments.contains(where: \.isWord) }

    /// Pinyin of the whole text for copying: "Wǒmen jīntiān qù túshūguǎn."
    public var pinyinText: String {
        var output = ""
        var capitalizeNext = true
        for segment in segments {
            switch segment.kind {
            case .word:
                var word = segment.pinyin
                if capitalizeNext, let first = word.first {
                    word = first.uppercased() + word.dropFirst()
                    capitalizeNext = false
                }
                if let last = output.last, !last.isWhitespace, !"(\"“‘「『《".contains(last) { output += " " }
                output += word
            case .punctuation:
                let mapped = Self.westernPunctuation(segment.text)
                output += mapped
                if mapped.contains(where: { ".!?".contains($0) }) { capitalizeNext = true }
            case .latin:
                if let last = output.last, !last.isWhitespace { output += " " }
                output += segment.text
            case .space:
                output += " "
            case .newline:
                output += "\n"
                capitalizeNext = true
            }
        }
        return output.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func westernPunctuation(_ text: String) -> String {
        let map: [Character: String] = [
            "，": ", ", "、": ", ", "。": ". ", "！": "! ", "？": "? ", "；": "; ", "：": ": ",
            "（": " (", "）": ") ", "“": " “", "”": "” ", "‘": " ‘", "’": "’ ", "「": " “", "」": "” ",
            "『": " ‘", "』": "’ ", "《": " «", "》": "» ", "…": "… ", "—": "—", "·": "·", "～": "~",
        ]
        return text.map { map[$0] ?? String($0) }.joined()
    }

    /// Segments overlapping a UTF-16 range (for highlighting the word being spoken).
    public func segmentIDs(overlapping range: NSRange) -> Set<Int> {
        Set(segments.filter { NSIntersectionRange($0.utf16Range, range).length > 0 }.map(\.id))
    }
}

/// Splits Chinese text into words and annotates them with pinyin, Hán Việt and dictionary entries.
public struct TextAnalyzer: Sendable {
    public let dictionary: HanziDictionary

    public init(dictionary: HanziDictionary) {
        self.dictionary = dictionary
    }

    /// Analysis runs on a background thread when awaited from the main actor.
    public func analyzeInBackground(_ text: String) async -> AnalyzedText {
        analyze(text)
    }

    public func analyze(_ text: String) -> AnalyzedText {
        var segments: [Segment] = []
        var nextID = 0
        let traditional = CJK.looksTraditional(text) ?? false

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(traditional ? .traditionalChinese : .simplifiedChinese, range: text.startIndex..<text.endIndex)
        func tag(_ range: Range<String.Index>) -> NLTag? {
            tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
        }

        for run in Self.runs(in: text) {
            switch run.kind {
            case .word:
                let words = wordRanges(in: text, run: run.range, traditional: traditional)
                for (index, word) in words.enumerated() {
                    var grammar: Polyphones.Context?
                    if text.distance(from: word.range.lowerBound, to: word.range.upperBound) == 1 {
                        let previous = index > 0 ? words[index - 1].range : nil
                        let next = index + 1 < words.count ? words[index + 1].range : nil
                        grammar = Polyphones.Context(tag: tag(word.range),
                                                     previous: previous.map { String(text[$0]) } ?? "",
                                                     previousTag: previous.flatMap(tag),
                                                     next: next.map { String(text[$0]) } ?? "",
                                                     nextTag: next.flatMap(tag))
                    }
                    segments.append(makeWord(text: text, range: word.range, context: word.contextReadings, grammar: grammar, id: nextID))
                    nextID += 1
                }
            default:
                segments.append(Segment(id: nextID, text: String(text[run.range]), kind: run.kind,
                                        utf16Range: NSRange(run.range, in: text), syllables: [], hanViet: [], entries: []))
                nextID += 1
            }
        }
        return AnalyzedText(text: text, segments: segments)
    }

    // MARK: Runs

    struct Run {
        let kind: Segment.Kind
        let range: Range<String.Index>
    }

    /// Groups characters into runs of Han characters, Latin/digits, punctuation, spaces and newlines.
    static func runs(in text: String) -> [Run] {
        func kind(of character: Character) -> Segment.Kind {
            if CJK.isHan(character) { return .word }
            if character.isNewline { return .newline }
            if character.isWhitespace { return .space }
            if character.isLetter || character.isNumber { return .latin }
            return .punctuation
        }
        var runs: [Run] = []
        var index = text.startIndex
        while index < text.endIndex {
            let currentKind = kind(of: text[index])
            var end = text.index(after: index)
            // Punctuation and newlines stay one character per segment; other runs merge.
            if currentKind != .punctuation, currentKind != .newline {
                while end < text.endIndex, kind(of: text[end]) == currentKind { end = text.index(after: end) }
            }
            runs.append(Run(kind: currentKind, range: index..<end))
            index = end
        }
        return runs
    }

    // MARK: Words

    struct WordRange {
        let range: Range<String.Index>
        /// Context-aware readings per character from Apple's tokenizer — only where it read a multi-character word
        /// (its single-character readings are just defaults, e.g. 还 → huán); nil elsewhere.
        let contextReadings: [String?]
    }

    /// One token from Apple's CFStringTokenizer: character offset and length within the run, plus its syllables.
    struct ContextToken {
        let start: Int
        let length: Int
        let syllables: [String]
    }

    /// Segments one run of Han characters into dictionary words.
    func wordRanges(in text: String, run: Range<String.Index>, traditional: Bool) -> [WordRange] {
        let runLength = text.distance(from: run.lowerBound, to: run.upperBound)
        let contextTokens = Self.contextTokens(in: text, range: run)
        var reliable = [String?](repeating: nil, count: runLength)
        var appleSpans = Set<[Int]>()
        for token in contextTokens {
            appleSpans.insert([token.start, token.length])
            guard token.length > 1, token.syllables.count == token.length, token.start + token.length <= runLength else { continue }
            for k in 0..<token.length { reliable[token.start + k] = token.syllables[k] }
        }

        func span(_ range: Range<String.Index>) -> (offset: Int, length: Int) {
            (text.distance(from: run.lowerBound, to: range.lowerBound), text.distance(from: range.lowerBound, to: range.upperBound))
        }
        /// The context reading of a range, when every character has a reliable one.
        func contextKey(_ range: Range<String.Index>) -> String? {
            let (offset, length) = span(range)
            let slice = reliable[offset..<(offset + length)]
            guard slice.allSatisfy({ $0 != nil }) else { return nil }
            return Pinyin.comparisonKey(slice.compactMap { $0 }.joined())
        }
        /// A dictionary word whose reading fits the context (银行 in 银行行长, not 行行).
        func isWord(_ range: Range<String.Index>) -> Bool {
            let entries = dictionary.entries(for: String(text[range]))
            guard !entries.isEmpty else { return false }
            guard let key = contextKey(range) else { return true }
            return entries.contains { Pinyin.comparisonKey($0.pinyin) == key }
        }

        // 1. Apple's tokenizer.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(traditional ? .traditionalChinese : .simplifiedChinese)
        var tokens: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: run) { range, _ in
            tokens.append(range)
            return true
        }
        if tokens.isEmpty { tokens = [run] }
        tokens = Self.coverGaps(tokens, in: run, text: text)

        // 2. Merge adjacent tokens into a dictionary word when CFStringTokenizer agrees it's one word, or for idioms
        //    and set phrases of 3+ characters the tokenizer over-split. (Two-character merges like 到+了 or 得+很
        //    are usually a word plus a particle.)
        var merged: [Range<String.Index>] = []
        var i = 0
        while i < tokens.count {
            var bestEnd = i
            var j = i + 1
            while j < tokens.count, j - i < 4,
                  text.distance(from: tokens[i].lowerBound, to: tokens[j].upperBound) <= dictionary.maxWordLength {
                let candidate = tokens[i].lowerBound..<tokens[j].upperBound
                let (offset, length) = span(candidate)
                if isWord(candidate), appleSpans.contains([offset, length]) || length >= 3 { bestEnd = j }
                j += 1
            }
            merged.append(tokens[i].lowerBound..<tokens[bestEnd].upperBound)
            i = bestEnd + 1
        }

        // 3. Split tokens that aren't words in this context with forward maximum matching.
        var words: [Range<String.Index>] = []
        for token in merged {
            if text.distance(from: token.lowerBound, to: token.upperBound) == 1 || isWord(token) {
                words.append(token)
                continue
            }
            var start = token.lowerBound
            while start < token.upperBound {
                var end = text.index(after: start)
                let limit = min(text.distance(from: start, to: token.upperBound), dictionary.maxWordLength)
                for length in stride(from: limit, through: 2, by: -1) {
                    let candidate = start..<text.index(start, offsetBy: length)
                    if candidate != token, isWord(candidate) {
                        end = candidate.upperBound
                        break
                    }
                }
                words.append(start..<end)
                start = end
            }
        }

        return words.map { range in
            let (offset, length) = span(range)
            return WordRange(range: range, contextReadings: Array(reliable[offset..<(offset + length)]))
        }
    }

    static func coverGaps(_ tokens: [Range<String.Index>], in run: Range<String.Index>, text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = run.lowerBound
        for token in tokens.sorted(by: { $0.lowerBound < $1.lowerBound }) where token.lowerBound >= cursor {
            var index = cursor
            while index < token.lowerBound {
                let next = text.index(after: index)
                result.append(index..<next)
                index = next
            }
            result.append(token)
            cursor = token.upperBound
        }
        while cursor < run.upperBound {
            let next = text.index(after: cursor)
            result.append(cursor..<next)
            cursor = next
        }
        return result
    }

    /// CFStringTokenizer's words with their context-aware pinyin ("银行行长" → 银行 yínháng · 行长 hángzhǎng).
    static func contextTokens(in text: String, range: Range<String.Index>) -> [ContextToken] {
        let substring = String(text[range])
        let cfString = substring as CFString
        guard let tokenizer = CFStringTokenizerCreate(nil, cfString, CFRange(location: 0, length: CFStringGetLength(cfString)),
                                                      kCFStringTokenizerUnitWordBoundary, Locale(identifier: "zh_CN") as CFLocale)
        else { return [] }
        var tokens: [ContextToken] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let utf16Range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let lower = String.Index(utf16Offset: utf16Range.location, in: substring)
            let upper = String.Index(utf16Offset: utf16Range.location + utf16Range.length, in: substring)
            guard lower <= upper, upper <= substring.endIndex else { continue }
            let token = substring[lower..<upper]
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""
            tokens.append(ContextToken(start: substring.distance(from: substring.startIndex, to: lower), length: token.count,
                                       syllables: Pinyin.syllabify(transcription, count: token.count) ?? []))
        }
        return tokens
    }

    // MARK: Annotation

    func makeWord(text: String, range: Range<String.Index>, context: [String?], grammar: Polyphones.Context?, id: Int) -> Segment {
        let word = String(text[range])
        let characters = Array(word)
        var entries = dictionary.entries(for: word)
        let reliable = context.count == characters.count && context.allSatisfy({ $0 != nil }) ? context.compactMap { $0 } : nil

        func promote(where matches: (DictionaryEntry) -> Bool) -> Bool {
            guard let index = entries.firstIndex(where: matches) else { return false }
            entries.insert(entries.remove(at: index), at: 0)
            return true
        }
        // Reading choice: Apple's context reading of a multi-character word, then (for lone characters) the
        // grammar-based polyphone rules, then the most common reading.
        let chosen = reliable.map { reading in promote { Pinyin.comparisonKey($0.pinyin) == Pinyin.comparisonKey(reading.joined()) } } ?? false
        if !chosen, characters.count == 1 {
            if let grammar, let rule = Polyphones.reading(of: characters[0], in: grammar), promote(where: { $0.pinyin.lowercased() == rule }) {
            } else if let common = dictionary.mandarin(for: characters[0]) {
                _ = promote { !$0.isProperNoun && Pinyin.comparisonKey($0.pinyin) == Pinyin.comparisonKey(common) }
            }
        }

        var syllables = entries.first?.syllables.filter(\.isSyllable) ?? []
        if syllables.count != characters.count {
            // No usable entry: read character by character.
            syllables = characters.enumerated().map { offset, character in
                if offset < context.count, let reading = context[offset] {
                    return Pinyin.Syllable(text: reading, tone: Pinyin.tone(ofMarked: reading))
                }
                let reading = dictionary.mandarin(for: character)
                    ?? dictionary.entries(for: String(character)).first.map { Pinyin.display($0.pinyin) }
                    ?? ""
                return Pinyin.Syllable(text: reading, tone: reading.isEmpty ? 0 : Pinyin.tone(ofMarked: reading))
            }
        }
        // A lone single-character word gets its common reading's lowercase form ("Zhōng" surname → "zhōng").
        if characters.count == 1, entries.first?.isProperNoun == true, let first = syllables.first {
            syllables = [Pinyin.Syllable(text: first.text.lowercased(), tone: first.tone)]
        }

        var hanViet = zip(characters, syllables).map { character, syllable in
            hanVietReading(for: character, pinyin: syllable.text)
        }
        // The chosen entry knows its Hán Việt in context (银行 → ngân hàng); fill gaps from per-character data.
        if let entryHanViet = entries.first?.hanViet, entryHanViet.count == characters.count {
            hanViet = zip(entryHanViet, hanViet).map { $0.isEmpty ? $1 : $0 }
        }
        return Segment(id: id, text: word, kind: .word, utf16Range: NSRange(range, in: text),
                       syllables: syllables, hanViet: hanViet, entries: entries)
    }

    /// Hán Việt for a character, choosing among several readings by the Mandarin reading when the data allows.
    func hanVietReading(for character: Character, pinyin: String) -> String {
        dictionary.hanViet(for: character, pinyin: pinyin) ?? dictionary.hanViet(for: character).first ?? ""
    }
}

extension Pinyin {
    /// Splits a tone-marked transcription into exactly `count` syllables, each with at most one tone mark
    /// ("xīān", 2 → ["xī", "ān"]). Returns nil when impossible.
    public static func syllabify(_ transcription: String, count: Int) -> [String]? {
        let chars = Array(transcription.filter { $0.isLetter })
        let n = chars.count
        guard count > 0, n >= count else { return count == 0 && n == 0 ? [] : nil }
        let keys = chars.map { lookupKey(String($0)) }
        let marked = chars.map { tone(ofMarked: String($0)) != 5 }
        // reachable[k][i]: chars[0..<i] splits into k valid syllables.
        var reachable = Array(repeating: Array(repeating: -1, count: n + 1), count: count + 1)
        reachable[0][0] = 0
        for k in 1...count {
            for end in 1...n {
                for length in 1...min(maxSyllableLength, end) {
                    let start = end - length
                    guard reachable[k - 1][start] >= 0, syllables.contains(keys[start..<end].joined()),
                          marked[start..<end].filter({ $0 }).count <= 1 else { continue }
                    reachable[k][end] = start
                    break
                }
            }
        }
        guard reachable[count][n] >= 0 else { return nil }
        var parts: [String] = []
        var end = n
        for k in stride(from: count, through: 1, by: -1) {
            let start = reachable[k][end]
            parts.append(String(chars[start..<end]))
            end = start
        }
        return parts.reversed()
    }
}
