import Foundation

/// 对齐引擎的选择入口。
///
/// 产品默认路径：**ASR 强制对齐**（macOS 26+ 的系统语音识别）。
/// 更老的系统上不静默降级成假精确时间，而是明确报告不可用，
/// 并退回旧的能量对齐（旧方案在真实歌曲上精度很差，因此结果会被标成低置信度）。
public enum AlignmentEngineFactory {

    public enum Backend: String, Equatable, Sendable {
        case systemSpeech
        /// 只用 Yohane，不回退（A/B 测试用）。
        case yohaneKaraokeCTC
        /// Yohane 日语歌唱对齐优先；未安装或运行失败时回退到系统 ASR。产品默认路径。
        case preferYohane
    }

    public struct Selection: Sendable {
        public var aligner: LyricAligning
        public var availability: ASRAvailability
        /// 给人看的说明，UI/CLI 直接显示
        public var detail: String

        public init(aligner: LyricAligning, availability: ASRAvailability, detail: String) {
            self.aligner = aligner
            self.availability = availability
            self.detail = detail
        }
    }

    public static func currentAvailability() async -> ASRAvailability {
        await ASRCapability.availability()
    }

    /// 列出所有可用的对轨能力（供 UI 展示「当前用的是哪一种」）。
    public static func providers() async -> [AlignmentProviderInfo] {
        let availability = await ASRCapability.availability()
        var list: [AlignmentProviderInfo] = []
        list.append(AlignmentProviderInfo(
            method: .qualityFirst,
            isAvailable: true,
            detail: "画面已有歌词时优先读取可见时间；普通视频自动回退 ASR"))
        list.append(AlignmentProviderInfo(
            method: .asrForcedAlign,
            isAvailable: availability == .ready,
            detail: availability.displayName))
        list.append(AlignmentProviderInfo(
            method: .yohaneForcedAlign,
            isAvailable: LocalYohaneForcedAligner.isInstalled,
            detail: LocalYohaneForcedAligner.availabilityDescription))
        list.append(AlignmentProviderInfo(
            method: .screenTimedOCR,
            isAvailable: true,
            detail: "画面里已有硬字幕时，可用 OCR 时间直接生成（不是音频自动对轨）"))
        list.append(AlignmentProviderInfo(
            method: .legacyEnergy,
            isAvailable: true,
            detail: "旧的能量/谱通量方案。真实歌曲实测句首平均误差 5.1 秒，仅作降级"))
        return list
    }

    /// A/B 开关（用于对比各优化项效果）。
    ///
    /// `Tuning()` 的成员默认值仍是**高质量实验基线**（多假设 + 3 次重复），
    /// 供 Phase 0 / 实验显式传入；产品默认路径改用 `Tuning.fast`，
    /// 由 `makeDefault(allowLegacyFallback:)` 使用。
    public struct Tuning: Sendable {
        /// 是否做多假设音频前端比较（原始 / 中置提取 / 频带强调 / 放慢）
        public var multiHypothesis: Bool = true
        /// 一键工作流自动使用本地 AI 人声分离，避免要求用户先单独操作。
        public var automaticallySeparateVocals: Bool = true
        /// 是否做第二轮局部重对齐
        public var localRealign: Bool = true
        /// 每个（入围）假设重复识别的次数
        public var hypothesisRepeats: Int = 3
        /// 是否把句首吸附到真实声学乐句起点
        public var onsetSnap: Bool = false
        /// 是否按人声段起点向后修正 ASR 句首（用于实歌 A/B）
        public var forwardOnsetCorrection: Bool = true
        /// 歌词与识别文本用假名读音匹配；显示和导出始终保留原始歌词。
        public var phoneticReadings: Bool = true
        /// Select the optional local singing-specific CTC backend. Kept off until
        /// held-out real-song accuracy is demonstrated; the normal app path is unchanged.
        public var backend: Backend = .systemSpeech
        /// A/B switch: bypass on-screen lyric OCR so audio-only backends can be compared fairly.
        public var preferScreenOCR: Bool = true
        public init() {}

        /// 产品默认快速路径：**只跑一次 ASR**（不做多假设、不重复识别），
        /// 保留局部重对齐，不做起点吸附。
        public static let fast: Tuning = {
            var tuning = Tuning()
            tuning.multiHypothesis = false
            tuning.hypothesisRepeats = 1
            tuning.localRealign = true
            tuning.onsetSnap = false
            tuning.forwardOnsetCorrection = true
            return tuning
        }()

        /// Phase 0 / 实验高质量基线：多假设 + 3 次重复 + 局部重对齐（等同 `Tuning()`）。
        public static let highQuality: Tuning = Tuning()

        /// Experimental, audio-only Yohane path for local A/B measurements.
        public static let yohaneAudioExperiment: Tuning = {
            var tuning = Tuning.fast
            tuning.backend = .yohaneKaraokeCTC
            tuning.preferScreenOCR = false
            return tuning
        }()
    }

    /// 产品默认引擎（快速路径）。返回选择结果，调用方应把 detail 显示出来。
    ///
    /// 使用 `Tuning.fast`：一次 ASR（`multiHypothesis = false`、
    /// `hypothesisRepeats = 1`），保留 `localRealign`、不做起点吸附。
    public static func makeDefault(allowLegacyFallback: Bool = true) async -> Selection {
        var tuning = Tuning.fast
        // MAGIKARA_ALIGNMENT_BACKEND：yohane = 只用 Yohane；asr = 只用系统 ASR；缺省 = Yohane 优先 + ASR 兜底。
        switch ProcessInfo.processInfo.environment["MAGIKARA_ALIGNMENT_BACKEND"] {
        case "yohane": tuning.backend = .yohaneKaraokeCTC
        case "asr": break
        default:
            if LocalYohaneForcedAligner.isInstalled { tuning.backend = .preferYohane }
        }
        return await makeDefault(allowLegacyFallback: allowLegacyFallback, tuning: tuning)
    }

    /// 显式指定 A/B 配置的引擎，行为与历史版本一致。
    ///
    /// Phase 0 / 实验传 `Tuning.highQuality`（或显式 `Tuning()`）复现高质量基线。
    public static func makeDefault(allowLegacyFallback: Bool = true,
                                   tuning: Tuning) async -> Selection {
        let availability = await ASRCapability.availability()
        let systemAligner: any LyricAligning
        if #available(macOS 26.0, *) {
            var cfg = ASRForcedAligner.Config()
            cfg.useMultiHypothesis = tuning.multiHypothesis
            cfg.automaticallySeparateVocals = tuning.automaticallySeparateVocals
            cfg.useLocalRealign = tuning.localRealign
            cfg.hypothesisRepeats = tuning.hypothesisRepeats
            cfg.useOnsetSnap = tuning.onsetSnap
            cfg.useForwardOnsetCorrection = tuning.forwardOnsetCorrection
            cfg.matcher.usePhoneticReadings = tuning.phoneticReadings
            systemAligner = ASRForcedAligner(config: cfg)
        } else {
            systemAligner = LocalLyricAligner()
        }
        let audioAligner: any LyricAligning
        switch tuning.backend {
        case .yohaneKaraokeCTC:
            audioAligner = LocalYohaneForcedAligner()
        case .preferYohane:
            audioAligner = FallbackLyricAligner(primary: LocalYohaneForcedAligner(),
                                                fallback: systemAligner)
        case .systemSpeech:
            audioAligner = systemAligner
        }

        // 质量优先：如果视频自身带日文硬字幕，先用画面时间把「字幕出现」做准；
        // OCR 覆盖不足时由同一个对象自动回到 ASR/旧方案，不增加用户选择成本。
        if #available(macOS 14.0, *), tuning.preferScreenOCR {
            let aligner = QualityFirstAligner(fallback: audioAligner)
            let modelNote: String
            switch availability {
            case .ready: modelNote = "ASR 已就绪"
            case .needsDownload: modelNote = "ASR 首次需要下载日语模型"
            default: modelNote = availability.displayName
            }
            let routeNote: String
            switch tuning.backend {
            case .yohaneKaraokeCTC:
                routeNote = "本机歌唱 CTC 模型\(LocalYohaneForcedAligner.isInstalled ? "已就绪" : "尚未就绪")；首次结果保持待确认"
            case .preferYohane:
                routeNote = "日语歌唱对齐优先，失败时回退 ASR（\(modelNote)）；结果保持待确认"
            case .systemSpeech:
                routeNote = "ASR \(modelNote)"
            }
            return Selection(aligner: aligner,
                             availability: availability,
                             detail: "使用 \(aligner.name)（\(routeNote)）")
        }

        if tuning.backend == .yohaneKaraokeCTC {
            let aligner = LocalYohaneForcedAligner()
            return Selection(aligner: aligner,
                             availability: availability,
                             detail: LocalYohaneForcedAligner.availabilityDescription)
        }
        if tuning.backend == .preferYohane {
            return Selection(aligner: audioAligner,
                             availability: availability,
                             detail: "日语歌唱对齐优先，失败时回退 ASR；结果保持待确认")
        }

        if allowLegacyFallback {
            return Selection(aligner: audioAligner,
                             availability: availability,
                             detail: "⚠️ \(availability.displayName)；已降级到旧的能量对齐，精度可能很差")
        }
        return Selection(aligner: audioAligner,
                         availability: availability,
                         detail: availability.displayName)
    }
}
