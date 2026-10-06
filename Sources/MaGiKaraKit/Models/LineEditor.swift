import Foundation

/// 歌词句的直接编辑（修剪 / 移动 / 分割结果落盘）。
///
/// 全部是纯函数，返回新的 `LyricLine`；非法操作返回 nil。
/// UI 只负责把手势换算成「时间 + 哪条边」，边界规则都收在这里，便于单元测试。
public enum LineEditor {

    public enum Edge: String, Sendable, CaseIterable {
        case displayStart
        case displayEnd
        case singStart
        case singEnd

        public var displayName: String {
            switch self {
            case .displayStart: return "显示开始"
            case .displayEnd: return "显示结束"
            case .singStart: return "演唱开始"
            case .singEnd: return "演唱结束"
            }
        }
    }

    /// 最短片段时长
    public static let minimumDuration: Double = 0.06

    /// 修剪某条边到指定时间。返回 nil 表示该时间会导致非法片段（过短或穿越）。
    public static func trimmed(_ line: LyricLine, edge: Edge, to time: Double) -> LyricLine? {
        var out = line
        let t = max(0, time)
        switch edge {
        case .displayStart:
            // 色块左边缘 = 画面歌词出现的时间。往里拖进走轨时，走轨同步缩短（不再拒绝）。
            guard t <= line.singEnd - minimumDuration else { return nil }
            out.displayStart = t
            out.displayStartIsManual = true
            if t > out.singStart { out.singStart = t }
        case .displayEnd:
            // 色块右边缘 = 画面歌词消失的时间。往里拖进走轨时，走轨同步缩短。
            guard t >= line.singStart + minimumDuration else { return nil }
            out.displayEnd = t
            out.displayEndIsManual = true
            if t < out.singEnd { out.singEnd = t }
        case .singStart:
            guard t <= line.singEnd - minimumDuration else { return nil }
            out.singStart = max(0, t)
            if out.displayStart > out.singStart { out.displayStart = out.singStart }
        case .singEnd:
            guard t >= line.singStart + minimumDuration else { return nil }
            out.singEnd = t
            if out.displayEnd < out.singEnd { out.displayEnd = out.singEnd }
        }
        out.enforceInvariants()
        return out
    }

    /// 在色块（显示窗口）内平移走轨：走轨时长不变（扫色速度不变），只改变它在块里的位置。
    /// 走轨不会被拖出色块——色块边缘就是画面歌词出现/消失的时刻。
    /// 会同时把显示窗口「定住」，不再被自动排程改回去。
    public static func sweepMoved(_ line: LyricLine, by delta: Double) -> LyricLine {
        let duration = max(minimumDuration, line.singEnd - line.singStart)
        let lowest = line.displayStart
        let highest = max(lowest, line.displayEnd - duration)
        var out = line
        out.singStart = min(max(line.singStart + delta, lowest), highest)
        out.singEnd = out.singStart + (line.singEnd - line.singStart)
        out.displayStartIsManual = true
        out.displayEndIsManual = true
        // 音拍随走轨一起平移
        return retimed(out, from: line.singStart...max(line.singStart + 1e-6, line.singEnd))
    }

    /// 把当前的显示窗口「定住」：用户碰过这块之后，色块到哪里画面歌词就到哪里，
    /// 自动排程不再重新计算它的出现/消失时间。
    public static func freezingDisplayWindow(_ line: LyricLine) -> LyricLine {
        var out = line
        out.displayStartIsManual = true
        out.displayEndIsManual = true
        return out
    }

    /// 移动整句：四个时间值与全部音拍一起平移，**保持时长**。
    /// 越界时贴着边界停住（不改变时长）。
    public static func moved(_ line: LyricLine, by delta: Double,
                             bounds: ClosedRange<Double>? = nil) -> LyricLine {
        var d = delta
        if let bounds {
            let span = line.displayEnd - line.displayStart
            let lo = bounds.lowerBound - line.displayStart
            let hi = bounds.upperBound - max(span, 0) - line.displayStart
            if hi >= lo { d = min(max(d, lo), hi) }
        }
        var out = line
        out.shift(by: d)
        out.enforceInvariants()
        return out
    }

    /// 修剪后重映射音拍时间（把旧的演唱区间等比映射到新区间）。
    public static func retimed(_ line: LyricLine, from old: ClosedRange<Double>) -> LyricLine {
        var out = line
        let newHi = max(out.singStart + 1e-6, out.singEnd)
        out.rescaleMorae(from: old, to: out.singStart...newHi)
        return out
    }

    /// 片段时长是否保持不变
    public static func keepsDuration(_ a: LyricLine, _ b: LyricLine, tolerance: Double = 1e-6) -> Bool {
        abs((a.singEnd - a.singStart) - (b.singEnd - b.singStart)) < tolerance
            && abs((a.displayEnd - a.displayStart) - (b.displayEnd - b.displayStart)) < tolerance
    }
}
