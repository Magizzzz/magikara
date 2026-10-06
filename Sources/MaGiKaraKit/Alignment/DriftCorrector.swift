import Foundation

/// 整体偏移与逐渐漂移的估计与修正（RD §8.1「全曲修正逐渐漂移」/ §8.2 第 8 步）。
///
/// 做法：用音频起音点（onset）作为参考，统计每句 `singStart` 与最近起音点的差值，
/// 对（时间, 差值）做最小二乘拟合，得到常数偏移与斜率。
/// 修正时按 `-(offset + slope * (t - meanTime))` 平移整句与全部音拍。
///
/// 这是启发式校正，不是声学对齐：起音点密集或伴奏复杂时估计会不稳，
/// 因此修正量会被限制在上限内，并返回估计质量供界面提示。
public enum DriftCorrector {

    public struct Estimate: Sendable {
        /// 常数偏移（秒），正值表示预测偏晚
        public var offset: Double
        /// 斜率（秒/秒）
        public var slope: Double
        /// 参与拟合的时间中心
        public var meanTime: Double
        /// 参与拟合的句数
        public var sampleCount: Int
        /// 残差标准差（秒），越小越可信
        public var residualStd: Double

        public var isUsable: Bool { sampleCount >= 4 && residualStd < 0.25 }
    }

    /// 单次修正允许的最大平移量（秒），避免把工程改坏。
    public static let maxShift = 1.5
    /// 斜率上限（秒/秒）
    public static let maxSlope = 0.08

    public static func estimate(project: KaraProject, audioURL: URL) throws -> Estimate {
        let audio = try AudioDecoder.decode(url: audioURL, sampleRate: AudioDecoder.defaultSampleRate, peakBuckets: 1)
        let features = AudioFeatureExtractor.extract(from: audio)
        return estimate(project: project, features: features)
    }

    public static func estimate(project: KaraProject, features: AudioFeatures) -> Estimate {
        let lines = project.sortedLines
        var samples: [(t: Double, d: Double)] = []

        guard !features.onsets.isEmpty else {
            return Estimate(offset: 0, slope: 0, meanTime: 0, sampleCount: 0, residualStd: 0)
        }

        for line in lines where line.singEnd > line.singStart {
            guard let nearest = features.onsets.min(by: {
                abs($0 - line.singStart) < abs($1 - line.singStart)
            }) else { continue }
            let d = nearest - line.singStart
            if abs(d) < 0.6 {
                samples.append((line.singStart, d))
            }
        }

        guard samples.count >= 2 else {
            return Estimate(offset: 0, slope: 0, meanTime: 0, sampleCount: samples.count, residualStd: 0)
        }

        let n = Double(samples.count)
        let meanT = samples.reduce(0) { $0 + $1.t } / n
        let meanD = samples.reduce(0) { $0 + $1.d } / n
        var num = 0.0
        var den = 0.0
        for s in samples {
            num += (s.t - meanT) * (s.d - meanD)
            den += (s.t - meanT) * (s.t - meanT)
        }
        var slope = den > 1e-6 ? num / den : 0
        slope = slope.clamped(to: -maxSlope...maxSlope)

        // 用固定斜率重算常数偏移
        var offsetSum = 0.0
        for s in samples { offsetSum += s.d - slope * (s.t - meanT) }
        let offset = offsetSum / n

        // 残差
        var variance = 0.0
        for s in samples {
            let predicted = offset + slope * (s.t - meanT)
            variance += (s.d - predicted) * (s.d - predicted)
        }
        let residualStd = (variance / n).squareRoot()

        return Estimate(offset: offset, slope: slope, meanTime: meanT,
                        sampleCount: samples.count, residualStd: residualStd)
    }

    /// 按估计值平移整个工程。样式不受影响。
    ///
    /// 注意符号：估计量是 `offset = 起音点 - 预测`，所以修正量就是把预测往起音点方向推同样的量，
    /// 即 `shift = offset + slope * (mid - meanTime)`。这里写成负号会让漂移越修越大。
    public static func apply(_ estimate: Estimate, to project: inout KaraProject) -> Int {
        guard estimate.isUsable else { return 0 }
        var changed = 0
        for i in project.lyricLines.indices {
            let line = project.lyricLines[i]
            guard line.singEnd > line.singStart else { continue }
            let mid = (line.singStart + line.singEnd) / 2
            let correction = estimate.offset + estimate.slope * (mid - estimate.meanTime)
            let shift = correction.clamped(to: -maxShift...maxShift)
            guard abs(shift) > 0.005 else { continue }
            project.lyricLines[i].shift(by: shift)
            changed += 1
        }
        project.enforceAllInvariants()
        return changed
    }
}
