import Foundation

/// Experimental local bridge to the Japanese-singing Yohane CTC aligner.
///
/// Unlike the current speech-ASR route, this backend does not transcribe and
/// interpolate missing lyric lines. It converts the project's preserved kana
/// morae to the model's Latin phone alphabet and aligns that known sequence to
/// a separated vocal stem. The model and Python environment stay outside the
/// app bundle in Application Support.
public struct LocalYohaneForcedAligner: MediaAudioSourceAwareLyricAligning {

    public enum BackendError: LocalizedError {
        case unavailable(String)
        case process(String)
        case invalidResult(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "本机日语歌唱对齐器未就绪：\(reason)"
            case .process(let reason): return "本机日语歌唱对齐失败：\(reason)"
            case .invalidResult(let reason): return "日语歌唱对齐结果无效：\(reason)"
            }
        }
    }

    /// 运行环境根目录。`MAGIKARA_SUPPORT_ROOT` 只给测试用：在独立目录里完整走一遍配置单，
    /// 不碰本机已经装好的环境。
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_SUPPORT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("LocalForcedAligner", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaGiKara/LocalForcedAligner", isDirectory: true)
    }

    public static var pythonURL: URL {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_LOCAL_ALIGNER_PYTHON"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return root.appendingPathComponent("venv/bin/python")
    }

    public static var modelURL: URL {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_YOHANE_MODEL"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return root.appendingPathComponent("models/yohane-ja-latn", isDirectory: true)
    }

    static var sidecarURL: URL? {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_LOCAL_ALIGNER_SCRIPT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.module.url(forResource: "sidecar",
                                 withExtension: "py",
                                 subdirectory: "local_forced_aligner")
    }

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("model.safetensors").path)
            && sidecarURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    public static var availabilityDescription: String {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            return "隔离 Python 环境缺失（预期位置：\(pythonURL.path)）"
        }
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("model.safetensors").path) else {
            return "Yohane 模型权重缺失（预期位置：\(modelURL.path)）"
        }
        guard sidecarURL != nil else {
            return "应用资源中找不到本地 sidecar"
        }
        return "本机 Yohane 模型已就绪；CTC 分数尚未用人工声学真值校准"
    }

    public var name: String { "Yohane 日语歌唱 CTC 强制对齐（本机实验）" }
    public var isProductionReady: Bool { false }
    public var method: AlignmentMethod { .yohaneForcedAlign }

    public init() {}

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
        guard Self.isInstalled else { throw BackendError.unavailable(Self.availabilityDescription) }
        // 整行只有符号（「♪」「？！」「……」）时没有任何音拍，CTC 会让整次对齐失败；
        // 只把能唱的行交给 sidecar，符号行对完后按前后句插回去。
        let allLines = lines
        let lines = allLines.filter(Self.hasSingableUnits)
        guard !lines.isEmpty else { throw AlignError.noLyrics }

        var temporaryDirectory: URL?
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        var voiceURL = recognitionAudioURL
        if recognitionAudioURL.standardizedFileURL == mediaURL.standardizedFileURL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("magikara-yohane-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
            let vocalURL = directory.appendingPathComponent("vocal.wav")
            let instrumentalURL = directory.appendingPathComponent("instrumental.wav")
            progress?(AlignProgress(fraction: 0.04, message: "先分离人声，准备日语歌唱对齐…"))
            do {
                _ = try await VocalSeparator().separate(mediaURL: mediaURL,
                                                        toVocalURL: vocalURL,
                                                        toInstrumentalURL: instrumentalURL) { fraction in
                    progress?(AlignProgress(fraction: 0.04 + min(1, max(0, fraction)) * 0.28,
                                            message: "正在提取清晰人声…"))
                }
                voiceURL = vocalURL
            } catch {
                throw BackendError.process("人声分离失败，未改用混音伪装成歌声对齐：\(error.localizedDescription)")
            }
        }

        let request = SidecarRequest(
            protocolVersion: 1,
            audioPath: voiceURL.path,
            modelPath: Self.modelURL.path,
            device: "auto",
            lines: lines.map { line in
                SidecarLine(id: line.id.uuidString,
                            order: line.order,
                            text: line.text,
                            tokens: line.tokens.map { token in
                                SidecarToken(surface: token.surface,
                                             reading: token.reading,
                                             morae: JapaneseReadingService.alignmentUnits(for: token))
                            })
            })

        progress?(AlignProgress(fraction: 0.36, message: "CTC 正在逐拍对齐日语歌词…（首次载入模型会较慢）"))
        let response = try await Task.detached(priority: .userInitiated) {
            try Self.runSidecar(request)
        }.value
        try Task.checkCancellation()
        progress?(AlignProgress(fraction: 0.92, message: "正在检查音拍顺序与时间范围…"))

        guard response.protocolVersion == 1, response.ok else {
            throw BackendError.process(response.error ?? "sidecar 协议或推理失败")
        }
        guard let duration = response.duration,
              let frameSeconds = response.frameSeconds else {
            throw BackendError.invalidResult("成功响应缺少时长或帧长")
        }
        let results = try Self.mapAlignedLines(response,
                                               lines: lines,
                                               duration: duration,
                                               frameSeconds: frameSeconds)

        // CTC 强制对齐总会给出一条路径，但没有歌词时长先验；重复句可能被摊成
        // 一条异常长的字幕。共用质量闸门，至少明确标为需复核并压低置信度，不能静默放行。
        let checked = QualityChecker.annotate(results: results.map(Self.compensateOnsetDelay),
                                              features: nil,
                                              audioDuration: duration)
        progress?(AlignProgress(fraction: 1, message: "日语歌唱强制对齐完成（实验结果保持待确认）"))
        return Self.insertUnsingableLines(allLines, into: checked, duration: duration)
    }

    /// CTC 给出的音拍时间落在发声峰值附近，比真实起音晚。《花》40 句对比 LRCLIB 人工时间轴：
    /// 全部偏晚，中位数 0.19 秒、平均 0.215 秒；用户试听也反馈走轨普遍晚 0.2–0.3 秒。
    static let onsetDelayCompensation = 0.19

    static func compensateOnsetDelay(_ line: AlignedLyricLine) -> AlignedLyricLine {
        let d = -min(onsetDelayCompensation, line.singStart)
        guard d < 0 else { return line }
        var copy = line
        copy.singStart += d
        copy.singEnd += d
        for i in copy.tokens.indices {
            copy.tokens[i].shiftMorae(by: d)
        }
        return copy
    }

    static func hasSingableUnits(_ line: LyricLineDraft) -> Bool {
        line.tokens.contains { !JapaneseReadingService.alignmentUnits(for: $0).isEmpty }
    }

    /// 把没交给 sidecar 的符号行插回结果：时间放在前一句结束与后一句开始之间。
    static func insertUnsingableLines(_ allLines: [LyricLineDraft],
                                      into results: [AlignedLyricLine],
                                      duration: Double) -> [AlignedLyricLine] {
        let skipped = allLines.filter { !hasSingableUnits($0) }
        guard !skipped.isEmpty else { return results }
        var merged = results
        for draft in skipped {
            // 尾句重复展开的拷贝会占用后续序号，按原歌词行身份判断前后，而不是只比较 order。
            let earlierIDs = Set(allLines.filter { $0.order < draft.order }.map(\.id))
            let index = merged.lastIndex { earlierIDs.contains($0.sourceLineID ?? $0.id) }
                .map { $0 + 1 } ?? 0
            let lo = merged[..<index].map(\.singEnd).max() ?? 0
            let hi = merged[index...].map(\.singStart).min() ?? max(lo, duration)
            let start: Double
            let end: Double
            if hi - lo >= 0.4 {
                start = lo + 0.1
                end = hi - 0.1
            } else {
                start = lo
                end = lo + 0.2
            }
            let line = AlignedLyricLine(id: draft.id,
                                        order: draft.order,
                                        singStart: start,
                                        singEnd: end,
                                        confidence: 0.3,
                                        tokens: draft.tokens,
                                        reasons: ["整句只有符号、没有可唱的字，时间按前后句插入，请手动确认。"],
                                        method: .yohaneForcedAlign,
                                        evidence: .interpolated)
            merged.insert(line, at: index)
        }
        return merged
    }

    /// 把 sidecar 返回的行（可能因尾句重复展开而多于输入）映射成对齐结果。
    ///
    /// 尾句重复展开后，返回行数可以多于输入行数。用 `sourceLineIndex` 把每一条
    /// 结果映射回对应草稿：同一草稿的多份拷贝共享 token/音拍结构，但各有唯一 id。
    /// 任何 id、顺序、音拍映射或时长不合法都会抛错，绝不放行半成品。
    static func mapAlignedLines(_ response: SidecarResponse,
                                lines: [LyricLineDraft],
                                duration: Double,
                                frameSeconds: Double) throws -> [AlignedLyricLine] {
        guard let alignedLines = response.lines else {
            throw BackendError.invalidResult("成功响应缺少歌词行")
        }
        guard alignedLines.count >= lines.count else {
            throw BackendError.invalidResult("返回 \(alignedLines.count) 句，少于输入 \(lines.count) 句")
        }

        var results: [AlignedLyricLine] = []
        results.reserveCapacity(alignedLines.count)
        var copyCounts: [Int: Int] = [:]
        var usedIDs = Set<UUID>()
        var lastOrder = Int.min
        for (resultIndex, aligned) in alignedLines.enumerated() {
            let sourceIndex: Int
            if let explicit = aligned.sourceLineIndex {
                sourceIndex = explicit
            } else if alignedLines.count == lines.count {
                sourceIndex = resultIndex
            } else {
                throw BackendError.invalidResult("扩展结果缺少 sourceLineIndex，无法映射回输入歌词")
            }
            guard lines.indices.contains(sourceIndex) else {
                throw BackendError.invalidResult("对齐结果引用了不存在的输入行 \(sourceIndex + 1)")
            }
            let draft = lines[sourceIndex]
            let copyIndex = copyCounts[sourceIndex, default: 0]
            copyCounts[sourceIndex] = copyIndex + 1

            if let repeatIndex = aligned.repeatIndex, repeatIndex != copyIndex {
                throw BackendError.invalidResult("第 \(aligned.order) 句重复序号不连续")
            }
            if copyIndex > 0, sourceIndex != lines.count - 1 {
                throw BackendError.invalidResult("目前只允许展开最后一句重复歌词")
            }

            guard aligned.order > lastOrder else {
                throw BackendError.invalidResult("对齐结果顺序不单调")
            }
            lastOrder = aligned.order
            guard aligned.start.isFinite, aligned.end.isFinite,
                  aligned.start >= 0, aligned.end > aligned.start,
                  aligned.end <= duration + frameSeconds * 1.5 else {
                throw BackendError.invalidResult("第 \(aligned.order) 句身份或时间范围不合法")
            }

            var tokens = draft.tokens
            if copyIndex > 0 {
                for tokenIndex in tokens.indices {
                    tokens[tokenIndex].id = UUID()
                    tokens[tokenIndex].rubyOverrides = tokens[tokenIndex].rubyOverrides?.map { override in
                        var copy = override
                        copy.id = UUID()
                        return copy
                    }
                }
            }
            var timings = Array(repeating: [MoraTiming](), count: tokens.count)
            for span in aligned.morae {
                guard tokens.indices.contains(span.tokenIndex),
                      timings.indices.contains(span.tokenIndex),
                      span.start.isFinite, span.end.isFinite,
                      span.start >= 0, span.end > span.start,
                      span.end <= duration + frameSeconds * 1.5 else {
                    throw BackendError.invalidResult("第 \(aligned.order) 句包含越界或空音拍")
                }
                let expected = JapaneseReadingService.alignmentUnits(for: tokens[span.tokenIndex])
                guard expected.indices.contains(span.moraIndex),
                      expected[span.moraIndex] == span.mora else {
                    throw BackendError.invalidResult("第 \(aligned.order) 句音拍映射与原歌词不一致")
                }
                timings[span.tokenIndex].append(MoraTiming(mora: span.mora,
                                                           start: span.start,
                                                           end: span.end,
                                                           confidence: span.score))
            }

            for tokenIndex in tokens.indices {
                let expectedCount = JapaneseReadingService.alignmentUnits(for: tokens[tokenIndex]).count
                timings[tokenIndex].sort { $0.start < $1.start }
                guard timings[tokenIndex].count == expectedCount else {
                    throw BackendError.invalidResult("第 \(aligned.order) 句第 \(tokenIndex + 1) 词读音无法完整映射到音拍")
                }
                tokens[tokenIndex].morae = timings[tokenIndex]
            }

            var lineID = UUID(uuidString: aligned.id) ?? (copyIndex == 0 ? draft.id : UUID())
            while usedIDs.contains(lineID) {
                lineID = UUID()
            }
            usedIDs.insert(lineID)

            let rawScore = max(0, min(1, aligned.rawScore))
            // Forced alignment always returns a path, even when the text is wrong.
            // Keep the first prototype below auto-accept until human-ground-truth
            // calibration proves its score predictive.
            let provisionalConfidence = min(0.84, rawScore)
            var reasons = [String(format: "CTC 原始声学分数 %.2f；尚未按真实歌曲人工真值校准，暂不自动验收。", rawScore)]
            reasons.append("设备：\(response.device ?? "unknown")；推理 \(String(format: "%.1f", response.inferenceSeconds ?? 0)) 秒")
            if response.repeatAnalysis?.applied == true,
               copyIndex > 0 || (response.repeatAnalysis?.count ?? 1) > 1 {
                reasons.append("该句由尾句纯音频重复证据自动展开（非人工真值），仍需人工校准。")
            }
            if sourceIndex == lines.count - 1, copyIndex == 0,
               let repeatReason = response.repeatAnalysis?.reason {
                reasons.append("尾句循环检测：\(repeatReason)")
                let candidateSummary = (response.repeatAnalysis?.candidates ?? [])
                    .sorted { $0.support > $1.support }
                    .prefix(3)
                    .map {
                        String(format: "N=%d 谱%.2f/覆盖%.2f/CV%.3f/支持%.2f/CTC%.2f",
                               $0.count, $0.spectral, $0.coverage ?? 0, $0.durationCv,
                               $0.support, $0.ctcRawScore)
                    }
                if !candidateSummary.isEmpty {
                    reasons.append("尾句音频候选：\(candidateSummary.joined(separator: "；"))")
                }
            }
            if copyIndex == 0 {
                reasons.append(contentsOf: (response.warnings ?? []).filter {
                    $0.hasPrefix("第 \(draft.order) 句")
                })
            }
            results.append(AlignedLyricLine(id: lineID,
                                            sourceLineID: copyIndex > 0 ? draft.id : nil,
                                            order: aligned.order,
                                            singStart: aligned.start,
                                            singEnd: aligned.end,
                                            confidence: provisionalConfidence,
                                            tokens: tokens,
                                            reasons: reasons,
                                            method: .yohaneForcedAlign,
                                            evidence: .ctcForcedAlignment))
        }

        let covered = Set(copyCounts.keys)
        guard covered == Set(lines.indices) else {
            let missing = Set(lines.indices).subtracting(covered).sorted()
            throw BackendError.invalidResult("输入第 \(missing.map { String($0 + 1) }.joined(separator: "、")) 行没有对齐结果")
        }
        return results
    }

    private static func runSidecar(_ request: SidecarRequest) throws -> SidecarResponse {
        guard let scriptURL = sidecarURL else {
            throw BackendError.unavailable("应用资源中找不到 sidecar.py")
        }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let requestData = try JSONEncoder().encode(request)
            try input.fileHandleForWriting.write(contentsOf: requestData)
            try input.fileHandleForWriting.close()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !outputData.isEmpty else {
                throw BackendError.process("sidecar 没有返回 JSON（退出码 \(process.terminationStatus)）")
            }
            do {
                return try JSONDecoder().decode(SidecarResponse.self, from: outputData)
            } catch {
                throw BackendError.process("sidecar 返回格式无法读取：\(error.localizedDescription)")
            }
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.process(error.localizedDescription)
        }
    }
}

private struct SidecarRequest: Encodable, Sendable {
    var protocolVersion: Int
    var audioPath: String
    var modelPath: String
    var device: String
    var lines: [SidecarLine]
}

private struct SidecarLine: Encodable, Sendable {
    var id: String
    var order: Int
    var text: String
    var tokens: [SidecarToken]
}

private struct SidecarToken: Encodable, Sendable {
    var surface: String
    var reading: String?
    var morae: [String]
}

struct SidecarResponse: Decodable {
    var protocolVersion: Int
    var ok: Bool
    var error: String?
    var duration: Double?
    var frameSeconds: Double?
    var inferenceSeconds: Double?
    var device: String?
    var warnings: [String]?
    var repeatAnalysis: SidecarRepeatAnalysis?
    var lines: [SidecarLineResult]?
}

struct SidecarRepeatAnalysis: Decodable {
    var applied: Bool
    var count: Int?
    var reason: String?
    var margin: Double?
    var candidates: [SidecarRepeatCandidate]? = nil
}

struct SidecarRepeatCandidate: Decodable {
    var count: Int
    var spectral: Double
    var coverage: Double?
    var durationCv: Double
    var support: Double
    var ctcRawScore: Double
}

struct SidecarLineResult: Decodable {
    var id: String
    var order: Int
    var sourceLineIndex: Int?
    var repeatIndex: Int?
    var start: Double
    var end: Double
    var rawScore: Double
    var morae: [SidecarMoraResult]
}

struct SidecarMoraResult: Decodable {
    var tokenIndex: Int
    var moraIndex: Int
    var mora: String
    var start: Double
    var end: Double
    var score: Double
}
