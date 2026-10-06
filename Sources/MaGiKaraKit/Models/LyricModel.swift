import Foundation

// MARK: - 屏幕槽位

/// 上下两条主轨代表两个屏幕显示槽位，而不是语言层。
public enum ScreenLane: String, Codable, CaseIterable, Sendable {
    case upper
    case lower

    public var displayName: String {
        switch self {
        case .upper: return "上行"
        case .lower: return "下行"
        }
    }

    /// 第 1 句 → 上行, 第 2 句 → 下行, 第 3 句 → 上行 ...
    public static func lane(forOrder order: Int) -> ScreenLane {
        order % 2 == 1 ? .upper : .lower
    }
}

// MARK: - 音拍

public struct MoraTiming: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 音拍文本，可能是「きゃ」这类拗音，也可能是带长音的「きー」。
    public var mora: String
    public var start: Double
    public var end: Double
    public var confidence: Double

    public init(id: UUID = UUID(), mora: String, start: Double, end: Double, confidence: Double = 0) {
        self.id = id
        self.mora = mora
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var duration: Double { end - start }

    /// 在进度 p（0...1）处的插值时间。
    public func time(atProgress p: Double) -> Double {
        start + (end - start) * max(0, min(1, p))
    }
}

// MARK: - Ruby 人工覆盖

/// 一段 Ruby 的人工覆盖。
///
/// 按 `token.surface` 内的**字符偏移**保存，而不是只存一整段读音字符串：
/// - 逐段可逆，删掉某个汉字的绑定时不会连带丢掉其它汉字；
/// - 汉字增删后只需清理越界/非汉字的段，不会退化成整词读音；
/// - 与旧字段 `LyricToken.reading` 共存，旧工程仍可正常解码。
public struct RubyOverride: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 覆盖区间在 `surface` 中的 Character 起点。
    public var surfaceStart: Int
    /// 覆盖的字符数（单字通常为 1；熟字訓可覆盖连续多字）。
    public var surfaceLength: Int
    /// 该区间对应的读音（平假名）。
    public var reading: String
    /// 写入时该区间对应的表记快照。
    /// 汉字被替换后用它判断绑定是否失效（旧工程为 nil 时退化为只校验区间）。
    public var surfaceText: String?

    public init(id: UUID = UUID(),
                surfaceStart: Int,
                surfaceLength: Int = 1,
                reading: String,
                surfaceText: String? = nil) {
        self.id = id
        self.surfaceStart = surfaceStart
        self.surfaceLength = max(1, surfaceLength)
        self.reading = reading
        self.surfaceText = surfaceText
    }
}

// MARK: - Token

/// 主歌词里的一个词。含汉字的词会带 reading 与 morae，用来画假名附轨 / Ruby。
public struct LyricToken: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 画面显示文字，例如「世界」。
    public var surface: String
    /// 读音（平假名），例如「せかい」；纯假名词为 nil。
    public var reading: String?
    public var morae: [MoraTiming]
    /// 在整句 displayText 中的字符起点与长度（RD 允许用 start/length 取代 Range<Int>）。
    public var sourceStart: Int
    public var sourceLength: Int
    /// 逐段人工 Ruby 覆盖；nil / 空表示完全使用自动对齐。
    /// 可选字段，旧工程缺失时自然为 nil。
    public var rubyOverrides: [RubyOverride]?

    public init(id: UUID = UUID(),
                surface: String,
                reading: String? = nil,
                morae: [MoraTiming] = [],
                sourceStart: Int = 0,
                sourceLength: Int = 0,
                rubyOverrides: [RubyOverride]? = nil) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.morae = morae
        self.sourceStart = sourceStart
        self.sourceLength = sourceLength
        self.rubyOverrides = rubyOverrides
    }

    /// 只有含汉字的词才需要 Ruby / 假名附轨（RD §5.1）。
    /// 存在人工绑定时，即使 `reading` 为空也仍然需要 Ruby。
    public var needsRuby: Bool {
        if !manualRubyOverrides().isEmpty { return true }
        guard let r = reading, !r.isEmpty else { return false }
        return JapaneseText.containsKanji(surface)
    }

    // MARK: Ruby 覆盖编辑

    /// 过滤掉越界或已不再是汉字的覆盖段，按起点排序。
    /// 汉字被删除/替换后，失效绑定不会残留（RD §6.3）。
    /// 注意：`reading` 为空的覆盖表示「显式删除/抑制该段自动注音」，会保留。
    public func sanitizedRubyOverrides() -> [RubyOverride] {
        guard let list = rubyOverrides, !list.isEmpty else { return [] }
        let chars = Array(surface)
        return list
            .filter { o in
                guard o.surfaceStart >= 0, o.surfaceLength > 0,
                      o.surfaceStart + o.surfaceLength <= chars.count else { return false }
                let slice = chars[o.surfaceStart..<(o.surfaceStart + o.surfaceLength)]
                guard slice.contains(where: { JapaneseText.isKanji($0) }) else { return false }
                // 表记快照不匹配（汉字被替换）→ 绑定失效，必须清理。
                if let expected = o.surfaceText, expected != String(slice) { return false }
                return true
            }
            .sorted { $0.surfaceStart < $1.surfaceStart }
    }

    /// 有实际读音的人工覆盖（不含删除标记）。
    public func manualRubyOverrides() -> [RubyOverride] {
        sanitizedRubyOverrides().filter { !$0.reading.isEmpty }
    }

    /// 被显式删除/抑制的自动注音段起点。
    public func suppressedRubyStarts() -> [Int] {
        sanitizedRubyOverrides().filter { $0.reading.isEmpty }.map(\.surfaceStart)
    }

    /// 写入/替换某段汉字的读音。
    /// - Parameter reading: 空字符串表示**删除该段绑定**（显式抑制自动注音，可再次编辑恢复）。
    public mutating func setRubyOverride(surfaceStart: Int,
                                         surfaceLength: Int = 1,
                                         reading: String) {
        let normalized = JapaneseText.normalizeReading(reading)
        let chars = Array(surface)
        let length = max(1, surfaceLength)
        let start = max(0, min(chars.count, surfaceStart))
        let end = max(start, min(chars.count, start + length))
        let snapshot = start < end ? String(chars[start..<end]) : nil
        var list = sanitizedRubyOverrides().filter { $0.surfaceStart != surfaceStart }
        list.append(RubyOverride(surfaceStart: surfaceStart,
                                 surfaceLength: length,
                                 reading: normalized,
                                 surfaceText: snapshot))
        list.sort { $0.surfaceStart < $1.surfaceStart }
        rubyOverrides = list
    }

    /// 删除该段的人工覆盖，回到自动对齐结果。
    public mutating func removeRubyOverride(surfaceStart: Int) {
        let list = sanitizedRubyOverrides().filter { $0.surfaceStart != surfaceStart }
        rubyOverrides = list.isEmpty ? nil : list
    }

    public var start: Double? { morae.first?.start }
    public var end: Double? { morae.last?.end }

    public var confidence: Double {
        guard !morae.isEmpty else { return 0 }
        return morae.reduce(0) { $0 + $1.confidence } / Double(morae.count)
    }

    /// 该 token 在句内的时间区间；没有 mora 时返回 nil，由上层按整句插值。
    public var timeRange: ClosedRange<Double>? {
        guard let s = start, let e = end, e >= s else { return nil }
        return s...e
    }

    /// 把 token 的所有音拍整体平移。
    public mutating func shiftMorae(by delta: Double) {
        for i in morae.indices {
            morae[i].start += delta
            morae[i].end += delta
        }
    }
}

// MARK: - 歌词句

public struct LyricLine: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var order: Int
    public var lane: ScreenLane
    /// 用户是否手工指定过上下行。一旦为 true，
    /// `renumber()` / `DisplayScheduler.assignLanes` 都不得按 order 把它改回去（RD §4.2）。
    public var laneIsManual: Bool
    /// 同层叠放顺序（用于 ASS 事件层与重叠时的显示优先级）。
    public var layer: Int
    public var displayText: String

    /// 字幕进入画面的时间
    public var displayStart: Double
    /// 开始扫色的时间
    public var singStart: Double
    /// 扫色结束的时间
    public var singEnd: Double
    /// 唱完继续停留后，退出画面的时间
    public var displayEnd: Double

    public var tokens: [LyricToken]
    public var confidence: Double
    public var needsReview: Bool
    /// 低置信度原因（RD §16.5 要求输出原因）。
    public var reviewReasons: [String]
    /// 单句样式覆盖（RD §10 全局样式与单句覆盖）。
    public var styleOverride: SubtitleStyleOverride?
    /// 这句的时间是怎么来的（随工程保存，UI 必须显示）。
    public var alignmentMethod: AlignmentMethod?
    /// 这句具体依据什么证据。
    public var alignmentEvidence: AlignmentEvidence?
    /// 是否被用户手动调整过（移动/修剪/分割/手改时间）。
    /// 一旦为 true，分析刷新**不得覆盖**它的时间 —— 否则用户的手工会被静默抹掉。
    public var isManuallyAdjusted: Bool = false
    /// 手动调整的简短说明，显示在检查面板里
    public var manualAdjustmentNote: String?
    /// 用户手动指定了「字幕出现」时间（拖动色块左边缘或在检查面板输入）。
    /// 为 true 时，自动排程（`DisplayScheduler.applyDisplayWindows`）保留这个值，
    /// 不再按「提前 0.5 秒」重新计算——否则用户拖好的结果松手就被覆盖回去。
    public var displayStartIsManual: Bool = false
    /// 用户手动指定了「字幕退出」时间。为 true 时自动排程不再把它延长到下一句出现。
    public var displayEndIsManual: Bool = false

    public init(id: UUID = UUID(),
                order: Int,
                lane: ScreenLane? = nil,
                laneIsManual: Bool = false,
                layer: Int = 0,
                displayText: String = "",
                displayStart: Double = 0,
                singStart: Double = 0,
                singEnd: Double = 0,
                displayEnd: Double = 0,
                tokens: [LyricToken] = [],
                confidence: Double = 0,
                needsReview: Bool = true,
                reviewReasons: [String] = ["尚未分析"],
                styleOverride: SubtitleStyleOverride? = nil,
                alignmentMethod: AlignmentMethod? = nil,
                alignmentEvidence: AlignmentEvidence? = nil,
                isManuallyAdjusted: Bool = false,
                manualAdjustmentNote: String? = nil) {
        self.id = id
        self.order = order
        self.lane = lane ?? ScreenLane.lane(forOrder: order)
        self.laneIsManual = laneIsManual
        self.layer = layer
        self.displayText = displayText
        self.displayStart = displayStart
        self.singStart = singStart
        self.singEnd = singEnd
        self.displayEnd = displayEnd
        self.tokens = tokens
        self.confidence = confidence
        self.needsReview = needsReview
        self.reviewReasons = reviewReasons
        self.styleOverride = styleOverride
        self.alignmentMethod = alignmentMethod
        self.alignmentEvidence = alignmentEvidence
        self.isManuallyAdjusted = isManuallyAdjusted
        self.manualAdjustmentNote = manualAdjustmentNote
    }

    // 容错解码：旧工程缺字段时不至于整份工程打不开。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        lane = try c.decodeIfPresent(ScreenLane.self, forKey: .lane) ?? ScreenLane.lane(forOrder: order)
        laneIsManual = try c.decodeIfPresent(Bool.self, forKey: .laneIsManual) ?? false
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        displayText = try c.decodeIfPresent(String.self, forKey: .displayText) ?? ""
        displayStart = try c.decodeIfPresent(Double.self, forKey: .displayStart) ?? 0
        singStart = try c.decodeIfPresent(Double.self, forKey: .singStart) ?? 0
        singEnd = try c.decodeIfPresent(Double.self, forKey: .singEnd) ?? 0
        displayEnd = try c.decodeIfPresent(Double.self, forKey: .displayEnd) ?? 0
        tokens = try c.decodeIfPresent([LyricToken].self, forKey: .tokens) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? true
        reviewReasons = try c.decodeIfPresent([String].self, forKey: .reviewReasons) ?? []
        styleOverride = try c.decodeIfPresent(SubtitleStyleOverride.self, forKey: .styleOverride)
        alignmentMethod = try c.decodeIfPresent(AlignmentMethod.self, forKey: .alignmentMethod)
        alignmentEvidence = try c.decodeIfPresent(AlignmentEvidence.self, forKey: .alignmentEvidence)
        isManuallyAdjusted = try c.decodeIfPresent(Bool.self, forKey: .isManuallyAdjusted) ?? false
        manualAdjustmentNote = try c.decodeIfPresent(String.self, forKey: .manualAdjustmentNote)
        displayStartIsManual = try c.decodeIfPresent(Bool.self, forKey: .displayStartIsManual) ?? false
        displayEndIsManual = try c.decodeIfPresent(Bool.self, forKey: .displayEndIsManual) ?? false
    }

    // MARK: 时间约束

    public static let minimumSingDuration: Double = 0.05

    /// 是否满足 displayStart <= singStart < singEnd <= displayEnd
    public var hasValidTiming: Bool {
        displayStart <= singStart + 1e-9
            && singStart < singEnd
            && singEnd <= displayEnd + 1e-9
    }

    public var singDuration: Double { max(0, singEnd - singStart) }
    public var displayDuration: Double { max(0, displayEnd - displayStart) }
    /// 扫色前的等待区
    public var leadIn: Double { max(0, singStart - displayStart) }
    /// 唱后停留区
    public var holdOut: Double { max(0, displayEnd - singEnd) }

    /// 强制满足四段时间顺序约束。
    /// 标记为手动调整过（拖动/修剪/分割/手改时间后调用）
    public mutating func markManuallyAdjusted(_ note: String) {
        isManuallyAdjusted = true
        manualAdjustmentNote = note
    }

    public mutating func enforceInvariants() {
        displayStart = max(0, displayStart)
        if singEnd <= singStart {
            singEnd = singStart + Self.minimumSingDuration
        }
        if displayStart > singStart { displayStart = singStart }
        if displayEnd < singEnd { displayEnd = singEnd }
    }

    public func normalized() -> LyricLine {
        var copy = self
        copy.enforceInvariants()
        return copy
    }

    // MARK: 编辑

    /// 拖动整个片段：四个时间值一起平移，所有音拍同步平移（RD §4 / §9.3）。
    public mutating func shift(by delta: Double) {
        displayStart += delta
        singStart += delta
        singEnd += delta
        displayEnd += delta
        for i in tokens.indices {
            tokens[i].shiftMorae(by: delta)
        }
    }

    /// 整体设置演唱区，保持显示区包住演唱区。
    public mutating func setSingRange(start: Double, end: Double) {
        singStart = start
        singEnd = max(start + Self.minimumSingDuration, end)
        enforceInvariants()
    }

    public var allMorae: [MoraTiming] { tokens.flatMap(\.morae) }

    /// 把全部音拍从一个时间区间线性映射到另一个区间。
    /// 用户调整演唱区时使用，保证「音拍时长之和 == 演唱时长」始终成立。
    public mutating func rescaleMorae(from old: ClosedRange<Double>, to new: ClosedRange<Double>) {
        let oldSpan = old.upperBound - old.lowerBound
        let newSpan = new.upperBound - new.lowerBound
        guard oldSpan > 1e-6, newSpan > 1e-6 else { return }
        for i in tokens.indices {
            for j in tokens[i].morae.indices {
                let a = (tokens[i].morae[j].start - old.lowerBound) / oldSpan
                let b = (tokens[i].morae[j].end - old.lowerBound) / oldSpan
                tokens[i].morae[j].start = new.lowerBound + a * newSpan
                tokens[i].morae[j].end = new.lowerBound + b * newSpan
            }
        }
    }

    /// 只平移某个 token 的全部音拍（「解除绑定编辑」时微调单个假名，RD §3.3）。
    public mutating func shiftTokenMorae(tokenID: UUID, by delta: Double) {
        guard let i = tokens.firstIndex(where: { $0.id == tokenID }) else { return }
        tokens[i].shiftMorae(by: delta)
    }

    /// 调整某个 token 的首/末音拍边界（拖动假名附轨边缘精调扫色，RD §9.1）。
    public mutating func setTokenBoundary(tokenID: UUID, isStart: Bool, time: Double) {
        guard let i = tokens.firstIndex(where: { $0.id == tokenID }) else { return }
        guard !tokens[i].morae.isEmpty else { return }
        if isStart {
            let limit = tokens[i].morae[0].end - 0.02
            tokens[i].morae[0].start = min(max(0, time), limit)
        } else {
            let lastIndex = tokens[i].morae.count - 1
            let limit = tokens[i].morae[lastIndex].start + 0.02
            tokens[i].morae[lastIndex].end = max(time, limit)
        }
    }

    public var moraCount: Int { tokens.reduce(0) { $0 + $1.morae.count } }

    /// 该句的全部 token 都带上 mora 时间。
    public var hasMoraTiming: Bool { !tokens.isEmpty && tokens.allSatisfy { !$0.morae.isEmpty } }

    /// 重新按 token 生成 displayText。
    public var recomputedDisplayText: String {
        tokens.map(\.surface).joined()
    }

    /// 不含空白的字符序列，用于排版宽度计算。
    public var rubyTokens: [LyricToken] { tokens.filter(\.needsRuby) }

    // MARK: 扫色进度

    /// 在时间 t 时，该句已唱的比例（0...1）。
    ///
    /// 本轮改为**整句匀速**：扫色边缘只受 singStart/singEnd 控制，
    /// 不受音拍长短影响（音拍只决定 token 的先后顺序，见 `SweepProgress`）。
    public func sweepProgress(at t: Double) -> Double {
        if t <= singStart { return 0 }
        if t >= singEnd { return 1 }
        return (t - singStart) / max(1e-6, singEnd - singStart)
    }

    public func isVisible(at t: Double) -> Bool {
        t >= displayStart && t < displayEnd
    }

    public func isSinging(at t: Double) -> Bool {
        t >= singStart && t < singEnd
    }
}
