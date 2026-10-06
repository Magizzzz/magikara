import Foundation
import AVFoundation

/// 解码后的单声道 PCM 与显示用波形峰值。
public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: Double
    /// 画波形用的降采样峰值（桶内绝对值最大）。
    public var peaks: [Float]
    /// 画波形用的降采样 RMS（桶内均方根）。
    ///
    /// 为什么两个都要：真实歌曲普遍被限幅压得很平（实测某ニコカラ源
    /// 动态范围只有 3.5 dB），只画峰值会得到一整条实心色块，看不出任何起伏。
    /// 峰值画外廓、RMS 画内部，是 DAW 的常规画法。
    public var rms: [Float]

    public init(samples: [Float], sampleRate: Double, duration: Double,
                peaks: [Float], rms: [Float] = []) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.peaks = peaks
        self.rms = rms
    }
}

public enum AudioDecodeError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "媒体里没有音频轨道"
        case .readerFailed(let m): return "音频读取失败：\(m)"
        case .emptyAudio: return "解出的音频为空"
        }
    }
}

/// 媒体解码入口（RD §2：导入 mp4 / mov / mp3 / wav，以及 aiff 等中间格式）。
/// 统一走 AVAssetReader，视频与音频容器共用一条路径。
public enum AudioDecoder {

    public static let defaultSampleRate: Double = 16000

    /// 同步解码为单声道 Float32 PCM。
    /// AVAssetReader 本身就是同步读循环，所以这里不需要 async。
    public static func decode(url: URL,
                              sampleRate: Double = defaultSampleRate,
                              peakBuckets: Int = 6000) throws -> DecodedAudio {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try loadAudioTracks(asset)
        guard let track = tracks.first else { throw AudioDecodeError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodeError.readerFailed("无法添加音频输出") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecodeError.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate) * 240)

        while reader.status == .reading {
            guard let sbuf = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sbuf) }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size else { continue }
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr {
                samples.append(contentsOf: chunk)
            }
        }

        if reader.status == .failed {
            throw AudioDecodeError.readerFailed(reader.error?.localizedDescription ?? "未知错误")
        }
        guard !samples.isEmpty else { throw AudioDecodeError.emptyAudio }

        // 以实际解出的采样数为准，比容器时长更贴合音频内容
        let realDuration = Double(samples.count) / sampleRate
        let envelope = Self.envelope(from: samples, buckets: peakBuckets)
        return DecodedAudio(samples: samples,
                            sampleRate: sampleRate,
                            duration: realDuration,
                            peaks: envelope.peaks,
                            rms: envelope.rms)
    }

    /// 只取媒体时长，用于导入时快速填 duration（可以是视频时长）。
    public static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? s : 0
    }

    /// 兼容旧调用点的别名。
    public static func decodeSync(url: URL,
                                  sampleRate: Double = defaultSampleRate,
                                  peakBuckets: Int = 6000) throws -> DecodedAudio {
        try decode(url: url, sampleRate: sampleRate, peakBuckets: peakBuckets)
    }

    /// 取音频轨道。
    ///
    /// 这里**刻意**使用同步的 `tracks(withMediaType:)`，而不是用信号量去桥接
    /// async 的 `loadTracks`。
    ///
    /// 原因：`semaphore.wait()` 会占住调用线程，而内层 `Task { }` 需要协作线程池里的
    /// 另一个线程才能跑完并 signal。一旦调用方本身就在协作线程上
    /// （例如 App 里的 `Task.detached`），线程池被占满时就会**自锁**。
    /// 实测这会让整套单元测试并发运行时整体挂死（各 suite 单独跑却都正常）。
    ///
    /// 同步 API 在 macOS 13 起标记为 deprecated，但它是纯本地属性访问，
    /// 对本地文件没有异步等待，用它是这里唯一无死锁的选择。
    @available(macOS, deprecated: 13.0, message: "刻意保留同步 API 以避免信号量自锁，见上方注释")
    static func loadAudioTracks(_ asset: AVURLAsset) throws -> [AVAssetTrack] {
        asset.tracks(withMediaType: .audio)
    }

    /// 降采样成显示包络：每桶的峰值与 RMS。
    public static func envelope(from samples: [Float], buckets: Int) -> (peaks: [Float], rms: [Float]) {
        guard !samples.isEmpty, buckets > 0 else { return ([], []) }
        let per = max(1, samples.count / buckets)
        var peaks: [Float] = []
        var rms: [Float] = []
        peaks.reserveCapacity(buckets)
        rms.reserveCapacity(buckets)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + per)
            var maxAbs: Float = 0
            var sumSquares: Float = 0
            for j in i..<end {
                let a = abs(samples[j])
                if a > maxAbs { maxAbs = a }
                sumSquares += samples[j] * samples[j]
            }
            peaks.append(maxAbs)
            rms.append((sumSquares / Float(max(1, end - i))).squareRoot())
            i = end
        }
        return (peaks, rms)
    }

    /// 兼容旧调用点：只要峰值。
    public static func peaks(from samples: [Float], buckets: Int) -> [Float] {
        envelope(from: samples, buckets: buckets).peaks
    }
}
