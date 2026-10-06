import Foundation

/// 字幕 Tab / 时间轴直接编辑时间的合法化结果。
public struct LineTimeEditResult: Equatable, Sendable {
    public var displayStart: Double
    public var displayEnd: Double
    public var singStart: Double
    public var singEnd: Double
    /// 是否因为越界/最小时长被夹紧。
    public var didClamp: Bool
    /// 是否与同轨相邻片段重叠并被吸附。
    public var didOverlap: Bool
    /// 是否因为无法回避的重叠而整体拒绝（调用方应保持原值）。
    public var rejected: Bool
    /// 面向用户的提示（nil 表示完全按用户输入生效）。
    public var message: String?

    public init(displayStart: Double,
                displayEnd: Double,
                singStart: Double,
                singEnd: Double,
                didClamp: Bool,
                didOverlap: Bool,
                rejected: Bool = false,
                message: String?) {
        self.displayStart = displayStart
        self.displayEnd = displayEnd
        self.singStart = singStart
        self.singEnd = singEnd
        self.didClamp = didClamp
        self.didOverlap = didOverlap
        self.rejected = rejected
        self.message = message
    }
}

/// 四时间模型下的时间编辑规则（沿用现有引擎限制，不合并 display / sing 两组时间）。
///
/// - 结束必须 > 开始；
/// - 最小时长沿用 `LyricLine.minimumSingDuration`；
/// - 超出 `0...duration` 自动夹紧；
/// - 同轨同层不允许重叠：能吸附到相邻边界就吸附，并给出可见提示。
public enum LineTimeEditor {

    /// 正在编辑哪条边（决定重叠时向哪侧吸附）。
    public enum Edge: String, Sendable {
        case start
        case end
        case both
    }

    public static var minimumDuration: Double { LyricLine.minimumSingDuration }

    /// 计算「可见开始/结束」编辑后的合法四时间。
    public static func displayRange(desiredStart: Double,
                                    desiredEnd: Double,
                                    singStart: Double,
                                    singEnd: Double,
                                    duration: Double,
                                    sameLaneNeighbors: [(start: Double, end: Double)] = [],
                                    movingEdge: Edge = .both) -> LineTimeEditResult {
        var s = desiredStart
        var e = desiredEnd
        var didOverlap = false
        var didClamp = false

        let minDuration = max(1e-6, minimumDuration)

        // 1) display 必须包住 sing（enforceInvariants 的约束）。
        if singEnd > singStart {
            s = min(s, singStart)
            e = max(e, singEnd)
        }

        // 2) 同轨相邻不重叠：能向空闲侧吸附就吸附，并记录提示。
        for neighbor in sameLaneNeighbors.sorted(by: { $0.start < $1.start }) {
            guard e > neighbor.start + 1e-9, s < neighbor.end - 1e-9 else { continue }
            didOverlap = true
            switch movingEdge {
            case .end:
                e = min(e, neighbor.start)
            case .start:
                if neighbor.end <= singStart + 1e-9 {
                    s = max(s, neighbor.end)
                } else {
                    e = min(e, neighbor.start)
                }
            case .both:
                let snapRight = abs(s - neighbor.end)
                let snapLeft = abs(e - neighbor.start)
                if neighbor.end <= singStart + 1e-9 && snapRight <= snapLeft {
                    s = max(s, neighbor.end)
                } else {
                    e = min(e, neighbor.start)
                }
            }
        }

        // 吸附后仍然重叠（例如可见区必须包住扫色区，而相邻片段正好压在那里）：
        // 整体阻止本次修改，调用方保持原值。
        let invalidAfterClamp = e <= s + 1e-9
        let stillOverlapping = sameLaneNeighbors.contains {
            LineTimeEditor.overlaps((start: s, end: e), $0)
        }
        if didOverlap && (invalidAfterClamp || stillOverlapping) {
            return LineTimeEditResult(displayStart: desiredStart,
                                      displayEnd: desiredEnd,
                                      singStart: singStart,
                                      singEnd: singEnd,
                                      didClamp: false,
                                      didOverlap: true,
                                      rejected: true,
                                      message: "与同轨相邻片段重叠，已阻止本次修改")
        }

        // 3) 最小时长。
        if e - s < minDuration {
            if movingEdge == .start {
                s = e - minDuration
            } else {
                e = s + minDuration
            }
            didClamp = true
        }

        // 4) 夹紧到视频范围。
        let lower = 0.0
        let upper = max(duration, max(s, e), minDuration)
        if s < lower { s = lower; didClamp = true }
        if e > upper { e = upper; didClamp = true }
        if e - s < minDuration {
            if movingEdge == .start {
                s = max(lower, e - minDuration)
            } else {
                e = upper >= s + minDuration ? s + minDuration : upper
            }
            didClamp = true
        }
        if abs(s - desiredStart) > 1e-9 || abs(e - desiredEnd) > 1e-9 { didClamp = true }

        var message: String?
        if didOverlap {
            message = "与同轨相邻片段重叠，已吸附到合法边界"
        } else if didClamp {
            message = "时间已夹紧到合法范围（最小时长 \(String(format: "%.2f", minDuration))s）"
        }

        return LineTimeEditResult(displayStart: s,
                                  displayEnd: e,
                                  singStart: singStart,
                                  singEnd: singEnd,
                                  didClamp: didClamp,
                                  didOverlap: didOverlap,
                                  message: message)
    }

    /// 计算「扫色开始/结束」编辑后的合法四时间（display 同步包住新的 sing）。
    public static func singRange(desiredStart: Double,
                                 desiredEnd: Double,
                                 displayStart: Double,
                                 displayEnd: Double,
                                 duration: Double,
                                 movingEdge: Edge = .both) -> LineTimeEditResult {
        var s = desiredStart
        var e = desiredEnd
        var didClamp = false
        let minDuration = max(1e-6, minimumDuration)

        if e - s < minDuration {
            if movingEdge == .start { s = e - minDuration } else { e = s + minDuration }
            didClamp = true
        }
        let upper = max(duration, max(s, e), minDuration)
        if s < 0 { s = 0; didClamp = true }
        if e > upper { e = upper; didClamp = true }
        if e - s < minDuration {
            if movingEdge == .start { s = max(0, e - minDuration) }
            else { e = min(upper, s + minDuration) }
            didClamp = true
        }

        var displayLo = min(displayStart, s)
        var displayHi = max(displayEnd, e)
        displayLo = max(0, displayLo)
        displayHi = min(max(duration, displayHi), max(displayHi, displayLo + minDuration))

        if abs(s - desiredStart) > 1e-9 || abs(e - desiredEnd) > 1e-9 { didClamp = true }
        return LineTimeEditResult(displayStart: displayLo,
                                  displayEnd: displayHi,
                                  singStart: s,
                                  singEnd: e,
                                  didClamp: didClamp,
                                  didOverlap: false,
                                  message: didClamp ? "扫色时间已夹紧到合法范围" : nil)
    }

    /// 判断两个可见区间是否重叠（用于 UI 提示，不修改数据）。
    public static func overlaps(_ a: (start: Double, end: Double),
                                _ b: (start: Double, end: Double)) -> Bool {
        a.end > b.start + 1e-9 && a.start < b.end - 1e-9
    }
}
