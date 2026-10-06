import Foundation
import AVFoundation
import Accelerate

/// 送入 ASR 的音频假设。
///
/// 动机：同一首歌，不同的前端处理会显著改变演唱识别质量。
/// 与其凭感觉挑一个，不如**都跑一遍，用客观指标选最好的**。
public enum AudioHypothesis: String, CaseIterable, Codable, Sendable {
    /// 原始混音的单声道下混（基线）
    case mix
    /// 频谱中置提取：每个频点取 min(|L|,|R|) 的幅度 + 中置相位
    /// （人声通常在中间，宽度大的乐器/混响会被压掉）
    case centerExtract
    /// 中置提取 + 人声频带强调（150–6000 Hz）
    case centerVocalBand
    /// 原始下混 + 人声频带强调
    case mixVocalBand
    /// 0.85× 放慢（快速演唱时给模型更多帧）
    case slowed

    public var displayName: String {
        switch self {
        case .mix: return "原始混音（单声道下混）"
        case .centerExtract: return "频谱中置提取"
        case .centerVocalBand: return "中置提取 + 人声频带强调"
        case .mixVocalBand: return "原始下混 + 人声频带强调"
        case .slowed: return "放慢 0.85×"
        }
    }

    /// 时间戳需要乘回的系数（放慢的假设要把时间轴压回去）
    public var timeScale: Double {
        self == .slowed ? 0.85 : 1.0
    }
}

/// 生成各假设的 16 kHz 单声道 WAV。
public enum AudioHypothesisBuilder {

    public static let sampleRate: Double = 16000

    /// 解码成立体声（16 kHz）。同时返回下混结果，避免重复解码。
    public static func decodeStereo(media: URL) throws -> (left: [Float], right: [Float]) {
        let asset = AVURLAsset(url: media)
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            sem.signal()
        }
        sem.wait()
        guard let track else {
            throw ASRError.audioExtractionFailed("媒体里没有音频轨道")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw ASRError.audioExtractionFailed("startReading 失败")
        }

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(16000 * 200)
        right.reserveCapacity(16000 * 200)
        while reader.status == .reading {
            guard let sbuf = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sbuf) }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size else { continue }
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            var i = 0
            while i + 1 < interleaved.count {
                left.append(interleaved[i])
                right.append(interleaved[i + 1])
                i += 2
            }
        }
        guard !left.isEmpty else { throw ASRError.audioExtractionFailed("解出的音频为空") }
        return (left, right)
    }

    /// 为某个假设写出 WAV。
    public static func build(hypothesis: AudioHypothesis,
                             left: [Float],
                             right: [Float],
                             to url: URL) throws -> Double {
        var samples: [Float]
        switch hypothesis {
        case .mix:
            samples = downmix(left, right)
        case .centerExtract:
            samples = centerExtract(left, right)
        case .centerVocalBand:
            samples = vocalBand(centerExtract(left, right))
        case .mixVocalBand:
            samples = vocalBand(downmix(left, right))
        case .slowed:
            samples = resample(downmix(left, right), rate: 0.85)
        }
        if samples.isEmpty { samples = [0] }
        try writeWAV(samples, to: url)
        return Double(samples.count) / sampleRate
    }

    // MARK: 各假设的实现

    static func downmix(_ l: [Float], _ r: [Float]) -> [Float] {
        let n = min(l.count, r.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = 0.5 * (l[i] + r[i]) }
        return out
    }

    /// 频谱中置提取：STFT → 每个频点用 min(|L|,|R|) 作为幅度、中置相位 → ISTFT。
    /// 这是经典的中置声道提取，能把宽度大的乐器/混响压掉，突出中间的人声。
    static func centerExtract(_ l: [Float], _ r: [Float]) -> [Float] {
        let n = min(l.count, r.count)
        guard n > 4096 else { return downmix(l, r) }
        let fftSize = 1024
        let hop = 256
        let half = fftSize / 2
        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return downmix(l, r)
        }

        var window = [Float](repeating: 0, count: fftSize)
        window.withUnsafeMutableBufferPointer {
            vDSP_hann_window($0.baseAddress!, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }

        var out = [Float](repeating: 0, count: n)
        var norm = [Float](repeating: 0, count: n)

        var lr = [Float](repeating: 0, count: fftSize)
        var li = [Float](repeating: 0, count: fftSize)
        var rr = [Float](repeating: 0, count: fftSize)
        var ri = [Float](repeating: 0, count: fftSize)
        var lOutR = [Float](repeating: 0, count: half)
        var lOutI = [Float](repeating: 0, count: half)
        var rOutR = [Float](repeating: 0, count: half)
        var rOutI = [Float](repeating: 0, count: half)
        var mOutR = [Float](repeating: 0, count: half)
        var mOutI = [Float](repeating: 0, count: half)

        var pos = 0
        while pos + fftSize <= n {
            for k in 0..<fftSize {
                lr[k] = l[pos + k] * window[k]
                rr[k] = r[pos + k] * window[k]
                li[k] = 0
                ri[k] = 0
            }
            lr.withUnsafeMutableBufferPointer { lp in
                li.withUnsafeMutableBufferPointer { ip in
                    lOutR.withUnsafeMutableBufferPointer { orp in
                        lOutI.withUnsafeMutableBufferPointer { oip in
                            let input = DSPSplitComplex(realp: lp.baseAddress!, imagp: ip.baseAddress!)
                            var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                            fft.forward(input: input, output: &output)
                        }
                    }
                }
            }
            rr.withUnsafeMutableBufferPointer { rp in
                ri.withUnsafeMutableBufferPointer { ip in
                    rOutR.withUnsafeMutableBufferPointer { orp in
                        rOutI.withUnsafeMutableBufferPointer { oip in
                            let input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                            fft.forward(input: input, output: &output)
                        }
                    }
                }
            }
            // 中置 = min(|L|,|R|) × 中置相位；用 (L+R) 的相位
            for k in 0..<half {
                let lmag = (lOutR[k] * lOutR[k] + lOutI[k] * lOutI[k]).squareRoot()
                let rmag = (rOutR[k] * rOutR[k] + rOutI[k] * rOutI[k]).squareRoot()
                let mag = min(lmag, rmag)
                let mr = lOutR[k] + rOutR[k]
                let mi = lOutI[k] + rOutI[k]
                let denom = (mr * mr + mi * mi).squareRoot()
                if denom > 1e-9 {
                    mOutR[k] = mag * mr / denom
                    mOutI[k] = mag * mi / denom
                } else {
                    mOutR[k] = 0
                    mOutI[k] = 0
                }
            }
            // 逆变换
            mOutR.withUnsafeMutableBufferPointer { rp in
                mOutI.withUnsafeMutableBufferPointer { ip in
                    let input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    lr.withUnsafeMutableBufferPointer { orp in
                        li.withUnsafeMutableBufferPointer { oip in
                            var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                            fft.inverse(input: input, output: &output)
                        }
                    }
                }
            }
            for k in 0..<fftSize {
                out[pos + k] += lr[k] * window[k]
                norm[pos + k] += window[k] * window[k]
            }
            pos += hop
        }
        // 窗归一化
        for i in 0..<n where norm[i] > 1e-6 {
            out[i] /= norm[i]
        }
        return out
    }

    /// 简单二阶 biquad 级联：高通 150 Hz + 低通 6000 Hz，突出人声频带。
    static func vocalBand(_ x: [Float]) -> [Float] {
        let highPassed = biquad(x, b0: 0.9435, b1: -1.8870, b2: 0.9435, a1: -1.8820, a2: 0.8880)
        return biquad(highPassed, b0: 0.2452, b1: 0.4904, b2: 0.2452, a1: -0.5095, a2: 0.2313)
    }

    static func biquad(_ x: [Float], b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let v = x[i]
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = y
            x2 = x1; x1 = v
            y2 = y1; y1 = y
        }
        return out
    }

    /// 线性插值重采样：rate < 1 表示放慢（输出更长）。
    static func resample(_ x: [Float], rate: Double) -> [Float] {
        guard rate > 0, !x.isEmpty else { return x }
        let outCount = Int(Double(x.count) / rate)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) * rate
            let i0 = Int(src)
            let frac = Float(src - Double(i0))
            let a = x[min(i0, x.count - 1)]
            let b = x[min(i0 + 1, x.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let channels = 1, bits = 16
        let byteRate = Int(sampleRate) * channels * bits / 8
        let blockAlign = channels * bits / 8
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(channels); u32(Int(sampleRate)); u32(byteRate); u16(blockAlign); u16(bits)
        data.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767)
        }
        pcm.withUnsafeBufferPointer { bp in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(bp.baseAddress!).assumingMemoryBound(to: UInt8.self),
                                            count: bp.count * 2))
        }
        try data.write(to: url)
    }
}
