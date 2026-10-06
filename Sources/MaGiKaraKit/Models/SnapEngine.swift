import Foundation

/// 吸附目标类型（用于在 UI 上说明「吸到了什么」）。
public enum SnapTarget: String, Sendable, CaseIterable {
    case playhead
    case timelineStart
    case audioBoundary
    case acousticOnset
    case acousticOffset
    case adjacentBlock

    public var displayName: String {
        switch self {
        case .playhead: return "播放头"
        case .timelineStart: return "时间线开头"
        case .audioBoundary: return "音频边界"
        case .acousticOnset: return "演唱起点"
        case .acousticOffset: return "演唱终点"
        case .adjacentBlock: return "相邻片段"
        }
    }
}

/// 吸附配置。默认全部开启；`enabled = false` 或按住 Option 时完全不吸附。
public struct SnapConfig: Sendable, Equatable {
    public var enabled: Bool = true
    /// 吸附阈值（像素）。换算成时间时除以 pixelsPerSecond，保证不同缩放下手感一致。
    public var thresholdPixels: Double = 8
    public var includePlayhead: Bool = true
    public var includeTimelineStart: Bool = true
    public var includeAudioBoundaries: Bool = true
    public var includeAcousticPoints: Bool = true
    public var includeAdjacentBlocks: Bool = true

    public init() {}
    public static let `default` = SnapConfig()
}

/// 一次吸附的结果。
public struct SnapResult: Sendable, Equatable {
    public var time: Double
    public var target: SnapTarget?
    /// 原始（未吸附）时间，便于 UI 判断是否真的吸上了
    public var rawTime: Double

    public var didSnap: Bool { target != nil }
}

/// 轻量吸附（对标剪映的 Auto Snapping / Track Magnet）。
///
/// 设计约束（用户明确要求）：
/// - **不得修改 ASR 的真实声学时间**。吸附只决定「拖动落点」，
///   拖动结束后写入的是这一句的时间值；token/mora 只做整体平移，绝不被吸附重写。
/// - 阈值按像素算，缩放到 4 px/秒 和 400 px/秒 时手感一致。
/// - 可整体关闭（按钮），也可按住 Option 临时关闭。
public enum SnapEngine {

    /// 收集吸附候选点。`audioOnsets` 来自音频分析（人声段起点），可为空。
    public static func candidates(project: KaraProject,
                                  excluding lineID: UUID?,
                                  audioOnsets: [Double] = [],
                                  config: SnapConfig = .default,
                                  playhead: Double = 0,
                                  duration: Double = 0) -> [(time: Double, target: SnapTarget)] {
        var out: [(Double, SnapTarget)] = []
        if config.includeTimelineStart {
            out.append((0, .timelineStart))
        }
        if config.includePlayhead {
            out.append((playhead, .playhead))
        }
        if config.includeAudioBoundaries, duration > 0 {
            out.append((duration, .audioBoundary))
        }
        for t in audioOnsets where t.isFinite {
            out.append((t, .audioBoundary))
        }
        for line in project.lyricLines where line.id != lineID {
            if config.includeAcousticPoints {
                out.append((line.singStart, .acousticOnset))
                out.append((line.singEnd, .acousticOffset))
            }
            if config.includeAdjacentBlocks {
                out.append((line.displayStart, .adjacentBlock))
                out.append((line.displayEnd, .adjacentBlock))
            }
        }
        return out.filter { $0.0.isFinite }
    }

    /// 吸附一个时间点。
    public static func snap(_ time: Double,
                            candidates: [(time: Double, target: SnapTarget)],
                            pixelsPerSecond: Double,
                            config: SnapConfig = .default,
                            temporarilyDisabled: Bool = false,
                            bounds: ClosedRange<Double>? = nil) -> SnapResult {
        var t = time
        if let bounds { t = min(max(bounds.lowerBound, t), bounds.upperBound) }
        guard config.enabled, !temporarilyDisabled, pixelsPerSecond > 0, !candidates.isEmpty else {
            return SnapResult(time: t, target: nil, rawTime: time)
        }
        let threshold = max(1e-4, config.thresholdPixels / pixelsPerSecond)
        var best: (time: Double, target: SnapTarget)?
        var bestDistance = Double.greatestFiniteMagnitude
        for c in candidates {
            let d = abs(c.time - t)
            guard d <= threshold else { continue }
            // 距离相同则取更靠前的时间，保证结果稳定可复现
            if d < bestDistance - 1e-12 || (abs(d - bestDistance) <= 1e-12 && (best.map { c.time < $0.time } ?? true)) {
                bestDistance = d
                best = c
            }
        }
        guard let best else { return SnapResult(time: t, target: nil, rawTime: time) }
        return SnapResult(time: best.time, target: best.target, rawTime: time)
    }

    /// 便捷重载：直接从工程收集候选再吸附。
    public static func snap(_ time: Double,
                            project: KaraProject,
                            excluding lineID: UUID?,
                            pixelsPerSecond: Double,
                            playhead: Double,
                            duration: Double,
                            audioOnsets: [Double] = [],
                            config: SnapConfig = .default,
                            temporarilyDisabled: Bool = false) -> SnapResult {
        let cs = candidates(project: project, excluding: lineID, audioOnsets: audioOnsets,
                            config: config, playhead: playhead, duration: duration)
        return snap(time, candidates: cs, pixelsPerSecond: pixelsPerSecond,
                    config: config, temporarilyDisabled: temporarilyDisabled,
                    bounds: 0...max(0.05, duration))
    }
}
