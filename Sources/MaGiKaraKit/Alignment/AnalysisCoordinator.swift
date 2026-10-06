import Foundation

/// 把「粘贴的歌词」+「对齐器」串成工程状态。
/// App 与 Phase 0 无头运行共用这一段，保证两条路径跑的是同一套逻辑。
public enum AnalysisCoordinator {

    /// 一键生成的可理解阶段（RD §8.1）。
    public enum Stage: String, CaseIterable, Sendable {
        case preparing = "正在准备音频…"
        case reading = "正在识别日语歌词…"
        case syncing = "正在同步演唱位置…"
        case kana = "正在生成假名与扫色…"
        case checking = "正在检查成品…"
    }

    // MARK: 从歌词文本建立工程行

    /// 粘贴歌词 → 交替上下行的歌词句（RD §2 / §4）。
    public static func makeLines(from text: String,
                                 dictionary: [String: String] = [:],
                                 reader: JapaneseReadingService = JapaneseReadingService()) -> [LyricLine] {
        let texts = JapaneseReadingService.splitLyricLines(from: text)
        var lines: [LyricLine] = []
        for (i, lineText) in texts.enumerated() {
            let order = i + 1
            let tokens = reader.tokens(for: lineText, dictionary: dictionary)
            var line = LyricLine(order: order,
                                 lane: ScreenLane.lane(forOrder: order),
                                 displayText: lineText,
                                 tokens: tokens)
            line.confidence = 0
            line.needsReview = true
            line.reviewReasons = ["尚未分析"]
            lines.append(line)
        }
        return lines
    }

    /// 重新生成某一句的 token（用户改了歌词文字之后）。
    public static func refreshTokens(for line: inout LyricLine,
                                     dictionary: [String: String],
                                     reader: JapaneseReadingService = JapaneseReadingService()) {
        line.tokens = reader.tokens(for: line.displayText, dictionary: dictionary)
        line.confidence = 0
        line.needsReview = true
        line.reviewReasons = ["歌词已修改，需要重新对齐"]
    }

    // MARK: 一键分析

    public struct Outcome: Sendable {
        public var project: KaraProject
        public var summary: AnalysisSummary
    }

    /// 执行完整自动分析。失败时抛错，但调用方应保留原工程不破坏（RD §2）。
    public static func analyze(project: KaraProject,
                               aligner: LyricAligning,
                               reader: JapaneseReadingService = JapaneseReadingService(),
                               progress: AlignProgressHandler? = nil) async throws -> Outcome {
        let start = CFAbsoluteTimeGetCurrent()
        let lines = project.sortedLines

        // 构造草稿：保留用户可能已修正过的读音，只清空时间
        let drafts: [LyricLineDraft] = lines.map { line in
            var tokens = line.tokens
            if tokens.isEmpty {
                tokens = reader.tokens(for: line.displayText, dictionary: project.dictionary)
            } else {
                for i in tokens.indices { tokens[i].morae = [] }
            }
            return LyricLineDraft(id: line.id, order: line.order, text: line.displayText, tokens: tokens)
        }

        let recognitionAudioURL = Self.validVocalAudioURL(for: project) ?? project.mediaURL
        let aligned: [AlignedLyricLine]
        if let sourceAware = aligner as? any MediaAudioSourceAwareLyricAligning {
            aligned = try await sourceAware.align(mediaURL: project.mediaURL,
                                                  recognitionAudioURL: recognitionAudioURL,
                                                  lines: drafts,
                                                  progress: progress)
        } else {
            aligned = try await aligner.align(audioURL: project.mediaURL,
                                              lines: drafts,
                                              progress: progress)
        }

        var updated = Self.merge(aligned: aligned, into: project)

        // 由演唱时间推导显示时间（四段时间）
        DisplayScheduler.applyDisplayWindows(to: &updated.lyricLines, policy: updated.displayPolicy)
        updated.enforceAllInvariants()

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let reviewCount = updated.lyricLines.filter(\.needsReview).count
        var evidenceCounts: [String: Int] = [:]
        for line in updated.lyricLines {
            let key = (line.alignmentEvidence ?? .durationPrior).rawValue
            evidenceCounts[key, default: 0] += 1
        }

        let summary = AnalysisSummary(
            alignerName: aligner.name,
            analyzedAt: Date(),
            elapsedSeconds: elapsed,
            totalLines: updated.lyricLines.count,
            lowConfidenceCount: reviewCount,
            mediaFingerprint: updated.mediaFingerprint(),
            notes: updated.lyricLines.flatMap(\.reviewReasons).uniqued(),
            method: aligner.method,
            evidenceCounts: evidenceCounts)

        updated.analysis = summary
        return Outcome(project: updated, summary: summary)
    }

    /// 只复用仍属于当前媒体、两条 stem 都存在的分离结果；旧工程或失效缓存安全回退到原媒体。
    static func validVocalAudioURL(for project: KaraProject) -> URL? {
        guard let assets = project.vocalSeparation,
              assets.sourceFingerprint == project.mediaFingerprint(),
              FileManager.default.fileExists(atPath: assets.vocalURL.path),
              FileManager.default.fileExists(atPath: assets.instrumentalURL.path) else { return nil }
        return assets.vocalURL
    }
    /// 把对齐结果合并回工程（纯函数，便于单测）。
    ///
    /// **手动调整过时间的句子一律保留时间** —— 否则用户拖过、修剪过的时间
    /// 会被一次「AI 一键生成」静默抹掉。
    public static func merge(aligned: [AlignedLyricLine], into project: KaraProject) -> KaraProject {
        var byID: [UUID: AlignedLyricLine] = [:]
        for a in aligned { byID[a.id] = a }

        var updated = project
        var originalLinesByID: [UUID: LyricLine] = [:]
        for line in project.lyricLines { originalLinesByID[line.id] = line }
        for i in updated.lyricLines.indices {
            let line = updated.lyricLines[i]
            guard let a = byID[line.id] else {
                updated.lyricLines[i].needsReview = true
                updated.lyricLines[i].reviewReasons = ["该句没有对齐结果"]
                continue
            }
            if line.isManuallyAdjusted {
                updated.lyricLines[i].needsReview = true
                updated.lyricLines[i].reviewReasons = ["已手动调整时间，自动对轨不覆盖"]
                continue
            }
            updated.lyricLines[i].tokens = a.tokens
            updated.lyricLines[i].singStart = a.singStart
            updated.lyricLines[i].singEnd = a.singEnd
            updated.lyricLines[i].confidence = a.confidence
            updated.lyricLines[i].needsReview = ConfidenceLevel.from(a.confidence) != .normal
            updated.lyricLines[i].reviewReasons = a.reasons
            updated.lyricLines[i].alignmentMethod = a.method
            updated.lyricLines[i].alignmentEvidence = a.evidence
        }

        // Tail-repeat expansion returns additional aligned rows linked to the
        // source lyric. Materialize them as real project rows; otherwise the
        // alignment bridge succeeds but the timeline silently drops the copies.
        let lastOriginalLine = project.sortedLines.last
        var knownIDs = Set(updated.lyricLines.map(\.id))
        var knownOrders = Set(updated.lyricLines.map(\.order))
        for a in aligned.sorted(by: { $0.order < $1.order }) {
            guard !knownIDs.contains(a.id),
                  let sourceID = a.sourceLineID,
                  sourceID == lastOriginalLine?.id,
                  let source = originalLinesByID[sourceID],
                  a.order > (lastOriginalLine?.order ?? 0),
                  !knownOrders.contains(a.order) else { continue }

            var copy = source
            copy.id = a.id
            copy.order = a.order
            copy.lane = ScreenLane.lane(forOrder: a.order)
            copy.laneIsManual = false
            copy.displayStart = 0
            copy.singStart = a.singStart
            copy.singEnd = a.singEnd
            copy.displayEnd = 0
            copy.tokens = a.tokens
            copy.confidence = a.confidence
            copy.needsReview = ConfidenceLevel.from(a.confidence) != .normal
            copy.reviewReasons = a.reasons
            copy.alignmentMethod = a.method
            copy.alignmentEvidence = a.evidence
            copy.isManuallyAdjusted = false
            copy.manualAdjustmentNote = nil
            updated.lyricLines.append(copy)
            knownIDs.insert(copy.id)
            knownOrders.insert(copy.order)
        }
        updated.lyricLines.sort { $0.order < $1.order }
        return updated
    }

}

extension Array where Element: Hashable {
    /// 去重并保持原顺序。
    public func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
