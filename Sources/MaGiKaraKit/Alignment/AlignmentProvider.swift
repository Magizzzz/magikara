import Foundation

/// 对轨所用的方法。必须随结果一起保存并在 UI/报告里显示 ——
/// 用户有权知道这个时间是「音频自动对出来的」还是「从画面字幕抄来的」。
public enum AlignmentMethod: String, Codable, Sendable, CaseIterable {
    /// 画面歌词优先，普通视频自动回退到音频 ASR。
    case qualityFirst = "quality-first"
    /// 语音识别 + 顺序全局匹配 + 逐字时间（音频自动对轨，产品主路径）
    case asrForcedAlign = "asr-forced-align"
    /// 日语歌唱专用 wav2vec2 CTC 强制对齐（本机实验后端）
    case yohaneForcedAlign = "yohane-forced-align"
    /// 画面已有硬字幕的 OCR 时间（辅助入口，**不是**音频自动对轨）
    case screenTimedOCR = "ocr-screen-timed"
    /// 旧的「能量 + 谱通量 + 时长先验」对齐（仅作降级/局部修正，不再作为主对齐器）
    case legacyEnergy = "legacy-energy-fallback"
    /// 测试替身
    case mock = "mock"

    public var displayName: String {
        switch self {
        case .qualityFirst: return "画面歌词优先（ASR 兜底）"
        case .asrForcedAlign: return "ASR 歌词匹配（语音识别时间）"
        case .yohaneForcedAlign: return "Yohane 日语歌唱强制对齐（本机实验）"
        case .screenTimedOCR: return "画面字幕 OCR 时间（辅助入口）"
        case .legacyEnergy: return "能量/谱通量对齐（旧方案，降级用）"
        case .mock: return "Mock（仅 UI 测试）"
        }
    }

    /// 是否是「从音频自动对出来的」。OCR 画面时间明确为 false。
    public var isAudioAutomaticAlignment: Bool {
        switch self {
        case .qualityFirst: return true
        case .asrForcedAlign, .yohaneForcedAlign: return true
        case .screenTimedOCR, .legacyEnergy, .mock: return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .qualityFirst: return "质量优先对轨"
        case .asrForcedAlign: return "ASR 歌词匹配"
        case .yohaneForcedAlign: return "日语歌唱强制对齐"
        case .screenTimedOCR: return "OCR 字幕时间"
        case .legacyEnergy: return "旧能量对齐"
        case .mock: return "Mock"
        }
    }
}

/// 对齐时使用的证据类型 —— 用来解释置信度为什么高或低。
public enum AlignmentEvidence: String, Codable, Sendable {
    /// 有 ASR 逐字时间戳直接支撑
    case asrTokens = "asr-tokens"
    /// CTC 声学模型直接对齐已知歌词音素
    case ctcForcedAlignment = "ctc-forced-alignment"
    /// 无 ASR 证据，在前后有证据的行之间插值
    case interpolated = "interpolated"
    /// 画面字幕时间（辅助入口）
    case screenOCR = "screen-ocr"
    /// 仅由时长先验铺开（旧方案）
    case durationPrior = "duration-prior"

    public var displayName: String {
        switch self {
        case .asrTokens: return "ASR 逐字证据"
        case .ctcForcedAlignment: return "CTC 歌唱音素证据"
        case .interpolated: return "无证据·插值"
        case .screenOCR: return "画面字幕时间"
        case .durationPrior: return "仅时长先验"
        }
    }
}

/// 一种对轨能力的描述，供 UI 展示与选择。
public struct AlignmentProviderInfo: Sendable, Identifiable {
    public var id: AlignmentMethod { method }
    public var method: AlignmentMethod
    public var isAvailable: Bool
    public var detail: String

    public init(method: AlignmentMethod, isAvailable: Bool, detail: String) {
        self.method = method
        self.isAvailable = isAvailable
        self.detail = detail
    }
}
