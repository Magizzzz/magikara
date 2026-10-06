import Foundation

/// 本地合成的伴奏床 —— 全部用正弦与噪声生成，无任何版权素材。
///
/// 目的：给 Phase 0 提供一个「伴奏较密集」的测试条件（RD §8.3），
/// 用来观察能量/谱通量对齐在伴奏干扰下的退化程度。
///
/// 这是合成伴奏，不是真实 J-Pop 编曲；它能验证鲁棒性趋势，不能替代真实歌曲验证。
public enum BackingTrackSynth {

    /// 生成一段和弦进行 + 贝斯 + 打击乐的伴奏床。
    public static func generate(duration: Double, sampleRate: Double = 16000) -> [Float] {
        let n = max(1, Int(duration * sampleRate))
        var out = [Float](repeating: 0, count: n)
        var rng = SplitMix64(seed: 0x5DEECE66D)

        // I - V - vi - IV（相对音高，A 大调附近）
        let chords: [[Double]] = [
            [440.00, 554.37, 659.25],   // A  C#  E
            [659.25, 830.61, 987.77],   // E  G#  B
            [369.99, 440.00, 554.37],   // F# A  C#
            [293.66, 369.99, 493.88],   // D  F# A
        ]
        let barSeconds = 2.0
        let beatSeconds = 0.5      // 120 BPM

        for i in 0..<n {
            let t = Double(i) / sampleRate
            let bar = Int(t / barSeconds)
            let chord = chords[bar % chords.count]

            // 和弦垫音：慢起慢落
            let posInBar = t - Double(bar) * barSeconds
            let env = 0.5 * (1 - cos(2 * Double.pi * min(1, posInBar / barSeconds)))
            var s = 0.0
            for f in chord {
                s += sin(2 * Double.pi * f * t) * 0.11
                s += sin(2 * Double.pi * (f * 2) * t) * 0.03
            }
            s *= env

            // 贝斯：每拍一下
            let beat = Int(t / beatSeconds)
            let posInBeat = t - Double(beat) * beatSeconds
            let bassEnv = exp(-posInBeat * 6.0)
            let bassFreq = chord[0] / 2
            s += sin(2 * Double.pi * bassFreq * t) * 0.22 * bassEnv

            // 底鼓：每拍低频冲击
            let kick = sin(2 * Double.pi * 55 * t) * exp(-posInBeat * 22.0) * 0.35
            // 军鼓/踩镲：反拍噪声
            let noise = rng.nextUnit() * 2 - 1
            let hatPhase = (t + beatSeconds / 2).truncatingRemainder(dividingBy: beatSeconds)
            let hat = noise * exp(-hatPhase * 55.0) * 0.16

            out[i] = Float(s + kick + hat)
        }
        return out
    }

    /// 把人声与伴奏混合。`backingGain` 越大伴奏越密集。
    public static func mix(vocal: [Float], backing: [Float], vocalGain: Float = 0.95, backingGain: Float) -> [Float] {
        let n = max(vocal.count, backing.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = i < vocal.count ? vocal[i] * vocalGain : 0
            let b = i < backing.count ? backing[i] * backingGain : 0
            // 软限幅，避免削顶
            out[i] = Float(tanh(Double(v + b)))
        }
        return out
    }
}

/// 可重现的伪随机数（不依赖系统随机源，保证测试集可重复）。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// 0...1
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
