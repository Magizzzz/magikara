import Foundation

/// 边界局部修正 —— 能量/VAD 在这里只做**小范围起止修正**，不再承担全曲主对齐。
///
/// RD §8.2 第 5/7 步的落地：ASR 给出候选区间后，在 ±`searchRadius` 秒内找一个
/// 更像人声起点/终点的位置（能量谷或起音点）。修正量被硬限制住，
/// 只有确实找到更强证据时才动用；找不到就保持 ASR 时间并如实标低置信度。
public enum BoundaryRefiner {

    public struct Config: Sendable {
        /// 允许修正的最大范围（秒）。故意很小：这一步只做微调。
        public var searchRadius: Double = 0.30
        /// 新位置必须比原位置「好」多少才采纳
        public var minimumGain: Double = 0.15
        /// 是否允许把起点往前推（人声起音常被 ASR 略微漏掉开头）
        public var preferEarliestOnset: Bool = true

        public init() {}
        public static let `default` = Config()
    }

    public struct Adjustment: Sendable {
        public var newTime: Double
        public var applied: Bool
        public var gain: Double
    }

    /// 在 t 附近找「更像边界」的时刻。
    /// 打分：越靠近强起音点、越靠近能量谷、且越接近原始 t，得分越高。
    public static func refine(time t: Double,
                              features: AudioFeatures,
                              config: Config = .default) -> Adjustment {
        guard features.frameCount > 4, features.hopSeconds > 0 else {
            return Adjustment(newTime: t, applied: false, gain: 0)
        }
        let hop = features.hopSeconds
        let center = features.frameIndex(forTime: t)
        let radius = max(1, Int(config.searchRadius / hop))
        let lo = max(0, center - radius)
        let hi = min(features.frameCount - 1, center + radius)
        guard lo < hi else { return Adjustment(newTime: t, applied: false, gain: 0) }

        var bestScore = -Double.infinity
        var bestFrame = center
        for f in lo...hi {
            let onset = Double(features.onsetStrength(frame: f, radius: 4))
            let dip = Double(features.dipScore(frame: f, radius: 4))
            let proximity = 1.0 - Double(abs(f - center)) / Double(max(1, radius))
            // 起音点权重最高：真正的「开口」应该有能量突变
            let score = 0.55 * onset + 0.25 * dip + 0.20 * proximity
            if score > bestScore {
                bestScore = score
                bestFrame = f
            }
        }
        let baseScore = 0.55 * Double(features.onsetStrength(frame: center, radius: 4))
            + 0.25 * Double(features.dipScore(frame: center, radius: 4))
            + 0.20
        let gain = bestScore - baseScore
        let newTime = features.time(forFrame: bestFrame)
        // 修正量本身也要够小
        guard gain >= config.minimumGain, abs(newTime - t) <= config.searchRadius else {
            return Adjustment(newTime: t, applied: false, gain: gain)
        }
        return Adjustment(newTime: newTime, applied: true, gain: gain)
    }

    /// 对一条线的起止做修正，返回 (start, end, 修正了几处)。
    public static func refineRange(start: Double,
                                   end: Double,
                                   features: AudioFeatures,
                                   config: Config = .default) -> (start: Double, end: Double, adjusted: Int) {
        var adjusted = 0
        var s = start
        var e = end
        let ra = refine(time: start, features: features, config: config)
        if ra.applied, ra.newTime < e - 0.05 {
            s = ra.newTime
            adjusted += 1
        }
        let rb = refine(time: end, features: features, config: config)
        if rb.applied, rb.newTime > s + 0.05 {
            e = rb.newTime
            adjusted += 1
        }
        return (s, e, adjusted)
    }
}
