import Foundation
import Speech
import AVFoundation
import CoreMedia

/// ASR 产出的带时间戳单元。日本语的时间片通常就是 1 个假名/音拍级单位。
public struct ASRToken: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// 一次识别的完整结果。
public struct ASRTranscript: Codable, Sendable {
    public var engine: String
    public var locale: String
    public var mediaName: String
    public var audioDuration: Double
    public var elapsedSeconds: Double
    public var tokens: [ASRToken]

    public init(engine: String, locale: String, mediaName: String,
                audioDuration: Double, elapsedSeconds: Double, tokens: [ASRToken]) {
        self.engine = engine
        self.locale = locale
        self.mediaName = mediaName
        self.audioDuration = audioDuration
        self.elapsedSeconds = elapsedSeconds
        self.tokens = tokens
    }

    public var fullText: String { tokens.map(\.text).joined() }
}

/// 本机 ASR 资源状态 —— UI/CLI 必须能显示这个，而不是静默失败。
public enum ASRAvailability: Sendable, Equatable {
    case ready
    case needsDownload
    case unsupportedLocale
    case unavailable(String)

    public var displayName: String {
        switch self {
        case .ready: return "日语识别模型已就绪（离线）"
        case .needsDownload: return "需要下载日语识别模型（首次联网，约几十 MB）"
        case .unsupportedLocale: return "本机不支持日语识别"
        case .unavailable(let why): return "语音识别不可用：\(why)"
        }
    }
}

/// 跨版本的能力查询入口。
///
/// `SpeechAnalyzer` / `SpeechTranscriber` 需要 macOS 26+。
/// 本工程最低支持 macOS 14，因此：
/// - 在 macOS 26+ 上走新的 ASR 强制对齐；
/// - 更老的系统上明确报告「不可用」，并降级到旧的能量对齐（不静默假成功）。
public enum ASRCapability {
    /// 编译期/运行期是否具备系统 ASR
    public static var isSupportedByOS: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public static func availability(locale: String = "ja-JP") async -> ASRAvailability {
        if #available(macOS 26.0, *) {
            return await SpeechASREngine.shared.availability(locale: locale)
        }
        return .unavailable("系统语音识别需要 macOS 26 或更高版本（当前系统更旧）")
    }

    /// 最近一次多假设比较报告（跨版本安全访问）
    public static var lastHypothesisReport: String {
        if #available(macOS 26.0, *) { return ASRForcedAligner.lastHypothesisReport }
        return ""
    }

    /// 最近一次向前声学修正报告
    public static var lastForwardReport: String {
        if #available(macOS 26.0, *) { return ASRForcedAligner.lastForwardReport }
        return ""
    }

    /// 最近一次声学起点吸附报告
    public static var lastSnapReport: String {
        if #available(macOS 26.0, *) { return ASRForcedAligner.lastSnapReport }
        return ""
    }

    /// 需要下载模型时，触发安装。
    @discardableResult
    public static func ensureAssets(locale: String = "ja-JP",
                                    progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> ASRAvailability {
        if #available(macOS 26.0, *) {
            return try await SpeechASREngine.shared.ensureAssets(locale: locale, progress: progress)
        }
        throw ASRError.unavailableOnThisOS
    }
}

public enum ASRError: LocalizedError {
    case unsupportedLocale
    case assetInstallFailed(String)
    case audioExtractionFailed(String)
    case transcriptionFailed(String)
    case cancelled
    case unavailableOnThisOS

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale: return "本机语音识别不支持日语（ja-JP）"
        case .assetInstallFailed(let m): return "日语语音模型安装失败：\(m)"
        case .audioExtractionFailed(let m): return "音频抽取失败：\(m)"
        case .transcriptionFailed(let m): return "语音识别失败：\(m)"
        case .cancelled: return "识别已取消"
        case .unavailableOnThisOS: return "系统语音识别需要 macOS 26 或更高版本"
        }
    }
}

/// 基于 macOS 26+ `SpeechAnalyzer` / `SpeechTranscriber` 的本地离线 ASR。
///
/// 选它的理由（都是本机实测）：
/// - **完全离线**，模型装完后不需要网络；系统自带，无第三方依赖、无需 Python；
/// - 给出**逐时间片时间戳**（`audioTimeRange`），正好用于强制对齐；
/// - 日语是系统支持语言之一（`SpeechTranscriber.supportedLocales` 含 ja_JP）；
/// - 实测一首 171 秒真实歌曲识别耗时 **2.0 秒（83.7× 实时）**，可用性极高。
///
/// 注意与 RD §8.2 的关系：ASR 只用来**找时间**，最终文字始终以用户歌词为准，
/// 绝不拿 ASR 的错误听写覆盖用户歌词。
@available(macOS 26.0, *)
public actor SpeechASREngine {

    public static let shared = SpeechASREngine()

    public static let defaultLocale = "ja-JP"
    public static let engineName = "macOS SpeechAnalyzer (SpeechTranscriber, 本地离线)"

    private var cachedTranscripts: [String: ASRTranscript] = [:]

    public init() {}

    // MARK: 资源状态

    /// 检查本机是否支持并能使用日语识别。UI 与 CLI 都应先调这个。
    public func availability(locale: String = SpeechASREngine.defaultLocale) async -> ASRAvailability {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier.hasPrefix(String(locale.prefix(2))) }) else {
            return .unsupportedLocale
        }
        let transcriber = makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsDownload
        case .unsupported:
            return .unsupportedLocale
        @unknown default:
            return .unavailable("未知资源状态 \(status)")
        }
    }

    /// 确保日语模型就绪；缺失时下载安装（首次需要联网）。progress 回调在 0...1。
    @discardableResult
    public func ensureAssets(locale: String = SpeechASREngine.defaultLocale,
                             progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> ASRAvailability {
        let available = await availability(locale: locale)
        if available == .ready { return .ready }
        if available == .unsupportedLocale { throw ASRError.unsupportedLocale }

        let transcriber = makeTranscriber(locale: locale)
        progress?(0.0, "正在下载日语识别模型…")
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                // 没有安装请求但状态不是 installed：可能是正在下载
                return await availability(locale: locale)
            }
            let observer = Task { [weak request] in
                while !Task.isCancelled, let p = request?.progress {
                    progress?(p.fractionCompleted, "正在下载日语识别模型…")
                    if p.isFinished { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            try await request.downloadAndInstall()
            observer.cancel()
            progress?(1.0, "日语识别模型已安装")
        } catch {
            throw ASRError.assetInstallFailed(error.localizedDescription)
        }
        return await availability(locale: locale)
    }

    // MARK: 识别

    /// 对媒体文件做识别。内部会把音轨抽成 16 kHz 单声道 WAV（临时文件，用完删除）。
    public func transcribe(mediaURL: URL,
                           locale: String = SpeechASREngine.defaultLocale,
                           progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> ASRTranscript {
        let cacheKey = "\(mediaURL.path)|\(locale)"
        if let cached = cachedTranscripts[cacheKey] { return cached }

        guard await availability(locale: locale) == .ready else {
            throw ASRError.assetInstallFailed("日语语音模型未就绪，请先安装")
        }

        progress?(0.05, "正在准备音频…")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("magikara-asr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audioDuration: Double
        do {
            audioDuration = try Self.extractToWAV(media: mediaURL, out: tmp)
        } catch {
            throw ASRError.audioExtractionFailed(error.localizedDescription)
        }
        if Task.isCancelled { throw ASRError.cancelled }
        progress?(0.15, "正在识别日语歌词…")

        let started = Date()
        let tokens = try await runTranscriber(file: tmp, locale: locale, progress: progress)
        let elapsed = Date().timeIntervalSince(started)

        let transcript = ASRTranscript(engine: Self.engineName,
                                       locale: locale,
                                       mediaName: mediaURL.lastPathComponent,
                                       audioDuration: audioDuration,
                                       elapsedSeconds: elapsed,
                                       tokens: tokens)
        cachedTranscripts[cacheKey] = transcript
        progress?(1.0, "识别完成（\(tokens.count) 个时间片）")
        return transcript
    }

    /// 阶段级缓存：只改字幕样式或只改歌词时不必重跑识别。
    public func cachedTranscript(for mediaURL: URL, locale: String = SpeechASREngine.defaultLocale) -> ASRTranscript? {
        cachedTranscripts["\(mediaURL.path)|\(locale)"]
    }

    public func clearCache() { cachedTranscripts.removeAll() }

    /// 直接喂已经准备好的 WAV（测试与 CLI 复用同一条路径）。
    public func transcribeWAV(_ wavURL: URL,
                              locale: String = SpeechASREngine.defaultLocale,
                              progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> ASRTranscript {
        guard await availability(locale: locale) == .ready else {
            throw ASRError.assetInstallFailed("日语语音模型未就绪")
        }
        let started = Date()
        let tokens = try await runTranscriber(file: wavURL, locale: locale, progress: progress)
        let file = try AVAudioFile(forReading: wavURL)
        return ASRTranscript(engine: Self.engineName,
                             locale: locale,
                             mediaName: wavURL.lastPathComponent,
                             audioDuration: Double(file.length) / file.processingFormat.sampleRate,
                             elapsedSeconds: Date().timeIntervalSince(started),
                             tokens: tokens)
    }

    // MARK: 内部

    private func makeTranscriber(locale: String) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: locale),
                          preset: .timeIndexedTranscriptionWithAlternatives)
    }

    private func runTranscriber(file: URL,
                               locale: String,
                               progress: (@Sendable (Double, String) -> Void)?) async throws -> [ASRToken] {
        let audioFile = try AVAudioFile(forReading: file)
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [ASRToken] in
            var out: [ASRToken] = []
            do {
                for try await result in transcriber.results {
                    // 关键：只收**最终**结果。
                    // `timeIndexedTranscriptionWithAlternatives` 预设会同时报出
                    // volatile（会不断被修正的部分结果），如果把它们也累加进来，
                    // 字符流会出现重复与半截内容，而且每次运行的切分点不同 ——
                    // 实测同一份音频三次运行的句首平均误差是 1.338 / 1.746 / 0.952 秒，
                    // 11/35 句时间不同。过滤 isFinal 后结果稳定。
                    guard result.isFinal else { continue }
                    let attributed = result.text
                    for run in attributed.runs {
                        let piece = String(attributed[run.range].characters)
                        guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        var start = 0.0
                        var end = 0.0
                        if let tr = run.audioTimeRange {
                            start = CMTimeGetSeconds(tr.start)
                            end = CMTimeGetSeconds(tr.end)
                        }
                        out.append(ASRToken(text: piece, start: start, end: end))
                    }
                }
            } catch {
                // 结果流中断：保留已经拿到的部分，由上层按证据不足处理
            }
            return out
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
        let tokens = await collector.value
        guard !tokens.isEmpty else {
            throw ASRError.transcriptionFailed("没有识别到任何内容")
        }
        return tokens.sorted { $0.start < $1.start }
    }

    /// 用 AVAssetReader 把媒体音轨解成 16 kHz 单声道 Float32 WAV。返回音频时长（秒）。
    static func extractToWAV(media: URL, out: URL) throws -> Double {
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
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw ASRError.audioExtractionFailed("startReading 失败")
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false) else {
            throw ASRError.audioExtractionFailed("无法创建音频格式")
        }
        let file = try AVAudioFile(forWriting: out, settings: format.settings)
        var frames = 0
        while reader.status == .reading {
            guard let sbuf = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sbuf) }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buf.frameLength = AVAudioFrameCount(count)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                    destination: buf.floatChannelData!.pointee)
            guard status == kCMBlockBufferNoErr else { continue }
            try file.write(from: buf)
            frames += count
        }
        return Double(frames) / 16000.0
    }
}
