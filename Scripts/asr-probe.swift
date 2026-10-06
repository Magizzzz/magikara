import Foundation
import Speech
import AVFoundation
import CoreMedia

// asr-probe —— 验证 macOS 26+ 的 SpeechAnalyzer / SpeechTranscriber 能否在本机对真实歌曲做
// 带时间戳的日语识别，并打印可用的本地资源状态。
//
// 用法: asr-probe <媒体路径> [输出json]

@main
struct ASRProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("用法: asr-probe <媒体路径> [输出json]")
            exit(1)
        }
        let mediaURL = URL(fileURLWithPath: args[1])

        print("=== Speech 框架资源 ===")
        let supported = await SpeechTranscriber.supportedLocales
        print("supportedLocales (\(supported.count)): \(supported.map(\.identifier).sorted().joined(separator: ", "))")

        let locale = Locale(identifier: "ja-JP")
        guard supported.contains(where: { $0.identifier.hasPrefix("ja") }) else {
            print("❌ 本机不支持日语识别")
            exit(2)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives)

        let installed = await SpeechTranscriber.installedLocales
        print("installedLocales (\(installed.count)): \(installed.map(\.identifier).sorted().joined(separator: ", "))")

        var status = await AssetInventory.status(forModules: [transcriber])
        print("ja-JP 资源状态: \(status)")
        if status != .installed {
            print("正在下载并安装 ja-JP 语音资源（首次需要联网）…")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                    status = await AssetInventory.status(forModules: [transcriber])
                    print("安装后状态: \(status)")
                } else {
                    print("⚠️ 没有可用的安装请求")
                }
            } catch {
                print("❌ 资源安装失败: \(error.localizedDescription)")
                exit(3)
            }
        }

        if let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            print("推荐音频格式: \(fmt)")
        }

        // ---- 抽取音频到临时 WAV（16 kHz 单声道 Float32）----
        print("\n=== 抽取音频 ===")
        let tmpWAV = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("asr-probe-\(UUID().uuidString).wav")
        do {
            let frames = try extractToWAV(media: mediaURL, out: tmpWAV)
            print("写出 \(tmpWAV.lastPathComponent)  采样 \(frames)")
        } catch {
            print("❌ 音频抽取失败: \(error.localizedDescription)")
            exit(4)
        }

        // ---- 识别 ----
        print("\n=== 开始识别 ===")
        let t0 = Date()
        do {
            let results = try await transcribe(file: tmpWAV, transcriber: transcriber)
            let elapsed = Date().timeIntervalSince(t0)
            print(String(format: "识别用时 %.1f 秒（音频 %.1f 秒，实时率 %.1fx）",
                         elapsed, framesDuration(tmpWAV), framesDuration(tmpWAV) / max(0.1, elapsed)))
            print("识别到 \(results.count) 个时间片")

            for r in results.prefix(40) {
                print(String(format: "  %7.2f – %7.2f  %@", r.start, r.end, r.text))
            }
            if results.count > 40 { print("  …（其余 \(results.count - 40) 条略）") }

            if args.count >= 3 {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                struct Doc: Codable { var media: String; var elapsed: Double; var results: [Seg] }
                try enc.encode(Doc(media: mediaURL.lastPathComponent, elapsed: elapsed, results: results))
                    .write(to: URL(fileURLWithPath: args[2]))
                print("JSON: \(args[2])")
            }
        } catch {
            print("❌ 识别失败: \(error.localizedDescription)")
            exit(5)
        }
        try? FileManager.default.removeItem(at: tmpWAV)
    }

    struct Seg: Codable {
        var start: Double
        var end: Double
        var text: String
        var confidence: Double
    }

    static func framesDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// 用 AVAssetReader 把媒体音轨解成 16 kHz 单声道 Float32 WAV。
    static func extractToWAV(media: URL, out: URL) throws -> Int {
        let asset = AVURLAsset(url: media)
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            sem.signal()
        }
        sem.wait()
        guard let track else { throw NSError(domain: "asr", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "没有音频轨道"]) }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "asr", code: 2, userInfo: [NSLocalizedDescriptionKey: "startReading 失败"])
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: out, settings: format.settings)
        var total = 0
        while reader.status == .reading {
            guard let sbuf = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buf.frameLength = AVAudioFrameCount(count)
            _ = buf.floatChannelData!.pointee.withMemoryRebound(to: UInt8.self, capacity: length) { _ in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: buf.floatChannelData!.pointee)
            }
            try file.write(from: buf)
            total += count
            CMSampleBufferInvalidate(sbuf)
        }
        return total
    }

    static func transcribe(file: URL, transcriber: SpeechTranscriber) async throws -> [Seg] {
        let audioFile = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 并行消费结果
        let collector = Task { () -> [Seg] in
            var out: [Seg] = []
            for try await result in transcriber.results {
                let attr = result.text
                // 逐 run 取时间范围
                for run in attr.runs {
                    let text = String(attr[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    var start = 0.0
                    var end = 0.0
                    if let tr = run.audioTimeRange {
                        start = CMTimeGetSeconds(tr.start)
                        end = CMTimeGetSeconds(tr.end)
                    }
                    out.append(Seg(start: start, end: end, text: text, confidence: 0))
                }
            }
            return out
        }

        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }
}
