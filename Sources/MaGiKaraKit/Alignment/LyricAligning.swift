import Foundation

/// 交给对齐器的歌词草稿：文字与读音已确定，但还没有任何时间。
public struct LyricLineDraft: Sendable, Identifiable {
    public var id: UUID
    public var order: Int
    public var text: String
    /// 已带 reading、尚无 timing 的 token。
    public var tokens: [LyricToken]

    public init(id: UUID = UUID(), order: Int, text: String, tokens: [LyricToken]) {
        self.id = id
        self.order = order
        self.text = text
        self.tokens = tokens
    }

    /// 该句参与对齐的音拍总数。
    public var unitCount: Int {
        tokens.reduce(0) { $0 + JapaneseReadingService.alignmentUnits(for: $1).count }
    }

    public var moraCount: Int { unitCount }
}

/// 对齐结果：仍然是 token 结构，但 morae 已经带上时间与置信度。
public struct AlignedLyricLine: Sendable {
    public var id: UUID
    /// When an aligner expands a repeated phrase, identifies the original lyric
    /// row from which this additional row was derived. Nil for ordinary rows.
    public var sourceLineID: UUID?
    public var order: Int
    public var singStart: Double
    public var singEnd: Double
    public var confidence: Double
    public var tokens: [LyricToken]
    /// 低置信度原因（RD §16.5）。
    public var reasons: [String]
    /// 这条时间是怎么来的 —— 必须随结果保存并在 UI 显示。
    public var method: AlignmentMethod
    /// 这一句具体依据什么证据。
    public var evidence: AlignmentEvidence

    public init(id: UUID,
                sourceLineID: UUID? = nil,
                order: Int,
                singStart: Double,
                singEnd: Double,
                confidence: Double,
                tokens: [LyricToken],
                reasons: [String] = [],
                method: AlignmentMethod = .legacyEnergy,
                evidence: AlignmentEvidence = .durationPrior) {
        self.id = id
        self.sourceLineID = sourceLineID
        self.order = order
        self.singStart = singStart
        self.singEnd = singEnd
        self.confidence = confidence
        self.tokens = tokens
        self.reasons = reasons
        self.method = method
        self.evidence = evidence
    }
}

public struct AlignProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public typealias AlignProgressHandler = @Sendable (AlignProgress) -> Void

public enum AlignError: LocalizedError {
    case cancelled
    case noLyrics
    case noVoiceDetected
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "分析已取消"
        case .noLyrics: return "没有可分析的歌词"
        case .noVoiceDetected: return "音频里没有检测到人声，无法自动对轨"
        case .decode(let m): return "音频读取失败：\(m)"
        }
    }
}

/// 可替换的对齐服务（RD §8.4）。
///
/// - `LocalLyricAligner` 是产品默认路径（真实本地分析）。
/// - `MockLyricAligner` 只用于 UI 单元测试，不得作为产品默认路径。
public protocol LyricAligning: Sendable {
    var name: String { get }
    /// 该方法属于哪一类（音频自动对轨 / 画面字幕 / 旧方案 / Mock）
    var method: AlignmentMethod { get }
    /// 是否是可用于产品路径的真实实现。
    var isProductionReady: Bool { get }

    func align(audioURL: URL,
               lines: [LyricLineDraft],
               progress: AlignProgressHandler?) async throws -> [AlignedLyricLine]
}

/// 让“画面来源”和“用于识别的音频来源”分开传递。
///
/// 视频帧/OCR 仍读取原始媒体；若工程里已有有效的人声分离轨，ASR 后端可单独使用该轨。
public protocol MediaAudioSourceAwareLyricAligning: LyricAligning {
    func align(mediaURL: URL,
               recognitionAudioURL: URL,
               lines: [LyricLineDraft],
               progress: AlignProgressHandler?) async throws -> [AlignedLyricLine]
}

public extension LyricAligning {
    var method: AlignmentMethod { .legacyEnergy }

    func align(audioURL: URL, lines: [LyricLineDraft]) async throws -> [AlignedLyricLine] {
        try await align(audioURL: audioURL, lines: lines, progress: nil)
    }
}
