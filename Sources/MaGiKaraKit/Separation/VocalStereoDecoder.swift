import AVFoundation
import Foundation

// MARK: - 高质量 44.1 kHz 立体声解码
//
// 刻意不复用现有的 `AudioDecoder`（那是给 ASR 用的 16 kHz 单声道降采样）。
// 这里直接让 AVAssetReader 把主音轨解成 44.1 kHz / 双声道 / Float32 交错 PCM，
// 与 MDX23C 的原生契约一致，避免二次重采样损失。

enum VocalStereoDecoder {

    /// 模型原生采样率。
    static let sampleRate: Double = 44_100

    struct Decoded {
        let channels: [[Float]]
        let sampleRate: Double
        let frameCount: Int
        var duration: TimeInterval { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    }

    static func decodeStereo(url: URL) throws -> Decoded {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VocalSeparationError.mediaMissing(url)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = audioTracks(of: asset)
        guard let track = tracks.first else { throw VocalSeparationError.mediaHasNoAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VocalSeparationError.mediaDecodeFailed(error.localizedDescription)
        }

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
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VocalSeparationError.mediaDecodeFailed("无法添加音频输出")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VocalSeparationError.mediaDecodeFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(Int(sampleRate) * 240)
        right.reserveCapacity(Int(sampleRate) * 240)

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size * 2 else { continue }

            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }

            let frames = interleaved.count / 2
            left.reserveCapacity(left.count + frames)
            right.reserveCapacity(right.count + frames)
            for i in 0..<frames {
                left.append(interleaved[2 * i])
                right.append(interleaved[2 * i + 1])
            }
        }

        if reader.status == .failed {
            throw VocalSeparationError.mediaDecodeFailed(reader.error?.localizedDescription ?? "未知错误")
        }
        guard !left.isEmpty, left.count == right.count else {
            throw VocalSeparationError.audioEmpty
        }
        return Decoded(channels: [left, right], sampleRate: sampleRate, frameCount: left.count)
    }

    /// 与 `AudioDecoder.loadAudioTracks` 同样的取舍：同步 API 是纯本地属性访问，
    /// 在后台/同步上下文里比信号量桥接 async 更安全（避免协作线程池自锁）。
    @available(macOS, deprecated: 13.0, message: "刻意保留同步 API 以避免信号量自锁，见上方注释")
    static func audioTracks(of asset: AVURLAsset) -> [AVAssetTrack] {
        asset.tracks(withMediaType: .audio)
    }
}
