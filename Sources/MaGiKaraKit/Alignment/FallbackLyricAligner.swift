import Foundation

/// 主对齐器失败时自动改用备用对齐器。
///
/// 用于「Yohane 日语歌唱对齐优先，ASR 兜底」：Yohane 没装好、人声分离失败或 sidecar 出错时，
/// 用户不需要手动换方案。取消（`CancellationError`）不算失败，会原样抛出，
/// 否则用户点了取消还会白白再跑一遍备用方案。
public struct FallbackLyricAligner: MediaAudioSourceAwareLyricAligning {
    private let primary: any LyricAligning
    private let fallback: any LyricAligning
    private let fallbackMessage: String

    public init(primary: any LyricAligning,
                fallback: any LyricAligning,
                fallbackMessage: String = "歌唱对齐未能完成，改用 ASR 对轨…") {
        self.primary = primary
        self.fallback = fallback
        self.fallbackMessage = fallbackMessage
    }

    public var name: String { "\(primary.name) → 失败回退 \(fallback.name)" }
    public var method: AlignmentMethod { primary.method }
    public var isProductionReady: Bool { fallback.isProductionReady }

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
            return try await run(primary, mediaURL: mediaURL, recognitionAudioURL: recognitionAudioURL,
                                 lines: lines, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            progress?(AlignProgress(fraction: 0.05, message: fallbackMessage))
            return try await run(fallback, mediaURL: mediaURL, recognitionAudioURL: recognitionAudioURL,
                                 lines: lines, progress: progress)
        }
    }

    private func run(_ aligner: any LyricAligning,
                     mediaURL: URL,
                     recognitionAudioURL: URL,
                     lines: [LyricLineDraft],
                     progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        if let sourceAware = aligner as? any MediaAudioSourceAwareLyricAligning {
            return try await sourceAware.align(mediaURL: mediaURL,
                                               recognitionAudioURL: recognitionAudioURL,
                                               lines: lines,
                                               progress: progress)
        }
        return try await aligner.align(audioURL: mediaURL, lines: lines, progress: progress)
    }
}
