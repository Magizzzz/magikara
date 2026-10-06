import Foundation

// MARK: - 运行环境配置单
//
// 把 App 发给别人时，下面这些东西对方电脑上没有：
//   * ffmpeg（带 libass）：随 App 内置在 Contents/Resources/bin，不需要下载；
//   * MDX23C 人声分离模型（Core ML，约 42 MB）；
//   * Yohane 日语歌唱对轨：隔离的 Python 3.12 + PyTorch 等依赖（用内置的 uv 安装），
//     以及 1.26 GB 的模型权重。
// 配置单负责「列出缺什么 → 一键下载安装 → 验证」，全部装在
// ~/Library/Application Support/MaGiKara 与 ~/Library/Caches/MaGiKara 下，不碰系统环境。

public enum RuntimeComponentID: String, CaseIterable, Sendable, Identifiable {
    case ffmpeg, separationModel, pythonEnvironment, alignerModel
    public var id: String { rawValue }
}

public struct RuntimeComponent: Sendable, Identifiable {
    public let id: RuntimeComponentID
    public let title: String
    public let purpose: String
    /// 需要下载的大约字节数（内置组件为 0）
    public let downloadBytes: Int64
    public let license: String
    public let isReady: Bool
    public let isBundled: Bool
}

public enum RuntimeSetupStep: Int, CaseIterable, Sendable, Identifiable {
    case check, python, packages, alignerModel, separationModel, verify
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .check: return "检查环境"
        case .python: return "准备 Python"
        case .packages: return "安装依赖"
        case .alignerModel: return "下载对轨模型"
        case .separationModel: return "下载分离模型"
        case .verify: return "验证环境"
        }
    }
}

public enum RuntimeSetupEvent: Sendable {
    case stepStarted(RuntimeSetupStep)
    case stepSkipped(RuntimeSetupStep)
    case source(String)
    /// 当前步骤的字节进度（已完成, 总量）
    case bytes(Int64, Int64?)
    /// 当前正在处理的条目（文件名 / 包名）
    case item(String)
    case log(String)
}

public enum RuntimeSetupError: LocalizedError {
    case uvMissing
    case notEnoughDisk(needed: Int64, available: Int64)
    case processFailed(String, Int32)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .uvMissing:
            return "App 里缺少内置的 uv（Python 包管理器），请重新下载完整的安装包。"
        case .notEnoughDisk(let needed, let available):
            return "磁盘空间不足：需要约 \(RuntimeSetup.formatBytes(needed))，当前只剩 \(RuntimeSetup.formatBytes(available))。"
        case .processFailed(let what, let code):
            return "\(what)失败（退出码 \(code)）。展开日志可以看到详细原因；网络不稳定时直接点「重试」即可，已下载的部分不会重下。"
        case .verification(let message):
            return "环境验证没有通过：\(message)"
        }
    }
}

public enum RuntimeSetup {

    // MARK: 固定的模型与依赖

    static let alignerRepository = "NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn"
    static let alignerRevision = "2ab2b5f46539ee284703c281f286b01d2410ee12"
    static let alignerWeightsBytes: Int64 = 1_261_938_632
    static let alignerWeightsSHA256 = "4d1d6fbb543534ab32bcceac5f5a42052c7fde3d16a83cbbce858473d5735042"
    /// 权重之外 transformers 加载所需的小文件
    static let alignerSmallFiles = ["config.json", "vocab.json", "added_tokens.json",
                                    "tokenizer_config.json", "processor_config.json"]
    /// 依赖下载约 170 MB，解压进缓存后约 530 MB（用于估算安装进度）
    static let packagesDownloadBytes: Int64 = 170_000_000
    static let packagesUnpackedBytes: Int64 = 530_000_000
    static let pythonDownloadBytes: Int64 = 25_000_000

    // MARK: 路径

    static var alignerRoot: URL { LocalYohaneForcedAligner.root }
    static var venvURL: URL { alignerRoot.appendingPathComponent("venv", isDirectory: true) }
    static var venvPython: URL { venvURL.appendingPathComponent("bin/python") }
    static var pythonInstallDir: URL { alignerRoot.appendingPathComponent("python", isDirectory: true) }
    static var uvCacheDir: URL { alignerRoot.appendingPathComponent(".uv-cache", isDirectory: true) }
    static var environmentMarker: URL { alignerRoot.appendingPathComponent("environment-ready.txt") }

    static var requirementsURL: URL? {
        Bundle.module.url(forResource: "requirements", withExtension: "txt", subdirectory: "local_forced_aligner")
    }

    /// App 内置的命令行工具（Contents/Resources/bin）。开发时退回本机安装的版本。
    static func bundledTool(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    static func uvURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_UV"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundledTool("uv") { return bundled }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    // MARK: 状态（配置单）

    static var pythonEnvironmentReady: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: venvPython.path) else { return false }
        if fm.fileExists(atPath: environmentMarker.path) { return true }
        // 以前用 Scripts/local_forced_aligner/setup.sh 手工装好的环境没有标记文件
        let sitePackages = venvURL.appendingPathComponent("lib/python3.12/site-packages")
        return ["torch", "torchaudio", "transformers", "pykakasi"].allSatisfy {
            fm.fileExists(atPath: sitePackages.appendingPathComponent($0).path)
        }
    }

    static var alignerModelReady: Bool {
        let fm = FileManager.default
        let model = LocalYohaneForcedAligner.modelURL
        let weights = model.appendingPathComponent("model.safetensors")
        let size = (try? fm.attributesOfItem(atPath: weights.path)[.size] as? NSNumber)?.int64Value
        return size == alignerWeightsBytes
            && alignerSmallFiles.allSatisfy { fm.fileExists(atPath: model.appendingPathComponent($0).path) }
    }

    static var separationModelReady: Bool {
        VocalSeparationModelInstaller.validCompiledModelURL(info: .mdx23cInstVocHQ) != nil
    }

    public static func components() -> [RuntimeComponent] {
        [
            RuntimeComponent(id: .ffmpeg,
                             title: "视频导出组件（ffmpeg）",
                             purpose: "把卡拉 OK 字幕烧录进 MP4",
                             downloadBytes: 0,
                             license: "GPL-3.0",
                             isReady: VideoExporter.ffmpegURL() != nil,
                             isBundled: bundledTool("ffmpeg") != nil),
            RuntimeComponent(id: .separationModel,
                             title: "人声分离模型（MDX23C）",
                             purpose: "分出伴奏和人声，对轨也要先用它提取人声",
                             downloadBytes: Int64(VocalSeparationModelInfo.mdx23cInstVocHQ.expectedByteCount),
                             license: "MIT",
                             isReady: separationModelReady,
                             isBundled: false),
            RuntimeComponent(id: .pythonEnvironment,
                             title: "对轨运行环境（Python 3.12 + PyTorch）",
                             purpose: "运行日语歌唱对轨模型的独立环境，不影响系统里的 Python",
                             downloadBytes: pythonDownloadBytes + packagesDownloadBytes,
                             license: "各依赖自身许可",
                             isReady: pythonEnvironmentReady,
                             isBundled: false),
            RuntimeComponent(id: .alignerModel,
                             title: "日语歌唱对轨模型（Yohane）",
                             purpose: "把歌词逐字对到歌声上；没有它会退回系统语音识别，精度较低",
                             downloadBytes: alignerWeightsBytes,
                             license: "CC BY-NC-SA 4.0（仅限非商业使用）",
                             isReady: alignerModelReady,
                             isBundled: false),
        ]
    }

    public static var isComplete: Bool { components().allSatisfy(\.isReady) }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 安装执行

public final class RuntimeSetupRunner: @unchecked Sendable {

    public typealias EventHandler = @Sendable (RuntimeSetupEvent) -> Void

    private let events: EventHandler
    private var source = DownloadSource.official

    public init(events: @escaping EventHandler) {
        self.events = events
    }

    public func run(preference: DownloadSourcePreference) async throws {
        try await check(preference: preference)
        try Task.checkCancellation()
        try await preparePython()
        try Task.checkCancellation()
        try await installPackages()
        try Task.checkCancellation()
        try await downloadAlignerModel()
        try Task.checkCancellation()
        try await downloadSeparationModel()
        try Task.checkCancellation()
        try await verify()
    }

    // MARK: 1. 检查环境

    private func check(preference: DownloadSourcePreference) async throws {
        events(.stepStarted(.check))
        let fm = FileManager.default
        try fm.createDirectory(at: RuntimeSetup.alignerRoot, withIntermediateDirectories: true)

        // 从网上下载的 App 带隔离属性；内置的命令行工具要去掉，否则子进程会被系统拦下。
        for name in ["uv", "ffmpeg"] {
            if let tool = RuntimeSetup.bundledTool(name) {
                removexattr(tool.path, "com.apple.quarantine", 0)
            }
        }

        var needed: Int64 = 0
        if !RuntimeSetup.pythonEnvironmentReady { needed += RuntimeSetup.packagesUnpackedBytes * 2 + 100_000_000 }
        if !RuntimeSetup.alignerModelReady { needed += RuntimeSetup.alignerWeightsBytes }
        if !RuntimeSetup.separationModelReady { needed += 150_000_000 }
        if let values = try? RuntimeSetup.alignerRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < needed + 500_000_000 {
            throw RuntimeSetupError.notEnoughDisk(needed: needed + 500_000_000, available: available)
        }
        events(.log("需要磁盘空间约 \(RuntimeSetup.formatBytes(needed))"))

        if !RuntimeSetup.pythonEnvironmentReady, RuntimeSetup.uvURL() == nil {
            throw RuntimeSetupError.uvMissing
        }

        events(.item(preference == .automatic ? "正在测试网络，选择下载源…" : "使用\(preference.title)"))
        source = await DownloadSource.resolve(preference)
        DownloadEndpoints.huggingFace = source.huggingFace
        events(.source(source.name))
        events(.log("下载源：\(source.name)（模型：\(source.huggingFace)）"))
    }

    // MARK: 2. Python

    private func preparePython() async throws {
        if RuntimeSetup.pythonEnvironmentReady || pythonRuns() {
            events(.stepSkipped(.python))
            return
        }
        events(.stepStarted(.python))
        events(.bytes(0, RuntimeSetup.pythonDownloadBytes))
        try? FileManager.default.removeItem(at: RuntimeSetup.venvURL)
        try await runUV(["venv", "--no-config", "--python", "3.12", "--python-preference", "only-managed",
                         RuntimeSetup.venvURL.path],
                        what: "准备 Python",
                        progressDirectory: RuntimeSetup.pythonInstallDir,
                        progressTotal: RuntimeSetup.pythonDownloadBytes * 3)
    }

    private func pythonRuns() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: RuntimeSetup.venvPython.path) else { return false }
        let process = Process()
        process.executableURL = RuntimeSetup.venvPython
        process.arguments = ["-c", "import sys"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: 3. 依赖

    private func installPackages() async throws {
        if RuntimeSetup.pythonEnvironmentReady {
            events(.stepSkipped(.packages))
            return
        }
        guard let requirements = RuntimeSetup.requirementsURL else {
            throw RuntimeSetupError.verification("App 资源里缺少 requirements.txt")
        }
        events(.stepStarted(.packages))
        try await runUV(["pip", "install", "--no-config", "--python", RuntimeSetup.venvPython.path,
                         "-r", requirements.path],
                        what: "安装依赖",
                        progressDirectory: RuntimeSetup.uvCacheDir,
                        progressTotal: RuntimeSetup.packagesUnpackedBytes)
        // 缓存只是中间产物，留着要多占 500 MB
        try? FileManager.default.removeItem(at: RuntimeSetup.uvCacheDir)
    }

    // MARK: 4. 对轨模型

    private func downloadAlignerModel() async throws {
        if RuntimeSetup.alignerModelReady {
            events(.stepSkipped(.alignerModel))
            return
        }
        events(.stepStarted(.alignerModel))
        let directory = LocalYohaneForcedAligner.modelURL
        let base = "\(source.huggingFace)/\(RuntimeSetup.alignerRepository)/resolve/\(RuntimeSetup.alignerRevision)"
        let fm = FileManager.default

        for file in RuntimeSetup.alignerSmallFiles {
            let destination = directory.appendingPathComponent(file)
            if fm.fileExists(atPath: destination.path) { continue }
            events(.item(file))
            try await ResumableDownloader().download(from: URL(string: "\(base)/\(file)")!, to: destination)
        }

        let total = RuntimeSetup.alignerWeightsBytes
        events(.item("model.safetensors（\(RuntimeSetup.formatBytes(total))）"))
        events(.log("下载 \(base)/model.safetensors"))
        let events = self.events
        try await ResumableDownloader().download(
            from: URL(string: "\(base)/model.safetensors")!,
            to: directory.appendingPathComponent("model.safetensors"),
            expectedBytes: total,
            sha256: RuntimeSetup.alignerWeightsSHA256) { received, _ in
                events(.bytes(received, total))
            }
        events(.log("对轨模型校验通过"))
    }

    // MARK: 5. 人声分离模型

    private func downloadSeparationModel() async throws {
        if RuntimeSetup.separationModelReady {
            events(.stepSkipped(.separationModel))
            return
        }
        events(.stepStarted(.separationModel))
        let info = VocalSeparationModelInfo.mdx23cInstVocHQ
        let total = Int64(info.expectedByteCount)
        events(.item(info.fileName))
        events(.log("下载 \(info.downloadURL.absoluteString)"))
        let events = self.events
        _ = try await VocalSeparator(modelInfo: info).ensureModel { fraction in
            // 安装器 0–0.8 是下载，之后是校验 / 解压 / 编译
            let downloaded = min(1, fraction / 0.8)
            events(.bytes(Int64(Double(total) * downloaded), total))
            if fraction >= 0.85 { events(.item("正在编译 Core ML 模型…")) }
        }
    }

    // MARK: 6. 验证

    private func verify() async throws {
        events(.stepStarted(.verify))
        events(.item("正在加载 PyTorch 与对轨依赖…"))
        let script = "import torch, torchaudio, transformers, pykakasi, soundfile, numpy; print('torch', torch.__version__)"
        try await runProcess(RuntimeSetup.venvPython, ["-c", script],
                                          environment: ["PYTHONNOUSERSITE": "1"],
                                          what: "加载对轨依赖")
        guard LocalYohaneForcedAligner.sidecarURL != nil else {
            throw RuntimeSetupError.verification("App 资源里缺少对轨脚本 sidecar.py")
        }
        guard RuntimeSetup.alignerModelReady else {
            throw RuntimeSetupError.verification("对轨模型文件不完整")
        }
        guard RuntimeSetup.separationModelReady else {
            throw RuntimeSetupError.verification("人声分离模型没有装好")
        }
        if VideoExporter.ffmpegURL() == nil {
            events(.log("警告：没有找到带字幕滤镜的 ffmpeg，导出 MP4 会失败"))
        }
        try? "ok \(Date())\n".write(to: RuntimeSetup.environmentMarker, atomically: true, encoding: .utf8)
        events(.item("全部就绪"))
    }

    // MARK: 子进程

    private func runUV(_ arguments: [String], what: String,
                       progressDirectory: URL, progressTotal: Int64) async throws {
        guard let uv = RuntimeSetup.uvURL() else { throw RuntimeSetupError.uvMissing }
        var environment = [
            "UV_PYTHON_INSTALL_DIR": RuntimeSetup.pythonInstallDir.path,
            "UV_CACHE_DIR": RuntimeSetup.uvCacheDir.path,
            "UV_HTTP_TIMEOUT": "120",
            "UV_NO_PROGRESS": "1",
        ]
        if let index = source.pythonPackageIndex { environment["UV_DEFAULT_INDEX"] = index }
        if let mirror = source.pythonInstallMirror { environment["UV_PYTHON_INSTALL_MIRROR"] = mirror }

        // uv 在非终端下没有字节进度；用目标目录的增长估算
        let events = self.events
        let poller = Task.detached {
            while !Task.isCancelled {
                let size = Self.directorySize(progressDirectory)
                events(.bytes(min(size, progressTotal), progressTotal))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer { poller.cancel() }
        _ = try await runProcess(uv, arguments, environment: environment, what: what) { line in
            // 「Downloading torch (70.4MiB)」这类行作为当前条目显示
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Downloading") || trimmed.hasPrefix("Downloaded") || trimmed.hasPrefix("Installed")
                || trimmed.hasPrefix("Prepared") || trimmed.hasPrefix("Resolved") {
                events(.item(trimmed))
            }
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                              includingPropertiesForKeys: [.fileAllocatedSizeKey],
                                                              options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return total
    }

    /// 运行子进程，逐行转发输出到日志；任务取消时结束子进程。
    @discardableResult
    private func runProcess(_ executable: URL, _ arguments: [String],
                            environment: [String: String],
                            what: String,
                            onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                   "LANG": "en_US.UTF-8"]
        env.merge(environment) { $1 }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        let events = self.events
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in collector.append(data) {
                events(.log(line))
                onLine?(line)
            }
        }
        events(.log("$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))"))

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() {
            for line in collector.append(rest) { events(.log(line)); onLine?(line) }
        }
        for line in collector.flush() { events(.log(line)); onLine?(line) }

        try Task.checkCancellation()
        guard status == 0 else { throw RuntimeSetupError.processFailed(what, status) }
        return collector.text
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = ""

    var text: String { lock.lock(); defer { lock.unlock() }; return all }

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
                all += line + "\n"
            }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        all += line + "\n"
        return [line]
    }
}
