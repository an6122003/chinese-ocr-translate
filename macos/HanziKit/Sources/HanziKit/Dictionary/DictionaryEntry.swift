import Foundation

/// One dictionary headword reading (CC-CEDICT layout) with Vietnamese and English senses.
public struct DictionaryEntry: Hashable, Sendable, Identifiable {
    public let id: Int64
    public let traditional: String
    public let simplified: String
    /// CC-CEDICT numbered pinyin, e.g. "xue2 xi2".
    public let pinyin: String
    public let vietnamese: [String]
    public let english: [String]
    /// HSK level (1–9 for HSK 3.0; 7 covers the 7–9 band), if the word is on the list.
    public let hskLevel: Int?
    /// Corpus frequency (higher is more common); 0 when unknown.
    public let frequency: Int
    /// Hán Việt per character for this reading ("" where unknown); empty when not available.
    public let hanViet: [String]

    public init(id: Int64, traditional: String, simplified: String, pinyin: String, vietnamese: [String],
                english: [String], hskLevel: Int? = nil, frequency: Int = 0, hanViet: [String] = []) {
        self.id = id
        self.traditional = traditional
        self.simplified = simplified
        self.pinyin = pinyin
        self.vietnamese = vietnamese
        self.english = english
        self.hskLevel = hskLevel
        self.frequency = frequency
        self.hanViet = hanViet
    }

    /// Combines another entry with the same reading (e.g. 了解 listed under both 了解 and 瞭解).
    func merged(with other: DictionaryEntry) -> DictionaryEntry {
        func union(_ a: [String], _ b: [String]) -> [String] { a + b.filter { !a.contains($0) } }
        return DictionaryEntry(id: id, traditional: traditional, simplified: simplified, pinyin: pinyin,
                               vietnamese: union(vietnamese, other.vietnamese), english: union(english, other.english),
                               hskLevel: [hskLevel, other.hskLevel].compactMap { $0 }.min(),
                               frequency: max(frequency, other.frequency),
                               hanViet: hanViet.isEmpty ? other.hanViet : hanViet)
    }

    /// "xuéxí"
    public var displayPinyin: String { Pinyin.display(pinyin) }
    public var syllables: [Pinyin.Syllable] { Pinyin.parseNumbered(pinyin) }

    /// CC-CEDICT capitalizes the pinyin of proper nouns (names, places).
    public var isProperNoun: Bool {
        pinyin.first?.isUppercase == true
    }

    /// Senses in the requested language, falling back to the other one.
    public func senses(preferring language: TargetLanguage) -> [String] {
        switch language {
        case .vietnamese: vietnamese.isEmpty ? english : vietnamese
        case .english: english.isEmpty ? vietnamese : english
        }
    }

    /// The first couple of senses, for compact one-line glosses: classifier notes and cross-references are
    /// skipped, and parenthetical usage notes are dropped when the sense has other content.
    public func shortGloss(preferring language: TargetLanguage, maxSenses: Int = 2) -> String {
        let glosses = senses(preferring: language)
            .filter { !DefinitionFormatter.isClassifier($0) }
            .map { DefinitionFormatter.withoutParentheticals(DefinitionFormatter.clean($0)) }
            .filter { !$0.isEmpty && !DefinitionFormatter.isCrossReference($0) }
        return glosses.prefix(maxSenses).joined(separator: "; ")
    }
}

/// An example sentence with translations.
public struct ExampleSentence: Hashable, Sendable, Identifiable {
    /// Tatoeba sentence number.
    public let id: Int64
    public let chinese: String
    public let vietnamese: String?
    public let english: String?
    /// Tatoeba username of the sentence's author (credited as the licence requires).
    public let author: String?

    public init(id: Int64, chinese: String, vietnamese: String?, english: String?, author: String? = nil) {
        self.id = id
        self.chinese = chinese
        self.vietnamese = vietnamese
        self.english = english
        self.author = author
    }

    /// "Tatoeba #2 · fucongcong"
    public var attribution: String {
        "Tatoeba #\(id)" + (author.map { " · \($0)" } ?? "")
    }

    public var url: URL? { URL(string: "https://tatoeba.org/sentences/show/\(id)") }
}

/// Makes CC-CEDICT-style sense strings readable.
public enum DefinitionFormatter {
    /// "CL:個|个[ge4],位[wei4]" (CVDICT: "LT:…") → "Lượng từ / CL: 个 gè, 位 wèi"; "學|学[xue2]" → "学 (xué)".
    public static func clean(_ sense: String) -> String {
        var text = sense.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("CL:") || text.hasPrefix("LT:") {
            let items = text.dropFirst(3).split(separator: ",").map { classifier -> String in
                let (word, reading) = parseReference(String(classifier))
                return reading.isEmpty ? word : "\(word) \(reading)"
            }
            return "Lượng từ / CL: " + items.joined(separator: ", ")
        }
        // Inline references like 學|学[xue2] or 学[xue2].
        let pattern = #"([^\s,;\[\]()|]+)(?:\|([^\s,;\[\]()|]+))?\[([A-Za-z:1-5 ]+)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let simplified = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ns.substring(with: match.range(at: 1))
                let reading = Pinyin.display(ns.substring(with: match.range(at: 3)))
                result += "\(simplified) (\(reading))"
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            text = result
        }
        return text
    }

    /// Classifier senses ("CL:個|个[ge4]", CVDICT "LT:…").
    public static func isClassifier(_ sense: String) -> Bool {
        sense.hasPrefix("CL:") || sense.hasPrefix("LT:")
    }

    /// "anh ấy (dùng cho …)" → "anh ấy"; a sense that is *only* a parenthetical is kept as it is.
    public static func withoutParentheticals(_ sense: String) -> String {
        var depth = 0
        var result = ""
        for character in sense {
            switch character {
            case "(", "（": depth += 1
            case ")", "）": depth = max(0, depth - 1)
            default: if depth == 0 { result.append(character) }
            }
        }
        // Only trim separators the removal can leave behind — not brackets that belong to the text.
        let trimmed = result.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:、，；：")))
        return trimmed.isEmpty ? sense : trimmed
    }

    /// "variant of 學|学[xue2]" style senses that only point elsewhere.
    public static func isCrossReference(_ sense: String) -> Bool {
        let lower = sense.lowercased()
        return lower.hasPrefix("variant of") || lower.hasPrefix("old variant of") || lower.hasPrefix("see ")
            || lower.hasPrefix("dị thể của") || lower.hasPrefix("xem ")
    }

    private static func parseReference(_ text: String) -> (String, String) {
        // "個|个[ge4]" → ("个", "gè")
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") else { return (text, "") }
        let words = text[..<open].split(separator: "|")
        let word = String(words.last ?? Substring(text))
        let reading = Pinyin.display(String(text[text.index(after: open)..<close]))
        return (word, reading)
    }
}
