import Foundation

/// 一键生成最终 MP4 的三个常用画质档位。
public enum VideoExportBitrate: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 目标视频码率（bit/s）。最终文件仍会随分辨率、帧率和内容复杂度略有浮动。
    public var bitsPerSecond: Int {
        switch self {
        case .low: return 4_000_000
        case .medium: return 8_000_000
        case .high: return 14_000_000
        }
    }

    /// H.264 视频目标码率（ffmpeg 参数）。
    public var videoBitrate: String {
        switch self {
        case .low: return "4M"
        case .medium: return "8M"
        case .high: return "14M"
        }
    }
}

/// 导出分辨率。`.source` 保持源视频尺寸，其余档位用 ffmpeg `scale` 等比缩放到目标画布。
/// 1080p / 4K 都是 16:9 画布；非 16:9 源素材会居中补边，不会被拉伸。
public enum VideoExportResolution: String, Codable, CaseIterable, Sendable {
    case source
    case hd1080
    case uhd4K = "uhd4k"

    public var displayName: String {
        switch self {
        case .source: return "源分辨率"
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }

    /// ffmpeg `scale` 的目标宽高；`.source` 返回 nil，表示不添加缩放滤镜。
    public var targetSize: (width: Int, height: Int)? {
        switch self {
        case .source: return nil
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }

    /// 等比缩放 + 居中补边的 `scale/pad` 滤镜；`.source` 返回 nil。
    /// 用 `force_original_aspect_ratio=decrease` 避免非 16:9 素材被拉伸。
    public var scaleFilter: String? {
        guard let size = targetSize else { return nil }
        return "scale=\(size.width):\(size.height):force_original_aspect_ratio=decrease,"
            + "pad=\(size.width):\(size.height):(ow-iw)/2:(oh-ih)/2"
    }
}

/// 导出帧率。`.source` 保持源帧率，其余档位用 ffmpeg `-r` 重采样。
public enum VideoExportFrameRate: String, Codable, CaseIterable, Sendable {
    case source
    case fps25
    case fps30
    case fps60

    public var displayName: String {
        switch self {
        case .source: return "源帧率"
        case .fps25: return "25 fps"
        case .fps30: return "30 fps"
        case .fps60: return "60 fps"
        }
    }

    /// ffmpeg `-r` 的值；`.source` 返回 nil，表示沿用源帧率。
    public var ffmpegValue: String? {
        switch self {
        case .source: return nil
        case .fps25: return "25"
        case .fps30: return "30"
        case .fps60: return "60"
        }
    }
}

/// MP4 的音频质量档位。
public enum VideoExportAudioQuality: String, Codable, CaseIterable, Sendable {
    case normal
    case high

    public var displayName: String {
        switch self {
        case .normal: return "普通"
        case .high: return "优质"
        }
    }

    public var audioBitrate: String {
        switch self {
        case .normal: return "192k"
        case .high: return "320k"
        }
    }

    public var bitsPerSecond: Int {
        switch self {
        case .normal: return 192_000
        case .high: return 320_000
        }
    }
}

/// 一次 MP4 导出的完整设置（画质 / 分辨率 / 帧率 / 音频质量）。
public struct VideoExportSettings: Codable, Hashable, Sendable {
    public var bitrate: VideoExportBitrate
    public var resolution: VideoExportResolution
    public var frameRate: VideoExportFrameRate
    public var audioQuality: VideoExportAudioQuality

    public init(bitrate: VideoExportBitrate = .medium,
                resolution: VideoExportResolution = .source,
                frameRate: VideoExportFrameRate = .source,
                audioQuality: VideoExportAudioQuality = .normal) {
        self.bitrate = bitrate
        self.resolution = resolution
        self.frameRate = frameRate
        self.audioQuality = audioQuality
    }

    private enum CodingKeys: String, CodingKey {
        case bitrate
        case resolution
        case frameRate
        case audioQuality
    }

    /// 新增音频档位后仍能读取没有该字段的旧设置，旧行为保持普通音频质量。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bitrate = try container.decode(VideoExportBitrate.self, forKey: .bitrate)
        resolution = try container.decode(VideoExportResolution.self, forKey: .resolution)
        frameRate = try container.decode(VideoExportFrameRate.self, forKey: .frameRate)
        audioQuality = try container.decodeIfPresent(VideoExportAudioQuality.self,
                                                     forKey: .audioQuality) ?? .normal
    }

    public static let `default` = VideoExportSettings()

    /// 目标视频码率（bit/s），供 UI 预估大小使用。
    public var videoBitsPerSecond: Int { bitrate.bitsPerSecond }

    /// 用媒体时长估算文件大小（字节）：(视频码率 + 音频码率) × 时长 / 8。
    /// 拿不到时长时返回 0，由界面回退到当前工程/播放器时长，避免显示空值。
    public func estimatedFileSize(duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let totalBitsPerSecond = Double(bitrate.bitsPerSecond + audioQuality.bitsPerSecond)
        return totalBitsPerSecond * duration / 8.0
    }
}

/// 使用本机 ffmpeg 把视频和 ASS 卡拉 OK 字幕烧录成 MP4。
///
/// ASS 与预览共用 `AssExporter` 的时间、逐字扫色和双轨位置，
/// 因此导出不是静态截图，而是真正的带动态字幕视频。
public enum VideoExporter {

    public enum ExportError: LocalizedError {
        case missingMedia
        case missingFFmpeg
        case ffmpegWithoutSubtitleFilter
        case unknownDuration
        case outputOverwritesInput
        case cancelled
        case failed(String)

        public var isCancellation: Bool {
            if case .cancelled = self { return true }
            return false
        }

        public var errorDescription: String? {
            switch self {
            case .missingMedia: return "没有可导出的素材"
            case .missingFFmpeg:
                return "找不到视频导出组件 ffmpeg。请先安装（终端运行 brew install ffmpeg），装好后重新导出。"
            case .ffmpegWithoutSubtitleFilter:
                return "已找到 ffmpeg，但它没有字幕滤镜（libass），无法烧录卡拉 OK 字幕。请安装带 libass 的版本（例如 Homebrew 的 ffmpeg-full），或把这样的 ffmpeg 放到 ~/.local/bin。"
            case .unknownDuration: return "无法确定素材时长，不能为纯音频生成视频画面"
            case .outputOverwritesInput: return "导出位置不能与素材文件相同，请换一个文件名"
            case .cancelled: return "已取消导出"
            case .failed(let message): return "MP4 导出失败：\(message)"
            }
        }
    }

    /// 导出取消句柄：可从任意线程调用 `cancel()`，会终止正在运行的 ffmpeg。
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        public init() {}

        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if running?.isRunning == true { running?.terminate() }
        }

        /// 进程启动后登记；若启动前已被取消则立刻终止。
        fileprivate func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled, process.isRunning { process.terminate() }
        }
    }

    /// 普通音频档位的兼容别名，供旧调用方读取默认 AAC 参数。
    public static let audioBitrate = VideoExportAudioQuality.normal.audioBitrate
    public static let audioBitsPerSecond = VideoExportAudioQuality.normal.bitsPerSecond

    /// 兼容旧调用：只给码率时，分辨率与帧率都沿用源媒体。
    public static func export(project: KaraProject,
                              bitrate: VideoExportBitrate,
                              to outputURL: URL) throws {
        try export(project: project,
                   settings: VideoExportSettings(bitrate: bitrate),
                   to: outputURL)
    }

    /// 纯音频素材没有画面：导出时用黑底 1920×1080 画布承载字幕。
    public static func isAudioOnly(project: KaraProject) -> Bool {
        MediaImportValidator.kind(forExtension: project.mediaURL.pathExtension) == .audio
    }

    /// 完整设置导出：质量决定码率，分辨率走 `scale`，帧率走 `-r`。
    ///
    /// 先写到同目录的临时文件，成功后再替换目标：失败或取消不会破坏已有文件。
    /// `progress` 在后台线程回调，取值 0…1（时长未知时不回调）。
    public static func export(project: KaraProject,
                              settings: VideoExportSettings,
                              to outputURL: URL,
                              cancellation: Cancellation? = nil,
                              progress: (@Sendable (Double) -> Void)? = nil) throws {
        guard project.mediaURL.isFileURL,
              FileManager.default.fileExists(atPath: project.mediaURL.path) else {
            throw ExportError.missingMedia
        }
        guard let ffmpeg = ffmpegURL() else {
            throw ffmpegCandidates().isEmpty ? ExportError.missingFFmpeg : ExportError.ffmpegWithoutSubtitleFilter
        }

        let stems = validSeparationAssets(in: project)
        let protected = [project.mediaURL, stems?.vocalURL, stems?.instrumentalURL]
            .compactMap { $0?.standardizedFileURL.path }
        guard !protected.contains(outputURL.standardizedFileURL.path) else {
            throw ExportError.outputOverwritesInput
        }
        let audioOnly = isAudioOnly(project: project)
        if audioOnly, project.duration <= 0 { throw ExportError.unknownDuration }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaGiKaraExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let assURL = tempDir.appendingPathComponent("karaoke.ass")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var options = AssExporter.Options()
        options.title = project.title
        try AssExporter.write(project: project, to: assURL, options: options)

        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).partial.mp4")
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let filterPath = escapedFilterPath(assURL.path)
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-y",
            "-progress", "pipe:1",
            "-i", project.mediaURL.path,
        ]
        var inputCount = 1
        if let stems {
            arguments.append(contentsOf: ["-i", stems.instrumentalURL.path,
                                          "-i", stems.vocalURL.path])
            inputCount += 2
        }
        var videoInput: Int?
        if audioOnly {
            arguments.append(contentsOf: [
                "-f", "lavfi",
                "-i", "color=c=black:s=\(Int(KaraokeCanvas.width))x\(Int(KaraokeCanvas.height)):r=30",
            ])
            videoInput = inputCount
        }
        arguments.append(contentsOf: [
            "-vf", videoFilter(assPath: filterPath, settings: settings),
        ])
        arguments.append(contentsOf: audioMappingArguments(project: project,
                                                           hasSeparatedStems: stems != nil,
                                                           videoInput: videoInput))
        if audioOnly {
            // 黑底画布是无限长的：按音频时长截断，静音导出时靠 -t 兜底
            arguments.append(contentsOf: ["-t", String(project.duration)])
            if !arguments.contains("-shortest") { arguments.append("-shortest") }
        }
        arguments.append(contentsOf: encoderArguments(settings: settings))
        arguments.append(partialURL.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments

        let progressPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = progressPipe
        process.standardError = errorPipe

        // 两个管道都必须边运行边读：任何一个写满缓冲（约 64KB）ffmpeg 都会阻塞，导出永久卡住。
        let errorTail = LockedText(limit: 8_192)
        let totalSeconds = project.duration
        let drained = DispatchGroup()
        drained.enter()
        drained.enter()
        var progressBuffer = ""
        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            progressBuffer += String(decoding: data, as: UTF8.self)
            while let newline = progressBuffer.firstIndex(of: "\n") {
                let line = String(progressBuffer[..<newline])
                progressBuffer.removeSubrange(...newline)
                if let fraction = progressFraction(fromLine: line, totalSeconds: totalSeconds) {
                    progress?(fraction)
                }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            errorTail.append(String(decoding: data, as: UTF8.self))
        }

        try process.run()
        cancellation?.attach(process)
        process.waitUntilExit()
        drained.wait()

        if cancellation?.isCancelled == true { throw ExportError.cancelled }
        guard process.terminationStatus == 0 else {
            let message = errorTail.value.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExportError.failed(message.isEmpty ? "未知错误（退出码 \(process.terminationStatus)）" : message)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: partialURL)
        } else {
            try FileManager.default.moveItem(at: partialURL, to: outputURL)
        }
        progress?(1)
    }

    /// 解析 `-progress` 输出中的 `out_time_us=` 行，换算为 0…1。
    /// 保持 internal，方便单元测试。
    static func progressFraction(fromLine line: String, totalSeconds: Double) -> Double? {
        guard totalSeconds > 0, line.hasPrefix("out_time_us="),
              let micros = Double(line.dropFirst("out_time_us=".count)
                .trimmingCharacters(in: .whitespaces)),
              micros >= 0 else { return nil }
        // 留 1% 给收尾（写 moov、替换文件），完成时再显式回调 1
        return min(0.99, micros / 1_000_000 / totalSeconds)
    }

    /// 线程安全的文本尾部缓冲，只保留最后 `limit` 个字符，避免错误输出无限增长。
    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            text += chunk
            if text.count > limit { text = String(text.suffix(limit)) }
        }
        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }

    /// 组装 `-vf` 滤镜链：先按设置缩放，再烧录 ASS，保证字幕在目标分辨率下清晰。
    /// 保持 internal，方便单元测试直接断言分辨率/帧率真的接进了 ffmpeg。
    static func videoFilter(assPath: String, settings: VideoExportSettings) -> String {
        var filters: [String] = []
        if let scale = settings.resolution.scaleFilter { filters.append(scale) }
        filters.append("ass=\(assPath)")
        return filters.joined(separator: ",")
    }

    /// 视频/音频编码参数（不含输入、滤镜与输出路径）。
    /// 保持 internal，方便单元测试断言帧率与码率档位。
    static func encoderArguments(settings: VideoExportSettings) -> [String] {
        var args = [
            "-c:v", "libx264", "-preset", "medium",
            "-b:v", settings.bitrate.videoBitrate,
            "-maxrate", settings.bitrate.videoBitrate,
            "-bufsize", bufferSize(for: settings.bitrate),
            "-pix_fmt", "yuv420p",
        ]
        if let fps = settings.frameRate.ffmpegValue {
            args.append(contentsOf: ["-r", fps])
        }
        args.append(contentsOf: [
            "-c:a", "aac", "-b:a", settings.audioQuality.audioBitrate,
            "-movflags", "+faststart",
        ])
        return args
    }

    /// 分轨导出的限幅：伴奏 = 混音 − 人声，叠加后或旧版分离文件可能超过满刻度，
    /// 转 AAC 后播放会削波破音。`level=false` 关掉自动响度补偿，只压超限的峰。
    static let stemLimiter = "alimiter=limit=0.977:attack=3:release=80:level=false"

    /// 分轨有效时只混合当前未静音的轨道；无有效分轨时完全沿用源媒体音频。
    /// 人声与伴奏在模型输出中相加还原原混音，`normalize=0` 避免无故压低响度。
    static func audioMappingArguments(project: KaraProject,
                                      hasSeparatedStems: Bool? = nil,
                                      videoInput: Int? = nil) -> [String] {
        // 纯音频时画面来自黑底画布输入，否则取源视频；`?` 让无视频流时不报错
        let videoMap = videoInput.map { "\($0):v:0" } ?? "0:v:0?"
        let stems = validSeparationAssets(in: project)
        let separated = hasSeparatedStems ?? (stems != nil)
        guard separated, stems != nil else {
            // 无有效分轨：预览里的「音频」静音作用在原音轨上，导出必须保持一致
            if project.trackStates.isMuted(.audio) { return ["-map", videoMap, "-an"] }
            return ["-map", videoMap, "-map", "0:a?"]
        }

        let muteInstrumental = project.trackStates.isMuted(.audio)
        let muteVocal = project.trackStates.isMuted(.vocal)
        switch (muteInstrumental, muteVocal) {
        case (false, false):
            return ["-filter_complex",
                    "[1:a:0]asetpts=PTS-STARTPTS[inst];[2:a:0]asetpts=PTS-STARTPTS[voc];[inst][voc]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,\(stemLimiter)[aout]",
                    "-map", videoMap, "-map", "[aout]", "-shortest"]
        case (false, true):
            return ["-map", videoMap, "-map", "1:a:0?", "-af", stemLimiter, "-shortest"]
        case (true, false):
            return ["-map", videoMap, "-map", "2:a:0?", "-af", stemLimiter, "-shortest"]
        case (true, true):
            return ["-map", videoMap, "-an"]
        }
    }

    /// 导出时是否会使用分离后的人声／伴奏（分轨存在、指纹匹配且文件都在）。
    public static func usesSeparatedAudio(project: KaraProject) -> Bool {
        validSeparationAssets(in: project) != nil
    }

    private static func validSeparationAssets(in project: KaraProject) -> VocalSeparationAssets? {
        guard let stems = project.vocalSeparation,
              stems.sourceFingerprint == project.mediaFingerprint(),
              FileManager.default.fileExists(atPath: stems.vocalURL.path),
              FileManager.default.fileExists(atPath: stems.instrumentalURL.path) else { return nil }
        return stems
    }

    private static func bufferSize(for bitrate: VideoExportBitrate) -> String {
        switch bitrate {
        case .low: return "8M"
        case .medium: return "16M"
        case .high: return "28M"
        }
    }

    /// 本机所有可执行的 ffmpeg 候选：App 内置、Homebrew／系统位置、用户目录、再到 PATH。
    /// 从 Finder 启动的 App 不继承终端的 PATH，所以必须自己列出常见位置。
    static func ffmpegCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "\(home)/.local/bin", "\(home)/bin", "/usr/bin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        // App 内置的 ffmpeg（发给别人用的安装包里自带，带 libass）排第一
        let bundled = RuntimeSetup.bundledTool("ffmpeg").map { [$0] } ?? []
        return bundled + directories.compactMap { directory in
            guard seen.insert(directory).inserted else { return nil }
            let candidate = (directory as NSString).appendingPathComponent("ffmpeg")
            return FileManager.default.isExecutableFile(atPath: candidate)
                ? URL(fileURLWithPath: candidate) : nil
        }
    }

    /// 第一个带 `ass`（libass）滤镜的 ffmpeg。
    /// 很多发行版（包括 Homebrew 默认的 ffmpeg）不含 libass，选错会得到难以理解的滤镜报错。
    static func ffmpegURL() -> URL? {
        ffmpegCandidates().first(where: supportsASSFilter)
    }

    private static let assSupportCache = LockedCache()

    private final class LockedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Bool] = [:]
        func value(for key: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }
        func set(_ value: Bool, for key: String) {
            lock.lock(); defer { lock.unlock() }
            storage[key] = value
        }
    }

    /// 通过 `ffmpeg -filters` 检查是否含 `ass` 滤镜；同一路径只检测一次。
    static func supportsASSFilter(_ ffmpeg: URL) -> Bool {
        if let cached = assSupportCache.value(for: ffmpeg.path) { return cached }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var supported = false
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            // 行形如 " ... ass               V->V       Render ASS subtitles ..."
            supported = text.split(separator: "\n").contains { line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                return fields.count >= 2 && fields[1] == "ass"
            }
        }
        assSupportCache.set(supported, for: ffmpeg.path)
        return supported
    }

    /// `ass=` 的 filter 参数仍会解析冒号、反斜杠和单引号，
    /// 即使 Process.arguments 已经替我们处理了 shell 层引号，也要转义这一层。
    private static func escapedFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
