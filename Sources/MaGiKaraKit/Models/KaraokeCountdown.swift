import Foundation

/// 卡拉 OK 倒计时（时间线「倒计时」轨道上的色块）。
///
/// 规则：
/// - 色块存在的这段时间，画面上显示 N 个圆点（默认 3 个），画在**下一句歌词将出现的位置**；
/// - `fill`：每个圆点依次被「走轨色」填满，整个色块走完时恰好全部填满；
/// - `dwindle`：圆点逐个熄灭；
/// - 预览与导出共用本文件的全部计算，所以两边永远一致；
/// - 开头那个倒计时由 `KaraProject.syncOpeningCountdown()` 自动生成并跟随第一句，
///   用户也可以在任意位置（例如间奏之前）自己再加。
public enum KaraokeCountdown {

    /// 自动倒计时的默认时长（秒）
    public static let defaultDuration: Double = 3.0

    /// 没亮的点：缩小到 60% 并淡化到 22% 不透明（仅「逐点熄灭」模式）。
    public static let unlitScale: Double = 0.6
    public static let unlitOpacity: Double = 0.22

    // MARK: 尺寸

    public static func dotDiameter(style: SubtitleStyle) -> Double {
        max(8, style.fontSize * style.countdown.sizeFactor)
    }

    public static func dotSpacing(style: SubtitleStyle) -> Double {
        max(0, style.fontSize * style.countdown.spacingFactor)
    }

    // MARK: 时间 → 状态

    /// 时间 t 正在显示的倒计时（总开关关闭时为 nil）。多个重叠时取开始得最晚的那个。
    public static func activeItem(in project: KaraProject, at t: Double) -> CountdownItem? {
        guard project.style.countdownEnabled, t >= 0 else { return nil }
        return project.countdowns
            .filter { $0.start <= t && t < $0.end }
            .max { $0.start < $1.start }
    }

    /// 「逐点走轨填色」：第 `dot` 个点（从 0 起）在时间 t 的填充进度 0...1。
    /// 每个点各占色块时长的 1/N，依次填满。
    public static func fillProgress(dot: Int, dotCount: Int, item: CountdownItem, at t: Double) -> Double {
        guard dotCount > 0, item.duration > 0 else { return 0 }
        let slot = item.duration / Double(dotCount)
        let dotStart = item.start + Double(dot) * slot
        return min(1, max(0, (t - dotStart) / slot))
    }

    /// 「逐点熄灭」：时间 t 还亮着的点数（色块结束前至少 1 个）。
    public static func litDots(dotCount: Int, item: CountdownItem, at t: Double) -> Int {
        guard dotCount > 0, item.duration > 0 else { return 0 }
        let remaining = max(0, item.end - t)
        let lit = Int(ceil(remaining / item.duration * Double(dotCount) - 1e-9))
        return min(dotCount, max(1, lit))
    }

    /// 导出用：逐点熄灭拆成的时间段，每段亮 `dots` 个点。
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var dots: Int
    }

    public static func dwindleSegments(dotCount: Int, item: CountdownItem) -> [Segment] {
        guard dotCount > 0, item.duration > 0 else { return [] }
        let slot = item.duration / Double(dotCount)
        return (0..<dotCount).map { k in
            Segment(start: item.start + Double(k) * slot,
                    end: item.start + Double(k + 1) * slot,
                    dots: dotCount - k)
        }
    }

    // MARK: 位置

    /// 倒计时画在哪一行：下一句（色块结束后第一个出现的句子）所在的那一行。
    public static func lane(for item: CountdownItem, in project: KaraProject) -> ScreenLane {
        let upcoming = project.sortedLines
            .filter { $0.displayStart >= item.end - 0.05 }
            .min { $0.displayStart < $1.displayStart }
        return (upcoming ?? project.sortedLines.first)?.lane ?? .upper
    }

    // MARK: 自动倒计时

    /// 开头倒计时：结束在第一句进入画面的那一刻，往前 `defaultDuration` 秒。
    /// 没有第一句、第一句没有有效时间、或离开头不足 0.3 秒（放不下）时返回 nil。
    public static func autoItem(for project: KaraProject) -> CountdownItem? {
        guard let first = project.sortedLines.first, first.singEnd > first.singStart else { return nil }
        let end = first.displayStart
        guard end >= CountdownItem.minimumDuration else { return nil }
        return CountdownItem(start: max(0, end - defaultDuration), end: end, isAuto: true)
    }
}
