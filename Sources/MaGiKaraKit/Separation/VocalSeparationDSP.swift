import Foundation

// MARK: - 分块
//
// 模型固定吃 261120 采样（255·1024 → 256 个 STFT 帧）。整首歌按 50% 重叠切块，
// 块间用 Hann 窗交叉淡化，最后按窗能量归一化。
//
// 这些是纯函数 / 纯值运算，不触碰 Core ML 与文件系统，便于单元测试验证
// 「重叠相加 + 残差」的关键性质。

enum VocalSeparationChunking {

    /// periodic Hann 窗（与 STFT / PyTorch 一致，注意不是 symmetric）。
    static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 0, count: max(0, length)) }
        return (0..<length).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(length)) }
    }

    /// 返回每个 chunk 的起始采样下标。
    ///
    /// 规则：从 0 开始按 hop 步进，直到 `sampleCount - chunk`；最后一个块
    /// 若没有正好落在末尾，则补一个收尾块，保证 [0, sampleCount) 全被覆盖。
    static func chunkStarts(sampleCount: Int, chunk: Int, hop: Int) -> [Int] {
        guard sampleCount > 0, chunk > 0, hop > 0 else { return [] }
        guard sampleCount > chunk else { return [0] }

        var starts = Array(stride(from: 0, through: sampleCount - chunk, by: hop))
        if let last = starts.last, last + chunk < sampleCount {
            starts.append(sampleCount - chunk)
        }
        if starts.isEmpty { starts = [0] }
        return starts
    }
}

// MARK: - 重叠相加
//
// 每个 chunk 推理出的时域波形乘 Hann 窗后累加，最后除以窗能量；
// instrumental 用 `mix - vocal` 残差，保证 vocal + instrumental == mix。

struct VocalOverlapAdd {

    let sampleCount: Int
    private var left: [Float]
    private var right: [Float]
    private var weights: [Float]

    init(sampleCount: Int) {
        let n = max(0, sampleCount)
        self.sampleCount = n
        left = [Float](repeating: 0, count: n)
        right = [Float](repeating: 0, count: n)
        weights = [Float](repeating: 0, count: n)
    }

    /// 累加一个 chunk 的时域立体声结果；`window` 通常来自 `VocalSeparationChunking.hannWindow`。
    mutating func add(_ channels: [[Float]], at start: Int, validCount: Int, window: [Float]) {
        guard channels.count >= 2, sampleCount > 0, start >= 0, start < sampleCount, validCount > 0 else { return }
        let count = min(validCount, sampleCount - start)
        let available = min(channels[0].count, channels[1].count)
        let usable = min(count, available, window.count)
        guard usable > 0 else { return }
        for i in 0..<usable {
            let w = window[i]
            left[start + i] += channels[0][i] * w
            right[start + i] += channels[1][i] * w
            weights[start + i] += w
        }
    }

    /// 按窗能量归一化后的 vocal 立体声。
    func normalizedVocal() -> [[Float]] {
        var l = [Float](repeating: 0, count: sampleCount)
        var r = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let w = weights[i]
            guard w > 1e-6 else { continue }
            l[i] = left[i] / w
            r[i] = right[i] / w
        }
        return [l, r]
    }

    /// 残差：instrumental = mix − vocal。两者逐样本可完全重构原混音。
    static func residual(mix: [[Float]], vocal: [[Float]]) -> [[Float]] {
        guard mix.count >= 2, vocal.count >= 2 else { return [[], []] }
        let count = min(mix[0].count, mix[1].count, vocal[0].count, vocal[1].count)
        var l = [Float](repeating: 0, count: count)
        var r = [Float](repeating: 0, count: count)
        for i in 0..<count {
            l[i] = mix[0][i] - vocal[0][i]
            r[i] = mix[1][i] - vocal[1][i]
        }
        return [l, r]
    }
}

// MARK: - 峰值限制
//
// mix − vocal 的残差在人声与伴奏反相的位置会叠出比原混音更高的波峰（实测《花》伴奏峰值 1.35，
// 26272 个采样超过满刻度，原混音只有 780 个）。浮点 WAV 本身不怕，但转成 AAC / 16 位或直接
// 送声卡就会削波破音。这里只在超过阈值的地方平滑压低增益：前向释放、反向起音两遍，
// 增益只降不升，所以压完后每个采样都不超过阈值，阈值以下的部分原样不动。

enum VocalPeakLimiter {

    /// 峰值上限（约 −0.2 dBFS）
    static let ceiling: Float = 0.977

    /// 立体声共用一条增益曲线，避免声像漂移。没有超限时原样返回。
    static func limited(_ channels: [[Float]],
                        sampleRate: Double,
                        ceiling: Float = ceiling,
                        attack: Double = 0.003,
                        release: Double = 0.080) -> [[Float]] {
        guard let first = channels.first, !first.isEmpty, sampleRate > 0 else { return channels }
        let n = channels.map(\.count).min() ?? 0
        var gain = [Float](repeating: 1, count: n)
        var over = false
        for i in 0..<n {
            var peak: Float = 0
            for ch in channels { peak = max(peak, abs(ch[i])) }
            if peak > ceiling {
                gain[i] = ceiling / peak
                over = true
            }
        }
        guard over else { return channels }

        let releaseCoef = Float(1 - exp(-1 / (release * sampleRate)))
        let attackCoef = Float(1 - exp(-1 / (attack * sampleRate)))
        // 前向：压低后按释放时间慢慢回到 1
        for i in 1..<n {
            let recovered = gain[i - 1] + (1 - gain[i - 1]) * releaseCoef
            gain[i] = min(gain[i], recovered)
        }
        // 反向：在波峰之前提前按起音时间降下来，避免增益突变产生咔哒声
        if n > 1 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                let ramp = gain[i + 1] + (1 - gain[i + 1]) * attackCoef
                gain[i] = min(gain[i], ramp)
            }
        }
        return channels.map { ch in
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = ch[i] * gain[i] }
            return out
        }
    }
}
