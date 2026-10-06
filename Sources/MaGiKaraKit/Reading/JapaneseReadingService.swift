import Foundation

/// 日语读音服务（RD §6.1）。
///
/// 唯一实现，基于 macOS 自带 CFStringTokenizer 的日语分词 + Latin 转写，
/// 再用 ICU 的 Latin-Hiragana 变换还原平假名。全部离线，无第三方依赖。
///
/// 已实测：
///   世界 → せかい / 生きている → いき て いる / 僕は君の名前を呼ぶ → ぼく は きみ の なまえ を よぶ
///   東京 → とうきょう / 今日 → きょう / 運命 → うんめい
///
/// 注意：不要用 `String.applyingTransform(.toLatin)`，它走的是中文拼音路径，
/// 实测「世界」会变成「shì jiè」。
public struct JapaneseReadingService: Sendable {

    public init() {}

    // MARK: 分句

    /// 把粘贴的整段歌词拆成歌词句（RD §2：粘贴日文歌词并拆分为歌词句）。
    public static func splitLyricLines(from raw: String) -> [String] {
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 单行整段粘贴的兜底：按句末标点切
        if lines.count <= 1, let only = lines.first {
            let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?"]
            var parts: [String] = []
            var current = ""
            for ch in only {
                current.append(ch)
                if sentenceEnders.contains(ch) {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(current.trimmingCharacters(in: .whitespaces))
            }
            let cleaned = parts.filter { !$0.isEmpty }
            if cleaned.count > 1 { lines = cleaned }
        }

        // 行内全角空格常用于分隔上下半句，统一成半角空格以便排版与分词
        return lines.map { $0.replacingOccurrences(of: "　", with: " ") }
    }

    // MARK: 分词与读音

    /// 日语分词结果。
    public struct Segment: Sendable {
        public var surface: String
        public var reading: String?     // 平假名；纯假名词为 nil
        public var isKanjiBearing: Bool
    }

    /// 对一行文本分词并给出读音。
    public func segments(for text: String) -> [Segment] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let range = CFRangeMake(0, ns.length)
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            range,
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale
        ) else {
            return [Segment(surface: text, reading: nil, isKanjiBearing: JapaneseText.containsKanji(text))]
        }

        var result: [Segment] = []
        var token = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while token != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard r.length > 0, r.location >= 0 else {
                token = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))

            var latin: String?
            if let attr = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) {
                latin = attr as? String
            }

            let hasKanji = JapaneseText.containsKanji(surface)
            var reading: String?
            if hasKanji, let latin = latin, !latin.isEmpty {
                let hira = JapaneseText.normalizeReading(
                    latin.applyingTransform(StringTransform("Latin-Hiragana"), reverse: false) ?? ""
                )
                // 转写失败时（返回原文或空）宁可不给 Ruby，也不给错读音
                if !hira.isEmpty, hira != surface, hira.unicodeScalars.contains(where: { JapaneseText.isKana($0) }) {
                    reading = hira
                }
            }

            result.append(Segment(surface: surface, reading: reading, isKanjiBearing: hasKanji))
            token = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return result
    }

    /// 单个词的读音（平假名）。
    public func reading(forWord word: String) -> String? {
        segments(for: word).first(where: { $0.surface == word })?.reading
    }

    // MARK: Ruby 对齐（只给汉字注音，假名不重复注音）

    /// 一段「汉字连续区间 → 读音」的对应关系。
    ///
    /// 例：「勝ち筋」读音「かちすじ」会拆成两段：
    ///   - 勝（surface 0..<1）→ か
    ///   - 筋（surface 2..<3）→ すじ
    /// 中间的假名「ち」自身不注音，只作为对齐锚点消耗读音。
    public struct RubyRun: Sendable, Equatable {
        /// token.surface 里的字符偏移（Character 计数）
        public var surfaceStart: Int
        public var surfaceLength: Int
        /// 对应读音（平假名）
        public var reading: String
        /// 该读音在完整 reading 里的字符偏移（用于映射音拍时间）
        public var readingStart: Int

        public init(surfaceStart: Int, surfaceLength: Int, reading: String, readingStart: Int) {
            self.surfaceStart = surfaceStart
            self.surfaceLength = surfaceLength
            self.reading = reading
            self.readingStart = readingStart
        }
    }

    /// Ruby 自动对齐的可信度。
    public enum RubyAlignmentQuality: String, Sendable, Equatable {
        /// 送假名全部命中锚点，汉字读音与整词读音一致。
        case exact
        /// 汉字读音能给出，但读音尾部有未归属内容（需要人工确认）。
        case ambiguous
        /// 无法可靠对齐：宁可不注音，也不能把整词读音盖到混合 token 上。
        case failed
    }

    /// 自动对齐结果。
    public struct RubyAlignment: Sendable, Equatable {
        public var runs: [RubyRun]
        public var quality: RubyAlignmentQuality
        /// 是否需要在 UI 上标记「待确认」。
        public var needsConfirmation: Bool

        public init(runs: [RubyRun],
                    quality: RubyAlignmentQuality,
                    needsConfirmation: Bool) {
            self.runs = runs
            self.quality = quality
            self.needsConfirmation = needsConfirmation
        }

        public static let failed = RubyAlignment(runs: [], quality: .failed, needsConfirmation: true)
    }

    /// 把「表记（可混汉字+假名）」与「整词读音」对齐成若干「汉字读音」段。
    ///
    /// 规则（严格版，宁可不注音也不猜）：
    /// - 连续汉字区间共享一段读音；
    /// - 送假名作为锚点，必须按顺序在读音里找到；找不到就判为无法对齐；
    /// - 只有句尾是汉字时，剩余读音才归给最后一个汉字段；
    /// - 句尾是假名却还有剩余读音，说明读音与表记不可靠，标记待确认。
    ///
    /// 返回空数组表示无法可靠对齐，调用方应直接不显示 Ruby。
    public static func rubyRuns(surface: String, reading: String) -> [RubyRun] {
        alignRuby(surface: surface, reading: reading).runs
    }

    /// 严格对齐并返回可信度，供 UI / 排版决定是否显示与是否标记待确认。
    public static func alignRuby(surface: String, reading: String) -> RubyAlignment {
        let s = Array(surface)
        let r = Array(JapaneseText.normalizeReading(reading))
        guard !s.isEmpty, !r.isEmpty else {
            return RubyAlignment(runs: [], quality: .failed, needsConfirmation: false)
        }
        guard s.contains(where: { JapaneseText.isKanji($0) }) else {
            // 纯假名 / 纯拉丁：本来就不需要 Ruby，不算失败。
            return RubyAlignment(runs: [], quality: .failed, needsConfirmation: false)
        }

        // 把 surface 切成「汉字段 / 假名段」交替序列。
        enum Segment { case kanji(Int, Int); case kana(Int, Int) }
        var segments: [Segment] = []
        var i = 0
        while i < s.count {
            if JapaneseText.isKanji(s[i]) {
                var k = i
                while k < s.count, JapaneseText.isKanji(s[k]) { k += 1 }
                segments.append(.kanji(i, k - i))
                i = k
            } else {
                var k = i
                while k < s.count, !JapaneseText.isKanji(s[k]) { k += 1 }
                segments.append(.kana(i, k - i))
                i = k
            }
        }

        var runs: [RubyRun] = []
        var j = 0
        var pendingKanji: (start: Int, length: Int)?
        var ambiguousTail = false

        for segment in segments {
            switch segment {
            case .kanji(let start, let length):
                // 连续汉字段先挂起，等后面的送假名做锚点后再分配读音。
                if let pending = pendingKanji, pending.start + pending.length == start {
                    pendingKanji = (pending.start, pending.length + length)
                } else {
                    pendingKanji = (start, length)
                }

            case .kana(let start, let length):
                guard let pending = pendingKanji else {
                    // 行首送假名：只消耗读音，不注音。
                    let kanaChars = Array(s[start..<(start + length)])
                    guard let anchor = findKana(kanaChars, in: r, from: j) else {
                        return .failed
                    }
                    j = anchor + length
                    continue
                }
                let kanaChars = Array(s[start..<(start + length)])
                guard let anchor = findKana(kanaChars, in: r, from: j), anchor > j else {
                    // 送假名在读音里找不到，或汉字段拿到空读音：不可靠，放弃。
                    return .failed
                }
                runs.append(RubyRun(surfaceStart: pending.start,
                                    surfaceLength: pending.length,
                                    reading: String(r[j..<anchor]),
                                    readingStart: j))
                j = anchor + length
                pendingKanji = nil
            }
        }

        if let pending = pendingKanji {
            // 句尾是汉字：剩余读音全部归给它（世界 → せかい、今日 → きょう）。
            guard j < r.count else { return .failed }
            runs.append(RubyRun(surfaceStart: pending.start,
                                surfaceLength: pending.length,
                                reading: String(r[j..<r.count]),
                                readingStart: j))
            j = r.count
        } else if j < r.count {
            // 句尾是假名却还有剩余读音：标记录音与表记不一致，需人工确认。
            ambiguousTail = true
        }

        guard !runs.isEmpty else {
            return RubyAlignment(runs: [], quality: .failed, needsConfirmation: true)
        }
        return RubyAlignment(runs: runs,
                             quality: ambiguousTail ? .ambiguous : .exact,
                             needsConfirmation: ambiguousTail)
    }

    /// 在 reading[from...] 里找到 kana 连续段，允许片假名与平假名混写。
    static func findKana(_ kana: [Character], in reading: [Character], from: Int) -> Int? {
        guard !kana.isEmpty else { return nil }
        var start = max(0, from)
        while start + kana.count <= reading.count {
            var matched = true
            for (offset, ch) in kana.enumerated() where !kanaMatches(ch, reading[start + offset]) {
                matched = false
                break
            }
            if matched { return start }
            start += 1
        }
        return nil
    }

    /// 假名比较：片假名统一成平假名后比较。
    static func kanaMatches(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        let na = JapaneseText.katakanaToHiragana(String(a)).first ?? a
        let nb = JapaneseText.katakanaToHiragana(String(b)).first ?? b
        return na == nb
    }

    /// 把 surface 切成连续的汉字段（只用于给每个汉字段生成可编辑槽位）。
    public static func kanjiRuns(in surface: String) -> [RubyRun] {
        let chars = Array(surface)
        var runs: [RubyRun] = []
        var i = 0
        while i < chars.count {
            guard JapaneseText.isKanji(chars[i]) else { i += 1; continue }
            var k = i
            while k < chars.count, JapaneseText.isKanji(chars[k]) { k += 1 }
            runs.append(RubyRun(surfaceStart: i, surfaceLength: k - i, reading: "", readingStart: -1))
            i = k
        }
        return runs
    }

    // MARK: Token 生成

    /// 把一行歌词转成 token 列表（含读音与排版范围）。
    /// - Parameter dictionary: 用户修正过的「表记 → 读音」项目词典，优先级最高。
    public func tokens(for lineText: String, dictionary: [String: String] = [:]) -> [LyricToken] {
        let segs = segments(for: lineText)
        var tokens: [LyricToken] = []
        var cursor = 0
        for seg in segs {
            let surface = seg.surface
            let length = (surface as NSString).length

            var reading: String?
            if let override = dictionary[surface], !override.isEmpty {
                // 用户词典可以直接把纯假名词也改成汉字读音
                reading = JapaneseText.normalizeReading(override)
            } else if seg.isKanjiBearing {
                reading = seg.reading
            }

            tokens.append(LyricToken(surface: surface,
                                     reading: reading,
                                     morae: [],
                                     sourceStart: cursor,
                                     sourceLength: length))
            cursor += length
        }
        return tokens
    }

    /// 依据 token 生成对齐用的音拍序列（纯假名与拉丁词也要参与对齐）。
    ///
    /// 标点与符号（？ ！ … 、 。 「 」 〜 ・ 等）**永远不占音拍**：它们没有读音，送给 Yohane 会因为
    /// 无法转成拉丁音素而让整次对轨失败。过滤必须放在所有分支的出口：标点 token 的「读音」
    /// 往往就是它自己（例如 `？`），走的是第一个分支，根本到不了下面的标点判断。
    public static func alignmentUnits(for token: LyricToken) -> [String] {
        rawAlignmentUnits(for: token).filter(isSingableUnit)
    }

    /// 这个音拍里有没有「能唱」的内容：假名、汉字、拉丁字母或数字。
    /// 全角字母数字先规整成半角再判断；全角标点（！ ？ （ ）…）规整后仍是标点，判为不可唱。
    /// 注意不能直接用 `JapaneseText.isLatinOrDigit`：它把整个全角 ASCII 区 U+FF01–FF5E
    /// （含全部全角标点）都算成了拉丁字母，会把 `？` 误判成可唱。
    static func isSingableUnit(_ unit: String) -> Bool {
        unit.precomposedStringWithCompatibilityMapping.unicodeScalars.contains { scalar in
            JapaneseText.isKana(scalar)
                || JapaneseText.isKanji(scalar)
                || (0x30...0x39).contains(scalar.value)      // 0-9
                || (0x41...0x5A).contains(scalar.value)      // A-Z
                || (0x61...0x7A).contains(scalar.value)      // a-z
                || scalar.value == 0x27                       // 撇号：英文缩写（flower's）里的合法字符，Yohane 词表包含它
        }
    }

    private static func rawAlignmentUnits(for token: LyricToken) -> [String] {
        if let r = token.reading, !r.isEmpty {
            return JapaneseText.morae(from: r)
        }
        if JapaneseText.isAllKana(token.surface) {
            return JapaneseText.morae(from: JapaneseText.normalizeReading(token.surface))
        }
        let trimmed = token.surface.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        let normalizedLatin = trimmed
            .replacingOccurrences(of: "’", with: "'")
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let latinScalars = Array(normalizedLatin.unicodeScalars)
        let hasLatinOrDigit = latinScalars.contains {
            (0x30...0x39).contains($0.value)
                || (0x61...0x7A).contains($0.value)
        }
        let isLatinWord = hasLatinOrDigit && latinScalars.allSatisfy {
            (0x30...0x39).contains($0.value)
                || (0x61...0x7A).contains($0.value)
                || $0.value == 0x27
        }
        if isLatinWord {
            // Yohane 的 CTC 目标是拉丁字符序列。每个字母单独保留边界，
            // 不能把整个单词按元音组重复（例如 here -> [here, here]）。
            return Array(normalizedLatin).map(String.init)
        }
        // 标点或未知字符：不占音拍
        if trimmed.unicodeScalars.allSatisfy({ !JapaneseText.isKana($0) && !JapaneseText.isKanji($0) && !JapaneseText.isLatinOrDigit($0) }) {
            return []
        }
        return [trimmed]
    }

}
