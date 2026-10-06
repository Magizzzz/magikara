import Foundation

/// 时间轴歌词色块的呈现描述。
///
/// 本期核心约束：时间轴**只表达时间长度与上下行位置**，色块内不显示任何完整歌词文字
/// （RD §3.1、P0 验收 1/4）。这里把「是否显示歌词文字」收成模型层的显式字段，
/// 让视图与测试共用同一份规则，避免以后有人不小心把文字加回去。
public struct TimelineSegmentPresentation: Equatable, Sendable {
    /// 是否显示完整歌词文字 —— 恒为 false。
    public var showsLyricText: Bool
    /// 低干扰序号（可为 nil）。
    public var sequenceLabel: String?
    public var isSelected: Bool
    public var isLocked: Bool
    public var lane: ScreenLane

    public init(showsLyricText: Bool,
                sequenceLabel: String?,
                isSelected: Bool,
                isLocked: Bool,
                lane: ScreenLane) {
        self.showsLyricText = showsLyricText
        self.sequenceLabel = sequenceLabel
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.lane = lane
    }
}

public enum TimelineSegment {

    /// 生成色块呈现描述。
    /// - Parameter showSequence: 是否显示低干扰序号（默认显示）。
    public static func presentation(for line: LyricLine,
                                    selectedLineID: UUID?,
                                    isLocked: Bool = false,
                                    showSequence: Bool = true) -> TimelineSegmentPresentation {
        TimelineSegmentPresentation(showsLyricText: false,
                                    sequenceLabel: showSequence ? "\(line.order)" : nil,
                                    isSelected: selectedLineID == line.id,
                                    isLocked: isLocked,
                                    lane: line.lane)
    }
}
