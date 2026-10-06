import Foundation

/// 日文归一化 —— 只用于「歌词 ↔ ASR 文本」的匹配，不改变任何用于显示的文字。
///
/// 做这几件事：
/// - NFKC（全角/半角、兼容字符统一）
/// - 片假名 → 平假名（ASR 与歌词经常一个用片假名一个用平假名）
/// - 丢掉标点、空白、控制符、记号（歌词里的「！」「、」与 ASR 不会一致）
/// - 保留长音符「ー」与踊り字，它们参与音拍
public enum JapaneseNormalizer {

    public static func normalizeForMatching(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        for scalar in nfkc.unicodeScalars {
            let v = scalar.value
            // 片假名 → 平假名
            if (0x30A1...0x30F6).contains(v) {
                out.append(Unicode.Scalar(v - 0x60)!)
                continue
            }
            if v == 0x30FD { out.append(Unicode.Scalar(0x309D)!); continue }
            if v == 0x30FE { out.append(Unicode.Scalar(0x309E)!); continue }
            if v == 0x30FC || v == 0x309D || v == 0x309E { out.append(scalar); continue }

            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                 .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .connectorPunctuation,
                 .otherPunctuation, .unassigned, .privateUse, .surrogate:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// 用于歌词 ↔ ASR 的语音表记对齐：有可靠日语读音时先转平假名，
    /// 未知读音保留原表记；这只影响内部匹配，不改用户看到或导出的歌词。
    public static func normalizeForAlignment(_ text: String,
                                             readingService: JapaneseReadingService = .init()) -> String {
        let phonetic = readingService.segments(for: text)
            .map { $0.reading ?? $0.surface }
            .joined()
        return normalizeForMatching(phonetic)
    }

    public static func isKana(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else {
            return c.unicodeScalars.allSatisfy { isKana(scalar: $0.value) }
        }
        return isKana(scalar: v)
    }

    static func isKana(scalar v: UInt32) -> Bool {
        (0x3041...0x309F).contains(v) || (0x30A1...0x30FA).contains(v) || v == 0x30FC
    }

    public static func isKanji(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else {
            return c.unicodeScalars.contains { isKanji(scalar: $0.value) }
        }
        return isKanji(scalar: v)
    }

    static func isKanji(scalar v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || v == 0x3005 || v == 0x3007 || (0xF900...0xFAFF).contains(v)
    }

    /// 字符类别的基础替换代价，仅用于恢复歌词与 ASR 文本的相对顺序。
    /// 替换命中不会直接提供时间证据；只有精确字符命中才能锚定歌词时间。
    public static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        if a == b { return 0 }
        let ka = isKana(a), kb = isKana(b)
        let ja = isKanji(a), jb = isKanji(b)
        if ka && kb { return 1.4 }
        if ja && jb { return 1.68 }
        if (ka && jb) || (ja && kb) { return 1.2 }   // 读音 vs 表记，常见且合理
        return 1.4
    }
}
