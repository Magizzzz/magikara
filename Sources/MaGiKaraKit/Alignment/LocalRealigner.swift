import Foundation

/// 第二轮局部对齐：只处理**证据弱或结构性错位**的句子。
///
/// 三类输入：
/// 1. `interpolated`：完全没有 ASR 证据，时间来自插值；
/// 2. 低证据质量：有"直接证据"但逐字命中率极低（典型的垃圾匹配）；
/// 3. 结构性错位：时间离插值估计很远，且没有字面证据。
///
/// 处理方式（都在局部窗口内，不动已经可靠的句子）：
/// - 在 [上一句可靠末尾, 下一句可靠开头] 的窗口内**重新切分演唱区**；
/// - 用**带强约束的歌词文本**重新做逐字 DP（替换代价提高、禁止跨大空隙），
///   逼它要么找到真实对应、要么承认没有；
/// - 只有命中率达到阈值才升级为 `asrTokens` 证据，否则保持插值并把置信度压住。
///
/// 核心原则：**不允许把没有证据的结果标成高置信度。**
public enum LocalRealigner {

    /// Reject bad direct anchors that jump backwards or claim implausibly long
    /// spans, then rebuild those lines between the surviving chronological anchors.
    /// This is a final safety net for ASR/local-realign output, not an accuracy
    /// estimator: rejected lines remain low-confidence interpolations.
    static func enforceChronologicalOrder(lyrics: [String],
                                          match: LyricASRMatch,
                                          audioDuration: Double,
                                          speechStart: Double = 0)
        -> (match: LyricASRMatch, rejectedDirectCount: Int) {
        guard !lyrics.isEmpty, !match.lines.isEmpty else { return (match, 0) }

        var lines = match.lines
        var anchors: [Int] = []
        var lastAnchorStart = -Double.infinity
        var rejected = 0
        var removedMatchedCharacters = 0
        let count = min(lyrics.count, lines.count)

        for index in 0..<count {
            guard lines[index].hasDirectEvidence else { continue }
            let start = lines[index].start ?? .nan
            let end = lines[index].end ?? .nan
            let maxDuration = max(8.0, Double(lyrics[index].count) * 0.75)
            let isValid = start.isFinite && end.isFinite
                && start >= 0 && end > start
                && end <= audioDuration + 0.25
                && end - start <= maxDuration
                && start >= lastAnchorStart
            guard isValid else {
                rejected += 1
                removedMatchedCharacters += lines[index].charTimes.filter { $0 != nil }.count
                lines[index].start = nil
                lines[index].end = nil
                lines[index].charTimes = Array(repeating: nil, count: lines[index].charTimes.count)
                lines[index].charEnds = Array(repeating: nil, count: lines[index].charEnds.count)
                lines[index].evidenceQuality = 0
                lines[index].hasDirectEvidence = false
                continue
            }
            anchors.append(index)
            lastAnchorStart = start
        }

        guard rejected > 0 else { return (match, 0) }

        let endOfAudio = max(speechStart, audioDuration.isFinite ? audioDuration : speechStart)
        var cursor = 0
        while cursor < count {
            guard !lines[cursor].hasDirectEvidence else {
                cursor += 1
                continue
            }
            let startIndex = cursor
            while cursor < count, !lines[cursor].hasDirectEvidence { cursor += 1 }
            let endIndex = cursor
            let previous = anchors.last { $0 < startIndex }
            let next = anchors.first { $0 >= endIndex }
            let lo = previous.flatMap { lines[$0].start } ?? max(0, speechStart)
            let hi = next.flatMap { lines[$0].start } ?? endOfAudio
            let span = max(0, hi - lo)
            let totalWeight = (startIndex..<endIndex).reduce(0.0) {
                $0 + Double(max(1, lyrics[min($1, lyrics.count - 1)].count))
            }
            var timeCursor = lo
            for index in startIndex..<endIndex {
                let weight = Double(max(1, lyrics[min(index, lyrics.count - 1)].count))
                let share = span * weight / max(1, totalWeight)
                let start = timeCursor + share * 0.12
                let end = max(start + 0.10, timeCursor + share * 0.88)
                lines[index].start = start
                lines[index].end = end
                lines[index].charTimes = Array(repeating: nil, count: lines[index].charTimes.count)
                lines[index].charEnds = Array(repeating: nil, count: lines[index].charEnds.count)
                lines[index].evidenceQuality = 0
                lines[index].hasDirectEvidence = false
                timeCursor += share
            }
        }

        let repaired = LyricASRMatch(lines: lines,
                                     regionCount: match.regionCount,
                                     asrCharCount: match.asrCharCount,
                                     matchedCharCount: max(0, match.matchedCharCount
                                                          - removedMatchedCharacters),
                                     totalCost: match.totalCost)
        return (repaired, rejected)
    }

    public struct Config: Sendable {
        /// 判定「证据质量太低」的阈值
        public var weakQualityThreshold: Double = 0.34
        /// 「直接证据」与插值估计相差多少秒以上，视为结构性错位
        public var structuralMismatch: Double = 2.0
        /// 局部重试时要求的最低命中率（比全局更严）
        public var acceptQuality: Double = 0.45
        /// 局部重试的替换代价倍数（提高 → 更不愿接受垃圾匹配）
        public var strictSubstitutionScale: Double = 1.6
        /// 局部窗口向两侧扩展的余量（秒）
        public var windowMargin: Double = 1.5

        public init() {}
        public static let `default` = Config()
    }

    public struct Change: Sendable {
        public var lineIndex: Int
        public var order: Int
        public var from: Double?
        public var to: Double?
        public var kind: String
        public var qualityBefore: Double
        public var qualityAfter: Double
    }

    /// 基于**插值估计**给每行一个一致性参考时间。
    /// 有直接证据的行用其自身时间；其余按相邻锚点与字数比例插入。
    static func interpolationReference(lyrics: [String],
                                       starts: [Double?],
                                       ends: [Double?],
                                       reliableAnchors: [Bool]? = nil,
                                       startBoundary: Double? = nil,
                                       endBoundary: Double? = nil,
                                       usePhoneticReadings: Bool = false) -> [Double] {
        let n = lyrics.count
        var ref = [Double](repeating: 0, count: n)
        let known = (0..<n).filter { index in
            guard starts[index] != nil else { return false }
            guard let reliableAnchors else { return true }
            return reliableAnchors.indices.contains(index) && reliableAnchors[index]
        }
        for i in 0..<n {
            let isReliableAnchor = known.contains(i)
            let prev = known.last { $0 < i }
            let next = known.first { $0 > i }
            let lo: Double
            let hi: Double
            let group: [Int]
            switch (prev, next) {
            case let (.some(previous), .some(following)):
                lo = ends[previous] ?? starts[previous] ?? 0
                hi = starts[following] ?? (lo + 5)
                group = Array((previous + 1)..<following)
            case let (.none, .some(following)):
                guard !isReliableAnchor else { ref[i] = starts[i] ?? 0; continue }
                lo = startBoundary ?? 0
                hi = starts[following] ?? (lo + 5)
                group = Array(0..<following)
            case let (.some(previous), .none):
                guard !isReliableAnchor else { ref[i] = starts[i] ?? 0; continue }
                lo = ends[previous] ?? starts[previous] ?? 0
                hi = endBoundary ?? (lo + 5)
                group = Array((previous + 1)..<n)
            case (.none, .none):
                lo = startBoundary ?? 0
                hi = endBoundary ?? (lo + 5)
                group = Array(0..<n)
            }

            guard group.contains(i) else {
                ref[i] = starts[i] ?? lo
                continue
            }
            let span = max(0.1, hi - lo)
            let total = group.reduce(0) {
                $0 + max(1, LocalRealigner.charCount(lyrics[$1], usePhoneticReadings: usePhoneticReadings))
            }
            var cursor = lo
            for k in group {
                let count = max(1, LocalRealigner.charCount(lyrics[k], usePhoneticReadings: usePhoneticReadings))
                let share = span * Double(count) / Double(max(1, total))
                if k == i { ref[i] = cursor + share * 0.15; break }
                cursor += share
            }
        }
        return ref
    }

    static func charCount(_ s: String, usePhoneticReadings: Bool = false) -> Int {
        if usePhoneticReadings { return JapaneseNormalizer.normalizeForAlignment(s).count }
        return JapaneseNormalizer.normalizeForMatching(s).count
    }

    /// 执行第二轮。返回新的时间与变更记录。
    public static func refine(lyrics: [String],
                              transcript: ASRTranscript,
                              match: LyricASRMatch,
                              config: Config = .default,
                              usePhoneticReadings: Bool = false) -> (starts: [Double?], ends: [Double?],
                                                              quality: [Double],
                                                              evidence: [AlignmentEvidence],
                                                              changes: [Change]) {
        let n = lyrics.count
        var starts = match.lines.map(\.start)
        var ends = match.lines.map(\.end)
        var quality = match.lines.map(\.evidenceQuality)
        var evidence = match.lines.map { $0.hasDirectEvidence ? AlignmentEvidence.asrTokens : .interpolated }
        var changes: [Change] = []

        let reliableAnchors = match.lines.map {
            $0.hasDirectEvidence && $0.evidenceQuality >= config.weakQualityThreshold
        }
        let speechStart = transcript.tokens.first?.start ?? 0
        let lastTokenEnd = transcript.tokens.last?.end ?? transcript.audioDuration
        let ref = interpolationReference(lyrics: lyrics, starts: starts, ends: ends,
                                         reliableAnchors: reliableAnchors,
                                         startBoundary: speechStart,
                                         endBoundary: max(speechStart + 0.3, lastTokenEnd),
                                         usePhoneticReadings: usePhoneticReadings)

        // 归一化后的 ASR 字符流（带归属 token）
        var asrChars: [Character] = []
        var asrOwner: [Int] = []
        for (k, token) in transcript.tokens.enumerated() {
            let normalized = usePhoneticReadings
                ? JapaneseNormalizer.normalizeForAlignment(token.text)
                : JapaneseNormalizer.normalizeForMatching(token.text)
            let chars = Array(normalized)
            for ch in chars { asrChars.append(ch); asrOwner.append(k) }
        }

        // 判定需要处理的句子
        let needsWork: [Int] = (0..<n).filter { i in
            if matchesNilEvidence(match: match, index: i) { return true }
            if quality[i] < config.weakQualityThreshold { return true }
            if let s = starts[i], abs(s - ref[i]) > config.structuralMismatch { return true }
            return false
        }

        for i in needsWork {
            let prevAnchor = (0..<i).last { starts[$0] != nil && !needsWork.contains($0) }
            let nextAnchor = ((i + 1)..<n).first { starts[$0] != nil && !needsWork.contains($0) }
            let loT = prevAnchor.flatMap { ends[$0] } ?? max(0, ref[i] - 6)
            let hiT = nextAnchor.flatMap { starts[$0] } ?? (ref[i] + 6)
            let winLo = loT - config.windowMargin
            let winHi = hiT + config.windowMargin

            // 窗口内的 ASR 字符范围
            let loIdx = asrOwner.firstIndex { transcript.tokens[$0].end >= winLo } ?? 0
            let hiIdx = asrOwner.lastIndex { transcript.tokens[$0].start <= winHi } ?? (asrChars.count - 1)
            guard loIdx <= hiIdx, loIdx < asrChars.count else { continue }

            // 一起重试的连续弱句（含中间还没处理的）
            var group = [i]
            var j = i + 1
            while j < n, needsWork.contains(j) { group.append(j); j += 1 }
            let text = group.flatMap { index in
                Array(usePhoneticReadings
                    ? JapaneseNormalizer.normalizeForAlignment(lyrics[index])
                    : JapaneseNormalizer.normalizeForMatching(lyrics[index]))
            }
            guard !text.isEmpty else { continue }

            var strict = ASRLyricMatcher.Config()
            strict.gapLyricCost = config.strictSubstitutionScale * 0.9
            strict.gapASRCost = 0.4
            strict.minEvidenceQuality = 0
            strict.regionGap = ASRLyricMatcher.Config().regionGap

            let (path, _) = ASRLyricMatcher.alignPathStrict(
                text, Array(asrChars[loIdx...hiIdx]),
                // loIdx/hiIdx 是归一化字符流下标，不是 transcript.tokens 的下标。
                // 一个 ASR 时间片常含多个字符，必须按 asrOwner 回取时长。
                durations: Array(asrOwner[loIdx...hiIdx].map { transcript.tokens[$0].duration }),
                config: strict,
                substitutionScale: config.strictSubstitutionScale)

            var offset = 0
            for li in group {
                let normalized = usePhoneticReadings
                    ? JapaneseNormalizer.normalizeForAlignment(lyrics[li])
                    : JapaneseNormalizer.normalizeForMatching(lyrics[li])
                let chars = Array(normalized)
                let mine = Array(path[offset..<min(path.count, offset + chars.count)])
                offset += chars.count

                var exact = 0
                var ids: [Int] = []
                for (pos, m) in mine.enumerated() {
                    guard let m else { continue }
                    let g = loIdx + m
                    guard g < asrChars.count, pos < chars.count,
                          chars[pos] == asrChars[g] else { continue }
                    exact += 1
                    ids.append(g)
                }
                let q = chars.isEmpty ? 0 : Double(exact) / Double(chars.count)

                let before = starts[li]
                let beforeQ = quality[li]
                if !ids.isEmpty, q >= config.acceptQuality {
                    let s = transcript.tokens[asrOwner[ids[0]]].start
                    let e = transcript.tokens[asrOwner[ids[ids.count - 1]]].end
                    starts[li] = s
                    ends[li] = e
                    quality[li] = q
                    evidence[li] = .asrTokens
                    changes.append(Change(lineIndex: li, order: li + 1, from: before, to: s,
                                          kind: "局部重试找到证据", qualityBefore: beforeQ, qualityAfter: q))
                } else {
                    // 局部重试没有找到可靠证据：回到可信邻句给出的插值位置，
                    // 不要把先前的可疑 ASR 起点继续包装成“插值”。
                    let previousStart = starts[li] ?? ref[li]
                    let previousEnd = ends[li] ?? (previousStart + 1.0)
                    let duration = min(10.0, max(0.3, previousEnd - previousStart))
                    starts[li] = ref[li]
                    ends[li] = ref[li] + duration
                    quality[li] = q
                    evidence[li] = .interpolated
                    changes.append(Change(lineIndex: li, order: li + 1, from: before, to: ref[li],
                                          kind: "局部重试仍无证据，保留插值",
                                          qualityBefore: beforeQ, qualityAfter: q))
                }
            }
        }

        return (starts, ends, quality, evidence, changes)
    }

    static func matchesNilEvidence(match: LyricASRMatch, index: Int) -> Bool {
        index < match.lines.count ? match.lines[index].start == nil : true
    }
}

public extension ASRLyricMatcher {
    /// 带「替换代价放大」的顺序 DP（局部重试用：更不愿接受垃圾匹配）。
    static func alignPathStrict(_ lyric: [Character], _ asr: [Character],
                                durations: [Double],
                                config: Config,
                                substitutionScale: Double) -> ([Int?], Double) {
        let n = lyric.count, m = asr.count
        guard n > 0 else { return ([], 0) }
        guard m > 0 else { return (Array(repeating: nil, count: n), Double(n) * config.gapLyricCost) }
        let insCost: [Double] = (0..<m).map { config.gapASRCost + config.skipTimeWeight * durations[$0] }
        var rows = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        func sub(_ a: Character, _ b: Character) -> Double {
            return JapaneseNormalizer.substitutionCost(a, b) * substitutionScale
        }
        rows[0][0] = 0
        for j in 1...m { rows[0][j] = rows[0][j - 1] + insCost[j - 1] }
        for i in 1...n {
            rows[i][0] = rows[i - 1][0] + config.gapLyricCost
            let lc = lyric[i - 1]
            for j in 1...m {
                rows[i][j] = min(rows[i - 1][j - 1] + sub(lc, asr[j - 1]),
                                 rows[i - 1][j] + config.gapLyricCost,
                                 rows[i][j - 1] + insCost[j - 1])
            }
        }
        var path = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               rows[i][j] == rows[i - 1][j - 1] + sub(lyric[i - 1], asr[j - 1]) {
                path[i - 1] = j - 1; i -= 1; j -= 1
            } else if i > 0, rows[i][j] == rows[i - 1][j] + config.gapLyricCost {
                i -= 1
            } else if j > 0, rows[i][j] == rows[i][j - 1] + insCost[j - 1] {
                j -= 1
            } else {
                break
            }
        }
        return (path, rows[n][m])
    }
}
