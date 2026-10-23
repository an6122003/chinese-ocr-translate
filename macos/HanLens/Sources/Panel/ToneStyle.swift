import AppKit
import HanziKit
import SwiftUI

/// Tone colours (the Pleco/MDBG convention): 1 red · 2 orange · 3 green · 4 blue · neutral grey.
enum ToneStyle {
    static func color(for tone: Int, enabled: Bool = true) -> Color {
        guard enabled else { return .secondary }
        switch tone {
        case 1: return dynamic(light: (0.86, 0.17, 0.15), dark: (1.00, 0.42, 0.38))
        case 2: return dynamic(light: (0.85, 0.47, 0.02), dark: (0.98, 0.70, 0.22))
        case 3: return dynamic(light: (0.10, 0.58, 0.25), dark: (0.36, 0.85, 0.50))
        case 4: return dynamic(light: (0.15, 0.39, 0.92), dark: (0.42, 0.66, 1.00))
        default: return .secondary
        }
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Tone-coloured pinyin for a word ("xuéxí" with each syllable in its colour).
    static func pinyin(_ syllables: [Pinyin.Syllable], colored: Bool) -> Text {
        var result = AttributedString()
        var previousWasSyllable = false
        for syllable in syllables {
            if syllable.isSyllable, previousWasSyllable,
               let first = Pinyin.stripTones(syllable.text).lowercased().first, "aoe".contains(first) {
                var apostrophe = AttributedString("'")
                apostrophe.foregroundColor = .secondary
                result += apostrophe
            }
            var piece = AttributedString(syllable.text)
            piece.foregroundColor = color(for: syllable.tone, enabled: colored)
            result += piece
            previousWasSyllable = syllable.isSyllable
        }
        return Text(result)
    }

    /// Tone-coloured pinyin from CC-CEDICT numbered pinyin.
    static func pinyin(numbered: String, colored: Bool) -> Text {
        pinyin(Pinyin.parseNumbered(numbered), colored: colored)
    }
}

/// Fonts used for Chinese text: PingFang SC/TC to match the script being shown.
enum HanFont {
    static func font(size: CGFloat, weight: Font.Weight = .regular, traditional: Bool = false) -> Font {
        .custom(traditional ? "PingFang TC" : "PingFang SC", size: size).weight(weight)
    }
}
