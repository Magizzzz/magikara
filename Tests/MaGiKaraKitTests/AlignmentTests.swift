import Testing
import Foundation
@testable import MaGiKaraKit

/// 显示区调度、质量检查、漂移修正、对齐器契约（RD §4 / §8.5 / §9.3）
@Suite struct AlignmentTests {

    @Test func yohaneBackendIsExplicitAndRemainsReviewOnly() {
        let experiment = AlignmentEngineFactory.Tuning.yohaneAudioExperiment
        let backend = LocalYohaneForcedAligner()
        #expect(experiment.backend == .yohaneKaraokeCTC)
        #expect(!experiment.preferScreenOCR)
        #expect(!backend.isProductionReady)
        #expect(backend.method.rawValue == "yohane-forced-align")
        #expect(backend.method.isAudioAutomaticAlignment)
        #expect(AlignmentEvidence.ctcForcedAlignment.displayName == "CTC 歌唱音素证据")
    }

    // MARK: Yohane 符号行

    @Test func yohaneSkipsSymbolOnlyLinesAndReinsertsThemBetweenNeighbours() {
        let first = repeatDraft(order: 1, surface: "はな", reading: "はな")
        let symbol = repeatDraft(order: 2, surface: "♪", reading: "♪")
        let last = repeatDraft(order: 3, surface: "そら", reading: "そら")
        let trailing = repeatDraft(order: 4, surface: "？！", reading: "？！")
        #expect(!LocalYohaneForcedAligner.hasSingableUnits(symbol))
        #expect(!LocalYohaneForcedAligner.hasSingableUnits(trailing))
        #expect(LocalYohaneForcedAligner.hasSingableUnits(first))

        let aligned = [
            AlignedLyricLine(id: first.id, order: 1, singStart: 1, singEnd: 2,
                             confidence: 0.5, tokens: first.tokens),
            AlignedLyricLine(id: last.id, order: 3, singStart: 6, singEnd: 7,
                             confidence: 0.5, tokens: last.tokens),
            // 尾句重复展开出的拷贝占用了序号 4
            AlignedLyricLine(id: UUID(), sourceLineID: last.id, order: 4, singStart: 7, singEnd: 8,
                             confidence: 0.5, tokens: last.tokens),
        ]
        let merged = LocalYohaneForcedAligner.insertUnsingableLines(
            [first, symbol, last, trailing], into: aligned, duration: 10)

        #expect(merged.count == 5)
        #expect(merged[1].id == symbol.id)
        #expect(merged[1].singStart >= 2 && merged[1].singEnd <= 6)
        #expect(merged[1].singEnd > merged[1].singStart)
        #expect(merged[4].id == trailing.id, "尾部符号行排在尾句拷贝之后")
        #expect(merged[4].singStart >= 8 && merged[4].singEnd <= 10)
        #expect(merged[1].evidence == .interpolated)
    }

    // MARK: Yohane 尾句重复展开映射

    private func repeatDraft(order: Int, surface: String, reading: String) -> LyricLineDraft {
        LyricLineDraft(id: UUID(), order: order, text: surface,
                       tokens: [LyricToken(surface: surface, reading: reading)])
    }

    private func repeatMora(_ tokenIndex: Int, _ moraIndex: Int, _ mora: String,
                            _ start: Double, _ end: Double) -> SidecarMoraResult {
        SidecarMoraResult(tokenIndex: tokenIndex, moraIndex: moraIndex, mora: mora,
                          start: start, end: end, score: 0.5)
    }

    private func repeatLine(_ id: String, order: Int, source: Int, repeatIndex: Int,
                            start: Double, end: Double,
                            morae: [SidecarMoraResult]) -> SidecarLineResult {
        SidecarLineResult(id: id, order: order, sourceLineIndex: source,
                          repeatIndex: repeatIndex, start: start, end: end,
                          rawScore: 0.5, morae: morae)
    }

    @Test func yohaneMapAcceptsExpandedRepeatLinesWithUniqueIDsAndMoraMapping() throws {
        let first = repeatDraft(order: 1, surface: "内", reading: "うち")
        let tail = repeatDraft(order: 2, surface: "花", reading: "はな")
        let copyID = UUID().uuidString

        let response = SidecarResponse(
            protocolVersion: 1, ok: true, error: nil, duration: 10, frameSeconds: 0.02,
            inferenceSeconds: 0.1, device: "cpu", warnings: [],
            repeatAnalysis: SidecarRepeatAnalysis(applied: true, count: 3,
                                                  reason: "谱重复支持 3 次", margin: 0.2),
            lines: [
                repeatLine(first.id.uuidString, order: 1, source: 0, repeatIndex: 0,
                           start: 0.5, end: 1.5,
                           morae: [repeatMora(0, 0, "う", 0.5, 1.0),
                                   repeatMora(0, 1, "ち", 1.0, 1.5)]),
                repeatLine(tail.id.uuidString, order: 2, source: 1, repeatIndex: 0,
                           start: 2.0, end: 3.0,
                           morae: [repeatMora(0, 0, "は", 2.0, 2.5),
                                   repeatMora(0, 1, "な", 2.5, 3.0)]),
                repeatLine(copyID, order: 3, source: 1, repeatIndex: 1,
                           start: 3.0, end: 4.0,
                           morae: [repeatMora(0, 0, "は", 3.0, 3.5),
                                   repeatMora(0, 1, "な", 3.5, 4.0)]),
                repeatLine(UUID().uuidString, order: 4, source: 1, repeatIndex: 2,
                           start: 4.0, end: 5.0,
                           morae: [repeatMora(0, 0, "は", 4.0, 4.5),
                                   repeatMora(0, 1, "な", 4.5, 5.0)]),
            ])

        let results = try LocalYohaneForcedAligner.mapAlignedLines(
            response, lines: [first, tail], duration: 10, frameSeconds: 0.02)

        #expect(results.count == 4, "尾句展开后应返回 4 行而不是 2 行")
        #expect(results.map(\.order) == [1, 2, 3, 4], "扩展行顺序必须连续")
        let ids = results.map(\.id)
        #expect(Set(ids).count == ids.count, "扩展行必须保持唯一 id")
        #expect(results[0].id == first.id)
        #expect(results[1].id == tail.id, "第一份拷贝沿用原句 id")
        #expect(results[2].id != tail.id)
        #expect(results[2].sourceLineID == tail.id, "重复出来的新句必须保留原歌词来源")
        #expect(Set(results.flatMap(\.tokens).map(\.id)).count == results.flatMap(\.tokens).count,
                "重复歌词不能复用 token id")
        for line in results.dropFirst() {
            let morae = line.tokens.flatMap(\.morae)
            #expect(morae.map(\.mora) == ["は", "な"], "逐拍映射必须与原歌词一致")
            #expect(morae.allSatisfy { $0.end > $0.start }, "音拍时长必须合法")
        }
        #expect(results[1].reasons.contains { $0.contains("重复证据自动展开") },
                "展开行必须显式标注为需人工校准")
        #expect(results[1].confidence <= 0.84, "展开结果仍不得自动验收")
    }

    @Test func yohaneMapRejectsMoraMismatchOnExpandedLines() {
        let first = repeatDraft(order: 1, surface: "内", reading: "うち")
        let tail = repeatDraft(order: 2, surface: "花", reading: "はな")
        let response = SidecarResponse(
            protocolVersion: 1, ok: true, error: nil, duration: 10, frameSeconds: 0.02,
            inferenceSeconds: 0.1, device: "cpu", warnings: [],
            repeatAnalysis: SidecarRepeatAnalysis(applied: true, count: 2,
                                                  reason: "x", margin: 0.2),
            lines: [
                repeatLine(first.id.uuidString, order: 1, source: 0, repeatIndex: 0,
                           start: 0.5, end: 1.5,
                           morae: [repeatMora(0, 0, "う", 0.5, 1.0),
                                   repeatMora(0, 1, "ち", 1.0, 1.5)]),
                repeatLine(tail.id.uuidString, order: 2, source: 1, repeatIndex: 0,
                           start: 2.0, end: 3.0,
                           morae: [repeatMora(0, 0, "は", 2.0, 2.5),
                                   repeatMora(0, 1, "は", 2.5, 3.0)]),  // 期望「な」
                repeatLine(UUID().uuidString, order: 3, source: 1, repeatIndex: 1,
                           start: 3.0, end: 4.0,
                           morae: [repeatMora(0, 0, "は", 3.0, 3.5),
                                   repeatMora(0, 1, "な", 3.5, 4.0)]),
            ])
        do {
            _ = try LocalYohaneForcedAligner.mapAlignedLines(
                response, lines: [first, tail], duration: 10, frameSeconds: 0.02)
            Issue.record("音拍映射与原歌词不一致时必须拒绝整个结果")
        } catch {
            // 预期路径：绝不静默放行错误的逐拍映射。
        }
    }

    @Test func yohaneMapRejectsWhenAnInputLineHasNoResult() {
        let first = repeatDraft(order: 1, surface: "内", reading: "うち")
        let tail = repeatDraft(order: 2, surface: "花", reading: "はな")
        let response = SidecarResponse(
            protocolVersion: 1, ok: true, error: nil, duration: 10, frameSeconds: 0.02,
            inferenceSeconds: 0.1, device: "cpu", warnings: [],
            repeatAnalysis: nil,
            lines: [
                repeatLine(first.id.uuidString, order: 1, source: 0, repeatIndex: 0,
                           start: 0.5, end: 1.5,
                           morae: [repeatMora(0, 0, "う", 0.5, 1.0),
                                   repeatMora(0, 1, "ち", 1.0, 1.5)]),
            ])
        do {
            _ = try LocalYohaneForcedAligner.mapAlignedLines(
                response, lines: [first, tail], duration: 10, frameSeconds: 0.02)
            Issue.record("缺少输入行结果时必须拒绝")
        } catch {
            // 预期路径。
        }
    }

    // MARK: 显示区调度

    @Test func displayWindowsRespectFourTimeOrder() {
        var lines: [LyricLine] = []
        for i in 1...6 {
            let t = Double(i) * 3.0
            lines.append(LyricLine(order: i, lane: ScreenLane.lane(forOrder: i),
                                   singStart: t, singEnd: t + 1.6))
        }
        DisplayScheduler.applyDisplayWindows(to: &lines)

        for line in lines {
            #expect(line.hasValidTiming, "第 \(line.order) 句四段时间顺序非法")
            #expect(line.displayStart <= line.singStart)
            #expect(line.singEnd <= line.displayEnd)
        }
    }

    @Test func displayEndWaitsForSameLaneHandoffWhenNextLyricIsSoon() throws {
        var lines = [
            LyricLine(order: 1, singStart: 3, singEnd: 4.6),
            LyricLine(order: 2, singStart: 6, singEnd: 7.6),
            LyricLine(order: 3, singStart: 10, singEnd: 11.6),
        ]
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let upper = lines.filter { $0.lane == .upper }.sorted { $0.order < $1.order }
        let first = try #require(upper.first)
        let nextInSameLane = try #require(upper.dropFirst().first)
        #expect(abs(first.displayEnd - nextInSameLane.displayStart) < 1e-6,
                "短间隔内应保留上一句，直到同一槽位被下一句替换")
        #expect(first.displayEnd > first.singEnd + 1.2,
                "上一句不应只停留固定尾留时间")
    }

    @Test func displayEndClearsAfterLongGapToNextLyric() throws {
        var lines = [
            LyricLine(order: 1, singStart: 3, singEnd: 4.6),
            LyricLine(order: 2, singStart: 16, singEnd: 17.6),
            LyricLine(order: 3, singStart: 20, singEnd: 21.6),
        ]
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let first = try #require(lines.first { $0.order == 1 })
        #expect(abs(first.displayEnd - (first.singEnd + 1.2)) < 1e-6,
                "下一句间隔超过 10 秒时，应提前清掉旧字幕")
    }

    @Test func bothVisibleRowsClearBeforeLongInstrumentalGap() throws {
        var lines = [
            LyricLine(order: 1, singStart: 3, singEnd: 4.6),
            LyricLine(order: 2, singStart: 6, singEnd: 7.6),
            LyricLine(order: 3, singStart: 20, singEnd: 21.6),
        ]
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let first = try #require(lines.first { $0.order == 1 })
        let second = try #require(lines.first { $0.order == 2 })
        #expect(abs(first.displayEnd - (second.singEnd + 1.2)) < 1e-6,
                "长伴奏前，较早的另一行也应和最后一句一起清空")
    }

    @Test func lastLineInLaneHoldsOut() throws {
        var lines: [LyricLine] = []
        for i in 1...4 {
            let t = Double(i) * 3.0
            lines.append(LyricLine(order: i, singStart: t, singEnd: t + 1.6))
        }
        let policy = DisplayPolicy(leadIn: 1.2, lastHoldOut: 1.2, adaptToGap: false)
        DisplayScheduler.applyDisplayWindows(to: &lines, policy: policy)

        let lower = lines.filter { $0.lane == .lower }.sorted { $0.order < $1.order }
        let last = try #require(lower.last, "缺少下行句")
        #expect(abs(last.displayEnd - (last.singEnd + 1.2)) < 1e-6)
    }

    @Test func leadInStaysWithinRecommendedRange() {
        var lines: [LyricLine] = []
        for i in 1...4 {
            let t = Double(i) * 6.0     // 间隔足够大
            lines.append(LyricLine(order: i, singStart: t, singEnd: t + 2.0))
        }
        DisplayScheduler.applyDisplayWindows(to: &lines)
        for line in lines {
            // RD §4：displayStart 在 singStart 前 0.8–2.0 秒
            #expect(line.leadIn <= 2.0 + 1e-6)
            #expect(line.leadIn >= 0.0)
        }
    }

    @Test func defaultDisplayLeadInIsAboutHalfSecond() {
        // 本轮要求：显示区默认入点在实际演唱开始前约 0.5 秒
        let line = LyricLine(order: 1, lane: .upper, displayText: "あ",
                             singStart: 10, singEnd: 12)
        var lines = [line]
        DisplayScheduler.applyDisplayWindows(to: &lines)
        #expect(abs(lines[0].leadIn - 0.5) < 1e-6)
        // 出点仍保留合理停留
        #expect(lines[0].holdOut > 0.5)

        var sequence = [
            LyricLine(order: 1, singStart: 3, singEnd: 4.6),
            LyricLine(order: 2, singStart: 6, singEnd: 7.6),
            LyricLine(order: 3, singStart: 10, singEnd: 11.6),
        ]
        DisplayScheduler.applyDisplayWindows(to: &sequence)
        let nextUpper = sequence.first { $0.order == 3 }
        #expect(abs((nextUpper?.leadIn ?? 0) - 0.5) < 1e-6,
                "有足够空隙时，后续歌词也应提前约 0.5 秒进入")
    }

    @Test func adjacentLinesInSameLaneNeverOverlap() {
        var lines: [LyricLine] = []
        for i in 1...6 {
            let t = Double(i) * 3.0
            lines.append(LyricLine(order: i, lane: ScreenLane.lane(forOrder: i),
                                   singStart: t, singEnd: t + 1.0))
        }
        DisplayScheduler.applyDisplayWindows(to: &lines)
        for lane in ScreenLane.allCases {
            let sameLane = lines.filter { $0.lane == lane }.sorted { $0.order < $1.order }
            for (a, b) in zip(sameLane, sameLane.dropFirst()) {
                #expect(a.displayEnd <= b.displayStart + 1e-6,
                        "同槽位相邻句不能重叠")
            }
        }
    }

    // MARK: 质量检查：漏句检测

    /// 造一个全浊音的假特征序列。
    private func makeFeatures(duration: Double,
                              onsets: [Double] = [],
                              silent: [ClosedRange<Double>] = []) -> AudioFeatures {
        let hop = 0.01
        let frameCount = Int(duration / hop)
        var voiced = [Bool](repeating: true, count: frameCount)
        for r in silent {
            for i in Int(r.lowerBound / hop)..<min(frameCount, Int(r.upperBound / hop)) {
                voiced[i] = false
            }
        }
        return AudioFeatures(sampleRate: 16000, frameSize: 1024, hop: 160, hopSeconds: hop,
                             frameCount: frameCount, duration: duration,
                             energyDB: [Float](repeating: -20, count: frameCount),
                             energyNorm: [Float](repeating: 0.7, count: frameCount),
                             novelty: [Float](repeating: 0.1, count: frameCount),
                             voiced: voiced, onsets: onsets)
    }

    private func alignedLine(order: Int, start: Double, end: Double,
                             confidence: Double = 0.95) -> AlignedLyricLine {
        AlignedLyricLine(id: UUID(), order: order, singStart: start, singEnd: end,
                         confidence: confidence, tokens: [], reasons: [])
    }

    @Test func uncoveredVoicedAudioIsFlaggedAsMissingLine() {
        // 音频 10 秒全浊音，但只给了两句，中间空了 2.5 秒
        let features = makeFeatures(duration: 10)
        let results = [
            alignedLine(order: 1, start: 1.0, end: 2.0),
            alignedLine(order: 2, start: 4.5, end: 5.5),
        ]
        let checked = QualityChecker.annotate(results: results, features: features, audioDuration: 10)

        let reasons = checked.flatMap(\.reasons).joined()
        #expect(reasons.contains("未被任何歌词覆盖"),
                "2.5 秒无人认领的人声必须触发漏句提示，实际原因：\(reasons)")
        #expect(checked[0].confidence < 0.85, "漏句邻接句的置信度应被压低")
    }

    @Test func tightGapIsNotFlaggedAsMissingLine() {
        let features = makeFeatures(duration: 10)
        let results = [
            alignedLine(order: 1, start: 1.0, end: 2.0),
            alignedLine(order: 2, start: 2.3, end: 3.3),
        ]
        let checked = QualityChecker.annotate(results: results, features: features, audioDuration: 10)
        let reasons = checked.flatMap(\.reasons).joined()
        #expect(!reasons.contains("未被任何歌词覆盖"), "0.3 秒的正常呼吸间隔不应被当成漏句")
    }

    @Test func lowConfidenceAlwaysHasAReviewReason() {
        let line = alignedLine(order: 1, start: 1.0, end: 2.0, confidence: 0.80)
        let checked = QualityChecker.annotate(results: [line], features: nil, audioDuration: 10)
        #expect(checked[0].reasons.contains("对齐置信度偏低，建议试听确认"))
    }

    @Test func overlapIsFlagged() {
        let features = makeFeatures(duration: 10)
        let results = [
            alignedLine(order: 1, start: 1.0, end: 4.0),
            alignedLine(order: 2, start: 3.0, end: 5.0),   // 与上一句重叠
        ]
        let checked = QualityChecker.annotate(results: results, features: features, audioDuration: 10)
        #expect(checked.flatMap(\.reasons).joined().contains("重叠"))
        #expect(checked[1].confidence <= 0.55)
    }

    @Test func tooShortLineIsFlagged() {
        let features = makeFeatures(duration: 10)
        let results = [alignedLine(order: 1, start: 1.0, end: 1.1)]
        let checked = QualityChecker.annotate(results: results, features: features, audioDuration: 10)
        #expect(checked[0].reasons.contains { $0.contains("过短") })
    }

    @Test func overlongForcedLyricIsFlaggedAndCannotKeepHighConfidence() {
        // Real Hana regression: one repeated English phrase was stretched across 25.52 seconds.
        let line = alignedLine(order: 43, start: 216.48, end: 242.00, confidence: 0.84)
        let checked = QualityChecker.annotate(results: [line], features: nil, audioDuration: 248.3)

        #expect(checked[0].reasons.contains { $0.contains("演唱时间异常长") })
        #expect(checked[0].confidence <= 0.60)
    }

    // MARK: 置信度分级（RD §8.5）

    @Test func confidenceLevels() {
        #expect(ConfidenceLevel.from(0.90) == .normal)
        #expect(ConfidenceLevel.from(0.85) == .normal)
        #expect(ConfidenceLevel.from(0.84) == .warning)
        #expect(ConfidenceLevel.from(0.60) == .warning)
        #expect(ConfidenceLevel.from(0.59) == .low)
        #expect(ConfidenceLevel.from(0) == .low)
    }

    // MARK: Mock 对齐器契约

    @Test func mockAlignerCannotBeMistakenForReal() async throws {
        let aligner = MockLyricAligner()
        #expect(!aligner.isProductionReady, "Mock 不得作为产品路径（RD §8.4）")

        let tokens = JapaneseReadingService().tokens(for: "世界に乾杯")
        let draft = LyricLineDraft(order: 1, text: "世界に乾杯", tokens: tokens)
        let results = try await aligner.align(audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
                                             lines: [draft], progress: nil)

        #expect(results.count == 1)
        #expect(results[0].confidence <= 0.5, "Mock 结果置信度必须被压住")
        #expect(results[0].reasons.joined().contains("Mock"), "Mock 结果必须显式标注来源")
    }

    @Test func mockAlignerProducesMonotonicMorae() async throws {
        let aligner = MockLyricAligner()
        let tokens = JapaneseReadingService().tokens(for: "素晴らしき世界")
        let draft = LyricLineDraft(order: 1, text: "素晴らしき世界", tokens: tokens)
        let results = try await aligner.align(audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
                                             lines: [draft], progress: nil)
        let morae = results[0].tokens.flatMap(\.morae)
        #expect(!morae.isEmpty)
        for (a, b) in zip(morae, morae.dropFirst()) {
            #expect(a.end <= b.start + 1e-9)
        }
    }

    // MARK: 漂移修正

    @Test func driftCorrectorEstimatesConstantOffset() {
        let base = makeFeatures(duration: 20)
        // 每句预测都比起音点晚 0.3 秒
        var project = KaraProject()
        project.lyricLines = (1...6).map { i in
            let t = Double(i) * 2.0
            return LyricLine(order: i, singStart: t + 0.3, singEnd: t + 1.0)
        }

        let onsets = (1...6).map { Double($0) * 2.0 }
        let features = AudioFeatures(sampleRate: base.sampleRate,
                                     frameSize: base.frameSize,
                                     hop: base.hop,
                                     hopSeconds: base.hopSeconds,
                                     frameCount: base.frameCount,
                                     duration: base.duration,
                                     energyDB: base.energyDB,
                                     energyNorm: base.energyNorm,
                                     novelty: base.novelty,
                                     voiced: base.voiced,
                                     onsets: onsets)

        let estimate = DriftCorrector.estimate(project: project, features: features)
        #expect(estimate.sampleCount == 6)
        // 预测偏晚 0.3 秒 → 估计的 offset 应为 -0.3（起音点 - 预测）
        #expect(abs(estimate.offset - (-0.3)) < 0.02)

        let changed = DriftCorrector.apply(estimate, to: &project)
        #expect(changed == 6)
        #expect(abs(project.lyricLines[0].singStart - 2.0) < 0.03)
    }

    @Test func driftCorrectorRefusesUnusableEstimate() {
        let features = makeFeatures(duration: 20, onsets: [1.0])   // 只有 1 个起音点
        var project = KaraProject()
        project.lyricLines = (1...4).map { i in
            LyricLine(order: i, singStart: Double(i) * 2.0, singEnd: Double(i) * 2.0 + 1)
        }
        let estimate = DriftCorrector.estimate(project: project, features: features)
        #expect(!estimate.isUsable, "样本不足时不应认定可用")
        var before = project
        let changed = DriftCorrector.apply(estimate, to: &project)
        #expect(changed == 0)
        #expect(before.lyricLines[0].singStart == project.lyricLines[0].singStart)
        before = project
    }
}
