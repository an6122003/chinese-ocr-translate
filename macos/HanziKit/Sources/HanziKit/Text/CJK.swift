import Foundation

/// Character classification and text clean-up for Chinese text.
public enum CJK {

    /// True for Han ideographs (CJK Unified Ideographs, extensions A–I, compatibility ideographs, 〇).
    public static func isHan(scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3007,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x2EBF0...0x2EE5F,
             0x30000...0x3134F, 0x31350...0x323AF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    public static func isHan(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return isHan(scalar: scalar)
    }

    /// CJK symbols & punctuation, full-width forms, and the "CJK compatibility forms" block.
    public static func isCJKPunctuation(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0xFF00...0xFFEF, 0xFE30...0xFE4F, 0xFE10...0xFE1F, 0x2026, 0x2014, 0x00B7, 0x2018...0x201F:
            return true
        default:
            return false
        }
    }

    /// Characters that sit inside Chinese text without surrounding spaces.
    public static func isCJKTextCharacter(_ character: Character) -> Bool {
        isHan(character) || isCJKPunctuation(character)
    }

    /// True when sentence-final punctuation ends the string ("。", "！", "？", "…", plus ASCII forms).
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return "。！？…；!?;：:」』”\"".contains(last)
    }

    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHan(scalar: $0) }
    }

    /// Share of non-whitespace characters that are Han ideographs.
    public static func hanRatio(_ text: String) -> Double {
        var han = 0
        var total = 0
        for character in text where !character.isWhitespace {
            total += 1
            if isHan(character) { han += 1 }
        }
        return total == 0 ? 0 : Double(han) / Double(total)
    }

    /// Cleans OCR / clipboard text: NBSP → space, removes the artificial spaces OCR puts between
    /// Chinese characters ("我 们" → "我们") while keeping real spaces between Latin words, trims.
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let chars = Array(text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n"))
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" {
                // Collapse a run of horizontal whitespace; drop it entirely between CJK characters.
                var j = i
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                let before = out.last
                let after = j < chars.count ? chars[j] : nil
                let dropsSpace = before == nil || after == nil || before == "\n" || after == "\n"
                    || (before.map(isCJKTextCharacter) ?? false) || (after.map(isCJKTextCharacter) ?? false)
                if !dropsSpace { out.append(" ") }
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        // Collapse 3+ newlines into a paragraph break.
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guesses whether text is written in traditional characters, using characters that only exist
    /// in one script. Returns nil when there is no signal.
    public static func looksTraditional(_ text: String) -> Bool? {
        var traditional = 0
        var simplified = 0
        for character in text {
            if traditionalOnly.contains(character) { traditional += 1 }
            if simplifiedOnly.contains(character) { simplified += 1 }
        }
        if traditional == simplified { return nil }
        return traditional > simplified
    }

    // A small set of very frequent script-distinguishing characters.
    private static let traditionalOnly: Set<Character> = Set("們這個來說時會對為國學過還麼沒後裡開發經東門問題愛書車長馬見現點樣請謝讓話語認識記體實點邊應該關係讀寫聽買賣錢電話視機場號員區際傳統種歡錯飯館醫")
    // (后, 里, 系 are left out: they also occur in traditional text.)
    private static let simplifiedOnly: Set<Character> = Set("们这个来说时会对为国学过还么没开发经东门问题爱书车长马见现点样请谢让话语认识记体实边应该关读写听买卖钱电视机场号员区际传统种欢错饭馆医")
}

extension String {
    /// The string with Chinese-aware whitespace normalization applied (see ``CJK/normalize(_:)``).
    public var cjkNormalized: String { CJK.normalize(self) }
}
