import Foundation
import CoreGraphics
import AppKit
import MaGiKaraKit

// magikara-phase0 —— Phase 0 无头命令行
//
// 用途：
//   1. 生成/复用本地测试集（macOS say 合成的日语语音 + 构造真值）；
//   2. 跑真实 LocalLyricAligner，输出逐句误差、置信度、产品闭环检查；
//   3. 写出 JSON / Markdown / HTML 可视化报告。
//
// 用法:
//   magikara-phase0 [输出目录] [--rebuild] [--mock] [--demo <路径>]
//   magikara-phase0 --probe <媒体路径>

let args = Array(CommandLine.arguments.dropFirst())

// --setup-runtime [auto|official|china]：无界面跑一遍配置单（下载并安装缺的组件）。
// 配合 MAGIKARA_SUPPORT_ROOT=<空目录> 可以在不碰本机环境的情况下完整测试。
if let si = args.firstIndex(of: "--setup-runtime") {
    let raw = si + 1 < args.count ? args[si + 1] : "auto"
    let preference = DownloadSourcePreference(rawValue: raw == "auto" ? "automatic" : raw) ?? .automatic
    print("配置单：")
    for component in RuntimeSetup.components() {
        print("  [\(component.isReady ? "✓" : " ")] \(component.title)  \(component.isBundled ? "内置" : component.downloadBytes == 0 ? "—" : RuntimeSetup.formatBytes(component.downloadBytes))")
    }
    let started = Date()
    let lastPercent = LockedBox(-1)
    let runner = RuntimeSetupRunner { event in
        switch event {
        case .stepStarted(let step): print("\n▶ \(step.title)")
        case .stepSkipped(let step): print("\n✓ \(step.title)（已就绪，跳过）")
        case .source(let name): print("  下载源：\(name)")
        case .item(let item): print("  · \(item)")
        case .log(let line): print("    \(line)")
        case .bytes(let done, let total):
            guard let total, total > 0 else { return }
            let percent = Int(Double(done) / Double(total) * 100) / 10 * 10
            if lastPercent.swap(percent) != percent {
                print("  \(percent)%  \(RuntimeSetup.formatBytes(done)) / \(RuntimeSetup.formatBytes(total))")
            }
        }
    }
    do {
        try await runner.run(preference: preference)
        print(String(format: "\n全部就绪，用时 %.0f 秒", Date().timeIntervalSince(started)))
        exit(0)
    } catch {
        print("\n失败：\(error.localizedDescription)")
        exit(1)
    }
}

// --probe <媒体路径>：只跑音频分析链路并报告事实，不需要歌词。
if let probeIndex = args.firstIndex(of: "--probe") {
    guard probeIndex + 1 < args.count else {
        print("--probe 需要跟一个媒体文件路径")
        exit(1)
    }
    let path = args[probeIndex + 1]
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("文件不存在: \(path)")
        exit(1)
    }
    print("MaGi Kara — 真实媒体音频探针")
    print("（只做解码 + 逐帧特征 + 浊音/起音，不需要歌词，因而还不涉及对轨精度）\n")
    do {
        let report = try AudioProbe.run(url: url)
        print(AudioProbe.renderText(report))

        let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TestAssets/probe-\(url.deletingPathExtension().lastPathComponent).json")
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outURL)
        print("\nJSON: \(outURL.path)")
    } catch {
        print("探针失败: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// --separate <媒体> <输出目录> [--compute all|cpu|gpu]：跑 App 同款人声分离，写出 vocal.wav / instrumental.wav。
// 用于评估伴奏质量（与 App 完全同一条代码路径）。
if let si = args.firstIndex(of: "--separate") {
    guard si + 2 < args.count else { print("用法: --separate <媒体> <输出目录> [--compute all|cpu|gpu]"); exit(1) }
    let media = URL(fileURLWithPath: args[si + 1])
    let outDir = URL(fileURLWithPath: args[si + 2], isDirectory: true)
    if let ci = args.firstIndex(of: "--compute"), ci + 1 < args.count {
        switch args[ci + 1] {
        case "cpu": VocalSeparationCoreMLModel.computeUnits = .cpuOnly
        case "gpu": VocalSeparationCoreMLModel.computeUnits = .cpuAndGPU
        default: VocalSeparationCoreMLModel.computeUnits = .all
        }
    }
    if let oi = args.firstIndex(of: "--overlap"), oi + 1 < args.count, let v = Int(args[oi + 1]) {
        VocalSeparator.overlap = v
    }
    if let ii = args.firstIndex(of: "--inst"), ii + 1 < args.count,
       let mode = VocalSeparator.InstrumentalSource(rawValue: args[ii + 1]) {
        VocalSeparator.instrumentalSource = mode
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let started = Date()
    do {
        let result = try await VocalSeparator().separate(
            mediaURL: media,
            toVocalURL: outDir.appendingPathComponent("vocal.wav"),
            toInstrumentalURL: outDir.appendingPathComponent("instrumental.wav"))
        print(String(format: "完成：%.1f 秒音频，用时 %.1f 秒", result.duration, Date().timeIntervalSince(started)))
    } catch {
        print("分离失败: \(error.localizedDescription)"); exit(1)
    }
    exit(0)
}

// --render-check <媒体路径> <输出工程路径>
// 生成一个「只用于渲染验收」的工程：用 MockLyricAligner 生成音拍时间（RD 规定 Mock 仅供 UI 测试），
// 文字是明显的占位内容，用于在真实视频的复杂画面上检查字幕层效果。
// 它**不是**对轨结果，标题里也写明了这一点。
if let rcIndex = args.firstIndex(of: "--render-check") {
    guard rcIndex + 2 < args.count else {
        print("用法: magikara-phase0 --render-check <媒体路径> <输出工程.magikara>")
        exit(1)
    }
    let mediaURL = URL(fileURLWithPath: args[rcIndex + 1])
    let outURL = URL(fileURLWithPath: args[rcIndex + 2])
    guard FileManager.default.fileExists(atPath: mediaURL.path) else {
        print("媒体不存在: \(mediaURL.path)")
        exit(1)
    }
    do {
        let dur = await AudioDecoder.duration(of: mediaURL)
        let texts = [
            "字幕位置の確認用です",
            "下部安全域に固定表示",
            "未唱は白、既唱は藍紫",
            "仮名は漢字の上に表示",
        ]
        var lines = AnalysisCoordinator.makeLines(from: texts.joined(separator: "\n"))
        let drafts = lines.map {
            LyricLineDraft(id: $0.id, order: $0.order, text: $0.displayText, tokens: $0.tokens)
        }
        let mock = MockLyricAligner(startTime: 28.0, secondsPerMora: 0.28)
        let aligned = try await mock.align(audioURL: mediaURL, lines: drafts, progress: nil)

        // 固定时间窗：让 App 打开时自动定位到的位置正好是「两行同时显示、且都处于扫色中间」
        let windows: [(Double, Double, Double, Double)] = [
            (27.0, 28.0, 31.0, 34.0),
            (28.0, 29.0, 32.0, 35.0),
            (34.0, 35.0, 38.0, 41.0),
            (35.0, 36.0, 39.0, 42.0),
        ]
        for (i, a) in aligned.enumerated() where i < lines.count && i < windows.count {
            var line = lines[i]
            line.tokens = a.tokens
            let oldLo = a.singStart
            let oldHi = max(a.singStart + 1e-6, a.singEnd)
            let w = windows[i]
            line.displayStart = w.0
            line.singStart = w.1
            line.singEnd = w.2
            line.displayEnd = w.3
            line.rescaleMorae(from: oldLo...oldHi, to: w.1...w.2)
            line.confidence = 1.0
            line.needsReview = false
            line.reviewReasons = ["渲染检查占位"]
            lines[i] = line
        }

        var project = KaraProject(mediaURL: mediaURL,
                                  duration: dur > 0 ? dur : 174.0,
                                  title: "【渲染检查占位】非对轨结果")
        project.lyricLines = lines
        project.enforceAllInvariants()
        try ProjectStore.save(project, to: outURL)

        print("已生成渲染检查工程: \(outURL.path)")
        print("⚠️  文字是占位内容，音拍由 MockLyricAligner 生成（仅 UI 测试用途），不代表真实对轨结果。")
        print("    App 打开后会自动定位到第 1 句的 35% 处，此时两行同时显示且都在扫色中间态。")
    } catch {
        print("生成失败: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// --export-mp4 <工程.magikara> <输出.mp4>
// 用真实导出链路（VideoExporter）把工程烧录成 MP4，用于端到端验收。
if let ei = args.firstIndex(of: "--export-mp4") {
    guard ei + 2 < args.count else {
        print("用法: magikara-phase0 --export-mp4 <工程.magikara> <输出.mp4>"); exit(1)
    }
    do {
        var project = try ProjectStore.load(from: URL(fileURLWithPath: args[ei + 1]))
        let output = URL(fileURLWithPath: args[ei + 2])
        // --preset <名字>：先套用歌词模版（样式 + 换行节奏），便于逐个模版看渲染效果
        if let pi = args.firstIndex(of: "--preset"), pi + 1 < args.count {
            guard let preset = SubtitleStyle.Preset(rawValue: args[pi + 1]) else {
                print("未知模版: \(args[pi + 1])。可用: \(SubtitleStyle.Preset.allCases.map(\.rawValue).joined(separator: ", "))")
                exit(1)
            }
            var style = preset.style
            style.countdown = project.style.countdown
            style.countdownEnabled = project.style.countdownEnabled
            project.style = style
            project.displayPolicy = preset.displayPolicy
            DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
            project.enforceAllInvariants()
            project.syncOpeningCountdown()
            print("已套用模版: \(preset.displayName)")
        }
        // --ass-only：只生成 ASS，不重编码视频
        if args.contains("--ass-only") {
            let assURL = output.deletingPathExtension().appendingPathExtension("ass")
            try AssExporter.write(project: project, to: assURL)
            print("ASS: \(assURL.path)")
            exit(0)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        // 进度回调在后台线程触发：用无状态的方式每 ~20% 打印一次，避免捕获可变变量
        try VideoExporter.export(project: project, settings: .default, to: output, progress: { fraction in
            let percent = Int(fraction * 100)
            if percent % 20 == 0 || percent >= 99 { print("  进度 \(percent)%") }
        })
        print(String(format: "导出完成: %@  耗时 %.1f 秒", output.path, CFAbsoluteTimeGetCurrent() - t0))
        // 同时留一份 ASS，便于核对字幕事件的时间
        let assURL = output.deletingPathExtension().appendingPathExtension("ass")
        try AssExporter.write(project: project, to: assURL)
        print("ASS: \(assURL.path)")
    } catch {
        print("导出失败: \(error.localizedDescription)"); exit(1)
    }
    exit(0)
}

// --align <媒体路径> <歌词txt> <输出工程.magikara>
// 真实端到端：真实媒体 + 真实歌词文本 → 选定本地对齐器 → 可打开的工程 + ASS。
if let ai = args.firstIndex(of: "--align") {
    guard ai + 3 < args.count else {
        print("用法: magikara-phase0 --align <媒体路径> <歌词txt> <输出工程.magikara>")
        exit(1)
    }
    let mediaURL = URL(fileURLWithPath: args[ai + 1])
    let outURL = URL(fileURLWithPath: args[ai + 3])
    guard FileManager.default.fileExists(atPath: mediaURL.path) else {
        print("媒体不存在: \(mediaURL.path)"); exit(1)
    }
    let lyricsInput = args[ai + 2]
    let lyricsText: String?
    if lyricsInput == "-" {
        lyricsText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    } else {
        lyricsText = try? String(contentsOf: URL(fileURLWithPath: lyricsInput), encoding: .utf8)
    }
    guard let lyricsText else {
        print("读不到歌词文本: \(lyricsInput)"); exit(1)
    }
    do {
        let dur = await AudioDecoder.duration(of: mediaURL)
        var project = KaraProject(mediaURL: mediaURL,
                                  duration: dur > 0 ? dur : 0,
                                  title: mediaURL.deletingPathExtension().lastPathComponent)
        project.lyricLines = AnalysisCoordinator.makeLines(from: lyricsText)
        print("媒体: \(mediaURL.lastPathComponent)  \(String(format: "%.1f", project.duration)) 秒")
        print("歌词: \(project.lyricLines.count) 行  总音拍 \(project.lyricLines.reduce(0) { $0 + $1.moraCount })")

        // 默认走产品路径（macOS 26+ 为 ASR 强制对齐；更老系统明确降级）
        // 可选开关：用于 A/B 对比各优化项的实际效果
        var tuning = AlignmentEngineFactory.Tuning()
        if args.contains("--yohane") {
            tuning.backend = .yohaneKaraokeCTC
        }
        if args.contains("--yohane-audio-only") {
            tuning.backend = .yohaneKaraokeCTC
            tuning.preferScreenOCR = false
        }
        if args.contains("--no-multi-hyp") { tuning.multiHypothesis = false }
        if args.contains("--no-vocal-separation") { tuning.automaticallySeparateVocals = false }
        if args.contains("--no-local-realign") { tuning.localRealign = false }
        if args.contains("--single-run") { tuning.hypothesisRepeats = 1 }
        if args.contains("--onset-snap") { tuning.onsetSnap = true }
        if args.contains("--no-forward-onset") { tuning.forwardOnsetCorrection = false }
        // --product-default：走 App 实际使用的默认路径（Yohane 优先 + ASR 兜底），而不是 A/B 配置
        let selection = args.contains("--product-default")
            ? await AlignmentEngineFactory.makeDefault()
            : await AlignmentEngineFactory.makeDefault(tuning: tuning)
        print("对齐器: \(selection.aligner.name)")
        print("方法:   \(selection.aligner.method.displayName)")
        print("说明:   \(selection.detail)")
        if selection.aligner.method != .asrForcedAlign
            && selection.aligner.method != .yohaneForcedAlign
            && selection.aligner.method != .qualityFirst {
            print("⚠️ 当前不是 ASR 自动对轨路径，精度可能很差。")
        }
        let aligner = selection.aligner
        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = try await AnalysisCoordinator.analyze(project: project, aligner: aligner) { p in
            if p.fraction >= 1.0 { print("  \(p.message)") }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        try ProjectStore.save(outcome.project, to: outURL)
        let assURL = outURL.deletingPathExtension().appendingPathExtension("ass")
        try AssExporter.write(project: outcome.project, to: assURL)

        print(String(format: "耗时: %.2f 秒", elapsed))
        print("")
        print("| # | 歌词 | 演唱起 | 演唱止 | 显示起 | 显示止 | 置信度 |")
        print("| --- | --- | --- | --- | --- | --- | --- |")
        for l in outcome.project.sortedLines {
            print(String(format: "| %d | %@ | %.2f | %.2f | %.2f | %.2f | %.2f |",
                         l.order, l.displayText, l.singStart, l.singEnd,
                         l.displayStart, l.displayEnd, l.confidence))
        }
        if let summary = outcome.project.analysis {
            print("方法: \(summary.method?.displayName ?? "-")   证据分布: \(summary.evidenceCounts)")
        }
        let forwardReport = ASRCapability.lastForwardReport
        if !forwardReport.isEmpty { print("\n\(forwardReport)") }
        let snapReport = ASRCapability.lastSnapReport
        if !snapReport.isEmpty { print("\n\(snapReport)") }
        let hypReport = ASRCapability.lastHypothesisReport
        if !hypReport.isEmpty {
            print("")
            print("── 多假设音频前端比较（按客观指标选最佳）──")
            print(hypReport)
        }
        if !ScreenLyricAligner.lastReport.isEmpty {
            print("\n── 画面歌词路径诊断 ──\n\(ScreenLyricAligner.lastReport)")
        }
        let low = outcome.project.sortedLines.filter(\.needsReview)
        print("")
        print("待确认 \(low.count) / \(outcome.project.lyricLines.count) 句")
        for l in low {
            print("  #\(l.order) 置信度 \(String(format: "%.2f", l.confidence)) — \(l.reviewReasons.joined(separator: "；"))")
        }
        print("")
        print("工程: \(outURL.path)")
        print("ASS : \(assURL.path)")
    } catch {
        print("对轨失败: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// --from-ocr <媒体路径> <lyrics-timed.json> <输出工程.magikara>
//
// 用画面字幕 OCR 得到的时间作为演唱时间，构建可直接打开的工程。
// 用途：把「对轨精度」与「字幕渲染/导出」两件事分开评估 ——
// 音频自动对轨在真实歌曲上失败时，仍然可以用真实的字幕时间来验收成品效果。
//
// 明确标注：行内音拍时间是按音拍数平均分配的**占位**，不是逐音拍对轨结果。
if let oi = args.firstIndex(of: "--from-ocr") {
    guard oi + 3 < args.count else {
        print("用法: magikara-phase0 --from-ocr <媒体路径> <lyrics-timed.json> <输出工程.magikara>")
        exit(1)
    }
    let mediaURL = URL(fileURLWithPath: args[oi + 1])
    let timedURL = URL(fileURLWithPath: args[oi + 2])
    let outURL = URL(fileURLWithPath: args[oi + 3])
    struct TimedLine: Decodable { var order: Int; var text: String; var start: Double; var end: Double }
    struct TimedDoc: Decodable { var lines: [TimedLine] }
    do {
        let doc = try JSONDecoder().decode(TimedDoc.self, from: Data(contentsOf: timedURL))
        let dur = await AudioDecoder.duration(of: mediaURL)
        let reader = JapaneseReadingService()
        var lines: [LyricLine] = []
        for (i, tl) in doc.lines.enumerated() {
            let order = i + 1
            var line = LyricLine(order: order,
                                 lane: ScreenLane.lane(forOrder: order),
                                 displayText: tl.text)
            line.tokens = reader.tokens(for: tl.text)

            // 演唱时间来自画面字幕的出现/消失（留 0.1 秒余量给显示区）
            let singStart = tl.start + 0.10
            let singEnd = max(singStart + 0.30, tl.end - 0.10)
            line.singStart = singStart
            line.singEnd = singEnd

            // 行内音拍：按音拍数平均分配（占位）
            let units = line.tokens.map { JapaneseReadingService.alignmentUnits(for: $0) }
            let totalUnits = units.reduce(0) { $0 + $1.count }
            if totalUnits > 0 {
                let span = singEnd - singStart
                var cursor = singStart
                for ti in line.tokens.indices {
                    let n = units[ti].count
                    guard n > 0 else { line.tokens[ti].morae = []; continue }
                    let slice = span * Double(n) / Double(totalUnits)
                    var morae: [MoraTiming] = []
                    for j in 0..<n {
                        let s = cursor + slice * Double(j) / Double(n)
                        let e = cursor + slice * Double(j + 1) / Double(n)
                        morae.append(MoraTiming(mora: units[ti][j], start: s, end: e, confidence: 0))
                    }
                    line.tokens[ti].morae = morae
                    cursor += slice
                }
            }
            line.confidence = 0
            line.needsReview = true
            line.alignmentMethod = .screenTimedOCR
            line.alignmentEvidence = .screenOCR
            line.reviewReasons = ["演唱时间来自画面字幕 OCR（不是音频自动对轨）；行内音拍为平均分配（占位）"]
            lines.append(line)
        }
        var project = KaraProject(mediaURL: mediaURL, duration: dur > 0 ? dur : 0,
                                  title: "なんもねえ · 字幕时间来自 OCR")
        project.lyricLines = lines
        // 显示区仍走产品的双行/停留调度，用来演示目标效果
        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        project.enforceAllInvariants()
        project.analysis = AnalysisSummary(alignerName: "ScreenTimedOCR",
                                           elapsedSeconds: 0,
                                           totalLines: lines.count,
                                           lowConfidenceCount: lines.count,
                                           notes: ["时间来自画面字幕 OCR，不是音频自动对轨"],
                                           method: .screenTimedOCR,
                                           evidenceCounts: ["screen-ocr": lines.count])
        try ProjectStore.save(project, to: outURL)
        let assURL = outURL.deletingPathExtension().appendingPathExtension("ass")
        try AssExporter.write(project: project, to: assURL)
        print("工程: \(outURL.path)")
        print("ASS : \(assURL.path)（\(lines.count) 句）")
        print("⚠️  对轨时间来自画面字幕 OCR，行内音拍为平均分配占位。")
    } catch {
        print("失败: \(error.localizedDescription)"); exit(1)
    }
    exit(0)
}

// --onset-report <媒体> <工程.magikara> <ocr-timed.json> <输出json>
//
// 两套指标并列：
//   A) acousticOnset —— 用**独立于 ASR** 的能量/谱通量起音检测得到的人声起点，
//      看「对轨时间」与「画面字幕时间」各自离它有多远；
//   B) screenSubtitleTime —— 画面字幕出现时间（OCR）。
// 这两者物理含义不同：前者是声学开口，后者是字幕显示时刻。
// 产品默认使用声学起点；画面字幕时间只作为独立评估参考。
if let oi = args.firstIndex(of: "--onset-report") {
    guard oi + 4 < args.count else {
        print("用法: magikara-phase0 --onset-report <媒体> <工程.magikara> <ocr-timed.json> <输出json>")
        exit(1)
    }
    let mediaURL = URL(fileURLWithPath: args[oi + 1])
    let projectURL = URL(fileURLWithPath: args[oi + 2])
    let ocrURL = URL(fileURLWithPath: args[oi + 3])
    let outURL = URL(fileURLWithPath: args[oi + 4])
    struct TimedLine: Decodable { var order: Int; var text: String; var start: Double; var end: Double }
    struct TimedDoc: Decodable { var lines: [TimedLine] }
    do {
        let project = try ProjectStore.load(from: projectURL)
        let ocr = try JSONDecoder().decode(TimedDoc.self, from: Data(contentsOf: ocrURL))
        guard let decoded = try? AudioDecoder.decode(url: mediaURL, sampleRate: 16000, peakBuckets: 256) else {
            print("音频解码失败"); exit(1)
        }
        let features = AudioFeatureExtractor.extract(from: decoded)

        // 强起音点：novelty 的局部极大且显著高于均值
        let novelty = features.novelty
        var mean: Double = 0
        for v in novelty { mean += Double(v) }
        mean /= Double(max(1, novelty.count))
        var variance: Double = 0
        for v in novelty { variance += (Double(v) - mean) * (Double(v) - mean) }
        let sd = (variance / Double(max(1, novelty.count))).squareRoot()
        // 用「人声段起点」作为独立的声学参考。
        //
        // 为什么不用 novelty 阈值：这首歌是密集的摇滚编曲，谱通量几乎没有低谷
        // （实测 novelty 均值 0.56、标准差 0.25），任何阈值要么留下几百个鼓点、
        // 要么一个都不剩，没有区分度。人声段起点（浊音从无到有）才是乐句真正
        // 的开口，而且它来自**与 ASR 完全不同的算法**（能量/似然 + 迟滞），
        // 可以作为独立参照。
        var strongOnsets: [Double] = []
        if features.frameCount > 2 {
            let minIslandFrames = max(1, Int(0.30 / features.hopSeconds))
            var i = 1
            while i < features.frameCount {
                if features.voiced[i], !features.voiced[i - 1] {
                    var j = i
                    while j < features.frameCount, features.voiced[j] { j += 1 }
                    if j - i >= minIslandFrames {
                        strongOnsets.append(features.time(forFrame: i))
                    }
                    i = j
                } else {
                    i += 1
                }
            }
        }
        print(String(format: "  [诊断] 人声段数=%d  novelty 均值=%.3f 标准差=%.3f",
                     strongOnsets.count, mean, sd))

        func nearestOnsetOffset(_ t: Double) -> Double? {
            guard let n = strongOnsets.min(by: { abs($0 - t) < abs($1 - t) }) else { return nil }
            let d = n - t
            return abs(d) <= 1.5 ? d : nil
        }

        struct Row: Codable {
            var order: Int; var text: String
            var alignStart: Double; var ocrStart: Double
            var alignToOnset: Double?; var ocrToOnset: Double?
        }
        var rows: [Row] = []
        let lines = project.sortedLines
        for (i, line) in lines.enumerated() {
            let ocrStart = i < ocr.lines.count ? ocr.lines[i].start : 0
            rows.append(Row(order: line.order, text: line.displayText,
                            alignStart: line.singStart, ocrStart: ocrStart,
                            alignToOnset: nearestOnsetOffset(line.singStart),
                            ocrToOnset: nearestOnsetOffset(ocrStart)))
        }
        func stats(_ vals: [Double]) -> (n: Int, mean: Double, median: Double, p90: Double) {
            guard !vals.isEmpty else { return (0, 0, 0, 0) }
            let s = vals.sorted()
            return (s.count, s.reduce(0, +) / Double(s.count), s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))])
        }
        let aVals = rows.compactMap { $0.alignToOnset.map(abs) }
        let oVals = rows.compactMap { $0.ocrToOnset.map(abs) }
        let a = stats(aVals), o = stats(oVals)

        print("独立声学起音点检测：共 \(strongOnsets.count) 个强起音")
        print("")
        print("  A) 对轨时间 到最近声学起音点的距离：n=\(a.n)  平均 \(String(format: "%.3f", a.mean))s  中位 \(String(format: "%.3f", a.median))s  P90 \(String(format: "%.3f", a.p90))s")
        print("  B) 画面字幕时间 到最近声学起音点的距离：n=\(o.n)  平均 \(String(format: "%.3f", o.mean))s  中位 \(String(format: "%.3f", o.median))s  P90 \(String(format: "%.3f", o.p90))s")
        print("")
        if a.mean < o.mean {
            print("  → 对轨时间比画面字幕时间更贴近真实声学起音（相差 \(String(format: "%.3f", o.mean - a.mean)) 秒）")
        } else {
            print("  → 画面字幕时间反而更贴近声学起音")
        }

        struct Doc: Codable {
            var media: String
            var strongOnsetCount: Int
            var alignToOnset: [String: Double]
            var ocrToOnset: [String: Double]
            var rows: [Row]
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Doc(media: mediaURL.lastPathComponent,
                           strongOnsetCount: strongOnsets.count,
                           alignToOnset: ["n": Double(a.n), "mean": a.mean, "median": a.median, "p90": a.p90],
                           ocrToOnset: ["n": Double(o.n), "mean": o.mean, "median": o.median, "p90": o.p90],
                           rows: rows)).write(to: outURL)
        print("JSON: \(outURL.path)")
    } catch {
        print("失败: \(error.localizedDescription)"); exit(1)
    }
    exit(0)
}

// --render-timeline <工程.magikara> <输出.png> [开始秒] [时长秒] [每秒像素]
//
// 离屏渲染时间线歌词块，作为「歌词块按真实演唱时间摆放 + 块内逐字按 token 时间摆放」
// 的可复查证据。**不启动 GUI**，因此不会触发任何系统权限弹窗，
// 而且用的是与 App 完全相同的 LyricBlockLayout / LyricCharTiming 代码。
if let ti = args.firstIndex(of: "--render-timeline") {
    guard ti + 2 < args.count else {
        print("用法: magikara-phase0 --render-timeline <工程.magikara> <输出.png> [开始秒] [时长秒] [每秒像素]")
        exit(1)
    }
    let projectURL = URL(fileURLWithPath: args[ti + 1])
    let outURL = URL(fileURLWithPath: args[ti + 2])
    let startSec = ti + 3 < args.count ? (Double(args[ti + 3]) ?? 108) : 108
    let spanSec = ti + 4 < args.count ? (Double(args[ti + 4]) ?? 16) : 16
    let pps = ti + 5 < args.count ? (Double(args[ti + 5]) ?? 72) : 72
    let W = 1800.0, H = 560.0
    let leftPad = 96.0, rightPad = 24.0
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("无法创建绘图上下文"); exit(1)
    }
    func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [r, g, b, a])!
    }
    ctx.setFillColor(rgb(0.99, 0.99, 1.0)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    do {
        let project = try ProjectStore.load(from: projectURL)
        let trackX0 = leftPad
        let trackW = W - leftPad - rightPad
        func xFor(_ t: Double) -> Double { trackX0 + (t - startSec) * pps }

        // 时间尺
        ctx.setFillColor(rgb(0.96, 0.96, 0.98))
        ctx.fill(CGRect(x: 0, y: H - 46, width: W, height: 46))
        ctx.setStrokeColor(rgb(0.75, 0.75, 0.82)); ctx.setLineWidth(1)
        var tick = (startSec / 2).rounded(.up) * 2
        while tick <= startSec + spanSec + 0.001 {
            let x = xFor(tick)
            ctx.move(to: CGPoint(x: x, y: H - 46)); ctx.addLine(to: CGPoint(x: x, y: H - 34))
            ctx.strokePath()
            let label = String(format: "%d:%04.1f", Int(tick) / 60, tick - Double(Int(tick) / 60 * 60))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)]
            let s = NSAttributedString(string: label, attributes: attrs)
            let size = s.size()
            NSGraphicsContext.saveGraphicsState()
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = gc
            s.draw(at: NSPoint(x: x - size.width / 2, y: H - 30))
            NSGraphicsContext.restoreGraphicsState()
            tick += 2
        }

        // 四条轨道：假名上行 / 歌词上行 / 假名下行 / 歌词下行
        struct Lane { var title: String; var y: Double; var height: Double; var isLyric: Bool }
        let lanes: [Lane] = [
            Lane(title: "假名 · 上行", y: H - 46 - 30 - 78, height: 34, isLyric: false),
            Lane(title: "歌词 · 上行", y: H - 46 - 30 - 40, height: 40, isLyric: true),
            Lane(title: "假名 · 下行", y: H - 46 - 30 - 78 - 96, height: 34, isLyric: false),
            Lane(title: "歌词 · 下行", y: H - 46 - 30 - 40 - 96, height: 40, isLyric: true),
        ]
        for lane in lanes {
            ctx.setFillColor(rgb(0.97, 0.97, 0.985))
            ctx.fill(CGRect(x: trackX0, y: lane.y, width: trackW, height: lane.height))
            ctx.setFillColor(rgb(0.30, 0.26, 0.45))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: lane.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1)
            ]).draw(at: NSPoint(x: 8, y: lane.y + lane.height / 2 - 7))
            NSGraphicsContext.restoreGraphicsState()
        }

        // 画歌词块
        var placed = 0
        for line in project.sortedLines {
            guard line.singEnd > line.singStart else { continue }
            let lane = lanes[line.lane == .upper ? 1 : 3]
            // 显示区（淡）
            let dx = xFor(line.displayStart)
            let dw = max(6, (line.displayEnd - line.displayStart) * pps)
            if dx + dw > trackX0, dx < trackX0 + trackW {
                ctx.setFillColor(rgb(0.62, 0.55, 0.92, 0.22))
                let r = CGRect(x: dx, y: lane.y + 4, width: dw, height: lane.height - 8)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.fillPath()
            }
            // 轨道被隐藏 → 压暗
            let trackVisible = project.trackStates.isVisible(line.lane == .upper ? .lyricUpper : .lyricLower)
            let trackLocked = project.trackStates.isLocked(line.lane == .upper ? .lyricUpper : .lyricLower)
            ctx.setAlpha(trackVisible ? 1.0 : 0.3)

            // 演唱区（实心 = 真实演唱区间）
            let sx = xFor(line.singStart)
            let sw = max(4, (line.singEnd - line.singStart) * pps)
            var under = false
            if let ph = ProcessInfo.processInfo.environment["MAGIKARA_PLAYHEAD"], let p = Double(ph) {
                under = p >= line.singStart && p < line.singEnd
            }
            ctx.setFillColor(under ? rgb(0.30, 0.18, 0.75, 0.55) : rgb(0.46, 0.38, 0.85, 0.45))
            let r2 = CGRect(x: sx, y: lane.y + 4, width: sw, height: lane.height - 8)
            ctx.addPath(CGPath(roundedRect: r2, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            if trackLocked {
                // 锁定：灰色斜纹 + 虚线描边
                ctx.saveGState()
                ctx.clip(to: r2)
                ctx.setStrokeColor(rgb(0.55, 0.55, 0.65, 0.55)); ctx.setLineWidth(2)
                var dx = sx - r2.height
                while dx < sx + sw {
                    ctx.move(to: CGPoint(x: dx, y: r2.minY))
                    ctx.addLine(to: CGPoint(x: dx + r2.height, y: r2.maxY))
                    ctx.strokePath()
                    dx += 9
                }
                ctx.restoreGState()
                ctx.setStrokeColor(rgb(0.45, 0.45, 0.55, 0.9)); ctx.setLineWidth(1.2)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.addPath(CGPath(roundedRect: r2, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            } else if line.needsReview {
                ctx.setStrokeColor(rgb(0.95, 0.55, 0.15, 0.95)); ctx.setLineWidth(1.4)
                ctx.addPath(CGPath(roundedRect: r2, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
            }
            // 选中块：紫色实线描边
            if let sel = ProcessInfo.processInfo.environment["MAGIKARA_SELECTED"], Int(sel) == line.order {
                ctx.setStrokeColor(rgb(0.35, 0.15, 0.85)); ctx.setLineWidth(2.2)
                ctx.addPath(CGPath(roundedRect: r2.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.strokePath()
            }
            ctx.setAlpha(1.0)
            // 块内逐字（与 App 共用 LyricBlockLayout）
            let layout = LyricBlockLayout.layout(line: line, pixelsPerSecond: pps,
                                                 originTime: line.singStart, width: sw)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for item in layout.items {
                let a = NSAttributedString(string: String(item.character), attributes: [
                    .font: NSFont.systemFont(ofSize: layout.fontSize, weight: .medium),
                    .foregroundColor: item.hasTokenEvidence
                        ? NSColor(calibratedWhite: 0.12, alpha: 1)
                        : NSColor(calibratedWhite: 0.12, alpha: 0.45)
                ])
                a.draw(at: NSPoint(x: sx + item.x, y: lane.y + lane.height / 2 - layout.fontSize * 0.72))
            }
            NSGraphicsContext.restoreGraphicsState()
            placed += 1
        }

        // playhead
        if let phs = ProcessInfo.processInfo.environment["MAGIKARA_PLAYHEAD"], let ph = Double(phs) {
            let x = xFor(ph)
            ctx.setStrokeColor(rgb(0.35, 0.15, 0.85)); ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: x, y: 40)); ctx.addLine(to: CGPoint(x: x, y: H - 46))
            ctx.strokePath()
        }

        // 说明
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let caption = "MaGi Kara · 时间线歌词块离屏渲染（与 App 共用 LyricBlockLayout / LyricCharTiming）\n"
            + "区间 \(String(format: "%.1f", startSec))–\(String(format: "%.1f", startSec + spanSec)) 秒  "
            + "缩放 \(String(format: "%.0f", pps)) px/秒  共 \(placed) 个歌词块\n"
            + "淡色外框 = 显示区（displayStart→displayEnd）；实心块 = 真实演唱区间（acousticOnset→acousticOffset）\n"
            + "块内逐字按 token/音拍时间摆放（字距不均匀）；橙色描边 = 待确认；斜纹+虚线 = 所在轨道已锁定；压暗 = 轨道已隐藏"
        NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1)
        ]).draw(at: NSPoint(x: 8, y: 8))
        NSGraphicsContext.restoreGraphicsState()

        guard let img = ctx.makeImage() else { print("渲染失败"); exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("PNG 编码失败"); exit(1) }
        try data.write(to: outURL)
        print("已渲染时间线: \(outURL.path)  块数 \(placed)")
        // 同时打印一份文本证据，便于核对
        print("")
        print("| # | 显示区 | 演唱区(块宽) | 块内字数 |")
        print("| --- | --- | --- | --- |")
        for line in project.sortedLines where line.singEnd > line.singStart
            && line.singEnd >= startSec && line.singStart <= startSec + spanSec {
            let l = LyricBlockLayout.layout(line: line, pixelsPerSecond: pps,
                                            originTime: line.singStart,
                                            width: (line.singEnd - line.singStart) * pps)
            print(String(format: "| %d | %.2f–%.2f | %.2f–%.2f (%.0fpx) | %d |",
                         line.order, line.displayStart, line.displayEnd,
                         line.singStart, line.singEnd, (line.singEnd - line.singStart) * pps,
                         l.items.count))
        }
    } catch {
        print("失败: \(error.localizedDescription)"); exit(1)
    }
    exit(0)
}

var directory: URL?
var rebuild = false
var useMock = false
var demoPath: String?

var index = 0
let argList = args
while index < argList.count {
    let arg = argList[index]
    switch arg {
    case "--rebuild": rebuild = true
    case "--mock": useMock = true
    case "--demo":
        index += 1
        if index < argList.count { demoPath = argList[index] }
    case "--help", "-h":
        print("""
        用法: magikara-phase0 [输出目录] [--rebuild] [--mock] [--demo <工程路径>]
              magikara-phase0 --probe <媒体路径>

          输出目录          默认 ./TestAssets
          --rebuild         强制重新合成测试集
          --mock            使用 MockLyricAligner（仅用于验证 UI 测试路径，结果不代表真实对轨）
          --demo <路径>     额外生成一个可直接用 App 打开的演示工程 (.magikara)
          --probe <路径>    对真实媒体跑音频分析并报告事实（不需要歌词）
        """)
        exit(0)
    default:
        directory = URL(fileURLWithPath: arg)
    }
    index += 1
}

let assetsDir = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("TestAssets")

let aligner: LyricAligning = useMock ? MockLyricAligner() : LocalLyricAligner()

print("MaGi Kara — Phase 0 对轨基线")
print("输出目录: \(assetsDir.path)")
print("对齐器: \(aligner.name)")
if !aligner.isProductionReady {
    print("⚠️  这不是产品路径，结果仅用于 UI 测试验证。")
}
print("")

do {
    let summary = try await Phase0Runner.run(assetsDirectory: assetsDir,
                                            rebuildTestSet: rebuild,
                                            aligner: aligner,
                                            log: { print($0) })

    print("")
    print("──────── 汇总 ────────")
    print("片段数:            \(summary.totalClips)")
    print("总句数:            \(summary.totalLines)")
    print(String(format: "句边界平均误差:    %.0f ms", summary.meanStartError * 1000))
    print(String(format: "均分基线平均误差:  %.0f ms", summary.baselineMeanStartError * 1000))
    if summary.baselineMeanStartError > 0 {
        print(String(format: "相对均分基线改善:  %.0f%%",
                     (1 - summary.meanStartError / summary.baselineMeanStartError) * 100))
    }
    print(String(format: "置信度放行比例(非准确率): %.1f%%", summary.autoAcceptRatio * 100))
    print(String(format: "真值核验自动通过(首尾均≤0.5s): %.1f%%", summary.truthQualifiedAutoAcceptRatio * 100))
    print("高置信度误放行句数: \(summary.falseAutoAcceptCount)")
    print("错配句数(>1s):     \(summary.unmatchedCount)")
    print(String(format: "总耗时:            %.2f s", summary.totalElapsedSeconds))
    print(String(format: "峰值内存:          %.0f MB", summary.peakMemoryMB))
    print("")
    print("报告: \(assetsDir.appendingPathComponent("reports/summary.md").path)")

    if let demoPath {
        let project = try await Phase0Runner.makeDemoProject(assetsDirectory: assetsDir,
                                                            aligner: aligner)
        let url = URL(fileURLWithPath: demoPath)
        try ProjectStore.save(project, to: url)
        print("演示工程: \(url.path)")

        // 顺带导出一份真实 ASS，方便直接用播放器检查扫色
        let assURL = url.deletingPathExtension().appendingPathExtension("ass")
        try AssExporter.write(project: project, to: assURL)
        let rubyCount = project.sortedLines.reduce(0) { $0 + $1.rubyTokens.count }
        print("演示 ASS: \(assURL.path)（\(project.lyricLines.count) 句，\(rubyCount) 个假名事件）")
    }
} catch {
    print("Phase 0 运行失败: \(error.localizedDescription)")
    exit(1)
}

/// 进度回调在下载线程上，用锁保护「上次打印到的百分比」。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    /// 写入新值，返回旧值
    func swap(_ newValue: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
