import Foundation

/// 置信度分级（RD §8.5）。
public enum ConfidenceLevel: String, Codable, Sendable {
    case normal      // >= 0.85
    case warning     // 0.60 ..< 0.85
    case low         // < 0.60 或没有匹配

    public static func from(_ c: Double) -> ConfidenceLevel {
        if c >= 0.85 { return .normal }
        if c >= 0.60 { return .warning }
        return .low
    }

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "待确认"
        case .low: return "需检查"
        }
    }
}

/// 一次自动分析的指标摘要，随工程保存，方便回看。
public struct AnalysisSummary: Codable, Hashable, Sendable {
    public var alignerName: String
    public var analyzedAt: Date
    public var elapsedSeconds: Double
    public var totalLines: Int
    public var lowConfidenceCount: Int
    /// 分析时媒体的指纹（时长+字节数），用于判断是否换了媒体。
    public var mediaFingerprint: String?
    /// 低置信度原因汇总。
    public var notes: [String]
    /// 本次分析用的对轨方法（关键：区分「音频自动对轨」与「画面字幕时间」）。
    public var method: AlignmentMethod?
    /// 逐条证据类型统计，例如 asr-tokens: 30, interpolated: 5
    public var evidenceCounts: [String: Int]

    public init(alignerName: String,
                analyzedAt: Date = Date(),
                elapsedSeconds: Double,
                totalLines: Int,
                lowConfidenceCount: Int,
                mediaFingerprint: String? = nil,
                notes: [String] = [],
                method: AlignmentMethod? = nil,
                evidenceCounts: [String: Int] = [:]) {
        self.alignerName = alignerName
        self.analyzedAt = analyzedAt
        self.elapsedSeconds = elapsedSeconds
        self.totalLines = totalLines
        self.lowConfidenceCount = lowConfidenceCount
        self.mediaFingerprint = mediaFingerprint
        self.notes = notes
        self.method = method
        self.evidenceCounts = evidenceCounts
    }
}

/// 歌词的换行方式。
public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    /// 滚动：每一行等到同一行的下一句来了才被替换，上下两行的更替是错开的。
    case rolling
    /// 翻页：上下两行成对出现、一页唱完整页换掉（ニコカラ 的常见做法）。
    case pageFlip

    public var displayName: String {
        switch self {
        case .rolling: return "滚动（逐行替换）"
        case .pageFlip: return "翻页（上下行成对换页）"
        }
    }
}

/// 显示区自动生成策略（RD §4 自动显示区建议）。
public struct DisplayPolicy: Codable, Hashable, Sendable {
    /// displayStart 在 singStart 前多久进入。
    public var leadIn: Double
    /// 同槽位最后一句唱完后停留多久。
    public var lastHoldOut: Double
    /// 是否按上一句实际间隔收缩 lead-in。
    public var adaptToGap: Bool
    /// 换行方式。
    public var mode: DisplayMode
    /// 翻页模式：下行比上行晚出现、也晚消失多久（秒）。参考 ニコカラ 合集约 0.6–1.0。
    public var lowerLineDelay: Double
    /// 翻页模式：上一页消失到下一页出现之间的空白（秒）。参考约 0.4。
    public var pageGap: Double
    /// 翻页模式：一页唱完后至少再停留多久（秒）；下一页来得很紧时会自动缩短。
    public var pageHoldOut: Double

    public init(leadIn: Double = 0.5,
                lastHoldOut: Double = 1.2,
                adaptToGap: Bool = true,
                mode: DisplayMode = .rolling,
                lowerLineDelay: Double = 0,
                pageGap: Double = 0.4,
                pageHoldOut: Double = 0.5) {
        self.leadIn = leadIn
        self.lastHoldOut = lastHoldOut
        self.adaptToGap = adaptToGap
        self.mode = mode
        self.lowerLineDelay = lowerLineDelay
        self.pageGap = pageGap
        self.pageHoldOut = pageHoldOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayPolicy()
        leadIn = try c.decodeIfPresent(Double.self, forKey: .leadIn) ?? d.leadIn
        lastHoldOut = try c.decodeIfPresent(Double.self, forKey: .lastHoldOut) ?? d.lastHoldOut
        adaptToGap = try c.decodeIfPresent(Bool.self, forKey: .adaptToGap) ?? d.adaptToGap
        mode = try c.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? d.mode
        lowerLineDelay = try c.decodeIfPresent(Double.self, forKey: .lowerLineDelay) ?? d.lowerLineDelay
        pageGap = try c.decodeIfPresent(Double.self, forKey: .pageGap) ?? d.pageGap
        pageHoldOut = try c.decodeIfPresent(Double.self, forKey: .pageHoldOut) ?? d.pageHoldOut
    }

    public static let `default` = DisplayPolicy()
}

/// 根据演唱时间生成上下槽位的显示时间（RD §4）。
public enum DisplayScheduler {

    /// 连续两句间隔不超过此时长时，保留已唱完的句子，直到同一屏幕槽位被后续歌词替换。
    /// 10 秒是本产品的体验阈值，不是行业硬性标准。
    public static let maximumHandoffGap: Double = 10.0

    /// 按 order 交替分配上下行。
    /// 用户手工指定过上下行的句子保持原样，不因为重新排布被改回去（RD §4.2）。
    public static func assignLanes(_ lines: inout [LyricLine]) {
        let sorted = lines.sorted { $0.order < $1.order }
        var laneByID: [UUID: ScreenLane] = [:]
        for line in sorted where !line.laneIsManual {
            laneByID[line.id] = ScreenLane.lane(forOrder: line.order)
        }
        for i in lines.indices {
            if let lane = laneByID[lines[i].id] { lines[i].lane = lane }
        }
    }

    /// 翻页模式：上下两行为一页，成对出现、成对消失。
    ///
    /// - 页开始（上行出现）：开唱前 `leadIn` 秒，但不早于上一页消失后的 `pageGap`；
    /// - 下行比上行晚 `lowerLineDelay` 秒出现，同样晚 `lowerLineDelay` 秒消失（出场和入场对称）；
    /// - 页结束（上行消失）：尽量晚，让下一页刚好能提前 `leadIn` 秒进场；
    ///   但至少停留到唱完（`pageHoldOut`，下一页很紧时自动缩短），最多停留 `lastHoldOut`；
    /// - 单行页（歌词行数是奇数、或用户手工改过上下行）按只有上行处理；
    /// - 用户手动指定的显示起止（`displayStartIsManual` / `displayEndIsManual`）原样保留。
    static func applyPageFlipWindows(to lines: inout [LyricLine], policy: DisplayPolicy) {
        let order = lines.indices.sorted {
            lines[$0].order != lines[$1].order
                ? lines[$0].order < lines[$1].order
                : lines[$0].singStart < lines[$1].singStart
        }
        var pages: [[Int]] = []
        var cursor = 0
        while cursor < order.count {
            let index = order[cursor]
            if lines[index].lane == .upper, cursor + 1 < order.count,
               lines[order[cursor + 1]].lane == .lower {
                pages.append([index, order[cursor + 1]])
                cursor += 2
            } else {
                pages.append([index])
                cursor += 1
            }
        }
        guard !pages.isEmpty else { return }

        let delay = max(0, policy.lowerLineDelay)
        var previousEnd: Double?
        for (pageIndex, page) in pages.enumerated() {
            let pageSingStart = lines[page[0]].singStart
            let pageSingEnd = page.map { lines[$0].singEnd }.max() ?? lines[page[0]].singEnd

            // 页开始
            var start = pageSingStart - policy.leadIn
            if let previousEnd { start = max(start, previousEnd + policy.pageGap) }
            start = min(max(0, start), pageSingStart)

            // 页结束
            var end: Double
            if pageIndex + 1 < pages.count {
                let nextStart = lines[pages[pageIndex + 1][0]].singStart
                let desired = nextStart - policy.leadIn - policy.pageGap
                let tightRoom = max(0, nextStart - policy.pageGap - pageSingEnd)
                let minEnd = pageSingEnd + min(policy.pageHoldOut, tightRoom)
                let maxEnd = pageSingEnd + max(policy.lastHoldOut, policy.pageHoldOut)
                end = min(max(desired, minEnd), maxEnd)
            } else {
                end = pageSingEnd + policy.lastHoldOut
            }

            for (position, index) in page.enumerated() {
                let offset = position == 1 ? delay : 0
                var displayStart = min(start + offset, lines[index].singStart)
                var displayEnd = max(end + offset, lines[index].singEnd)
                if lines[index].displayStartIsManual {
                    displayStart = min(lines[index].displayStart, lines[index].singStart)
                }
                if lines[index].displayEndIsManual {
                    displayEnd = lines[index].displayEnd
                }
                lines[index].displayStart = max(0, displayStart)
                lines[index].displayEnd = max(displayEnd, lines[index].singEnd)
                lines[index].enforceInvariants()
            }
            previousEnd = lines[page[0]].displayEnd
        }
    }

    /// 只有 singStart/singEnd 有效时，推导出 displayStart/displayEnd。
    public static func applyDisplayWindows(to lines: inout [LyricLine], policy: DisplayPolicy = .default) {
        assignLanes(&lines)
        if policy.mode == .pageFlip {
            applyPageFlipWindows(to: &lines, policy: policy)
            return
        }
        let chronologicalIndices = lines.indices.sorted {
            if lines[$0].order != lines[$1].order {
                return lines[$0].order < lines[$1].order
            }
            return lines[$0].singStart < lines[$1].singStart
        }
        let chronologicalPositions = Dictionary(uniqueKeysWithValues:
            chronologicalIndices.enumerated().map { ($0.element, $0.offset) })
        // 连续短间隔构成一个歌词段落。遇到 >10 秒的空档时，所有残留行都在
        // 空档前最后一句的尾留结束，避免更早的上/下行字幕孤零零留在画面上。
        var clusterEndIndex: [Int: Int] = [:]
        for (position, current) in chronologicalIndices.enumerated().reversed() {
            guard position + 1 < chronologicalIndices.count else {
                clusterEndIndex[current] = current
                continue
            }
            let next = chronologicalIndices[position + 1]
            let gap = lines[next].singStart - lines[current].singEnd
            clusterEndIndex[current] = gap <= Self.maximumHandoffGap
                ? (clusterEndIndex[next] ?? next)
                : current
        }

        for lane in ScreenLane.allCases {
            let idxs = lines.indices
                .filter { lines[$0].lane == lane }
                .sorted { lines[$0].order < lines[$1].order }
            guard !idxs.isEmpty else { continue }

            for (n, i) in idxs.enumerated() {
                let singStart = lines[i].singStart
                let singEnd = lines[i].singEnd

                // displayStart：默认 singStart 前 leadIn，受上一句同槽位内容约束。
                var lead = policy.leadIn
                if policy.adaptToGap, n > 0 {
                    let prevEnd = lines[idxs[n - 1]].singEnd
                    let gap = singStart - prevEnd
                    if gap > 0 {
                        // 间隔够用时遵守用户设定的提前量（默认 0.5 秒）；
                        // 只有间隔更短时才收缩，不能因空档更长而提前更多。
                        lead = min(policy.leadIn, max(0, gap * 0.5))
                    } else {
                        lead = 0.0
                    }
                }
                var displayStart = max(0, singStart - lead)

                if n > 0 {
                    let prevDisplayStart = lines[idxs[n - 1]].displayStart
                    // 同槽位片段不能重叠
                    displayStart = max(displayStart, prevDisplayStart + LyricLine.minimumSingDuration)
                    displayStart = min(displayStart, singStart)
                }

                // displayEnd：正常歌词间隔内，保持当前句直到它所在槽位被后续句替换；
                // 如果紧接着的下一句要等超过 10 秒，则只保留短尾留，避免字幕长时间悬空。
                var displayEnd: Double
                if n + 1 < idxs.count {
                    // 下一句的 displayStart 依赖它的 singStart，此处用同样公式先算一次
                    let nextIdx = idxs[n + 1]
                    let nextSingStart = lines[nextIdx].singStart
                    var nextLead = policy.leadIn
                    if policy.adaptToGap {
                        let gap = nextSingStart - singEnd
                        nextLead = gap > 0 ? min(policy.leadIn, max(0, gap * 0.5)) : 0.0
                    }
                    var nextDisplayStart = max(0, nextSingStart - nextLead)
                    nextDisplayStart = max(nextDisplayStart, displayStart + LyricLine.minimumSingDuration)
                    nextDisplayStart = min(nextDisplayStart, nextSingStart)
                    // 下一句的出现时间若是用户手动指定的，本句要保持到那个时刻，而不是自动算出的值
                    if lines[nextIdx].displayStartIsManual {
                        nextDisplayStart = min(lines[nextIdx].displayStart, nextSingStart)
                    }
                    let clusterEnd = clusterEndIndex[i] ?? i
                    let nextSameLanePosition = chronologicalPositions[nextIdx] ?? Int.max
                    let clusterEndPosition = chronologicalPositions[clusterEnd] ?? Int.min
                    if nextSameLanePosition <= clusterEndPosition {
                        displayEnd = nextDisplayStart
                    } else {
                        displayEnd = lines[clusterEnd].singEnd + policy.lastHoldOut
                    }
                } else {
                    let clusterEnd = clusterEndIndex[i] ?? i
                    displayEnd = lines[clusterEnd].singEnd + policy.lastHoldOut
                }

                // 用户手动指定的显示边界优先于自动计算（仍须包住演唱区）
                if lines[i].displayStartIsManual {
                    displayStart = min(lines[i].displayStart, singStart)
                }
                if lines[i].displayEndIsManual {
                    displayEnd = lines[i].displayEnd
                }
                lines[i].displayStart = displayStart
                lines[i].displayEnd = max(displayEnd, singEnd)
                lines[i].enforceInvariants()
            }
        }
    }
}

/// 工程文件（RD §5）。单个 JSON，扩展名 .magikara。
public struct KaraProject: Codable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "magikara"

    public var version: Int
    public var mediaURL: URL
    /// 安全书签，媒体被移动后可重新定位。
    public var mediaBookmark: Data?
    public var duration: Double
    public var title: String
    public var lyricLines: [LyricLine]
    public var style: SubtitleStyle
    /// 用户修正过的「表记 → 读音」项目词典（RD §6.1）。
    public var dictionary: [String: String]
    public var displayPolicy: DisplayPolicy
    public var analysis: AnalysisSummary?
    /// 轨道状态（显隐 / 锁定 / 静音），随工程保存。
    public var trackStates: TrackStateStore = TrackStateStore()
    /// 本地离线分离结果；旧工程缺少此字段时自动视为尚未分离。
    public var vocalSeparation: VocalSeparationAssets?
    /// 在线歌词只记录文本来源，不代表使用了来源时间戳对轨。
    public var lyricsSource: LyricsSourceInfo?
    /// 时间线「倒计时」轨道上的色块；开头那个由 `syncOpeningCountdown()` 自动生成并跟随第一句。
    public var countdowns: [CountdownItem] = []
    /// 用户删除或手动改过自动生成的开头倒计时后为 true：不再自动补回，避免把用户的操作悄悄覆盖。
    public var countdownAutoDismissed: Bool = false

    public init(version: Int = KaraProject.currentVersion,
                mediaURL: URL = URL(fileURLWithPath: "/"),
                mediaBookmark: Data? = nil,
                duration: Double = 0,
                title: String = "未命名工程",
                lyricLines: [LyricLine] = [],
                style: SubtitleStyle = .default,
                dictionary: [String: String] = [:],
                displayPolicy: DisplayPolicy = .default,
                analysis: AnalysisSummary? = nil,
                trackStates: TrackStateStore = TrackStateStore(),
                vocalSeparation: VocalSeparationAssets? = nil,
                lyricsSource: LyricsSourceInfo? = nil) {
        self.version = version
        self.mediaURL = mediaURL
        self.mediaBookmark = mediaBookmark
        self.duration = duration
        self.title = title
        self.lyricLines = lyricLines
        self.style = style
        self.dictionary = dictionary
        self.displayPolicy = displayPolicy
        self.analysis = analysis
        self.trackStates = trackStates
        self.vocalSeparation = vocalSeparation
        self.lyricsSource = lyricsSource
    }

    /// 手写了 init(from:) 与 encode(to:)，编译器不再自动合成 CodingKeys，需要显式声明。
    enum CodingKeys: String, CodingKey {
        case version, mediaURL, mediaBookmark, duration, title
        case lyricLines, style, dictionary, displayPolicy, analysis, trackStates, vocalSeparation, lyricsSource
        case countdowns, countdownAutoDismissed
    }

    /// 容错解析媒体路径。
    ///
    /// `URL` 直接 Codable 时，`"file:///a/b.mp4"` 会得到带 scheme 的 URL，
    /// 但手写或第三方生成的工程里常常只有一个裸路径 `"/a/b.mp4"`，
    /// 这样解出来的是没有 scheme 的相对 URL，AVFoundation 会直接报
    /// `unsupported URL`（实测踩过），所以这里统一规范成文件 URL。
    static func normalizeMediaURL(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(fileURLWithPath: "/") }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(fileURLWithPath: trimmed)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if let raw = try c.decodeIfPresent(String.self, forKey: .mediaURL) {
            mediaURL = Self.normalizeMediaURL(raw)
        } else {
            mediaURL = URL(fileURLWithPath: "/")
        }
        mediaBookmark = try c.decodeIfPresent(Data.self, forKey: .mediaBookmark)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名工程"
        lyricLines = try c.decodeIfPresent([LyricLine].self, forKey: .lyricLines) ?? []
        style = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? .legacyDefault
        dictionary = try c.decodeIfPresent([String: String].self, forKey: .dictionary) ?? [:]
        displayPolicy = try c.decodeIfPresent(DisplayPolicy.self, forKey: .displayPolicy) ?? .default
        analysis = try c.decodeIfPresent(AnalysisSummary.self, forKey: .analysis)
        trackStates = try c.decodeIfPresent(TrackStateStore.self, forKey: .trackStates) ?? TrackStateStore()
        vocalSeparation = try c.decodeIfPresent(VocalSeparationAssets.self, forKey: .vocalSeparation)
        lyricsSource = try c.decodeIfPresent(LyricsSourceInfo.self, forKey: .lyricsSource)
        countdowns = try c.decodeIfPresent([CountdownItem].self, forKey: .countdowns) ?? []
        countdownAutoDismissed = try c.decodeIfPresent(Bool.self, forKey: .countdownAutoDismissed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(mediaURL.absoluteString, forKey: .mediaURL)
        try c.encodeIfPresent(mediaBookmark, forKey: .mediaBookmark)
        try c.encode(duration, forKey: .duration)
        try c.encode(title, forKey: .title)
        try c.encode(lyricLines, forKey: .lyricLines)
        try c.encode(style, forKey: .style)
        try c.encode(dictionary, forKey: .dictionary)
        try c.encode(displayPolicy, forKey: .displayPolicy)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        try c.encode(trackStates, forKey: .trackStates)
        try c.encodeIfPresent(vocalSeparation, forKey: .vocalSeparation)
        try c.encodeIfPresent(lyricsSource, forKey: .lyricsSource)
        try c.encode(countdowns, forKey: .countdowns)
        try c.encode(countdownAutoDismissed, forKey: .countdownAutoDismissed)
    }

    // MARK: 倒计时

    /// 用户编辑倒计时的唯一入口（拖动、修剪、检查面板输入都走这里）。
    ///
    /// 用户一碰自动生成的开头倒计时，它就变成普通倒计时：不再被 `syncOpeningCountdown()` 改回、
    /// 也不会被补回。注意拖动期间每一帧传进来的都是「拖动开始时的快照」（那时它还是自动的），
    /// 所以不能只看工程里现有那一项——否则第二帧起会被快照改回自动，拖好的位置下次同步就丢了。
    public mutating func replaceCountdown(_ item: CountdownItem) {
        guard let index = countdowns.firstIndex(where: { $0.id == item.id }) else { return }
        var edited = item
        edited.start = max(0, edited.start)
        edited.end = max(edited.end, edited.start + CountdownItem.minimumDuration)
        if countdowns[index].isAuto || item.isAuto { countdownAutoDismissed = true }
        edited.isAuto = false
        countdowns[index] = edited
    }

    /// 保证开头有一个自动倒计时，并让它跟随第一句歌词。
    ///
    /// - 没有自动倒计时、且用户没删过/改过：按第一句补一个；
    /// - 已有自动倒计时：随第一句的出现时间重新对齐（重新对轨、修剪第一句后保持贴合）；
    /// - 第一句从 0 秒开始、没有空间放倒计时：移除自动那个。
    /// 用户手动建的、或改过的倒计时（`isAuto == false`）永远不会被动。
    public mutating func syncOpeningCountdown() {
        guard !lyricLines.isEmpty else { return }
        let auto = KaraokeCountdown.autoItem(for: self)
        if let index = countdowns.firstIndex(where: \.isAuto) {
            if let auto {
                countdowns[index].start = auto.start
                countdowns[index].end = auto.end
            } else {
                countdowns.remove(at: index)
            }
        } else if !countdownAutoDismissed, let auto {
            countdowns.append(auto)
        }
        countdowns.sort { $0.start < $1.start }
    }

    // MARK: 便利访问

    public var sortedLines: [LyricLine] { lyricLines.sorted { $0.order < $1.order } }

    public func lines(in lane: ScreenLane) -> [LyricLine] {
        sortedLines.filter { $0.lane == lane }
    }

    public var linesNeedingReview: [LyricLine] {
        sortedLines.filter { $0.needsReview }
    }

    public var confidenceLevel: ConfidenceLevel { ConfidenceLevel.from(averageConfidence) }

    public var averageConfidence: Double {
        guard !lyricLines.isEmpty else { return 0 }
        return lyricLines.reduce(0) { $0 + $1.confidence } / Double(lyricLines.count)
    }

    /// 当前时刻某个槽位应该显示哪一句（RD §4：当前句 + 下一句，唱完不立刻消失）。
    public func activeLine(in lane: ScreenLane, at t: Double) -> LyricLine? {
        let candidates = lines(in: lane)
        // 优先取正在显示的最后一句
        return candidates.last { $0.displayStart <= t && t < $0.displayEnd }
    }

    /// 当前正在扫色的句子。
    public func singingLine(at t: Double) -> LyricLine? {
        sortedLines.first { $0.isSinging(at: t) }
    }

    /// 供预览使用的上下两行。
    public func previewLines(at t: Double) -> (upper: LyricLine?, lower: LyricLine?) {
        (activeLine(in: .upper, at: t), activeLine(in: .lower, at: t))
    }

    /// 全部歌词整体平移（四个时间与所有音拍一起动），用于修正对轨的系统性偏早 / 偏晚。
    /// 最早的显示起点不会被推到 0 秒之前；返回实际平移量。
    @discardableResult
    public mutating func shiftAllLines(by delta: Double) -> Double {
        guard let earliest = lyricLines.map(\.displayStart).min() else { return 0 }
        let d = max(delta, -earliest)
        guard abs(d) > 1e-9 else { return 0 }
        for i in lyricLines.indices {
            lyricLines[i].shift(by: d)
            lyricLines[i].enforceInvariants()
        }
        syncOpeningCountdown()
        return d
    }

    public mutating func enforceAllInvariants() {
        for i in lyricLines.indices {
            lyricLines[i].enforceInvariants()
        }
    }

    /// 重新编号 order 并刷新 lane（用户手工指定的 lane 保留）。
    public mutating func renumber() {
        lyricLines.sort { $0.order < $1.order }
        for i in lyricLines.indices {
            lyricLines[i].order = i + 1
            if !lyricLines[i].laneIsManual {
                lyricLines[i].lane = ScreenLane.lane(forOrder: i + 1)
            }
        }
    }

    /// 某句是否因所在轨道被锁定而不可编辑。
    public func isEditable(_ line: LyricLine) -> Bool {
        !trackStates.isLocked(line: line)
    }

    /// 是否已经导入过媒体。
    public var hasMedia: Bool {
        let p = mediaURL.path
        return !p.isEmpty && p != "/"
    }

    public var mediaExists: Bool {
        guard hasMedia else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: mediaURL.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// 媒体指纹，用于判断工程里的分析结果是否还对应同一个媒体。
    public func mediaFingerprint() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: mediaURL.path),
              let size = attrs[.size] as? Int else { return nil }
        return "\(mediaURL.lastPathComponent)|\(size)|\(String(format: "%.2f", duration))"
    }
}
