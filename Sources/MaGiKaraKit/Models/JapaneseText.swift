import Foundation

/// 日语字符判定与假名规范化。纯字符级工具，不含任何模型。
public enum JapaneseText {

    public static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3007:                 return true   // 々 〇
        case 0x3400...0x4DBF:                return true   // 拡張A
        case 0x4E00...0x9FFF:                return true   // 基本
        case 0xF900...0xFAFF:                return true   // 互換
        case 0x20000...0x2FA1F:              return true   // 拡張B以降
        default:                             return false
        }
    }

    /// 便利重载：一个 `Character` 只要包含任意汉字 scalar 就算汉字。
    public static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { isKanji($0) }
    }

    public static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(scalar.value)
    }

    public static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A1...0x30FA).contains(scalar.value) || scalar.value == 0x30FC || scalar.value == 0x30FD || scalar.value == 0x30FE
    }

    public static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        isHiragana(scalar) || isKatakana(scalar)
    }

    /// 半角/全角拉丁与数字
    public static func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true
        case 0xFF01...0xFF5E: return true
        default: return false
        }
    }

    public static func containsKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { isKanji($0) }
    }

    public static func isAllKana(_ s: String) -> Bool {
        let scalars = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { isKana($0) || $0.value == 0x30FC }
    }

    /// 片假名 → 平假名（含 ヴ ヷ ヸ ヹ ヺ）
    public static func katakanaToHiragana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x30A1...0x30F6:
                out.append(Unicode.Scalar(scalar.value - 0x60)!)
            case 0x30FD: out.append(Unicode.Scalar(0x309D)!)   // ヽ
            case 0x30FE: out.append(Unicode.Scalar(0x309E)!)   // ヾ
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    public static func hiraganaToKatakana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x3096:
                out.append(Unicode.Scalar(scalar.value + 0x60)!)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// 去除读音里的空白、中点与括号注释。
    public static func normalizeReading(_ s: String) -> String {
        var t = katakanaToHiragana(s)
        t = t.replacingOccurrences(of: " ", with: "")
        t = t.replacingOccurrences(of: "　", with: "")
        t = t.replacingOccurrences(of: "・", with: "")
        t = t.replacingOccurrences(of: "、", with: "")
        t = t.replacingOccurrences(of: "，", with: "")
        return t
    }

    /// 拗音（小写假名）不单独成拍。
    public static func isSmallKana(_ c: Character) -> Bool {
        "ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶ".contains(c)
    }

    /// 把平假名读音拆成音拍（mora）。
    ///
    /// 规则：
    /// - 拗音与前一个假名合成一拍；
    /// - 促音「っ」独立成拍；
    /// - 撥音「ん」独立成拍；
    /// - 长音符「ー」并入前一拍（作为该拍的延长，不新增 mora）；
    /// - 其余每个假名一拍。
    public static func morae(from reading: String) -> [String] {
        let chars = Array(reading)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "ー" {
                if var last = result.popLast() {
                    last.append(c)
                    result.append(last)
                } else {
                    result.append(String(c))
                }
                i += 1
                continue
            }
            if isSmallKana(c), var last = result.popLast(), isKana(last.unicodeScalars.first!) {
                last.append(c)
                result.append(last)
                i += 1
                continue
            }
            result.append(String(c))
            i += 1
        }
        return result
    }

    /// 音拍数（用于时长先验与排版）。
    public static func moraCount(of reading: String) -> Int {
        morae(from: reading).count
    }
}
