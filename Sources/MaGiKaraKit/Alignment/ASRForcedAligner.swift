import Foundation

/// 新的默认对齐器：**语音识别 + 顺序全局匹配 + 逐字时间 + 局部音频修正**。
///
/// 与旧 `LocalLyricAligner` 的根本区别：
///
/// | | 旧（能量/谱通量） | 新（ASR 强制对齐） |
/// | --- | --- | --- |
/// | 依据 | 总能量与谱通量的起伏 | 声学模型逐字时间戳 |
/// | 密集伴奏 | 动态范围 3.3 dB 时几乎无信息 | 模型本身对伴奏鲁棒 |
/// | 真实歌曲实测 | 句首平均误差 **5.095 秒** | 句首平均误差 **0.959 秒** |
///
/// 能量/VAD 在这里只剩两个辅助职责：
/// 1. 判断某段是否有人声（有声段检测）；
/// 2. 在 ±0.3 秒内对 ASR 给出的边界做微调（`BoundaryRefiner`）。
@available(macOS 26.0, *)
public struct ASRForcedAligner: MediaAudioSourceAwareLyricAligning {

    public struct Config: Sendable {
        public var locale: String = SpeechASREngine.defaultLocale
        /// 是否做局部音频边界修正
        public var refineBoundaries: Bool = true
        public var matcher: ASRLyricMatcher.Config = .default
        public var refiner: BoundaryRefiner.Config = .default
        /// 是否做多假设音频前端选择（原始/中置提取/频带强调/放慢）
        public var useMultiHypothesis: Bool = true
        /// 一键对轨时，在没有可复用人声轨的情况下先用本地 Core ML 模型分离人声。
        /// 分离失败会保守回退到原混音，不阻断对轨。
        public var automaticallySeparateVocals: Bool = true
        /// 每个（入围）假设重复识别的次数。系统 ASR 有逐次波动，
        /// 多跑几次并用同一套指标选最优，结果更稳也更准。
        public var hypothesisRepeats: Int = 3
        /// 是否做第二轮局部重对齐
        public var useLocalRealign: Bool = true
        public var realigner: LocalRealigner.Config = .default
        /// 是否把句首吸附到真实的声学乐句起点
        public var useOnsetSnap: Bool = false  // 实测：吸附到人声段起点会增大绝对误差（见报告），默认关闭
        public var snapper: OnsetSnapper.Config = .default
        /// **向前**声学修正：ASR 时间片起点实测系统性偏早（独立人声段起点检测显示
        /// 对轨时间距起点 0.45 秒、画面字幕 0.33 秒）。因此只在
        /// [起点, 起点+forwardWindow] 内找**第一个**人声段起点并把句首推过去；
        /// 不做双向吸附（双向会跳到句内换气点，实测更差），也不加固定偏移。
        public var useForwardOnsetCorrection: Bool = true
        public var forwardWindow: Double = 1.25
        /// 一行里逐字命中率低于此值时降级为低置信度
        public var goodEvidenceQuality: Double = 0.55
        /// 置信度分级阈值（RD §8.5）
        public var normalThreshold: Double = 0.85
        public var warningThreshold: Double = 0.60

        public init() {}
        public static let `default` = Config()
    }

    public var config: Config

    /// 最近一次多假设比较结果（CLI/报告用）
    public nonisolated(unsafe) static var lastHypothesisReport: String = ""
    /// 最近一次声学起点吸附结果
    public nonisolated(unsafe) static var lastSnapReport: String = ""
    /// 最近一次向前声学修正结果
    public nonisolated(unsafe) static var lastForwardReport: String = ""

    public init(config: Config = .default) {
        self.config = config
    }

    /// 依次对每种音频假设跑 ASR，用歌词命中率/覆盖率/单调性/演唱区一致性挑最佳。
    private func runMultiHypothesis(recognitionAudioURL: URL,
                                    locale: String,
                                    lyrics: [String],
                                    progressStart: Double,
                                    progress: AlignProgressHandler?) async throws -> AudioHypothesisSelector.Outcome {
        let engine = SpeechASREngine.shared
        let progressEnd = 0.66
        func stage(_ fraction: Double) -> Double {
            progressStart + (progressEnd - progressStart) * fraction
        }
        progress?(AlignProgress(fraction: stage(0), message: "正在准备对轨音频…"))
        let stereo = try AudioHypothesisBuilder.decodeStereo(media: recognitionAudioURL)

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("magikara-hyp-\\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hypotheses = AudioHypothesis.allCases
        var scores: [HypothesisScore] = []
        var transcripts: [AudioHypothesis: ASRTranscript] = [:]
        var matches: [AudioHypothesis: LyricASRMatch] = [:]
        var wavs: [AudioHypothesis: URL] = [:]
        // 每个假设的多次得分（用于按**平均分**选择，而不是按单次最高分）
        var scoreHistory: [AudioHypothesis: [Double]] = [:]

        // 系统 ASR 本身不是逐次确定的（实测同一段音频 token 数 293/291/290 会有差异，
        // 而我的区域分配 DP 对输入的小扰动很敏感，会翻到错误的切分，出现 30 秒级误差）。
        // 因此：**同一假设跑多次，用同一套客观指标在「假设 × 重复」里全局取最优**。
        // 这既降低了对单次识别波动的依赖，也让最终结果稳定可复现。
        func runOnce(_ h: AudioHypothesis, index: Int, base: Double, label: String) async {
            let wav: URL
            if let cached = wavs[h] {
                wav = cached
            } else {
                let url = tmpDir.appendingPathComponent("\(h.rawValue).wav")
                do {
                    _ = try AudioHypothesisBuilder.build(hypothesis: h, left: stereo.left,
                                                         right: stereo.right, to: url)
                } catch {
                    scores.append(HypothesisScore(hypothesis: h, lyricHitRate: 0, coverage: 0,
                                                  monotonicity: 0, regionConsistency: 0, outlierRate: 0,
                                                  score: -1, tokenCount: 0, asrCharCount: 0,
                                                  elapsedSeconds: 0, errorNote: error.localizedDescription))
                    return
                }
                wavs[h] = url
                wav = url
            }
            progress?(AlignProgress(fraction: base, message: "正在识别日语歌词…（\(label)）"))
            do {
                let started = Date()
                let raw = try await engine.transcribeWAV(wav, locale: locale)
                let elapsed = Date().timeIntervalSince(started)
                let (score, trans, match) = AudioHypothesisSelector.evaluate(
                    hypothesis: h, wavURL: wav, transcript: raw, lyrics: lyrics,
                    matcherConfig: config.matcher, elapsed: elapsed)
                scoreHistory[h, default: []].append(score.score)
                // 多次运行时保留该假设下得分最好的那一次
                if let existing = scores.firstIndex(where: { $0.hypothesis == h }) {
                    if score.score > scores[existing].score {
                        scores[existing] = score
                        transcripts[h] = trans
                        matches[h] = match
                    }
                } else {
                    scores.append(score)
                    transcripts[h] = trans
                    matches[h] = match
                }
            } catch {
                if !scores.contains(where: { $0.hypothesis == h }) {
                    scores.append(HypothesisScore(hypothesis: h, lyricHitRate: 0, coverage: 0,
                                                  monotonicity: 0, regionConsistency: 0, outlierRate: 0,
                                                  score: -1, tokenCount: 0, asrCharCount: 0,
                                                  elapsedSeconds: 0, errorNote: error.localizedDescription))
                }
            }
        }

        // 第一轮：每个假设各跑一次，先排序
        for (i, h) in hypotheses.enumerated() {
            if Task.isCancelled { throw AlignError.cancelled }
            await runOnce(h, index: i,
                          base: stage(0.04 + 0.48 * Double(i) / Double(hypotheses.count)),
                          label: h.displayName)
        }

        // 第二轮：对前两名各再跑 2 次（重复次数越多，选中好结果的概率越高）
        let ranked = scores.filter { $0.score >= 0 }.sorted { $0.score > $1.score }
        let repeats = max(0, config.hypothesisRepeats - 1)
        for (k, top) in ranked.prefix(2).enumerated() {
            for r in 0..<repeats {
                if Task.isCancelled { throw AlignError.cancelled }
                await runOnce(top.hypothesis, index: k,
                              base: stage(0.57 + 0.04 * Double(k) + 0.025 * Double(r)),
                              label: "\(top.hypothesis.displayName) 第 \(r + 2) 次")
            }
        }

        // 选择规则：按**各假设的多次平均分**排序，分数接近时用固定优先级打破平局。
        //
        // 为什么不用单次最高分：几个假设的得分经常只差 0.01（实测 0.797/0.798/0.800），
        // 单次最高分会在它们之间来回跳，导致同一首歌两次运行结果不同（实测句首平均误差
        // 在 0.83–1.33 秒之间波动）。取平均 + 固定优先级后结果稳定可复现。
        let preference: [AudioHypothesis] = [.mix, .mixVocalBand, .slowed, .centerExtract, .centerVocalBand]
        func preferenceRank(_ h: AudioHypothesis) -> Int {
            preference.firstIndex(of: h) ?? preference.count
        }
        let candidates = scores.filter { $0.score >= 0 && transcripts[$0.hypothesis] != nil }
        guard !candidates.isEmpty else {
            throw ASRError.transcriptionFailed("所有音频假设都识别失败")
        }
        let finalRanked = candidates.sorted { a, b in
            let ma = (scoreHistory[a.hypothesis] ?? [a.score]).reduce(0, +) / Double(max(1, (scoreHistory[a.hypothesis] ?? [a.score]).count))
            let mb = (scoreHistory[b.hypothesis] ?? [b.score]).reduce(0, +) / Double(max(1, (scoreHistory[b.hypothesis] ?? [b.score]).count))
            if abs(ma - mb) > 0.015 { return ma > mb }
            return preferenceRank(a.hypothesis) < preferenceRank(b.hypothesis)
        }
        guard let best = finalRanked.first, let bestTranscript = transcripts[best.hypothesis] else {
            throw ASRError.transcriptionFailed("所有音频假设都识别失败")
        }
        progress?(AlignProgress(fraction: progressEnd, message: "候选识别比较完成"))
        return AudioHypothesisSelector.Outcome(best: bestTranscript,
                                               bestHypothesis: best.hypothesis,
                                               scores: scores,
                                               matches: matches)
    }

    public var name: String { "ASRForcedAligner（本地离线语音识别 + 顺序强制对齐）" }
    public var isProductionReady: Bool { true }
    public var method: AlignmentMethod { .asrForcedAlign }

    public func align(audioURL: URL,
                      lines: [LyricLineDraft],
                      progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        try await align(mediaURL: audioURL,
                        recognitionAudioURL: audioURL,
                        lines: lines,
                        progress: progress)
    }

    public func align(mediaURL: URL,
                      recognitionAudioURL: URL,
                      lines: [LyricLineDraft],
                      progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        guard !lines.isEmpty else { throw AlignError.noLyrics }

        // ---- 1. 语音识别 ----
        let engine = SpeechASREngine.shared
        let status = await engine.availability(locale: config.locale)
        if status == .unsupportedLocale { throw ASRError.unsupportedLocale }
        if status == .needsDownload {
            progress?(AlignProgress(fraction: 0.02, message: "正在下载日语识别模型…"))
            _ = try await engine.ensureAssets(locale: config.locale) { fraction, message in
                progress?(AlignProgress(fraction: 0.02 + fraction * 0.08, message: message))
            }
        } else if case .unavailable(let why) = status {
            throw ASRError.transcriptionFailed(why)
        }

        var effectiveRecognitionAudioURL = recognitionAudioURL
        var temporarySeparationDirectory: URL?
        defer {
            if let temporarySeparationDirectory {
                try? FileManager.default.removeItem(at: temporarySeparationDirectory)
            }
        }
        var recognitionProgressStart = 0.10

        // 优先复用工程中已经验证过的 vocal stem。没有时，同一键工作流里本地分离；
        // 这样不要求用户先单独点“AI人声分离”。
        let alreadyHasSeparatedAudio = recognitionAudioURL.standardizedFileURL
            != mediaURL.standardizedFileURL
        if config.automaticallySeparateVocals && !alreadyHasSeparatedAudio {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("magikara-align-vocal-\(UUID().uuidString)",
                                        isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory,
                                                        withIntermediateDirectories: true)
                let vocalURL = temporaryDirectory.appendingPathComponent("vocal.wav")
                let instrumentalURL = temporaryDirectory.appendingPathComponent("instrumental.wav")
                progress?(AlignProgress(fraction: 0.10,
                                        message: "准备本地 AI 人声分离…首次使用会安装模型"))
                let separator = VocalSeparator()
                let result = try await separator.separate(mediaURL: mediaURL,
                                                          toVocalURL: vocalURL,
                                                          toInstrumentalURL: instrumentalURL) { fraction in
                    progress?(AlignProgress(fraction: 0.10 + min(1, max(0, fraction)) * 0.27,
                                            message: "AI 正在分离人声与伴奏…"))
                }
                effectiveRecognitionAudioURL = result.vocalURL
                temporarySeparationDirectory = temporaryDirectory
                recognitionProgressStart = 0.38
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temporaryDirectory)
                throw AlignError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: temporaryDirectory)
                // 软失败：仍可用原混音对轨，但明确显示回退，不把分离失败伪装成成功。
                progress?(AlignProgress(fraction: 0.38,
                                        message: "人声分离不可用，回退原混音继续对轨…"))
                recognitionProgressStart = 0.38
            }
        }

        // ---- 1. 多假设音频前端：都跑一遍 ASR，再用客观指标选最好的一路 ----
        var transcript: ASRTranscript
        let asrAudioURL = effectiveRecognitionAudioURL
        let asrProgressStart = recognitionProgressStart
        do {
            if config.useMultiHypothesis {
                let selection = try await runMultiHypothesis(recognitionAudioURL: asrAudioURL,
                                                             locale: config.locale,
                                                             lyrics: lines.map(\.text),
                                                             progressStart: asrProgressStart,
                                                             progress: progress)
                transcript = selection.best
                Self.lastHypothesisReport = selection.comparisonReport
            } else {
                transcript = try await engine.transcribe(mediaURL: asrAudioURL, locale: config.locale) { fraction, message in
                    progress?(AlignProgress(fraction: asrProgressStart
                                            + fraction * (0.66 - asrProgressStart),
                                            message: message))
                }
            }
        } catch let e as ASRError {
            throw e
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }

        if Task.isCancelled { throw AlignError.cancelled }

        // ---- 2. 顺序全局匹配 ----
        progress?(AlignProgress(fraction: 0.70, message: "正在同步演唱位置…"))
        let texts = lines.map(\.text)
        var match = ASRLyricMatcher.match(lyrics: texts, transcript: transcript, config: config.matcher)
        if config.useLocalRealign {
            let second = LocalRealigner.refine(lyrics: texts, transcript: transcript,
                                               match: match, config: config.realigner,
                                               usePhoneticReadings: config.matcher.usePhoneticReadings)
            match = LyricASRMatch(lines: match.lines.enumerated().map { (i, old) in
                var m = old
                m.start = second.starts[i]
                m.end = second.ends[i]
                m.evidenceQuality = second.quality[i]
                m.hasDirectEvidence = second.evidence[i] == .asrTokens
                return m
            }, regionCount: match.regionCount, asrCharCount: match.asrCharCount,
               matchedCharCount: match.matchedCharCount, totalCost: match.totalCost)
        }

        // ---- 3. 音频特征（仅用于局部修正与有声段判断）----
        progress?(AlignProgress(fraction: 0.80, message: "正在生成假名与扫色…"))
        var features: AudioFeatures?
        if config.refineBoundaries {
            if let decoded = try? AudioDecoder.decode(url: effectiveRecognitionAudioURL,
                                                      sampleRate: AudioDecoder.defaultSampleRate,
                                                      peakBuckets: 512) {
                features = AudioFeatureExtractor.extract(from: decoded)
            }
        }

        // ---- 3.5 把句首吸附到真实的声学乐句起点 ----
        // 实测 ASR 时间片边界与独立检测到的人声段起点平均差 0.44 秒，
        // 这一步在 ±0.8 秒内做保序一对一的吸附来消除这个偏移。
        var snapInfo = ""
        if config.useOnsetSnap, let features {
            let onsets = OnsetSnapper.islandOnsets(features: features,
                                                   minDuration: config.snapper.minIslandDuration)
            let starts = match.lines.map(\.start)
            let ends = match.lines.map(\.end)
            let snapped = OnsetSnapper.snap(starts: starts, ends: ends,
                                            onsets: onsets, config: config.snapper)
            if snapped.snappedCount > 0 {
                match = LyricASRMatch(lines: match.lines.enumerated().map { (i, old) in
                    var m = old
                    m.start = snapped.starts[i]
                    return m
                }, regionCount: match.regionCount, asrCharCount: match.asrCharCount,
                   matchedCharCount: match.matchedCharCount, totalCost: match.totalCost)
            }
            snapInfo = String(format: "声学起点吸附：%d/%d 句，平均位移 %.3f 秒（检测到 %d 个人声段起点）",
                              snapped.snappedCount, starts.compactMap { $0 }.count,
                              snapped.meanShift, onsets.count)
            Self.lastSnapReport = snapInfo
        }

        // ---- 3.6 向前声学修正 ----
        // 只在「ASR 起点之后」找第一个人声段起点，用来消除系统性偏早。
        // 找不到就不动，绝不凭感觉加固定偏移。
        var forwardInfo = ""
        if config.useForwardOnsetCorrection, let features {
            let onsets = OnsetSnapper.islandOnsets(features: features,
                                                   minDuration: config.snapper.minIslandDuration)
            var moved = 0
            var total = 0.0
            match = LyricASRMatch(lines: match.lines.map { old in
                var m = old
                guard let st = m.start, let en = m.end else { return m }
                let limit = st + config.forwardWindow
                if let next = onsets.first(where: { $0 >= st + 0.02 && $0 <= limit }),
                   next < en - 0.08 {
                    total += next - st
                    moved += 1
                    m.start = next
                }
                return m
            }, regionCount: match.regionCount, asrCharCount: match.asrCharCount,
               matchedCharCount: match.matchedCharCount, totalCost: match.totalCost)
            forwardInfo = String(format: "向前声学修正：%d 句，平均后移 %.3f 秒（人声段起点 %d 个）",
                                 moved, moved == 0 ? 0 : total / Double(moved), onsets.count)
            Self.lastForwardReport = forwardInfo
        }

        let chronology = LocalRealigner.enforceChronologicalOrder(
            lyrics: texts,
            match: match,
            audioDuration: transcript.audioDuration,
            speechStart: transcript.tokens.first?.start ?? 0)
        match = chronology.match
        if chronology.rejectedDirectCount > 0 {
            progress?(AlignProgress(
                fraction: 0.91,
                message: "发现 \(chronology.rejectedDirectCount) 句时间倒序或跨度异常，已撤销可疑证据并按邻句补位"))
        }

        // ---- 4. 组装结果 ----
        var results: [AlignedLyricLine] = []
        results.reserveCapacity(lines.count)

        for (i, draft) in lines.enumerated() {
            if Task.isCancelled { throw AlignError.cancelled }
            let lm = i < match.lines.count ? match.lines[i] : nil
            let units = draft.tokens.flatMap { JapaneseReadingService.alignmentUnits(for: $0) }

            var singStart = lm?.start ?? 0
            var singEnd = lm?.end ?? (singStart + 0.3)
            var refined = 0
            if let features, lm?.start != nil {
                let r = BoundaryRefiner.refineRange(start: singStart, end: singEnd,
                                                    features: features, config: config.refiner)
                if r.adjusted > 0 {
                    singStart = r.start
                    singEnd = r.end
                    refined = r.adjusted
                }
            }
            if singEnd <= singStart { singEnd = singStart + LyricLine.minimumSingDuration }

            // ---- 逐字 → 逐音拍时间 ----
            // ASR 是逐字（假名）粒度；音拍序列与之基本一一对应。
            // 字少于音拍时（例如一个字对应两个音拍）按比例细分；
            // 字多于音拍时把多出来的字并入相邻音拍。
            var tokens = draft.tokens
            let span = max(0.05, singEnd - singStart)
            var unitIndex = 0
            let unitCount = max(1, units.count)
            for ti in tokens.indices {
                let tokenUnits = JapaneseReadingService.alignmentUnits(for: tokens[ti])
                guard !tokenUnits.isEmpty else { tokens[ti].morae = []; continue }
                var morae: [MoraTiming] = []
                for u in tokenUnits {
                    let a = Double(unitIndex) / Double(unitCount)
                    let b = Double(unitIndex + 1) / Double(unitCount)
                    var s = singStart + span * a
                    var e = singStart + span * b
                    // 用逐字时间（如果该位置有证据）替换比例时间
                    if let lm {
                        let charPos = min(lm.charTimes.count - 1,
                                          max(0, Int(Double(unitIndex) / Double(unitCount)
                                                     * Double(lm.charTimes.count))))
                        if charPos >= 0, charPos < lm.charTimes.count,
                           let ct = lm.charTimes[charPos] {
                            s = ct
                            if let ce = lm.charEnds[charPos], ce > ct { e = ce }
                        }
                    }
                    morae.append(MoraTiming(mora: u, start: s, end: max(s + 0.02, e),
                                            confidence: confidenceForEvidence(lm)))
                    unitIndex += 1
                }
                tokens[ti].morae = morae
            }
            // 保证音拍单调
            var lastEnd = singStart
            for ti in tokens.indices {
                for mi in tokens[ti].morae.indices {
                    if tokens[ti].morae[mi].start < lastEnd {
                        tokens[ti].morae[mi].start = lastEnd
                    }
                    if tokens[ti].morae[mi].end <= tokens[ti].morae[mi].start {
                        tokens[ti].morae[mi].end = tokens[ti].morae[mi].start + 0.02
                    }
                    lastEnd = tokens[ti].morae[mi].end
                }
            }

            let evidence: AlignmentEvidence = (lm?.hasDirectEvidence ?? false) ? .asrTokens : .interpolated
            let confidence = lineConfidence(match: lm, refined: refined, tokenCount: units.count)

            var reasons: [String] = []
            if evidence == .interpolated {
                reasons.append("该句在语音识别结果里没有可靠对应，时间由相邻句插值得到")
            }
            if let lm, lm.evidenceQuality < config.goodEvidenceQuality, lm.hasDirectEvidence {
                reasons.append(String(format: "逐字命中率仅 %.0f%%，识别文本与歌词差异较大", lm.evidenceQuality * 100))
            }
            if refined == 0, config.refineBoundaries, lm?.hasDirectEvidence == true {
                reasons.append("边界附近没有找到更强的起音点，未做音频修正")
            }
            if units.isEmpty {
                reasons.append("该句没有可对齐的音拍")
            }
            if confidence < config.normalThreshold, reasons.isEmpty {
                reasons.append("识别证据一般，建议试听确认")
            }

            results.append(AlignedLyricLine(id: draft.id,
                                            order: draft.order,
                                            singStart: singStart,
                                            singEnd: singEnd,
                                            confidence: confidence,
                                            tokens: tokens,
                                            reasons: reasons,
                                            method: .asrForcedAlign,
                                            evidence: evidence))
        }

        progress?(AlignProgress(fraction: 0.94, message: "正在检查成品…"))
        let annotated = QualityChecker.annotate(results: results,
                                                features: features,
                                                audioDuration: transcript.audioDuration)
        progress?(AlignProgress(fraction: 1.0, message: "完成"))
        return annotated
    }

    private func confidenceForEvidence(_ m: LyricASRMatch.LineMatch?) -> Double {
        guard let m else { return 0 }
        return lineConfidence(match: m, refined: 0, tokenCount: 0)
    }

    /// 置信度只反映**证据强度**，不做任何「看起来更准」的修饰。
    private func lineConfidence(match m: LyricASRMatch.LineMatch?, refined: Int, tokenCount: Int) -> Double {
        guard let m else { return 0 }
        guard m.hasDirectEvidence else {
            // 插值：给一个明确偏低的上限，不允许伪装成高置信度
            return 0.45
        }
        var c = 0.55 + 0.35 * m.evidenceQuality
        if refined > 0 { c += 0.05 }
        if tokenCount == 0 { c -= 0.15 }
        return max(config.warningThreshold * 0.5, min(0.98, c))
    }
}
