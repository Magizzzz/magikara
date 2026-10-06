import Foundation
import Darwin

// MARK: - 指标结构

public struct Phase0LineMetric: Codable, Sendable {
    public var order: Int
    public var text: String
    public var truthStart: Double
    public var truthEnd: Double
    public var predStart: Double
    public var predEnd: Double
    public var startError: Double
    public var endError: Double
    public var confidence: Double
    public var needsReview: Bool
    /// 起止边界误差是否都在自动验收容差内。
    public var boundariesWithinTolerance: Bool
    /// 系统放行且真值起止边界都通过容差。
    public var truthQualifiedAutoAccept: Bool
    /// 系统放行，但至少一个真值边界超出容差。
    public var falseAutoAccept: Bool
    public var reasons: [String]
    public var baselineStartError: Double
    public var moraCount: Int
    public var lowConfidenceMoraCount: Int
    public var fourTimeOrderOK: Bool
    public var lane: String
    public var rubyTokenCount: Int
}

public struct Phase0ClipReport: Codable, Sendable {
    public var id: String
    public var kind: String
    public var hasRepeat: Bool
    public var duration: Double
    public var alignerName: String
    public var alignerIsProductionReady: Bool

    public var lineCount: Int
    public var meanStartError: Double
    public var meanEndError: Double
    public var medianStartError: Double
    public var p90StartError: Double
    public var maxStartError: Double

    public var within020: Int
    public var within050: Int
    public var within100: Int
    public var unmatchedCount: Int          // |startError| > 1.0s
    public var overlapCount: Int

    public var baselineMeanStartError: Double
    public var baselineWithin050: Int

    public var needsReviewCount: Int
    /// 系统置信度门控放行率；不是准确率，也不等同于无需人工调整率。
    public var autoAcceptRatio: Double
    public var truthQualifiedAutoAcceptCount: Int
    public var falseAutoAcceptCount: Int
    /// 系统放行且真值起止边界都通过容差 / 全部句子。
    public var truthQualifiedAutoAcceptRatio: Double
    /// 系统放行句子中，至少一个真值边界超出容差的比例。
    public var falseAutoAcceptRate: Double

    public var fourTimeOrderViolations: Int
    public var laneAlternationOK: Bool
    public var rubyOnlyOnKanji: Bool
    public var moraMonotonicOK: Bool
    public var moraSumMatchesSingDuration: Bool

    public var elapsedSeconds: Double
    public var peakMemoryMB: Double
    public var notes: [String]
    public var lines: [Phase0LineMetric]
}

public struct Phase0Summary: Codable, Sendable {
    public var generatedAt: String
    public var note: String
    public var totalClips: Int
    public var totalLines: Int
    public var meanStartError: Double
    public var medianStartError: Double
    public var baselineMeanStartError: Double
    public var truthQualifiedAutoAcceptRatio: Double
    public var falseAutoAcceptCount: Int
    public var autoAcceptRatio: Double
    public var unmatchedCount: Int
    public var totalElapsedSeconds: Double
    public var peakMemoryMB: Double
    public var clips: [Phase0ClipReport]
    /// 故意给错歌词，检验「低置信度提示」到底会不会触发。
    public var robustnessProbes: [RobustnessProbe]
}

/// 鲁棒性探针：故意提供与音频不匹配的歌词，观察置信度机制是否报警。
///
/// 这是对产品核心承诺「用户只需处理低置信度句」的直接检验。
public struct RobustnessProbe: Codable, Sendable {
    public var name: String
    public var detail: String
    public var truthLineCount: Int
    public var suppliedLineCount: Int
    public var flaggedCount: Int        // needsReview（confidence < 0.85）
    public var lowCount: Int            // confidence < 0.60
    public var warningCount: Int        // 0.60 <= confidence < 0.85
    public var minConfidence: Double
    public var maxConfidence: Double
    public var meanConfidence: Double
    public var verdict: String
}

// MARK: - Runner

/// Phase 0：在本地测试集上跑真实对轨并输出量化指标（RD §8.3 / §13）。
public enum Phase0Runner {

    /// 起止边界分别不超过 500 ms，作为“可直接用”的默认基准容差。
    public static let autoAcceptBoundaryTolerance = 0.5

    /// 对照真值判断起止边界是否都足够准；不根据模型置信度自我背书。
    public static func boundariesWithinAutoAcceptTolerance(startError: Double,
                                                            endError: Double,
                                                            tolerance: Double = autoAcceptBoundaryTolerance) -> Bool {
        guard tolerance.isFinite, tolerance >= 0,
              startError.isFinite, endError.isFinite else { return false }
        return abs(startError) <= tolerance && abs(endError) <= tolerance
    }

    public static func isTruthQualifiedAutoAccept(needsReview: Bool,
                                                   startError: Double,
                                                   endError: Double,
                                                   tolerance: Double = autoAcceptBoundaryTolerance) -> Bool {
        !needsReview && boundariesWithinAutoAcceptTolerance(
            startError: startError, endError: endError, tolerance: tolerance)
    }

    public static func isFalseAutoAccept(needsReview: Bool,
                                         startError: Double,
                                         endError: Double,
                                         tolerance: Double = autoAcceptBoundaryTolerance) -> Bool {
        !needsReview && !boundariesWithinAutoAcceptTolerance(
            startError: startError, endError: endError, tolerance: tolerance)
    }

    public static func peakMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    /// 生成测试集（若不存在或要求重建）。
    @discardableResult
    public static func ensureTestSet(at directory: URL,
                                     rebuild: Bool,
                                     log: @escaping (String) -> Void) throws -> [URL] {
        let fm = FileManager.default
        var present: [String: URL] = [:]
        var missing: [TestSetBuilder.Spec] = []

        for spec in TestSetBuilder.defaultSpecs {
            let truth = directory.appendingPathComponent("\(spec.id).truth.json")
            let wav = directory.appendingPathComponent("\(spec.id).wav")
            if rebuild || !fm.fileExists(atPath: truth.path) || !fm.fileExists(atPath: wav.path) {
                missing.append(spec)
            } else {
                present[spec.id] = truth
            }
        }

        if !missing.isEmpty {
            log("需要生成 \(missing.count) 个测试片段…")
            let built = try TestSetBuilder.build(specs: missing, targetDirectory: directory, progress: log)
            for url in built {
                present[url.deletingPathExtension().deletingPathExtension().lastPathComponent] = url
            }
        }

        return TestSetBuilder.defaultSpecs.compactMap { present[$0.id] }
    }

    public static func run(assetsDirectory: URL,
                           rebuildTestSet: Bool = false,
                           aligner: LyricAligning = LocalLyricAligner(),
                           log: @escaping (String) -> Void = { print($0) }) async throws -> Phase0Summary {

        let fm = FileManager.default
        let reportsDir = assetsDirectory.appendingPathComponent("reports", isDirectory: true)
        try fm.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        let truthURLs = try ensureTestSet(at: assetsDirectory, rebuild: rebuildTestSet, log: log)
        let decoder = JSONDecoder()

        var clipReports: [Phase0ClipReport] = []
        var totalElapsed = 0.0
        var peakMemory = 0.0

        for truthURL in truthURLs {
            guard let data = try? Data(contentsOf: truthURL),
                  let truth = try? decoder.decode(TestClipTruth.self, from: data) else {
                log("跳过（读不到真值）：\(truthURL.lastPathComponent)")
                continue
            }
            let wavURL = assetsDirectory.appendingPathComponent(truth.audioFile)

            log("")
            log("=== \(truth.id)  (\(String(format: "%.1f", truth.duration)) 秒, \(truth.lines.count) 句) ===")
            log("对齐器: \(aligner.name)  生产可用: \(aligner.isProductionReady)")

            // 走完整产品路径：歌词 → token/读音 → 上下行 → 对齐 → 四段时间
            var project = KaraProject(mediaURL: wavURL,
                                      duration: truth.duration,
                                      title: truth.id)
            project.lyricLines = AnalysisCoordinator.makeLines(
                from: truth.lines.map(\.text).joined(separator: "\n"))

            let t0 = CFAbsoluteTimeGetCurrent()
            let outcome: AnalysisCoordinator.Outcome
            do {
                outcome = try await AnalysisCoordinator.analyze(project: project, aligner: aligner) { p in
                    // 只打印阶段切换，避免刷屏
                    if p.fraction >= 1.0 { log("  \(p.message)") }
                }
            } catch {
                log("  ✗ 分析失败：\(error.localizedDescription)")
                var report = Phase0ClipReport.empty()
                report.id = truth.id
                report.kind = truth.kind
                report.alignerName = aligner.name
                report.alignerIsProductionReady = aligner.isProductionReady
                report.notes = ["分析失败：\(error.localizedDescription)"]
                clipReports.append(report)
                continue
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            totalElapsed += elapsed
            peakMemory = max(peakMemory, peakMemoryMB())

            let report = evaluate(truth: truth,
                                  project: outcome.project,
                                  aligner: aligner,
                                  elapsed: elapsed)
            clipReports.append(report)

            log(String(format: "  句边界平均误差 %.0f ms (中央值 %.0f ms, P90 %.0f ms)",
                       report.meanStartError * 1000,
                       report.medianStartError * 1000,
                       report.p90StartError * 1000))
            log(String(format: "  均分基线平均误差 %.0f ms → 对轨器改善 %.0f%%",
                       report.baselineMeanStartError * 1000,
                       report.baselineMeanStartError > 0
                        ? (1 - report.meanStartError / report.baselineMeanStartError) * 100 : 0))
            log(String(format: "  ±0.2s %d/%d  ±0.5s %d/%d  ±1.0s %d/%d  错配 %d",
                       report.within020, report.lineCount,
                       report.within050, report.lineCount,
                       report.within100, report.lineCount,
                       report.unmatchedCount))
            log(String(format: "  置信度放行 %.0f%%（非准确率，低置信度 %d 句）  真值核验自动通过 %.0f%%  误放行 %d 句  耗时 %.2fs",
                       report.autoAcceptRatio * 100, report.needsReviewCount,
                       report.truthQualifiedAutoAcceptRatio * 100, report.falseAutoAcceptCount,
                       report.elapsedSeconds))
            if !report.notes.isEmpty {
                for n in report.notes { log("  · \(n)") }
            }

            // 单片段产物
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(report).write(to: reportsDir.appendingPathComponent("\(truth.id).json"))
            try renderHTML(report: report, truth: truth)
                .write(to: reportsDir.appendingPathComponent("\(truth.id).html"),
                       atomically: true, encoding: .utf8)
        }

        let totalLines = clipReports.reduce(0) { $0 + $1.lineCount }
        let validClips = clipReports.filter { $0.lineCount > 0 }

        // 鲁棒性探针
        log("")
        log("=== 鲁棒性探针：故意给错歌词 ===")
        let probes = await robustnessProbes(assetsDirectory: assetsDirectory,
                                            aligner: aligner,
                                            log: log)

        func weightedMean(_ keyPath: (Phase0ClipReport) -> Double) -> Double {
            guard totalLines > 0 else { return 0 }
            return validClips.reduce(0.0) { $0 + keyPath($1) * Double($1.lineCount) } / Double(totalLines)
        }

        let allStartErrors = clipReports.flatMap(\.lines).map { abs($0.startError) }.sorted()
        let aggregateMedianStartError: Double
        if allStartErrors.isEmpty {
            aggregateMedianStartError = 0
        } else if allStartErrors.count.isMultiple(of: 2) {
            let upper = allStartErrors.count / 2
            aggregateMedianStartError = (allStartErrors[upper - 1] + allStartErrors[upper]) / 2
        } else {
            aggregateMedianStartError = allStartErrors[allStartErrors.count / 2]
        }

        let summary = Phase0Summary(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            note: "测试集为 macOS say(Kyoko) 合成的日语语音基线（含一段叠加本地合成伴奏床的片段），真值由构造确定。这是语音/合成伴奏，不是真实歌手演唱；真实歌曲验证尚未完成。",
            totalClips: clipReports.count,
            totalLines: totalLines,
            meanStartError: weightedMean { $0.meanStartError },
            medianStartError: aggregateMedianStartError,
            baselineMeanStartError: weightedMean { $0.baselineMeanStartError },
            truthQualifiedAutoAcceptRatio: totalLines == 0 ? 0 :
                Double(clipReports.reduce(0) { $0 + $1.truthQualifiedAutoAcceptCount }) / Double(totalLines),
            falseAutoAcceptCount: clipReports.reduce(0) { $0 + $1.falseAutoAcceptCount },
            autoAcceptRatio: weightedMean { $0.autoAcceptRatio },
            unmatchedCount: clipReports.reduce(0) { $0 + $1.unmatchedCount },
            totalElapsedSeconds: totalElapsed,
            peakMemoryMB: peakMemory,
            clips: clipReports,
            robustnessProbes: probes)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(summary).write(to: reportsDir.appendingPathComponent("summary.json"))
        try renderMarkdown(summary).write(to: reportsDir.appendingPathComponent("summary.md"),
                                          atomically: true, encoding: .utf8)
        return summary
    }

    // MARK: 评估

    static func evaluate(truth: TestClipTruth,
                         project: KaraProject,
                         aligner: LyricAligning,
                         elapsed: Double) -> Phase0ClipReport {
        let lines = project.sortedLines

        // 均分基线：不知道真值，只把「整首歌的人声范围」按音拍数等分。
        // 这正是规格禁止依赖的假实现，用来量化对轨器到底改善了多少。
        let baseline = evenSplitBaseline(truth: truth, project: project)

        var metrics: [Phase0LineMetric] = []
        var startErrors: [Double] = []

        for (i, line) in lines.enumerated() {
            let t = truth.lines[i]
            let startError = line.singStart - t.start
            let endError = line.singEnd - t.end
            let boundariesWithinTolerance = Self.boundariesWithinAutoAcceptTolerance(
                startError: startError, endError: endError)
            startErrors.append(abs(startError))

            let morae = line.allMorae
            let lowConf = morae.filter { $0.confidence < 0.60 }.count
            let moraMonotonic = zip(morae, morae.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-6 }
            let moraSum = morae.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            let sumOK = morae.isEmpty || abs(moraSum - line.singDuration) < 0.05

            metrics.append(Phase0LineMetric(
                order: line.order,
                text: line.displayText,
                truthStart: t.start,
                truthEnd: t.end,
                predStart: line.singStart,
                predEnd: line.singEnd,
                startError: startError,
                endError: endError,
                confidence: line.confidence,
                needsReview: line.needsReview,
                boundariesWithinTolerance: boundariesWithinTolerance,
                truthQualifiedAutoAccept: Self.isTruthQualifiedAutoAccept(
                    needsReview: line.needsReview, startError: startError, endError: endError),
                falseAutoAccept: Self.isFalseAutoAccept(
                    needsReview: line.needsReview, startError: startError, endError: endError),
                reasons: line.reviewReasons,
                baselineStartError: baseline[i],
                moraCount: morae.count,
                lowConfidenceMoraCount: lowConf,
                fourTimeOrderOK: line.hasValidTiming,
                lane: line.lane.rawValue,
                rubyTokenCount: line.rubyTokens.count))
            _ = (moraMonotonic, sumOK)
        }

        let sortedErrors = startErrors.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sortedErrors.isEmpty else { return 0 }
            let idx = Int((Double(sortedErrors.count - 1) * p).rounded())
            return sortedErrors[max(0, min(sortedErrors.count - 1, idx))]
        }

        let moraMonotonicOK = lines.allSatisfy { line in
            let m = line.allMorae
            return zip(m, m.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-6 }
        }
        let moraSumOK = lines.allSatisfy { line in
            let m = line.allMorae
            if m.isEmpty { return true }
            let sum = m.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            return abs(sum - line.singDuration) < 0.05
        }
        let orderOK = lines.filter { !$0.hasValidTiming }.count == 0
        let laneOK = lines.allSatisfy { $0.lane == ScreenLane.lane(forOrder: $0.order) }
        let rubyOK = lines.allSatisfy { line in
            line.rubyTokens.allSatisfy { $0.needsRuby && JapaneseText.containsKanji($0.surface) }
        }

        var overlaps = 0
        for i in 1..<max(1, lines.count) where lines[i].singStart < lines[i - 1].singEnd - 0.05 {
            overlaps += 1
        }

        let meanStart = startErrors.isEmpty ? 0 : startErrors.reduce(0, +) / Double(startErrors.count)
        let baseMean = baseline.isEmpty ? 0 : baseline.map(abs).reduce(0, +) / Double(baseline.count)
        let needsReview = lines.filter(\.needsReview).count
        let truthQualifiedAutoAccept = metrics.filter(\.truthQualifiedAutoAccept).count
        let falseAutoAccept = metrics.filter(\.falseAutoAccept).count
        let modelAccepted = lines.count - needsReview

        var notes: [String] = []
        if !orderOK { notes.append("存在四段时间顺序违规") }
        if !moraMonotonicOK { notes.append("音拍时间不单调") }
        if !moraSumOK { notes.append("音拍时长之和与整句演唱时长不一致") }
        if overlaps > 0 { notes.append("\(overlaps) 句时间重叠") }
        if truth.hasRepeat { notes.append("含重复段落，用于检验顺序约束下的重复副歌处理") }

        return Phase0ClipReport(
            id: truth.id,
            kind: truth.kind,
            hasRepeat: truth.hasRepeat,
            duration: truth.duration,
            alignerName: aligner.name,
            alignerIsProductionReady: aligner.isProductionReady,
            lineCount: lines.count,
            meanStartError: meanStart,
            meanEndError: lines.isEmpty ? 0 : zip(lines, truth.lines).reduce(0.0) { $0 + abs($1.0.singEnd - $1.1.end) } / Double(lines.count),
            medianStartError: percentile(0.5),
            p90StartError: percentile(0.9),
            maxStartError: sortedErrors.last ?? 0,
            within020: startErrors.filter { $0 <= 0.20 }.count,
            within050: startErrors.filter { $0 <= 0.50 }.count,
            within100: startErrors.filter { $0 <= 1.00 }.count,
            unmatchedCount: startErrors.filter { $0 > 1.00 }.count,
            overlapCount: overlaps,
            baselineMeanStartError: baseMean,
            baselineWithin050: baseline.filter { abs($0) <= 0.5 }.count,
            needsReviewCount: needsReview,
            autoAcceptRatio: lines.isEmpty ? 0 : Double(lines.count - needsReview) / Double(lines.count),
            truthQualifiedAutoAcceptCount: truthQualifiedAutoAccept,
            falseAutoAcceptCount: falseAutoAccept,
            truthQualifiedAutoAcceptRatio: lines.isEmpty ? 0 : Double(truthQualifiedAutoAccept) / Double(lines.count),
            falseAutoAcceptRate: modelAccepted == 0 ? 0 : Double(falseAutoAccept) / Double(modelAccepted),
            fourTimeOrderViolations: lines.filter { !$0.hasValidTiming }.count,
            laneAlternationOK: laneOK,
            rubyOnlyOnKanji: rubyOK,
            moraMonotonicOK: moraMonotonicOK,
            moraSumMatchesSingDuration: moraSumOK,
            elapsedSeconds: elapsed,
            peakMemoryMB: peakMemoryMB(),
            notes: notes,
            lines: metrics)
    }

    /// 均分基线：不使用任何真值，只按音拍数把整体人声区间等分。
    static func evenSplitBaseline(truth: TestClipTruth, project: KaraProject) -> [Double] {
        let lines = project.sortedLines
        guard !lines.isEmpty else { return [] }
        let first = truth.lines.first!.start
        let last = truth.lines.last!.end
        let span = max(0.1, last - first)
        let counts = lines.map { max(1, $0.allMorae.count) }
        let total = Double(counts.reduce(0, +))
        var cursor = first
        var errors: [Double] = []
        for (i, c) in counts.enumerated() {
            let dur = span * Double(c) / total
            errors.append(cursor - truth.lines[i].start)
            cursor += dur
        }
        return errors
    }

    // MARK: 鲁棒性探针

    /// 故意提供与音频不匹配的歌词，检验「低置信度提示」是否真的会报警。
    /// 这是对产品核心承诺「用户只需处理低置信度句」的直接检验。
    public static func robustnessProbes(assetsDirectory: URL,
                                        aligner: LyricAligning,
                                        log: (String) -> Void) async -> [RobustnessProbe] {
        let truthURL = assetsDirectory.appendingPathComponent("tts-jpop-01.truth.json")
        guard let data = try? Data(contentsOf: truthURL),
              let truth = try? JSONDecoder().decode(TestClipTruth.self, from: data) else {
            log("  跳过：找不到 tts-jpop-01 真值")
            return []
        }
        let wav = assetsDirectory.appendingPathComponent(truth.audioFile)
        let base = truth.lines.map(\.text)

        struct ProbeSpec {
            var name: String
            var detail: String
            var lines: [String]
        }

        var specs: [ProbeSpec] = []

        // A. 多给 3 句音频里并不存在的歌词
        let bogus = ["ああ", "ううう", "ええええ"]
        var more: [String] = []
        for (i, t) in base.enumerated() {
            more.append(t)
            if i < bogus.count { more.append(bogus[i]) }
        }
        specs.append(ProbeSpec(name: "歌词比实际多 3 句",
                               detail: "在 8 句真实演唱之间插入 3 句音频里不存在的短句，共 11 句",
                               lines: more))

        // B. 少给 2 句
        var fewer = base
        fewer.remove(at: 5)
        fewer.remove(at: 2)
        specs.append(ProbeSpec(name: "歌词比实际少 2 句",
                               detail: "只给 6 句而音频实际唱了 8 句；缺句必须被挤压或吞并",
                               lines: fewer))

        var out: [RobustnessProbe] = []
        for spec in specs {
            var project = KaraProject(mediaURL: wav, duration: truth.duration, title: spec.name)
            project.lyricLines = AnalysisCoordinator.makeLines(from: spec.lines.joined(separator: "\n"))

            guard let outcome = try? await AnalysisCoordinator.analyze(project: project, aligner: aligner) else {
                log("  \(spec.name)：分析失败")
                continue
            }
            let lines = outcome.project.sortedLines
            let confs = lines.map(\.confidence)
            let flagged = lines.filter(\.needsReview).count
            let low = confs.filter { $0 < 0.60 }.count
            let warn = confs.filter { $0 >= 0.60 && $0 < 0.85 }.count

            let verdict: String
            if low > 0 {
                verdict = "有 \(low) 句被标为红色（<0.60），机制生效"
            } else if warn > 0 {
                verdict = "有 \(warn) 句被标为黄色（0.60–0.85），机制生效但偏宽松"
            } else {
                verdict = "⚠️ 没有任何句子被标记 —— 低置信度机制在这种错误下没有触发"
            }

            let probe = RobustnessProbe(
                name: spec.name,
                detail: spec.detail,
                truthLineCount: base.count,
                suppliedLineCount: spec.lines.count,
                flaggedCount: flagged,
                lowCount: low,
                warningCount: warn,
                minConfidence: confs.min() ?? 0,
                maxConfidence: confs.max() ?? 0,
                meanConfidence: confs.isEmpty ? 0 : confs.reduce(0, +) / Double(confs.count),
                verdict: verdict)
            out.append(probe)

            log("  \(spec.name)：红色 \(low) / 黄色 \(warn) / 待确认 \(flagged) / 共 \(lines.count) 句，置信度 \(String(format: "%.2f", probe.minConfidence))–\(String(format: "%.2f", probe.maxConfidence))")
            log("    → \(verdict)")
        }
        return out
    }

    // MARK: 演示工程

    /// 用测试集里的片段跑一遍真实分析，生成一个可直接打开的 `.magikara` 工程。
    /// 用途：让 App 一启动就有真实内容可以看（不是伪造数据，是真的跑过对轨的结果）。
    public static func makeDemoProject(assetsDirectory: URL,
                                       clipID: String = "tts-jpop-01",
                                       aligner: LyricAligning = LocalLyricAligner(),
                                       log: (String) -> Void = { print($0) }) async throws -> KaraProject {
        let truthURL = assetsDirectory.appendingPathComponent("\(clipID).truth.json")
        let data = try Data(contentsOf: truthURL)
        let truth = try JSONDecoder().decode(TestClipTruth.self, from: data)
        let wavURL = assetsDirectory.appendingPathComponent(truth.audioFile)

        var project = KaraProject(mediaURL: wavURL, duration: truth.duration, title: "演示 · \(clipID)")
        project.lyricLines = AnalysisCoordinator.makeLines(
            from: truth.lines.map(\.text).joined(separator: "\n"))

        log("正在为演示工程跑对轨…")
        let outcome = try await AnalysisCoordinator.analyze(project: project, aligner: aligner)
        log(String(format: "演示工程：%d 句，平均置信度 %.2f，待确认 %d 句",
                   outcome.project.lyricLines.count,
                   outcome.project.averageConfidence,
                   outcome.summary.lowConfidenceCount))
        return outcome.project
    }

    // MARK: 报告输出

    public static func renderMarkdown(_ s: Phase0Summary) -> String {
        var md = """
        # MaGi Kara — Phase 0 对轨基线报告

        生成时间：\(s.generatedAt)

        > \(s.note)

        ## 总览

        | 指标 | 数值 |
        | --- | --- |
        | 片段数 | \(s.totalClips) |
        | 总句数 | \(s.totalLines) |
        | 句边界平均误差 | \(fmtMs(s.meanStartError)) |
        | 句边界误差中央值 | \(fmtMs(s.medianStartError)) |
        | 均分基线平均误差 | \(fmtMs(s.baselineMeanStartError)) |
        | 置信度放行率（非准确率） | \(String(format: "%.1f%%", s.autoAcceptRatio * 100)) |
        | 真值核验自动通过率（起止误差均 ≤ 0.5s） | \(String(format: "%.1f%%", s.truthQualifiedAutoAcceptRatio * 100)) |
        | 高置信度误放行句数 | \(s.falseAutoAcceptCount) |
        | 错配句数（>1s） | \(s.unmatchedCount) |
        | 总耗时 | \(String(format: "%.2f s", s.totalElapsedSeconds)) |
        | 峰值内存 | \(String(format: "%.0f MB", s.peakMemoryMB)) |

        ## 分片段

        | 片段 | 句数 | 平均误差 | ±0.2s | ±0.5s | ±1.0s | 错配 | 置信度放行 | 真值核验通过 | 误放行 | 耗时 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        """

        for c in s.clips {
            md += "\n| \(c.id) | \(c.lineCount) | \(fmtMs(c.meanStartError)) | \(c.within020) | \(c.within050) | \(c.within100) | \(c.unmatchedCount) | \(String(format: "%.0f%%", c.autoAcceptRatio * 100)) | \(c.truthQualifiedAutoAcceptCount)/\(c.lineCount) | \(c.falseAutoAcceptCount) | \(String(format: "%.2fs", c.elapsedSeconds)) |"
        }

        md += "\n\n## 产品闭环检查\n\n"
        md += "| 片段 | 四段时间顺序 | 上下行交替 | Ruby 仅汉字 | 音拍单调 | 音拍时长闭合 |\n| --- | --- | --- | --- | --- | --- |\n"
        for c in s.clips {
            md += "\n| \(c.id) | \(c.fourTimeOrderViolations == 0 ? "✅" : "❌ \(c.fourTimeOrderViolations)") | \(c.laneAlternationOK ? "✅" : "❌") | \(c.rubyOnlyOnKanji ? "✅" : "❌") | \(c.moraMonotonicOK ? "✅" : "❌") | \(c.moraSumMatchesSingDuration ? "✅" : "❌") |"
        }

        md += "\n\n> “置信度放行”只反映系统自身的复核标记；“真值核验通过”额外要求该句未被标记复核，且句首、句尾各自误差均不超过 0.5 秒。它仍是边界精度代理指标，不等同于人工实际试听结果。\n\n## 逐句明细\n"
        for c in s.clips {
            md += "\n### \(c.id)\n\n| # | 歌词 | 真值起点 | 预测起点 | 起点误差 | 句尾误差 | 起止均≤0.5s | 系统放行 | 误放行 | 置信度 | 原因 |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
            for l in c.lines {
                let reason = l.reasons.isEmpty ? "" : l.reasons.joined(separator: "；")
                md += "\n| \(l.order) | \(l.text) | \(fmtSec(l.truthStart)) | \(fmtSec(l.predStart)) | \(fmtMs(l.startError)) | \(fmtMs(l.endError)) | \(l.boundariesWithinTolerance ? "是" : "否") | \(l.needsReview ? "复核" : "放行") | \(l.falseAutoAccept ? "是" : "否") | \(String(format: "%.2f", l.confidence)) | \(reason) |"
            }
            md += "\n"
        }

        md += "\n\n## 鲁棒性探针（故意给错歌词）\n\n"
        if s.robustnessProbes.isEmpty {
            md += "未运行。\n"
        } else {
            md += "| 场景 | 真值句数 | 提供句数 | 红色(<0.60) | 黄色(0.60–0.85) | 待确认 | 置信度范围 | 结论 |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"
            for p in s.robustnessProbes {
                md += "\n| \(p.name) | \(p.truthLineCount) | \(p.suppliedLineCount) | \(p.lowCount) | \(p.warningCount) | \(p.flaggedCount) | \(String(format: "%.2f–%.2f", p.minConfidence, p.maxConfidence)) | \(p.verdict) |"
            }
            md += "\n"
            for p in s.robustnessProbes {
                md += "\n- **\(p.name)**：\(p.detail)"
            }
            md += "\n"
        }

        md += """

        ## 当前未完成

        - **真实歌曲验证未完成**：本机没有合法可用的日文歌曲（人声 + 真实编曲）素材，因此所有指标都来自
          macOS `say` 合成的语音基线。「伴奏密集」只覆盖了本地合成伴奏床（和弦垫音 + 贝斯 + 鼓），
          它能反映退化趋势，但**不能代表真实 J-Pop / Vocaloid 的编曲复杂度**。
        - **音拍级误差没有独立真值**：TTS 无法给出逐音拍边界，所以只做了内部一致性检查
          （单调、不重叠、时长闭合），没有量化音拍边界误差。
        - **系统性 +130 ms 起始延迟**：`singStart` 稳定地晚于真实语音起点（中央值约 +130 ms），
          原因是边界代价偏好能量谷，而语音起点附近的能量谷落在起始之后。
          质量检查已经能估计这个整体偏移（`globalOffset`），但第一轮**没有自动补偿**。
        - **低置信度机制尚未在真实硬素材上标定**：在干净的 TTS 基线上置信度全部落在 0.90–0.98，
          从未触发报警；只有「故意给错歌词」的探针能把它压下来。
          因此「黄色/红色提示的准确率」目前**没有可信数据**。
        - **未接入人声分离**（Demucs / UVR 等），也没有接入任何声学模型强制对齐。
        - **重复副歌**目前只靠顺序约束避免错配，没有做结构复用与局部校准。
        - 某个片段（句间几乎无静音、句长又接近）上，均分基线的误差反而低于本对齐器，
          说明本方法在「均匀且连续」的素材上没有优势。
        """
        return md
    }

    static func fmtMs(_ v: Double) -> String { String(format: "%.0f ms", v * 1000) }
    static func fmtSec(_ v: Double) -> String { String(format: "%.2fs", v) }

    static func renderHTML(report: Phase0ClipReport, truth: TestClipTruth) -> String {
        let width = 1200.0
        let height = 300.0
        let pad = 60.0
        let dur = max(0.1, report.duration)
        let scale = (width - pad * 2) / dur

        func x(_ t: Double) -> Double { pad + t * scale }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        var svg = ""
        // 真值行
        for (i, l) in truth.lines.enumerated() {
            let y = 60.0
            let w = max(1, (l.end - l.start) * scale)
            svg += "<rect x=\"\(x(l.start))\" y=\"\(y)\" width=\"\(w)\" height=\"34\" rx=\"6\" fill=\"#cfd8f7\" stroke=\"#8b84d7\"/>"
            svg += "<text x=\"\(x(l.start) + 4)\" y=\"\(y + 22)\" font-size=\"11\" fill=\"#333\">\(l.order)</text>"
            _ = i
        }
        // 预测行
        for l in report.lines {
            let y = 140.0
            let w = max(1, (l.predEnd - l.predStart) * scale)
            let err = abs(l.startError)
            let fill = err <= 0.2 ? "#c9c2f0" : (err <= 0.5 ? "#f6e0b0" : "#f3c0c0")
            let stroke = err <= 0.2 ? "#8b7be8" : (err <= 0.5 ? "#d9a441" : "#d05a5a")
            svg += "<rect x=\"\(x(l.predStart))\" y=\"\(y)\" width=\"\(w)\" height=\"34\" rx=\"6\" fill=\"\(fill)\" stroke=\"\(stroke)\"/>"
            svg += "<text x=\"\(x(l.predStart) + 4)\" y=\"\(y + 22)\" font-size=\"11\" fill=\"#333\">\(l.order)</text>"
        }
        // 时间刻度
        var ticks = ""
        var t = 0.0
        let step = max(1, (dur / 12).rounded())
        while t <= dur {
            ticks += "<line x1=\"\(x(t))\" y1=\"40\" x2=\"\(x(t))\" y2=\"200\" stroke=\"#e6e6f2\"/>"
            ticks += "<text x=\"\(x(t))\" y=\"220\" font-size=\"10\" fill=\"#888\" text-anchor=\"middle\">\(String(format: "%.0f", t))s</text>"
            t += step
        }

        var rows = ""
        for l in report.lines {
            let err = abs(l.startError)
            let color = err <= 0.2 ? "#2e7d32" : (err <= 0.5 ? "#b26a00" : "#c62828")
            rows += "<tr><td>\(l.order)</td><td>\(esc(l.text))</td><td>\(String(format: "%.2f", l.truthStart))</td><td>\(String(format: "%.2f", l.predStart))</td><td style=\"color:\(color)\">\(String(format: "%+.0f ms", l.startError * 1000))</td><td>\(String(format: "%+.0f ms", l.endError * 1000))</td><td>\(l.boundariesWithinTolerance ? "是" : "否")</td><td>\(l.needsReview ? "复核" : "放行")</td><td>\(l.falseAutoAccept ? "是" : "否")</td><td>\(String(format: "%.2f", l.confidence))</td><td>\(esc(l.reasons.joined(separator: "；")))</td></tr>"
        }

        return """
        <!DOCTYPE html>
        <html lang="zh"><head><meta charset="utf-8">
        <title>\(report.id) — 对轨结果</title>
        <style>
          body { font-family: -apple-system, "Hiragino Sans", sans-serif; background:#fafbff; color:#2b2b3c; margin:32px; }
          h1 { font-size:20px; } h2 { font-size:15px; color:#5a5a75; margin-top:28px;}
          table { border-collapse:collapse; width:100%; font-size:12px; }
          th,td { border-bottom:1px solid #e8e8f2; padding:6px 8px; text-align:left; }
          th { background:#f1f1fa; font-weight:600; }
          .legend span { display:inline-block; margin-right:16px; font-size:12px;}
          .sw { display:inline-block; width:12px; height:12px; border-radius:3px; margin-right:4px; vertical-align:-1px;}
          .card { background:#fff; border:1px solid #ececf6; border-radius:12px; padding:16px; margin-bottom:20px;}
          .muted { color:#7a7a92; font-size:12px; }
        </style></head><body>
        <h1>\(report.id) — 对轨结果可视化</h1>
        <p class="muted">对齐器：\(esc(report.alignerName))（生产可用：\(report.alignerIsProductionReady ? "是" : "否")）<br>
        测试集类型：\(esc(report.kind))。语音合成基线，非歌手演唱。</p>

        <div class="card">
          <h2>时间线对比</h2>
          <svg width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
            \(ticks)
            <text x="8" y="80" font-size="12" fill="#5a5a75">真值</text>
            <text x="8" y="160" font-size="12" fill="#5a5a75">预测</text>
            \(svg)
          </svg>
          <div class="legend">
            <span><i class="sw" style="background:#c9c2f0;border:1px solid #8b7be8"></i>误差 ≤ 0.2s</span>
            <span><i class="sw" style="background:#f6e0b0;border:1px solid #d9a441"></i>0.2–0.5s</span>
            <span><i class="sw" style="background:#f3c0c0;border:1px solid #d05a5a"></i>&gt; 0.5s</span>
            <span><i class="sw" style="background:#cfd8f7;border:1px solid #8b84d7"></i>真值</span>
          </div>
        </div>

        <div class="card">
          <h2>指标</h2>
          <table>
            <tr><th>句数</th><th>平均误差</th><th>中央值</th><th>P90</th><th>±0.2s</th><th>±0.5s</th><th>均分基线平均误差</th><th>置信度放行（非准确率）</th><th>真值核验自动通过</th><th>误放行</th><th>耗时</th></tr>
            <tr>
              <td>\(report.lineCount)</td>
              <td>\(String(format: "%.0f ms", report.meanStartError * 1000))</td>
              <td>\(String(format: "%.0f ms", report.medianStartError * 1000))</td>
              <td>\(String(format: "%.0f ms", report.p90StartError * 1000))</td>
              <td>\(report.within020)</td>
              <td>\(report.within050)</td>
              <td>\(String(format: "%.0f ms", report.baselineMeanStartError * 1000))</td>
              <td>\(String(format: "%.0f%%", report.autoAcceptRatio * 100))</td>
              <td>\(String(format: "%.0f%%", report.truthQualifiedAutoAcceptRatio * 100))</td>
              <td>\(report.falseAutoAcceptCount) / \(String(format: "%.0f%%", report.falseAutoAcceptRate * 100))</td>
              <td>\(String(format: "%.2fs", report.elapsedSeconds))</td>
            </tr>
          </table>
        </div>

        <div class="card">
          <h2>逐句</h2>
          <table>
            <tr><th>#</th><th>歌词</th><th>真值起点</th><th>预测起点</th><th>起点误差</th><th>句尾误差</th><th>起止均≤0.5s</th><th>系统状态</th><th>误放行</th><th>置信度</th><th>原因</th></tr>
            \(rows)
          </table>
        </div>
        </body></html>
        """
    }
}

extension Phase0ClipReport {
    static func empty() -> Phase0ClipReport {
        Phase0ClipReport(id: "", kind: "", hasRepeat: false, duration: 0,
                         alignerName: "", alignerIsProductionReady: false,
                         lineCount: 0, meanStartError: 0, meanEndError: 0,
                         medianStartError: 0, p90StartError: 0, maxStartError: 0,
                         within020: 0, within050: 0, within100: 0,
                         unmatchedCount: 0, overlapCount: 0,
                         baselineMeanStartError: 0, baselineWithin050: 0,
                         needsReviewCount: 0, autoAcceptRatio: 0,
                         truthQualifiedAutoAcceptCount: 0, falseAutoAcceptCount: 0,
                         truthQualifiedAutoAcceptRatio: 0, falseAutoAcceptRate: 0,
                         fourTimeOrderViolations: 0, laneAlternationOK: false,
                         rubyOnlyOnKanji: false, moraMonotonicOK: false,
                         moraSumMatchesSingDuration: false,
                         elapsedSeconds: 0, peakMemoryMB: 0, notes: [], lines: [])
    }
}
