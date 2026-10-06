import Foundation

/// 把句首吸附到**真实的声学乐句起点**上。
///
/// 为什么需要这一步：
/// ASR 的时间片边界来自声学模型，实测与独立检测到的「人声段起点」
/// （浊音从无到有，能量/似然 + 迟滞，与 ASR 完全不同的算法）平均相差
/// **0.44 秒**（中位 0.43）。这个偏移是真实存在的对齐误差，
/// 不是「字幕显示 vs 声学开口」的定义差异。
///
/// 做法：在 ±`maxShift` 秒内寻找人声段起点，用**保序 + 一对一**的 DP 分配，
/// 一份起点只能被一句占用，且总位移最小。找不到合适起点就保持原时间。
///
/// 注意：这一步只吸附**句首**（唱到哪个字开始），句尾仍来自 ASR 时间片，
/// 避免把整句拉伸得失真。
public enum OnsetSnapper {

    public struct Config: Sendable {
        /// 允许的最大吸附距离（秒）
        public var maxShift: Double = 0.80
        /// 人声段最短长度（秒），过滤掉噪声
        public var minIslandDuration: Double = 0.30
        /// 吸附后必须仍与句尾保持的最短时长
        public var minLineDuration: Double = 0.25
        /// 某一行的句首没有吸附时的代价。**必须大于 maxShift**，
        /// 否则「不吸附」永远免费，DP 会一句都不吸（实测就是这样）。
        public var unsnappedLineCost: Double = 1.2
        /// 跳过一个人声段起点的代价（乐句起点并非每句都用得上，允许跳过但要付代价）
        public var skipOnsetCost: Double = 0.15

        public init() {}
        public static let `default` = Config()
    }

    public struct Result: Sendable {
        public var starts: [Double?]
        public var snappedCount: Int
        public var meanShift: Double
    }

    /// 从音频特征里取「人声段起点」。
    public static func islandOnsets(features: AudioFeatures,
                                    minDuration: Double = 0.30) -> [Double] {
        guard features.frameCount > 2 else { return [] }
        let minFrames = max(1, Int(minDuration / features.hopSeconds))
        var out: [Double] = []
        var i = 1
        while i < features.frameCount {
            if features.voiced[i], !features.voiced[i - 1] {
                var j = i
                while j < features.frameCount, features.voiced[j] { j += 1 }
                if j - i >= minFrames {
                    out.append(features.time(forFrame: i))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// 保序一对一吸附。
    public static func snap(starts: [Double?],
                            ends: [Double?],
                            onsets: [Double],
                            config: Config = .default) -> Result {
        let n = starts.count
        guard n > 0, !onsets.isEmpty else {
            return Result(starts: starts, snappedCount: 0, meanShift: 0)
        }

        // 只考虑「有起点」的行，保持顺序
        let lineIdx = (0..<n).filter { starts[$0] != nil }
        let m = onsets.count
        guard !lineIdx.isEmpty else { return Result(starts: starts, snappedCount: 0, meanShift: 0) }

        let inf = Double.infinity
        let L = lineIdx.count

        // 正确的三向 DP：
        //   (i,j) → (i+1, j  )  这一行不吸附          代价 unsnappedLineCost
        //   (i,j) → (i,   j+1)  跳过这个起点          代价 skipOnsetCost
        //   (i,j) → (i+1, j+1)  这一行吸附到该起点    代价 位移
        //
        // 之前的写法把「跳过起点」错误地写成了 (i+1, j+1)，
        // 于是它和「吸附」变成同一状态的两个选项，而跳过恒为常数 0.15、
        // 吸附是 0…0.8 的位移，结果永远选跳过 —— 实测 0/35 句被吸附。
        var dp = [[Double]](repeating: [Double](repeating: inf, count: m + 1), count: L + 1)
        var back = [[Int]](repeating: [Int](repeating: -1, count: m + 1), count: L + 1)
        dp[0][0] = 0

        for i in 0...L {
            for j in 0...m {
                let cur = dp[i][j]
                guard cur.isFinite else { continue }
                // 跳过起点
                if j < m {
                    let v = cur + config.skipOnsetCost
                    if v < dp[i][j + 1] {
                        dp[i][j + 1] = v
                        back[i][j + 1] = 1
                    }
                }
                guard i < L else { continue }
                let li = lineIdx[i]
                guard let st = starts[li] else { continue }
                let en = ends[li] ?? (st + 1)
                // 这一行不吸附
                let unsnapped = cur + config.unsnappedLineCost
                if unsnapped < dp[i + 1][j] {
                    dp[i + 1][j] = unsnapped
                    back[i + 1][j] = 0
                }
                // 吸附
                if j < m {
                    let o = onsets[j]
                    let shift = abs(o - st)
                    if shift <= config.maxShift, en - o >= config.minLineDuration {
                        let v = cur + shift
                        if v < dp[i + 1][j + 1] {
                            dp[i + 1][j + 1] = v
                            back[i + 1][j + 1] = 2
                        }
                    }
                }
            }
        }

        // 最优终点：行必须全部处理完（i == L），j 任意
        var bestJ = 0
        var bestCost = inf
        for j in 0...m where dp[L][j] < bestCost {
            bestCost = dp[L][j]
            bestJ = j
        }

        var newStarts = starts
        var snapped = 0
        var totalShift = 0.0
        var i = L
        var j = bestJ
        while i > 0 || j > 0 {
            let code = back[i][j]
            if code == 2 {
                let onsetIdx = j - 1
                let li = lineIdx[i - 1]
                if let st = starts[li] {
                    let o = onsets[onsetIdx]
                    totalShift += abs(o - st)
                    newStarts[li] = o
                    snapped += 1
                }
                i -= 1; j -= 1
            } else if code == 1 {
                j -= 1
            } else if code == 0 {
                i -= 1
            } else {
                break
            }
        }

        return Result(starts: newStarts,
                      snappedCount: snapped,
                      meanShift: snapped == 0 ? 0 : totalShift / Double(snapped))
    }
}
