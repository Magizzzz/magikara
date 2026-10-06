import Foundation

/// 单个假设的评估结果 —— 用来客观挑选「哪一路音频识别得最好」。
public struct HypothesisScore: Sendable {
    public var hypothesis: AudioHypothesis
    /// 歌词命中率：逐字完全命中的字符数 / 歌词总字符数
    public var lyricHitRate: Double
    /// 覆盖率：拿到直接 ASR 证据的行数 / 总行数
    public var coverage: Double
    /// 单调性：相邻两句时间不回退的比例
    public var monotonicity: Double
    /// 演唱区一致性：行时间落在某个 ASR 演唱区时间范围内的比例
    public var regionConsistency: Double
    /// 结构性离群比例：行时间与「按相邻锚点插值」的估计相差 >3 秒的比例。
    /// 这一项专门用来否决那些「字符命中率还行、但把某一句甩到几十秒之外」的识别结果。
    public var outlierRate: Double
    /// 综合分（各项等权；只在假设之间比较，不对外声称精度）
    public var score: Double
    /// 诊断：识别出的时间片数、字符数
    public var tokenCount: Int
    public var asrCharCount: Int
    public var elapsedSeconds: Double
    public var errorNote: String?

    public var summaryLine: String {
        String(format: "%@  命中 %.2f 覆盖 %.2f 单调 %.2f 区一致 %.2f 离群 %.2f → %.3f",
               hypothesis.displayName, lyricHitRate, coverage, monotonicity,
               regionConsistency, outlierRate, score)
    }
}

/// 多假设选择器：把同一首歌的多种音频前端分别送 ASR，
/// 用**歌词命中率 / 覆盖率 / 单调性 / 演唱区一致性**挑最好的那一份，
/// 不做任何「凭感觉的固定偏移」。
public enum AudioHypothesisSelector {

    public struct Outcome: Sendable {
        public var best: ASRTranscript
        public var bestHypothesis: AudioHypothesis
        public var scores: [HypothesisScore]
        /// 各假设的匹配结果（已经是时间轴压回后的）
        public var matches: [AudioHypothesis: LyricASRMatch]

        public var comparisonReport: String {
            scores.map(\.summaryLine).joined(separator: "\n")
        }
    }

    public static func evaluate(hypothesis: AudioHypothesis,
                                wavURL: URL,
                                transcript raw: ASRTranscript,
                                lyrics: [String],
                                matcherConfig: ASRLyricMatcher.Config,
                                elapsed: Double) -> (HypothesisScore, ASRTranscript, LyricASRMatch) {
        let scale = hypothesis.timeScale
        let transcript = scale == 1.0 ? raw : scaled(raw, by: scale)
        let match = ASRLyricMatcher.match(lyrics: lyrics, transcript: transcript, config: matcherConfig)

        let totalChars = max(1, lyrics.reduce(0) {
            $0 + Self.charCount($1, usePhoneticReadings: matcherConfig.usePhoneticReadings)
        })
        let exactTotal = match.lines.reduce(0.0) {
            $0 + $1.evidenceQuality * Double(max(1, charCount(
                lyrics[$1.lineIndex], usePhoneticReadings: matcherConfig.usePhoneticReadings)))
        }
        let lyricHitRate = exactTotal / Double(totalChars)

        let direct = match.lines.filter(\.hasDirectEvidence).count
        let coverage = Double(direct) / Double(max(1, match.lines.count))

        var monoNumerator = 0
        var monoDenominator = 0
        for (a, b) in zip(match.lines, match.lines.dropFirst()) {
            guard let sa = a.start, let sb = b.start else { continue }
            monoDenominator += 1
            if sb >= sa - 1e-6 { monoNumerator += 1 }
        }
        let monotonicity = monoDenominator == 0 ? 0 : Double(monoNumerator) / Double(monoDenominator)

        // 演唱区一致性：行起点是否落在某个演唱区的时间范围内
        let starts = transcript.tokens.map(\.start)
        let ends = transcript.tokens.map(\.end)
        var regionSpans: [(Double, Double)] = []
        var spanStart: Double?
        var spanEnd: Double = 0
        for (i, t) in transcript.tokens.enumerated() {
            if let s = spanStart {
                if t.start - spanEnd > matcherConfig.regionGap {
                    regionSpans.append((s, spanEnd))
                    spanStart = t.start
                }
            } else {
                spanStart = t.start
            }
            spanEnd = t.end
            _ = i
        }
        if let s = spanStart { regionSpans.append((s, spanEnd)) }
        _ = starts; _ = ends

        var inside = 0
        var considered = 0
        for line in match.lines {
            guard let st = line.start else { continue }
            considered += 1
            // 允许 0.5 秒容差
            if regionSpans.contains(where: { st >= $0.0 - 0.5 && st <= $0.1 + 0.5 }) { inside += 1 }
        }
        let regionConsistency = considered == 0 ? 0 : Double(inside) / Double(considered)

        // 结构性离群：与插值估计差 >3 秒的行占比
        let speechStart = transcript.tokens.first?.start ?? 0
        let ref = LocalRealigner.interpolationReference(
            lyrics: lyrics,
            starts: match.lines.map(\.start),
            ends: match.lines.map(\.end),
            reliableAnchors: match.lines.map {
                $0.hasDirectEvidence && $0.evidenceQuality >= matcherConfig.minEvidenceQuality
            },
            startBoundary: speechStart,
            endBoundary: max(speechStart + 0.3,
                             transcript.tokens.last?.end ?? transcript.audioDuration),
            usePhoneticReadings: matcherConfig.usePhoneticReadings)
        var outliers = 0
        var consideredLines = 0
        for (i, line) in match.lines.enumerated() {
            guard let st = line.start, i < ref.count else { continue }
            consideredLines += 1
            if abs(st - ref[i]) > 3.0 { outliers += 1 }
        }
        let outlierRate = consideredLines == 0 ? 0 : Double(outliers) / Double(consideredLines)

        // 离群要**扣分**，否则「命中率还行但把某句甩到几十秒外」的结果会被选中
        let score = 0.38 * lyricHitRate + 0.24 * coverage + 0.14 * monotonicity
                  + 0.24 * regionConsistency - 0.60 * outlierRate
        let s = HypothesisScore(hypothesis: hypothesis,
                                lyricHitRate: lyricHitRate,
                                coverage: coverage,
                                monotonicity: monotonicity,
                                regionConsistency: regionConsistency,
                                outlierRate: outlierRate,
                                score: score,
                                tokenCount: transcript.tokens.count,
                                asrCharCount: match.asrCharCount,
                                elapsedSeconds: elapsed,
                                errorNote: nil)
        return (s, transcript, match)
    }

    static func charCount(_ s: String, usePhoneticReadings: Bool = false) -> Int {
        if usePhoneticReadings { return JapaneseNormalizer.normalizeForAlignment(s).count }
        return JapaneseNormalizer.normalizeForMatching(s).count
    }

    /// 放慢假设要把它识别出来的时间轴压回原始时间轴。
    public static func scaled(_ t: ASRTranscript, by scale: Double) -> ASRTranscript {
        var copy = t
        copy.tokens = t.tokens.map { ASRToken(text: $0.text, start: $0.start * scale, end: $0.end * scale) }
        copy.audioDuration = t.audioDuration * scale
        copy.engine = "\(t.engine) · 时间轴已压回 \(scale)×"
        return copy
    }
}
