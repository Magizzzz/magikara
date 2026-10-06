import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// 画面带硬字幕时的高置信度时间入口。
///
/// 这不是把 OCR 冒充成音频对轨：它只在「画面里的日文行」与用户粘贴的歌词
/// 达到足够覆盖率时启用，并把每句证据标成 `screen-ocr`。没有足够画面证据时，
/// 由 `QualityFirstAligner` 自动回到本地 ASR 强制对轨。
@available(macOS 14.0, *)
public struct ScreenLyricAligner: LyricAligning {
    public struct Config: Sendable {
        /// 采样频率。2 fps 对淡入淡出和短句已经足够，避免一键生成过慢。
        public var sampleRate: Double = 2.0
        /// 日文歌词通常位于画面底部；裁掉上方内容可显著减少标题/水印误识别。
        public var cropTopFraction: Double = 0.68
        /// 单帧 OCR 与用户歌词的最低相似度。
        public var frameSimilarityThreshold: Double = 0.42
        /// 合并同一行连续帧时允许的最小相似度。
        public var mergeSimilarityThreshold: Double = 0.55
        /// 画面歌词覆盖率低于此值时不抢占 ASR 主路径。
        public var minimumCoverage: Double = 0.75
        /// OCR 时间只负责可见行的显示/扫色区，给切换边缘留一小点余量。
        public var edgeTrim: Double = 0.05

        public init() {}
        public static let `default` = Config()
    }

    private struct Observation: Sendable {
        var text: String
        var key: String
        var start: Double
        var end: Double
        var similarity: Double
        var frameCount: Int
    }

    private struct Assignment: Sendable {
        var observation: Observation
        var similarity: Double
        var splitIndex: Int
        var splitCount: Int
    }

    public var config: Config

    /// 最近一次画面路径的轻量诊断，供 CLI/验收使用，不写入工程。
    public nonisolated(unsafe) static var lastReport: String = ""

    public init(config: Config = .default) {
        self.config = config
    }

    public var name: String { "ScreenLyricAligner（画面歌词优先）" }
    public var isProductionReady: Bool { true }
    public var method: AlignmentMethod { .screenTimedOCR }

    public func align(audioURL: URL,
                      lines: [LyricLineDraft],
                      progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        guard !lines.isEmpty else { throw AlignError.noLyrics }
        progress?(AlignProgress(fraction: 0.04, message: "正在检查画面歌词…"))

        let expected = lines.map { JapaneseNormalizer.normalizeForMatching($0.text) }
        let observations = try await scan(mediaURL: audioURL,
                                          expected: expected,
                                          progress: progress)
        let assignments = assign(observations: observations, expected: expected)
        let matched = assignments.compactMap { $0 }.count
        let coverage = Double(matched) / Double(max(1, lines.count))
        let meanSimilarity = assignments.compactMap(\.?.similarity).reduce(0, +)
            / Double(max(1, matched))
        let diagnostic = observations
            .filter { $0.start >= 120 && $0.start <= 142 }
            .map { String(format: "%.1f–%.1f:%@", $0.start, $0.end, $0.key) }
            .joined(separator: " | ")
        Self.lastReport = "画面候选 \(observations.count) 段，匹配 \(matched)/\(lines.count) 句，平均相似度 \(String(format: "%.3f", meanSimilarity))\n\(diagnostic)"

        // 低覆盖时必须回 ASR，而不是拿稀疏 OCR 结果硬铺整首。
        guard coverage >= config.minimumCoverage, meanSimilarity >= 0.62 else {
            throw AlignError.decode(String(format: "画面歌词覆盖率不足（%.0f%%，相似度 %.0f%%）",
                                           coverage * 100, meanSimilarity * 100))
        }

        progress?(AlignProgress(fraction: 0.78,
                                message: String(format: "已识别画面歌词 %d/%d 句，正在生成扫色时间…",
                                                matched, lines.count)))
        // 画面时间决定「这一句何时出现」，ASR 时间只负责在该窗口内细化逐字扫色。
        // ASR 不可用或模型未下载时，仍可用 OCR 行区间完成稳定的句级成品。
        var asrMatches: [LyricASRMatch.LineMatch]?
        if #available(macOS 26.0, *) {
            if let transcript = try? await SpeechASREngine.shared.transcribe(
                mediaURL: audioURL,
                locale: SpeechASREngine.defaultLocale) {
                var matcherConfig = ASRLyricMatcher.Config()
                // 该结果的 charTimes 需要与行内音拍表面字符一一对应；
                // 语音强制对齐主路径则使用读音归一化。
                matcherConfig.usePhoneticReadings = false
                asrMatches = ASRLyricMatcher.match(
                    lyrics: lines.map(\.text), transcript: transcript, config: matcherConfig).lines
            }
        }
        return lines.enumerated().map { index, draft in
            guard let assignment = assignments[index] else {
                // 只会在覆盖率仍达标时出现，明确压低置信度并按邻近时间占位。
                let previous = assignments[..<index].last(where: { $0 != nil })??.observation.end ?? 0
                let next = assignments[(index + 1)...].first(where: { $0 != nil })??.observation.start
                    ?? previous + 2.0
                let span = max(0.3, next - previous)
                return makeResult(draft, start: previous + span * 0.15,
                                  end: previous + span * 0.85,
                                  confidence: 0.45,
                                  reasons: ["画面歌词未稳定识别，时间由相邻画面行插值"],
                                  evidence: .interpolated,
                                  fineTiming: nil)
            }

            let span = max(0.25, assignment.observation.end - assignment.observation.start)
            let part = span / Double(max(1, assignment.splitCount))
            let start = assignment.observation.start + part * Double(assignment.splitIndex)
            let end = assignment.observation.start + part * Double(assignment.splitIndex + 1)
            let trim = min(config.edgeTrim, max(0, (end - start) * 0.12))
            let confidence = min(0.98,
                                0.76 + assignment.similarity * 0.20
                                    + min(0.04, Double(assignment.observation.frameCount) * 0.005))
            var reasons: [String] = []
            if assignment.similarity < 0.88 {
                reasons.append(String(format: "画面歌词相似度 %.0f%%，建议试听确认", assignment.similarity * 100))
            }
            return makeResult(draft,
                              start: start + trim,
                              end: max(start + 0.05, end - trim),
                              confidence: confidence,
                              reasons: reasons,
                              evidence: .screenOCR,
                              fineTiming: fineTiming(for: index,
                                                     match: asrMatches?.dropFirst(index).first,
                                                     start: start + trim,
                                                     end: max(start + 0.05, end - trim),
                                                     unitCount: draft.unitCount))
        }

    }

    private func makeResult(_ draft: LyricLineDraft,
                            start: Double,
                            end: Double,
                            confidence: Double,
                            reasons: [String],
                            evidence: AlignmentEvidence,
                            fineTiming: ([Double?], [Double?])?) -> AlignedLyricLine {
        let s = max(0, start)
        let e = max(s + LyricLine.minimumSingDuration, end)
        let units = draft.tokens.flatMap { JapaneseReadingService.alignmentUnits(for: $0) }
        let span = max(0.05, e - s)
        var cursor = 0
        var tokens = draft.tokens
        for tokenIndex in tokens.indices {
            let tokenUnits = JapaneseReadingService.alignmentUnits(for: tokens[tokenIndex])
            guard !tokenUnits.isEmpty else {
                tokens[tokenIndex].morae = []
                continue
            }
            var morae: [MoraTiming] = []
            for unit in tokenUnits {
                let a = Double(cursor) / Double(max(1, units.count))
                let b = Double(cursor + 1) / Double(max(1, units.count))
                var unitStart = s + span * a
                var unitEnd = s + span * b
                if let fineTiming,
                   cursor < fineTiming.0.count,
                   let asrStart = fineTiming.0[cursor],
                   let asrEnd = fineTiming.1[cursor],
                   asrEnd > asrStart {
                    unitStart = max(s, min(e - 0.02, asrStart))
                    unitEnd = max(unitStart + 0.02, min(e, asrEnd))
                }
                morae.append(MoraTiming(mora: unit,
                                        start: unitStart,
                                        end: unitEnd,
                                        confidence: confidence))
                cursor += 1
            }
            tokens[tokenIndex].morae = morae
        }
        return AlignedLyricLine(id: draft.id,
                                order: draft.order,
                                singStart: s,
                                singEnd: e,
                                confidence: confidence,
                                tokens: tokens,
                                reasons: reasons,
                                method: .screenTimedOCR,
                                evidence: evidence)
    }

    private func fineTiming(for _: Int,
                            match: LyricASRMatch.LineMatch?,
                            start: Double,
                            end: Double,
                            unitCount: Int) -> ([Double?], [Double?])? {
        guard let match,
              match.hasDirectEvidence,
              match.charTimes.count == unitCount,
              match.charEnds.count == unitCount else { return nil }
        let valid = zip(match.charTimes, match.charEnds).filter { pair in
            let (s, e) = pair
            guard let s, let e else { return false }
            return e > s && e >= start - 0.35 && s <= end + 0.35
        }
        guard valid.count >= max(2, unitCount / 2) else { return nil }
        return (match.charTimes, match.charEnds)
    }

    private func scan(mediaURL: URL,
                      expected: [String],
                      progress: AlignProgressHandler?) async throws -> [Observation] {
        let asset = AVURLAsset(url: mediaURL)
        let duration = try await asset.load(.duration)
        let seconds = max(0, CMTimeGetSeconds(duration))
        guard seconds.isFinite, seconds > 0 else {
            throw AlignError.decode("无法读取视频时长")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let step = 1.0 / max(0.5, config.sampleRate)
        var frames: [(text: String, key: String, time: Double, score: Double)] = []
        var time = 0.0
        while time < seconds {
            try Task.checkCancellation()
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: cmTime, actualTime: nil),
               let crop = cropBottom(of: image) {
                let texts = recognize(crop)
                if let best = texts.compactMap({ candidate -> (String, String, Double)? in
                    let key = JapaneseNormalizer.normalizeForMatching(candidate)
                    guard key.count >= 2 else { return nil }
                    let score = expected.map { similarity(key, $0) }.max() ?? 0
                    guard score >= config.frameSimilarityThreshold else { return nil }
                    return (candidate, key, score)
                }).max(by: { $0.2 < $1.2 }) {
                    frames.append((best.0, best.1, time, best.2))
                }
            }
            if Int(time / step) % 8 == 0 {
                progress?(AlignProgress(fraction: 0.06 + min(0.62, time / seconds * 0.62),
                                        message: "正在读取画面歌词 (Int(time))/(Int(seconds)) 秒…"))
            }
            time += step
        }

        var observations: [Observation] = []
        for frame in frames {
            guard let last = observations.last else {
                observations.append(Observation(text: frame.text, key: frame.key,
                                                start: frame.time, end: frame.time + step,
                                                similarity: frame.score, frameCount: 1))
                continue
            }
            if frame.time - last.end <= step * 1.6,
               similarity(last.key, frame.key) >= config.mergeSimilarityThreshold {
                let newCount = last.frameCount + 1
                observations[observations.count - 1].end = frame.time + step
                observations[observations.count - 1].similarity =
                    (last.similarity * Double(last.frameCount) + frame.score) / Double(newCount)
                observations[observations.count - 1].frameCount = newCount
                if frame.score > last.similarity {
                    observations[observations.count - 1].text = frame.text
                    observations[observations.count - 1].key = frame.key
                }
            } else {
                observations.append(Observation(text: frame.text, key: frame.key,
                                                start: frame.time, end: frame.time + step,
                                                similarity: frame.score, frameCount: 1))
            }
        }
        return observations
    }

    private func cropBottom(of image: CGImage) -> CGImage? {
        let height = CGFloat(image.height)
        let top = min(0.92, max(0.50, config.cropTopFraction))
        // CGImage 的坐标原点在左上角语义上更符合视频画面；取最底部区域时
        // 必须从 `top` 对应的 y 开始，不能误取片头/水印区域。
        let rect = CGRect(x: 0, y: height * top,
                          width: CGFloat(image.width), height: height * (1 - top))
        return image.cropping(to: rect)
    }

    private func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ja-JP", "zh-Hans"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func assign(observations: [Observation],
                        expected: [String]) -> [Assignment?] {
        guard !observations.isEmpty else { return Array(repeating: nil, count: expected.count) }
        var out = Array<Assignment?>(repeating: nil, count: expected.count)
        var observationIndex = 0
        var lineIndex = 0
        while lineIndex < expected.count, observationIndex < observations.count {
            var current = observations[observationIndex]
            var score = similarity(current.key, expected[lineIndex])

            // OCR 在歌词切换处偶尔会把上一句的残影延长数秒。若后面存在
            // 明显更强的同序候选，优先跳到最强候选，避免把下一句错误吸附到残影。
            if observationIndex + 1 < observations.count,
               let best = (observationIndex + 1..<observations.count)
                    .map({ ($0, similarity(observations[$0].key, expected[lineIndex])) })
                    .max(by: { $0.1 < $1.1 }),
               best.1 > score + 0.15,
               best.1 >= 0.55 {
                observationIndex = best.0
                current = observations[observationIndex]
                score = best.1
            }

            // 过滤掉水印/切换残影：若下一段明显更像当前歌词，跳过当前段。
            while score < 0.55, observationIndex + 1 < observations.count {
                let upper = min(observations.count, observationIndex + 12)
                guard let better = (observationIndex + 1..<upper).first(where: {
                    similarity(observations[$0].key, expected[lineIndex]) >= 0.55
                }) else { break }
                observationIndex = better
                current = observations[observationIndex]
                score = similarity(observations[observationIndex].key, expected[lineIndex])
            }
            guard score >= 0.55 else {
                lineIndex += 1
                continue
            }

            // 连续两句文字相同（副歌常见）时，单个 OCR 连续区间按句数切开；
            // 这比把两句合成一个大块更符合字幕过渡，也避免时间线只显示半句。
            if lineIndex + 1 < expected.count,
               expected[lineIndex] == expected[lineIndex + 1] {
                var endIndex = observationIndex
                while endIndex + 1 < observations.count,
                      observations[endIndex + 1].start - observations[endIndex].end <= 1.0,
                      similarity(observations[endIndex + 1].key, expected[lineIndex]) >= 0.45 {
                    endIndex += 1
                }
                if endIndex > observationIndex || current.end - current.start >= 1.0 {
                    let combined = Observation(
                        text: current.text,
                        key: current.key,
                        start: current.start,
                        end: observations[endIndex].end,
                        similarity: observations[observationIndex...endIndex]
                            .map(\.similarity).reduce(0, +)
                            / Double(endIndex - observationIndex + 1),
                        frameCount: observations[observationIndex...endIndex]
                            .map(\.frameCount).reduce(0, +))
                    out[lineIndex] = Assignment(observation: combined, similarity: score,
                                                splitIndex: 0, splitCount: 2)
                    out[lineIndex + 1] = Assignment(observation: combined,
                                                    similarity: score,
                                                    splitIndex: 1, splitCount: 2)
                    lineIndex += 2
                    observationIndex = endIndex + 1
                    continue
                }
            }

            var splitCount = 1
            if lineIndex + 1 < expected.count {
                let nextScore = similarity(current.key, expected[lineIndex + 1])
                if nextScore >= 0.82, current.end - current.start >= 1.0 {
                    splitCount = 2
                }
            }
            if splitCount == 2 {
                out[lineIndex] = Assignment(observation: current, similarity: score,
                                            splitIndex: 0, splitCount: 2)
                out[lineIndex + 1] = Assignment(observation: current,
                                                similarity: similarity(current.key, expected[lineIndex + 1]),
                                                splitIndex: 1, splitCount: 2)
                lineIndex += 2
            } else {
                out[lineIndex] = Assignment(observation: current, similarity: score,
                                            splitIndex: 0, splitCount: 1)
                lineIndex += 1
            }
            observationIndex += 1
        }
        return out
    }

    /// 归一化编辑距离相似度（0...1）。
    ///
    /// 一边为空时必须在这里直接返回：下面的 `1...a.count` 在空串时是 `1...0`，
    /// Swift 会以 "Range requires lowerBound <= upperBound" 直接崩溃整个 app。
    /// 视频某一帧 OCR 没读到字（或期望歌词为空）是很常见的情况，不能是崩溃。
    func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        let a = Array(lhs), b = Array(rhs)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i]
            for j in 1...b.count {
                next.append(min(row[j] + 1,
                                next[j - 1] + 1,
                                row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            row = next
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count, 1))
    }
}

/// 质量优先的一键对轨：画面有歌词时先用屏幕时间，普通视频自动回退 ASR。
@available(macOS 14.0, *)
public struct QualityFirstAligner: MediaAudioSourceAwareLyricAligning {
    private let screen: ScreenLyricAligner
    private let fallback: any LyricAligning

    public init(screen: ScreenLyricAligner = ScreenLyricAligner(),
                fallback: any LyricAligning) {
        self.screen = screen
        self.fallback = fallback
    }

    public var name: String { "QualityFirstAligner（画面歌词优先 + ASR 兜底）" }
    public var isProductionReady: Bool { true }
    public var method: AlignmentMethod { .qualityFirst }

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
        do {
            return try await screen.align(audioURL: mediaURL, lines: lines, progress: progress)
        } catch {
            let usesSeparatedVoice = recognitionAudioURL.standardizedFileURL != mediaURL.standardizedFileURL
            progress?(AlignProgress(fraction: 0.70,
                                    message: usesSeparatedVoice
                                        ? "画面歌词覆盖不足，改用分离人声进行本地对轨…"
                                        : "画面歌词覆盖不足，切换本地 ASR 对轨…"))
            if let sourceAware = fallback as? any MediaAudioSourceAwareLyricAligning {
                return try await sourceAware.align(mediaURL: mediaURL,
                                                   recognitionAudioURL: recognitionAudioURL,
                                                   lines: lines,
                                                   progress: progress)
            }
            return try await fallback.align(audioURL: mediaURL, lines: lines, progress: progress)
        }
    }
}
