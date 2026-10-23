import NaturalLanguage

/// Picks the reading of common single-character polyphones from their grammatical role, using Apple's
/// part-of-speech tagger: 还 adverb → hái / verb → huán, 得 particle → de / modal verb → děi, 长 before 得 → zhǎng…
///
/// Only consulted for characters that stand alone as a word; inside dictionary words (银行, 长城) the dictionary
/// reading wins.
enum Polyphones {
    struct Context {
        var tag: NLTag?
        var previous: String = ""
        var previousTag: NLTag?
        var next: String = ""
        var nextTag: NLTag?
    }

    /// Numbers and demonstratives that put the next character in its classifier role (一只, 这行, 几种).
    private static let quantifiers: Set<String> = ["一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "几",
                                                    "这", "那", "哪", "每", "半", "百", "千", "万", "多", "好几"]

    /// The reading as CC-CEDICT numbered pinyin ("hai2"), or nil to fall back to the most common reading.
    static func reading(of character: Character, in c: Context) -> String? {
        let afterQuantifier = quantifiers.contains(c.previous)
        switch character {
        case "还", "還":
            return c.tag == .verb ? "huan2" : "hai2"
        case "长", "長":
            // Standing alone, 长 is mostly the adjective cháng (很长, 长头发, 很长的时间); zhǎng "grow" has clear cues.
            if ["得", "大", "出", "高", "胖", "满", "滿"].contains(where: { c.next.hasPrefix($0) }) || c.tag == .verb {
                return "zhang3"
            }
            return "chang2"
        case "得":
            switch c.tag {
            case .verb?: return c.nextTag == .verb || c.nextTag == .adverb ? "dei3" : "de2"
            default: return "de5"
            }
        case "了":
            // 吃不了 / 吃得了 (can / can't manage) → liǎo; otherwise the particle.
            if c.previous == "不" || (c.previous == "得" && c.previousTag != .verb) { return "liao3" }
            return "le5"
        case "着", "著":
            // 睡着了 / 找着了: the result complement zháo ("managed to").
            if ["睡", "找", "猜", "见", "摸", "点", "烧", "着"].contains(c.previous) { return "zhao2" }
            return c.tag == .verb ? "zhao2" : "zhe5"
        case "行":
            if afterQuantifier { return "hang2" } // 这行字, 两行
            switch c.tag {
            case .noun?, .classifier?: return "hang2"
            default: return "xing2"
            }
        case "为", "為":
            switch c.tag {
            case .verb?: return "wei2"
            case .preposition?, .conjunction?: return "wei4"
            default: return nil
            }
        case "地":
            switch c.tag {
            case .noun?: return "di4"
            case .particle?, .otherWord?: return "de5"
            default: return nil
            }
        case "只", "隻":
            if afterQuantifier { return "zhi1" } // 一只猫
            switch c.tag {
            case .classifier?, .noun?: return "zhi1"
            case .adverb?: return "zhi3"
            default: return nil
            }
        case "都":
            return c.tag == .noun ? "du1" : "dou1"
        case "少":
            return c.tag == .noun ? "shao4" : "shao3"
        case "种", "種":
            return c.tag == .verb ? "zhong4" : "zhong3"
        case "重":
            switch c.tag {
            case .adverb?: return "chong2"
            case .adjective?: return "zhong4"
            default: return nil
            }
        case "教":
            switch c.tag {
            case .verb?: return "jiao1"
            case .noun?: return "jiao4"
            default: return nil
            }
        case "中":
            return c.tag == .verb ? "zhong4" : "zhong1"
        case "干", "幹":
            switch c.tag {
            case .verb?: return "gan4"
            case .adjective?: return "gan1"
            default: return nil
            }
        case "数", "數":
            switch c.tag {
            case .verb?: return "shu3"
            case .noun?: return "shu4"
            default: return nil
            }
        case "乐", "樂":
            return c.tag == .noun ? "yue4" : "le4"
        case "假":
            // 请…假, 三天假, 放了假: time off.
            if ["天", "周", "月", "年", "请", "放", "休", "病", "寒", "暑", "了"].contains(c.previous) || c.tag == .noun { return "jia4" }
            return "jia3"
        case "处", "處":
            switch c.tag {
            case .noun?: return "chu4"
            case .verb?: return "chu3"
            default: return nil
            }
        case "将", "將":
            return c.tag == .noun ? "jiang4" : "jiang1"
        case "传", "傳":
            return c.tag == .noun ? "zhuan4" : "chuan2"
        case "难", "難":
            return c.tag == .noun ? "nan4" : "nan2"
        case "便":
            return "bian4"
        case "觉", "覺":
            return "jue2"
        case "看":
            return "kan4"
        case "差":
            return "cha4"
        default:
            return nil
        }
    }
}
