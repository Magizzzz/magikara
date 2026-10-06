import Foundation
import Accelerate

/// 逐帧音频特征：能量、谱通量、谱平坦度、浊音似然、起音点。
/// 这是「粗对齐 + 强制对齐」的唯一输入信号，全部本地计算。
///
/// 真实素材带来的教训（TTS 测试集暴露不出来）：
/// 流行歌曲普遍被压得很响（loudness war），一首 174 秒的ニコカラ实测
/// 能量动态范围只有 **3.5 dB**。这时任何「绝对 dB 阈值」的人声判定都会整体失效
/// （旧实现直接返回 0% 浊音，导致整首歌被判成「没有检测到人声」而拒绝对轨）。
/// 因此这里改成：
///   1. 用**相对**分位数阈值（相对该素材自己的动态范围）；
///   2. 主要依据换成「谱平坦度 + 人声频带能量占比 + 相对响度」合成的连续似然，
///      而不是单看总能量 —— 密集伴奏下总能量区分不了人声与鼓。
public struct AudioFeatures: Sendable {
    public var sampleRate: Double
    public var frameSize: Int
    public var hop: Int
    public var hopSeconds: Double
    public var frameCount: Int
    public var duration: Double

    /// 每帧 RMS（dB）
    public var energyDB: [Float]
    /// 每帧能量，稳健归一化到 0...1
    public var energyNorm: [Float]
    /// 每帧谱通量（人声频带），稳健归一化到 0...1
    public var novelty: [Float]
    /// 浊音 / 有声判定（由 voiceLikelihood 阈值化而来）
    public var voiced: [Bool]
    /// 起音点时间（秒）
    public var onsets: [Double]

    /// 每帧「像人声」的连续似然 0...1。
    /// 追加在末尾是为了不破坏既有 memberwise init 的调用顺序。
    public var voiceLikelihood: [Float] = []

    /// 该素材的能量动态范围（dB，95% 分位 − 15% 分位）。
    /// 小于约 8 dB 时说明压缩很重，能量类方法能提供的信息很有限。
    public var dynamicRangeDB: Double = 0
    /// 该素材是否不适合纯能量法
    public var isHeavilyCompressed: Bool = false

    /// VAD 实际使用的相对阈值（用于把连续似然锐化成 0/1 附近的分数）
    public var voiceLowThreshold: Float = 0
    public var voiceHighThreshold: Float = 1
    /// true 表示该素材动态范围健康，人声判定走能量阈值（对干净素材更准）
    public var usesEnergyVAD: Bool = true

    public func time(forFrame i: Int) -> Double { Double(i) * hopSeconds }

    public func frameIndex(forTime t: Double) -> Int {
        max(0, min(frameCount - 1, Int((t / hopSeconds).rounded(.down))))
    }

    /// 取第 i 帧的人声分数（0...1）。
    ///
    /// 这里**不是**直接返回原始似然，而是按 VAD 的相对阈值做锐化：
    /// 干净素材（例如 TTS：语音段与静音段分布双峰）会被还原成接近 0/1 的分数，
    /// 从而保留二值浊音原本的区分度；压缩很重的素材则保留一段软过渡。
    ///
    /// 直接用原始似然会削弱对齐代价的对比度 —— 实测会把 TTS 基线从 199 ms 拖到 489 ms。
    /// 旧数据只有二值 voiced 时自动回退。
    public func voiceScore(_ i: Int) -> Float {
        // 动态范围健康的素材：二值浊音本身就很准，直接用，保持代价函数的对比度
        if !usesEnergyVAD, i >= 0, i < voiceLikelihood.count {
            let span = max(1e-6, voiceHighThreshold - voiceLowThreshold)
            return max(0, min(1, (voiceLikelihood[i] - voiceLowThreshold) / span))
        }
        if i >= 0, i < voiced.count { return voiced[i] ? 1 : 0 }
        return 0
    }

    /// 区间内平均人声似然。
    public func meanVoiceScore(from: Int, to: Int) -> Double {
        let lo = max(0, min(frameCount, from))
        let hi = max(lo, min(frameCount, to))
        guard hi > lo else { return 0 }
        var sum: Double = 0
        for i in lo..<hi { sum += Double(voiceScore(i)) }
        return sum / Double(hi - lo)
    }

    /// 取能量（未归一化 dB）的局部极小值程度：越大越像音拍边界。
    public func dipScore(frame: Int, radius: Int = 4) -> Float {
        let lo = max(0, frame - radius)
        let hi = min(frameCount - 1, frame + radius)
        guard lo <= hi else { return 0 }
        var localMin = Float.greatestFiniteMagnitude
        var localMax = -Float.greatestFiniteMagnitude
        for i in lo...hi {
            localMin = min(localMin, energyNorm[i])
            localMax = max(localMax, energyNorm[i])
        }
        let span = max(1e-4, localMax - localMin)
        return (localMax - energyNorm[frame]) / span
    }

    /// 该帧附近是否有起音点。
    public func onsetStrength(frame: Int, radius: Int = 6) -> Float {
        let lo = max(0, frame - radius)
        let hi = min(frameCount - 1, frame + radius)
        // 没有任何帧（音频为空/过短）时 hi = -1，`lo...hi` 会以「Range requires lowerBound <= upperBound」崩溃
        guard lo <= hi else { return 0 }
        var m: Float = 0
        for i in lo...hi { m = max(m, novelty[i]) }
        return m
    }
}

public enum AudioFeatureExtractor {

    public static let frameSize = 1024          // 64 ms @16k
    public static let hop = 160                 // 10 ms @16k
    /// 人声频带
    static let vocalLowHz: Double = 300
    static let vocalHighHz: Double = 3400

    public static func extract(from audio: DecodedAudio) -> AudioFeatures {
        let sr = audio.sampleRate
        let n = frameSize
        let h = hop
        let samples = audio.samples
        let frameCount = max(1, (samples.count - n) / h + 1)
        let hopSeconds = Double(h) / sr

        var energyDB = [Float](repeating: -120, count: frameCount)
        var novelty = [Float](repeating: 0, count: frameCount)
        var tonality = [Float](repeating: 0, count: frameCount)
        var vocalBandRatio = [Float](repeating: 0, count: frameCount)
        var vocalBandEnergy = [Float](repeating: 0, count: frameCount)

        guard frameCount > 2, samples.count >= n else {
            return AudioFeatures(sampleRate: sr, frameSize: n, hop: h, hopSeconds: hopSeconds,
                                 frameCount: frameCount, duration: audio.duration,
                                 energyDB: energyDB, energyNorm: [], novelty: novelty,
                                 voiced: [], onsets: [],
                                 voiceLikelihood: [], dynamicRangeDB: 0, isHeavilyCompressed: false)
        }

        // Hann 窗
        var window = [Float](repeating: 0, count: n)
        window.withUnsafeMutableBufferPointer { wp in
            vDSP_hann_window(wp.baseAddress!, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        }

        let log2n = vDSP_Length(round(log2(Double(n))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return AudioFeatures(sampleRate: sr, frameSize: n, hop: h, hopSeconds: hopSeconds,
                                 frameCount: frameCount, duration: audio.duration,
                                 energyDB: energyDB, energyNorm: [], novelty: novelty,
                                 voiced: [], onsets: [],
                                 voiceLikelihood: [], dynamicRangeDB: 0, isHeavilyCompressed: false)
        }

        let half = n / 2
        let binWidth = sr / Double(n)
        let loBin = max(1, Int(vocalLowHz / binWidth))
        let hiBin = min(half - 1, Int(vocalHighHz / binWidth))
        let fluxLoBin = max(1, Int(150.0 / binWidth))
        let fluxHiBin = min(half - 1, Int(5000.0 / binWidth))

        var realIn = [Float](repeating: 0, count: n)
        var imagIn = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: half)
        var imagOut = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        var prevMagnitude = [Float](repeating: 0, count: half)
        var sq = [Float](repeating: 0, count: half)
        var sq2 = [Float](repeating: 0, count: half)
        var sumSq = [Float](repeating: 0, count: half)

        for f in 0..<frameCount {
            let start = f * h
            var rms: Float = 0
            samples.withUnsafeBufferPointer { sp in
                vDSP_rmsqv(sp.baseAddress! + start, 1, &rms, vDSP_Length(n))
            }
            energyDB[f] = 20 * log10(max(rms, 1e-7))

            samples.withUnsafeBufferPointer { sp in
                vDSP_vmul(sp.baseAddress! + start, 1, window, 1, &realIn, 1, vDSP_Length(n))
            }
            vDSP_vclr(&imagIn, 1, vDSP_Length(n))

            realIn.withUnsafeMutableBufferPointer { rp in
                imagIn.withUnsafeMutableBufferPointer { ip in
                    realOut.withUnsafeMutableBufferPointer { ro in
                        imagOut.withUnsafeMutableBufferPointer { io in
                            let input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            var output = DSPSplitComplex(realp: ro.baseAddress!, imagp: io.baseAddress!)
                            fft.forward(input: input, output: &output)
                        }
                    }
                }
            }

            vDSP.square(realOut, result: &sq)
            vDSP.square(imagOut, result: &sq2)
            vDSP.add(sq, sq2, result: &sumSq)
            var count = Int32(half)
            vvsqrtf(&magnitude, sumSq, &count)

            // 谱通量：只累加正向变化，限制在人声/乐器主体频带
            var flux: Float = 0
            if f > 0 {
                for k in fluxLoBin...fluxHiBin {
                    let d = magnitude[k] - prevMagnitude[k]
                    if d > 0 { flux += d }
                }
            }
            novelty[f] = flux
            prevMagnitude = magnitude

            // 谱平坦度（几何均值 / 算术均值）→ 1 表示噪声，0 表示有明确音高
            var logSum: Float = 0
            var arithSum: Float = 0
            var bandEnergy: Float = 0
            var totalEnergy: Float = 0
            for k in 1..<half {
                let m = magnitude[k]
                totalEnergy += m * m
            }
            for k in loBin...hiBin {
                let m = magnitude[k]
                logSum += log(max(m, 1e-6))
                arithSum += m
                bandEnergy += m * m
            }
            let bandCount = Float(hiBin - loBin + 1)
            let geo = exp(logSum / bandCount)
            let arith = max(1e-9, arithSum / bandCount)
            let flatness = max(0, min(1, geo / arith))
            tonality[f] = 1 - flatness
            vocalBandRatio[f] = totalEnergy > 1e-9 ? bandEnergy / totalEnergy : 0
            vocalBandEnergy[f] = bandEnergy
        }

        let energyNorm = robustNormalize(energyDB.map { Float(pow(10, Double($0) / 20)) })
        let noveltyNorm = robustNormalize(novelty)

        // 动态范围诊断
        let sortedDB = energyDB.sorted()
        let p15 = Double(sortedDB[Int(Double(sortedDB.count - 1) * 0.15)])
        let p95 = Double(sortedDB[Int(Double(sortedDB.count - 1) * 0.95)])
        let dynamicRange = max(0, p95 - p15)
        let heavilyCompressed = dynamicRange < 8.0

        // 人声似然：谱平坦度（最重要）+ 人声频带占比 + 相对响度
        let tonalityNorm = robustNormalize(tonality)
        let bandNorm = robustNormalize(vocalBandRatio)
        let levelNorm = robustNormalize(energyDB)
        var likelihood = [Float](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            likelihood[f] = max(0, min(1, 0.45 * tonalityNorm[f] + 0.20 * bandNorm[f] + 0.35 * levelNorm[f]))
        }

        // 两条 VAD 路径：
        // - 动态范围健康（>= 8 dB）：用能量阈值。干净素材上这最准，
        //   实测 TTS 基线上换成似然阈值会把句边界误差从 199 ms 拖到 ~500 ms。
        // - 压缩很重：能量阈值整体失效（实测某真实歌曲动态范围仅 3.5 dB，
        //   二值浊音 0%），改用相对分位数的复合似然。
        let vad: (voiced: [Bool], low: Float, high: Float)
        let useEnergy = !heavilyCompressed
        if useEnergy {
            vad = detectVoicedByEnergy(energyDB: energyDB)
        } else {
            vad = detectVoicedByLikelihood(likelihood: likelihood)
        }
        let voiced = vad.voiced
        let onsets = detectOnsets(novelty: noveltyNorm, hopSeconds: hopSeconds)

        return AudioFeatures(sampleRate: sr, frameSize: n, hop: h, hopSeconds: hopSeconds,
                             frameCount: frameCount, duration: audio.duration,
                             energyDB: energyDB, energyNorm: energyNorm, novelty: noveltyNorm,
                             voiced: voiced, onsets: onsets,
                             voiceLikelihood: likelihood,
                             dynamicRangeDB: dynamicRange,
                             isHeavilyCompressed: heavilyCompressed,
                             voiceLowThreshold: vad.low,
                             voiceHighThreshold: vad.high,
                             usesEnergyVAD: useEnergy)
    }

    // MARK: 工具

    /// 用 5% / 95% 分位数做稳健归一化，避免个别爆音把整条曲线压平。
    static func robustNormalize(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let sorted = v.sorted()
        let lo = sorted[Int(Double(sorted.count - 1) * 0.05)]
        let hi = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let span = max(1e-6, hi - lo)
        return v.map { max(0, min(1, ($0 - lo) / span)) }
    }

    /// 能量阈值 + 迟滞 + 最短时长约束的人声检测（动态范围健康的素材走这条）。
    ///
    /// 这是最早验证过的实现：TTS 基线上句边界平均误差 199 ms。
    static func detectVoicedByEnergy(energyDB: [Float]) -> (voiced: [Bool], low: Float, high: Float) {
        guard !energyDB.isEmpty else { return ([], 0, 1) }
        let sorted = energyDB.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let peak = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let dynamic = max(4.0, peak - noiseFloor)
        let high = noiseFloor + max(6.0, 0.35 * dynamic)
        let low = high - min(4.0, 0.25 * dynamic)

        var voiced = [Bool](repeating: false, count: energyDB.count)
        var state = false
        for i in energyDB.indices {
            let e = energyDB[i]
            if state {
                if e < low { state = false }
            } else {
                if e > high { state = true }
            }
            voiced[i] = state
        }

        smoothRuns(&voiced, value: true, minRun: 12)   // 120 ms
        smoothRuns(&voiced, value: false, minRun: 8)   // 80 ms
        return (voiced, low, high)
    }

    /// 相对分位数阈值的人声检测（压缩很重的素材走这条）。
    ///
    /// 阈值完全相对于**该素材自己的似然分布**，不再用「噪声底 + 固定 6 dB」，
    /// 否则压缩很重的歌会一句都判不出来。
    static func detectVoicedByLikelihood(likelihood: [Float]) -> (voiced: [Bool], low: Float, high: Float) {
        guard !likelihood.isEmpty else { return ([], 0, 1) }
        let sorted = likelihood.sorted()
        let p15 = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let span = p95 - p15

        // 似然分布几乎没有起伏时（整首都很"像人声"或都很不像），
        // 用绝对下限兜底，避免把整首判成有声或全判成无声。
        let high: Float = span > 0.05 ? p15 + 0.45 * span : max(p95, 0.35)
        let low: Float = high - max(0.03, 0.15 * max(span, 0.05))

        var voiced = [Bool](repeating: false, count: likelihood.count)
        var state = false
        for i in likelihood.indices {
            let v = likelihood[i]
            if state {
                if v < low { state = false }
            } else {
                if v > high { state = true }
            }
            voiced[i] = state
        }

        let minVoiced = 12   // 120 ms
        let minSilence = 8   // 80 ms
        smoothRuns(&voiced, value: true, minRun: minVoiced)
        smoothRuns(&voiced, value: false, minRun: minSilence)
        return (voiced, low, high)
    }

    /// 把长度小于 minRun 的连续同值段翻转为另一值。
    static func smoothRuns(_ arr: inout [Bool], value: Bool, minRun: Int) {
        var i = 0
        while i < arr.count {
            if arr[i] != value { i += 1; continue }
            var j = i
            while j < arr.count && arr[j] == value { j += 1 }
            if j - i < minRun {
                for k in i..<j { arr[k] = !value }
            }
            i = j
        }
    }

    /// 局部极大值 + 自适应阈值 + 最小间隔的起音检测。
    static func detectOnsets(novelty: [Float], hopSeconds: Double) -> [Double] {
        guard novelty.count > 3 else { return [] }
        var mean: Float = 0
        vDSP_meanv(novelty, 1, &mean, vDSP_Length(novelty.count))
        var std: Float = 0
        for v in novelty { std += (v - mean) * (v - mean) }
        std = sqrt(std / Float(novelty.count))
        // 阈值保持原来的 0.6σ：起音点不参与强制对齐的代价函数，
        // 只用于漂移估计与「句首无起音」提示，取最近点即可，密集一些无害。
        let threshold = mean + 0.6 * std

        let minGapFrames = max(1, Int(0.06 / hopSeconds))
        var onsets: [Double] = []
        var lastFrame = -minGapFrames
        for i in 1..<(novelty.count - 1) {
            let v = novelty[i]
            if v > threshold, v >= novelty[i - 1], v > novelty[i + 1], i - lastFrame >= minGapFrames {
                onsets.append(Double(i) * hopSeconds)
                lastFrame = i
            }
        }
        return onsets
    }
}

// MARK: - 特征查询扩展

extension AudioFeatures {
    /// 区间内浊音帧比例。
    public func voicedFraction(from: Int, to: Int) -> Double {
        let lo = max(0, min(frameCount, from))
        let hi = max(lo, min(frameCount, to))
        guard hi > lo else { return 0 }
        var count = 0
        for i in lo..<hi where voiced[i] { count += 1 }
        return Double(count) / Double(hi - lo)
    }
}
