import Foundation

/// 时间线吸附（对标 FCPX 的吸附开关，快捷键 N）。
///
/// 拖动时把「正在动的边」吸到附近的参考点：播放头、其它句子的四条边、倒计时两端、0 秒。
/// 阈值按屏幕像素算（缩放越大，能吸住的时间范围越小），手感与缩放无关。
public enum TimelineSnapper {

    /// 吸附距离（像素）
    public static let thresholdPixels: Double = 8

    public struct Result: Equatable, Sendable {
        /// 修正后的位移
        public var delta: Double
        /// 吸到的参考时间；nil 表示没有吸附
        public var target: Double?
    }

    public struct TimeResult: Equatable, Sendable {
        /// 吸附后的时间
        public var time: Double
        public var target: Double?
    }

    /// 移动若干条边（整块移动时是多条边一起动），找离参考点最近的一条，吸过去。
    /// - Parameters:
    ///   - edges: 拖动开始时这些边的原始时间
    ///   - delta: 鼠标给出的原始位移（秒）
    ///   - candidates: 参考点
    ///   - pixelsPerSecond: 当前缩放
    public static func snap(edges: [Double],
                            delta: Double,
                            candidates: [Double],
                            pixelsPerSecond: Double,
                            thresholdPixels: Double = thresholdPixels) -> Result {
        guard pixelsPerSecond > 0, !edges.isEmpty, !candidates.isEmpty else {
            return Result(delta: delta, target: nil)
        }
        let threshold = thresholdPixels / pixelsPerSecond
        var best: (distance: Double, delta: Double, target: Double)?
        for edge in edges {
            let moved = edge + delta
            for c in candidates {
                let distance = abs(c - moved)
                guard distance <= threshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, c - edge, c)
                }
            }
        }
        guard let best else { return Result(delta: delta, target: nil) }
        return Result(delta: best.delta, target: best.target)
    }

    /// 单个时间点（修剪一条边、拖播放头）的吸附。
    public static func snap(time: Double,
                            candidates: [Double],
                            pixelsPerSecond: Double,
                            thresholdPixels: Double = thresholdPixels) -> TimeResult {
        let r = snap(edges: [time], delta: 0, candidates: candidates,
                     pixelsPerSecond: pixelsPerSecond, thresholdPixels: thresholdPixels)
        return TimeResult(time: time + r.delta, target: r.target)
    }

    /// 收集参考点：其它句子的四条边、倒计时两端、0 秒，以及（可选）播放头。
    public static func candidates(project: KaraProject,
                                  excludingLine: UUID? = nil,
                                  excludingCountdown: UUID? = nil,
                                  playhead: Double?) -> [Double] {
        var out: [Double] = [0]
        if let playhead { out.append(playhead) }
        for line in project.lyricLines where line.id != excludingLine {
            out += [line.displayStart, line.singStart, line.singEnd, line.displayEnd]
        }
        for item in project.countdowns where item.id != excludingCountdown {
            out += [item.start, item.end]
        }
        return out
    }
}
