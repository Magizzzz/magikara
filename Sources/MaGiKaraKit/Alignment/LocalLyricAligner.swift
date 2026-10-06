import Foundation

/// 真实本地对轨器 —— 产品默认路径（RD §8.4）。
///
/// 流程完全本地、离线，不使用任何均分时间的假实现：
///
/// 1. AVFoundation 解码为 16k 单声道 PCM；
/// 2. 逐帧提取 RMS 能量、人声频带谱通量，做浊音检测与起音检测；
/// 3. **粗对齐**：在能量/静音候选边界上做单调动态规划，用「音拍数 × 音拍时长先验」
///    给每句挑一个音频区间，间奏/前奏通过自由跳过自然排除；
/// 4. **强制对齐**：在每句区间内对音拍序列做带时长先验与浊音代价的 DP，
///    解出逐音拍边界；
/// 5. 置信度来自时长拟合、浊音覆盖、边界能量谷质量，并输出低置信度原因。
///
/// 已知限制（真实存在，不隐藏）：这是能量/谱通量驱动的强制对齐，
/// 不是声学模型强制对齐。它对「用户歌词为真值」这一点是可靠的，
/// 但对伴奏密集、混响重、气声多的素材精度会下降，会体现为低置信度。
public struct LocalLyricAligner: LyricAligning {

    public struct Configuration: Sendable {
        public var sampleRate: Double = AudioDecoder.defaultSampleRate
        /// 候选边界的最小间隔（秒）
        public var candidateMinSpacing: Double = 0.18
        /// 音拍时长先验的下限/上限（秒）
        public var minMoraDuration: Double = 0.08
        public var maxMoraDuration: Double = 0.45
        /// 单音拍最短/最长帧数
        public var minMoraFrames: Int = 4
        public var maxMoraFrames: Int = 60
        /// 粗对齐：区间时长与先验不匹配的权重
        public var spanDurationWeight: Double = 3.0
        /// 粗对齐：区间含静音/非人声的权重
        public var spanUnvoicedWeight: Double = 2.2
        /// 强制对齐：音拍时长拟合权重
        public var moraDurationWeight: Double = 1.2
        /// 强制对齐：非浊音帧代价
        public var unvoicedFrameCost: Double = 0.15
        /// 边界落在能量谷 / 起音点的奖励权重
        public var boundaryWeight: Double = 1.5
        /// 粗对齐迭代次数（用于精化音拍时长先验）
        public var refineIterations: Int = 2
        /// 每句至少需要的音拍数（0 表示只警告不报错）
        public var allowEmptyLines: Bool = true

        public init() {}
        public static let `default` = Configuration()
    }

    public var config: Configuration

    public init(config: Configuration = .default) {
        self.config = config
    }

    public var name: String { "LocalLyricAligner（本地能量+谱通量强制对齐）" }
    public var isProductionReady: Bool { true }
    /// 保留但**不再是默认路径**：真实歌曲实测句首平均误差 5.095 秒，仅作降级与局部修正用。
    public var method: AlignmentMethod { .legacyEnergy }

    // MARK: - Entry

    public func align(audioURL: URL,
                      lines: [LyricLineDraft],
                      progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        guard !lines.isEmpty else { throw AlignError.noLyrics }

        progress?(AlignProgress(fraction: 0.02, message: "正在准备音频…"))
        let audio: DecodedAudio
        do {
            audio = try AudioDecoder.decode(url: audioURL, sampleRate: config.sampleRate)
        } catch {
            throw AlignError.decode(error.localizedDescription)
        }
        if Task.isCancelled { throw AlignError.cancelled }
        progress?(AlignProgress(fraction: 0.16, message: "正在准备音频…"))

        let cfg = config
        return try Self.analyze(audio: audio, lines: lines, config: cfg, progress: progress)
    }

    // MARK: - 单句重新对齐

    /// 单句「重新对齐」（RD §8.1）。
    ///
    /// 只在给定时间窗口内重跑，不动其它句，也不重跑整曲。
    public func realign(line: LyricLineDraft,
                        audioURL: URL,
                        window: ClosedRange<Double>,
                        moraDuration: Double? = nil) async throws -> AlignedLyricLine {
        let audio: DecodedAudio
        do {
            audio = try AudioDecoder.decode(url: audioURL, sampleRate: config.sampleRate)
        } catch {
            throw AlignError.decode(error.localizedDescription)
        }
        if Task.isCancelled { throw AlignError.cancelled }

        let features = AudioFeatureExtractor.extract(from: audio)
        let units = line.tokens.flatMap { JapaneseReadingService.alignmentUnits(for: $0) }

        var span = Span(start: max(0, features.frameIndex(forTime: window.lowerBound)),
                        end: min(features.frameCount, features.frameIndex(forTime: window.upperBound) + 1))
        if span.end <= span.start { span.end = min(features.frameCount, span.start + 2) }
        let needed = units.count * config.minMoraFrames
        if span.end - span.start < needed {
            span.end = min(features.frameCount, span.start + needed)
        }

        // 音拍时长先验：优先用调用方给的（例如整曲分析得到的值），
        // 否则在该窗口内用「浊音时长 / 音拍数」估计。
        let prior: Double
        if let moraDuration {
            prior = moraDuration
        } else {
            let voiced = features.meanVoiceScore(from: span.start, to: span.end)
            let dur = Double(span.end - span.start) * features.hopSeconds
            let estimate = units.isEmpty ? 0.2 : (dur * voiced) / Double(units.count)
            prior = estimate.clamped(to: config.minMoraDuration...config.maxMoraDuration)
        }

        let aligned = Self.forceAlignLine(draft: line,
                                         units: units,
                                         span: span,
                                         features: features,
                                         moraDuration: prior,
                                         config: config)
        return QualityChecker.annotate(results: [aligned],
                                       features: features,
                                       audioDuration: audio.duration).first ?? aligned
    }

    // MARK: - Pipeline

    static func analyze(audio: DecodedAudio,
                        lines: [LyricLineDraft],
                        config: Configuration,
                        progress: AlignProgressHandler?) throws -> [AlignedLyricLine] {

        // 音拍序列（用户歌词为真值，只借用读音来拆音拍）
        let unitsPerLine: [[String]] = lines.map { draft in
            draft.tokens.flatMap { JapaneseReadingService.alignmentUnits(for: $0) }
        }
        let totalUnits = unitsPerLine.reduce(0) { $0 + $1.count }

        progress?(AlignProgress(fraction: 0.24, message: "正在识别日语歌词…"))

        let features = AudioFeatureExtractor.extract(from: audio)
        if Task.isCancelled { throw AlignError.cancelled }

        // 只在素材完全没有可用信息时才报错。
        // 真实歌曲常被压得很响（实测动态范围 3.5 dB），二值浊音可能几乎失效，
        // 这时仍然继续，但把「材料不适合能量法」写进结果原因里。
        guard features.frameCount > 2 else { throw AlignError.noVoiceDetected }
        let voicedFrames = features.voiced.reduce(0) { $0 + ($1 ? 1 : 0) }
        let meanLikelihood = features.meanVoiceScore(from: 0, to: features.frameCount)
        let likelihoodSpread: Double = {
            guard !features.voiceLikelihood.isEmpty else { return 0 }
            let sorted = features.voiceLikelihood.sorted()
            return Double(sorted[Int(Double(sorted.count - 1) * 0.95)]
                          - sorted[Int(Double(sorted.count - 1) * 0.15)])
        }()
        if voicedFrames == 0 && likelihoodSpread < 0.05 {
            throw AlignError.noVoiceDetected
        }
        // 音拍时长先验的分母：优先用「浊音帧数 × 帧长」。
        // 不要取 max(..., meanLikelihood × 总时长)：后者在含大量静音的素材上会明显偏大，
        // 把先验整体拉长，粗对齐随之偏移（实测会把 TTS 基线从 199 ms 拖到 ~500 ms）。
        let voicedDuration = voicedFrames > 0
            ? Double(voicedFrames) * features.hopSeconds
            : meanLikelihood * features.duration
        progress?(AlignProgress(fraction: 0.36, message: "正在识别日语歌词…"))

        // 音拍时长先验：先用人声总时长 / 总音拍数做一个保守估计
        var moraDuration = totalUnits > 0 ? voicedDuration / Double(totalUnits) : 0.20
        moraDuration = min(config.maxMoraDuration, max(config.minMoraDuration, moraDuration))

        let candidates = boundaryCandidates(features: features, minSpacing: config.candidateMinSpacing)
        guard candidates.count >= 2 else { throw AlignError.noVoiceDetected }

        progress?(AlignProgress(fraction: 0.46, message: "正在同步演唱位置…"))

        // 粗对齐（迭代精化音拍时长先验）
        var spans: [Span] = []
        for iteration in 0..<max(1, config.refineIterations) {
            if Task.isCancelled { throw AlignError.cancelled }
            spans = coarseAlign(lines: lines,
                                unitsPerLine: unitsPerLine,
                                features: features,
                                candidates: candidates,
                                moraDuration: moraDuration,
                                config: config)
            if iteration < max(1, config.refineIterations) - 1 {
                let refined = refineMoraDuration(spans: spans, unitsPerLine: unitsPerLine,
                                                 features: features, fallback: moraDuration)
                if abs(refined - moraDuration) < 0.005 { moraDuration = refined; break }
                moraDuration = refined
            }
        }

        progress?(AlignProgress(fraction: 0.68, message: "正在同步演唱位置…"))
        if Task.isCancelled { throw AlignError.cancelled }

        // 强制对齐
        var results: [AlignedLyricLine] = []
        results.reserveCapacity(lines.count)

        for (i, draft) in lines.enumerated() {
            if Task.isCancelled { throw AlignError.cancelled }
            let units = unitsPerLine[i]
            var span = spans[i]

            // 保证区间容得下所有音拍
            let needed = units.count * config.minMoraFrames
            if span.end - span.start < needed {
                span.end = min(features.frameCount, span.start + needed)
            }
            if span.end - span.start < 2 {
                span.end = min(features.frameCount, span.start + 2)
            }

            let aligned = forceAlignLine(draft: draft,
                                        units: units,
                                        span: span,
                                        features: features,
                                        moraDuration: moraDuration,
                                        config: config)
            results.append(aligned)

            let frac = 0.68 + 0.22 * (Double(i + 1) / Double(lines.count))
            progress?(AlignProgress(fraction: frac, message: "正在生成假名与扫色…"))
        }

        progress?(AlignProgress(fraction: 0.92, message: "正在检查成品…"))

        let checked = QualityChecker.annotate(results: results,
                                             features: features,
                                             audioDuration: audio.duration)
        progress?(AlignProgress(fraction: 1.0, message: "完成"))
        return checked
    }

    // MARK: - 候选边界

    /// 候选边界 = 能量局部极小 + 静音段中心。强制对齐在这些位置之间单调推进。
    static func boundaryCandidates(features: AudioFeatures, minSpacing: Double) -> [Int] {
        let n = features.frameCount
        guard n > 1 else { return [0] }
        let minGap = max(1, Int(minSpacing / features.hopSeconds))

        var scored: [(frame: Int, score: Float)] = []
        scored.reserveCapacity(n)
        for f in 0..<n {
            let dip = features.dipScore(frame: f, radius: 5)
            let quiet = 1 - features.energyNorm[f]
            let unvoicedBonus: Float = features.voiced[f] ? 0 : 0.6
            scored.append((f, dip * 0.5 + quiet * 0.3 + unvoicedBonus))
        }

        // 按分数降序贪心挑选，保证最小间隔
        var taken = [Bool](repeating: false, count: n)
        var chosen: [Int] = []
        for item in scored.sorted(by: { $0.score > $1.score }) {
            let f = item.frame
            if taken[f] { continue }
            chosen.append(f)
            let lo = max(0, f - minGap)
            let hi = min(n - 1, f + minGap)
            for k in lo...hi { taken[k] = true }
        }
        var result = Set(chosen)
        result.insert(0)
        result.insert(n - 1)
        return result.sorted()
    }

    // MARK: - 粗对齐

    struct Span: Sendable {
        var start: Int   // frame
        var end: Int     // frame (exclusive)
    }

    static func coarseAlign(lines: [LyricLineDraft],
                            unitsPerLine: [[String]],
                            features: AudioFeatures,
                            candidates: [Int],
                            moraDuration: Double,
                            config: Configuration) -> [Span] {
        let n = lines.count
        let c = candidates.count
        let hop = features.hopSeconds
        let duration = features.duration

        // 每句期望时长
        var expected = [Double](repeating: 1.0, count: n)
        for i in 0..<n {
            let u = unitsPerLine[i].count
            if u > 0 {
                expected[i] = Double(u) * moraDuration
            } else {
                expected[i] = max(0.5, Double(lines[i].text.count) * 0.12)
            }
        }

        var best = [[Double]](repeating: [Double](repeating: .infinity, count: c), count: n)
        var chosenStart = [[Int]](repeating: [Int](repeating: -1, count: c), count: n)
        var chosenPrevEnd = [[Int]](repeating: [Int](repeating: -1, count: c), count: n)

        for i in 0..<n {
            let e = expected[i]
            let minDur = max(0.25, 0.40 * e)
            let maxDur = min(duration, max(1.5, 2.90 * e))

            // 上一句在候选 a 之前（含）的最优收尾
            var prefixMin = [Double](repeating: .infinity, count: c)
            var prefixArg = [Int](repeating: -1, count: c)
            if i > 0 {
                var m = Double.infinity
                var arg = -1
                for a in 0..<c {
                    if best[i - 1][a] < m { m = best[i - 1][a]; arg = a }
                    prefixMin[a] = m
                    prefixArg[a] = arg
                }
            }

            for a in 0..<c {
                let base: Double
                if i == 0 {
                    base = 0                      // 开头允许自由跳过前奏
                } else {
                    base = prefixMin[a]
                }
                if !base.isFinite { continue }

                let aTime = Double(candidates[a]) * hop
                // 跳过时长短于下限的候选
                var j = a + 1
                while j < c && (Double(candidates[j]) * hop - aTime) < minDur { j += 1 }
                while j < c {
                    let bTime = Double(candidates[j]) * hop
                    let dur = bTime - aTime
                    if dur > maxDur { break }
                    let cost = base + spanCost(startFrame: candidates[a],
                                               endFrame: candidates[j],
                                               expected: e,
                                               features: features,
                                               config: config)
                    if cost < best[i][j] {
                        best[i][j] = cost
                        chosenStart[i][j] = a
                        chosenPrevEnd[i][j] = (i == 0) ? -1 : prefixArg[a]
                    }
                    j += 1
                }
            }
        }

        // 回溯
        var spans = [Span](repeating: Span(start: 0, end: 0), count: n)
        var endIdx = -1
        var endCost = Double.infinity
        for j in 0..<c where best[n - 1][j] < endCost {
            endCost = best[n - 1][j]
            endIdx = j
        }
        guard endIdx >= 0 else {
            // 完全无法分配（音频过短）：退化为整段覆盖，并让质量检查标红
            let per = max(1, features.frameCount / max(1, n))
            for i in 0..<n {
                spans[i] = Span(start: min(features.frameCount - 1, i * per),
                                end: min(features.frameCount, (i + 1) * per))
            }
            return spans
        }

        var j = endIdx
        for i in stride(from: n - 1, through: 0, by: -1) {
            let a = max(0, chosenStart[i][j])
            spans[i] = Span(start: candidates[a], end: candidates[j])
            j = chosenPrevEnd[i][j]
            if j < 0 { j = a }
        }
        return spans
    }

    static func spanCost(startFrame: Int,
                         endFrame: Int,
                         expected: Double,
                         features: AudioFeatures,
                         config: Configuration) -> Double {
        let hop = features.hopSeconds
        let dur = Double(endFrame - startFrame) * hop
        guard dur > 0 else { return 1e6 }
        let ratio = max(1e-3, dur / max(1e-3, expected))
        let durPenalty = config.spanDurationWeight * pow(log(ratio), 2)
        // 用连续人声似然，而不是二值浊音：密集伴奏下二值几乎恒为真，失去区分度
        let unvoiced = 1 - features.meanVoiceScore(from: startFrame, to: endFrame)
        let unvoicedPenalty = config.spanUnvoicedWeight * unvoiced
        let shortPenalty = dur < 0.25 ? 10.0 : 0.0
        return durPenalty + unvoicedPenalty + shortPenalty
    }

    static func refineMoraDuration(spans: [Span],
                                   unitsPerLine: [[String]],
                                   features: AudioFeatures,
                                   fallback: Double) -> Double {
        var totalTime = 0.0
        var totalUnits = 0
        for (i, span) in spans.enumerated() {
            let u = unitsPerLine[i].count
            guard u > 0 else { continue }
            let dur = Double(span.end - span.start) * features.hopSeconds
            guard dur > 0.2 else { continue }
            totalTime += dur
            totalUnits += u
        }
        guard totalUnits > 0, totalTime > 0 else { return fallback }
        let estimate = totalTime / Double(totalUnits)
        return min(0.45, max(0.08, estimate))
    }

    // MARK: - 强制对齐

    static func forceAlignLine(draft: LyricLineDraft,
                               units: [String],
                               span: Span,
                               features: AudioFeatures,
                               moraDuration: Double,
                               config: Configuration) -> AlignedLyricLine {
        let hop = features.hopSeconds
        let k = units.count
        let a = max(0, min(features.frameCount - 1, span.start))
        let b = max(a + 1, min(features.frameCount, span.end))
        let spanLen = b - a

        // 没有音拍：只给出区间内的人声范围，置信度为 0 并说明原因
        if k == 0 {
            let (s, e) = voicedExtent(features: features, from: a, to: b)
            return AlignedLyricLine(id: draft.id,
                                    order: draft.order,
                                    singStart: Double(s) * hop,
                                    singEnd: Double(max(s + 1, e)) * hop,
                                    confidence: 0,
                                    tokens: draft.tokens,
                                    reasons: ["该句没有可对齐的音拍（无歌词文字或全为标点）"])
        }

        let moraFrames = max(Double(config.minMoraFrames), moraDuration / hop)
        let minD = config.minMoraFrames
        let maxD = config.maxMoraFrames

        // 非人声程度的前缀和，用于 O(1) 段代价。
        // 用 (1 - 似然) 而不是 0/1，让密集伴奏下仍有区分度。
        var unvoicedPrefix = [Double](repeating: 0, count: spanLen + 1)
        for t in 0..<spanLen {
            unvoicedPrefix[t + 1] = unvoicedPrefix[t] + (1 - Double(features.voiceScore(a + t)))
        }
        func unvoicedMass(_ from: Int, _ to: Int) -> Double {
            unvoicedPrefix[to - a] - unvoicedPrefix[from - a]
        }

        // 边界代价（落在能量谷/起音点则奖励，即为负代价）
        var boundaryCost = [Double](repeating: 0, count: spanLen + 1)
        for t in 0..<spanLen {
            let f = a + t
            let dip = Double(features.dipScore(frame: f, radius: 5))
            let onset = Double(features.onsetStrength(frame: f, radius: 6))
            boundaryCost[t] = -config.boundaryWeight * (0.6 * dip + 0.4 * onset)
        }

        let inf = Double.infinity
        var dp = [[Double]](repeating: [Double](repeating: inf, count: spanLen + 1), count: k + 1)
        var back = [[Int]](repeating: [Int](repeating: -1, count: spanLen + 1), count: k + 1)

        // 起始边界：允许在区间内任意位置，稍微惩罚偏离区间起点
        let maxStartOffset = max(0, spanLen - k * minD)
        for t in 0...maxStartOffset {
            let drift = 0.4 * Double(t) / Double(max(1, spanLen))
            dp[0][t] = boundaryCost[t] + drift
        }

        for m in 1...k {
            let lo = m * minD
            let hi = min(spanLen, m * maxD)
            if lo > hi { break }
            for t in lo...hi {
                var bestCost = inf
                var bestTp = -1
                let tpLo = max((m - 1) * minD, t - maxD)
                let tpHi = min(t - minD, spanLen)
                if tpLo <= tpHi {
                    for tp in tpLo...tpHi {
                        let prev = dp[m - 1][tp]
                        if !prev.isFinite { continue }
                        let d = Double(t - tp)
                        let durPenalty = config.moraDurationWeight * pow(log(d / moraFrames), 2)
                        let uv = unvoicedMass(a + tp, a + t) * config.unvoicedFrameCost
                        var startAdd = 0.0
                        if m >= 2 { startAdd = boundaryCost[tp] }
                        let cost = prev + durPenalty + uv + startAdd
                        if cost < bestCost {
                            bestCost = cost
                            bestTp = tp
                        }
                    }
                }
                dp[m][t] = bestCost
                back[m][t] = bestTp
            }
        }

        // 结束边界：可以在区间内任意位置
        var endT = -1
        var endBest = inf
        let endLo = min(spanLen, k * minD)
        if endLo <= spanLen {
            for t in endLo...spanLen {
                let v = dp[k][t]
                if !v.isFinite { continue }
                let drift = 0.4 * Double(spanLen - t) / Double(max(1, spanLen))
                let total = v + boundaryCost[t] + drift
                if total < endBest {
                    endBest = total
                    endT = t
                }
            }
        }

        // 极端情况（区间太短）退化为按先验铺开，并标记低置信度
        var boundaries = [Int](repeating: a, count: k + 1)
        var degenerate = false
        if endT < 0 {
            degenerate = true
            for idx in 0...k {
                boundaries[idx] = a + Int((Double(idx) * Double(spanLen) / Double(k)).rounded())
            }
            boundaries[k] = b
        } else {
            var t = endT
            for m in stride(from: k, through: 1, by: -1) {
                boundaries[m] = a + t
                let tp = back[m][t]
                t = tp < 0 ? max(0, t - minD) : tp
            }
            boundaries[0] = a + t
        }

        // 逐音拍置信度
        var moraConfidence = [Double](repeating: 0, count: k)
        for m in 0..<k {
            let s = boundaries[m]
            let e = max(s + 1, boundaries[m + 1])
            let d = Double(e - s)
            let durFit = exp(-abs(log(d / moraFrames)))
            let voicedFrac = 1 - unvoicedMass(s, e) / max(1, d)
            let bq = (-(boundaryCost[max(0, min(spanLen, s - a))] + boundaryCost[max(0, min(spanLen, e - a))]))
                / max(1e-6, 2 * config.boundaryWeight)
            let conf = 0.45 * durFit + 0.35 * voicedFrac + 0.20 * max(0, min(1, bq))
            moraConfidence[m] = max(0, min(1, conf))
        }

        // 写回 token
        var tokens = draft.tokens
        var offset = 0
        for ti in tokens.indices {
            let u = JapaneseReadingService.alignmentUnits(for: tokens[ti])
            guard u.count > 0, offset + u.count <= k else {
                tokens[ti].morae = []
                continue
            }
            var morae: [MoraTiming] = []
            morae.reserveCapacity(u.count)
            for j in 0..<u.count {
                let idx = offset + j
                let s = Double(boundaries[idx]) * hop
                let e = Double(max(boundaries[idx] + 1, boundaries[idx + 1])) * hop
                morae.append(MoraTiming(mora: u[j], start: s, end: e, confidence: moraConfidence[idx]))
            }
            tokens[ti].morae = morae
            offset += u.count
        }

        let singStart = Double(boundaries[0]) * hop
        let singEnd = Double(max(boundaries[0] + 1, boundaries[k])) * hop
        let actualDur = singEnd - singStart
        let expectedDur = Double(k) * moraDuration
        let spanFit = exp(-abs(log(max(1e-3, actualDur) / max(1e-3, expectedDur))))
        let coverage = 1 - unvoicedMass(boundaries[0], max(boundaries[0] + 1, boundaries[k]))
            / Double(max(1, boundaries[k] - boundaries[0]))
        let meanMora = moraConfidence.reduce(0, +) / Double(k)

        var confidence = 0.40 * spanFit + 0.25 * coverage + 0.35 * meanMora
        if degenerate { confidence = min(confidence, 0.45) }
        confidence = max(0, min(1, confidence))

        var reasons: [String] = []
        if degenerate { reasons.append("可用音频区间过短，音拍时间只能按先验铺开") }
        if coverage < 0.55 { reasons.append("该句区间内人声比例偏低（可能伴奏密集或分句有误）") }
        if spanFit < 0.70 { reasons.append("整句时长与音拍数不匹配（可能漏句、串句或重复段错配）") }
        if meanMora < 0.60 { reasons.append("音拍边界不够稳定") }
        let onsetNearStart = features.onsets.contains { abs($0 - singStart) < 0.30 }
        if !onsetNearStart { reasons.append("句首附近没有检测到起音") }

        return AlignedLyricLine(id: draft.id,
                                order: draft.order,
                                singStart: singStart,
                                singEnd: singEnd,
                                confidence: confidence,
                                tokens: tokens,
                                reasons: reasons,
                                method: .legacyEnergy,
                                evidence: .durationPrior)
    }

    /// 区间内第一段与最后一段浊音的帧范围。
    static func voicedExtent(features: AudioFeatures, from: Int, to: Int) -> (Int, Int) {
        var s = -1
        var e = -1
        var i = from
        while i < to {
            if features.voiced[i] {
                if s < 0 { s = i }
                e = i
            }
            i += 1
        }
        if s < 0 { return (from, min(to, from + 1)) }
        return (s, e + 1)
    }
}
