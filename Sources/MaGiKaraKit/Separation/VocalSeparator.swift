import Foundation

// MARK: - 公开 API
//
// 供 UI 调用的本地人声分离后端。不依赖 AppState / PlaybackEngine / TimelineView /
// KaraProject / 导出逻辑，也不改动它们。
//
// 典型用法：
// ```swift
// let separator = VocalSeparator()
// try await separator.ensureModel { p in update(progress: p) }
// let result = try await separator.separate(mediaURL: song,
//                                           toVocalURL: vocal,
//                                           toInstrumentalURL: inst) { p in update(progress: p) }
// ```
//
// 取消：`separate` 内部每个 chunk 都检查 `Task.checkCancellation()`；把调用包在
// `Task` 里 `cancel()` 即可，会抛 `CancellationError` 并清理本次临时输出。

public final class VocalSeparator: @unchecked Sendable {

    /// 伴奏怎么得到：混音 − 人声（残差）、模型直接输出的伴奏，或两者平均。
    public enum InstrumentalSource: String, Sendable { case residual, model, blend }

    /// 实验开关（命令行评估用）。分块重叠：hop = chunk / overlap。
    nonisolated(unsafe) public static var overlap = 2
    nonisolated(unsafe) public static var instrumentalSource: InstrumentalSource = .residual

    public let modelInfo: VocalSeparationModelInfo

    private let lock = NSLock()
    private var _status: VocalSeparationModelStatus
    private var installTask: Task<URL, Error>?

    public init(modelInfo: VocalSeparationModelInfo = .mdx23cInstVocHQ) {
        self.modelInfo = modelInfo
        if let compiled = VocalSeparationModelInstaller.validCompiledModelURL(info: modelInfo) {
            _status = .ready(compiledModelURL: compiled)
        } else {
            _status = .notInstalled
        }
    }

    // MARK: 状态 / 缓存位置

    public var modelStatus: VocalSeparationModelStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// 模型安装 / 编译缓存目录（调用时创建）。
    public static func modelCacheDirectory() throws -> URL {
        let url = try VocalSeparationModelInstaller.installRoot()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 不抛错的缓存目录版本，方便 UI 直接展示。
    public var modelCacheURL: URL? {
        try? Self.modelCacheDirectory()
    }

    /// 已安装可直接推理的编译产物 URL；未安装返回 nil。
    public func cachedCompiledModelURL() -> URL? {
        VocalSeparationModelInstaller.validCompiledModelURL(info: modelInfo)
    }

    // MARK: 安装

    /// 首次安装（或修复）：下载 → 校验长度/摘要 → 安全解压 → 编译并缓存。
    /// 已安装时直接返回，并回调一次 `progress(1.0)`。
    @discardableResult
    public func ensureModel(progress: ((Double) -> Void)? = nil) async throws -> URL {
        if let compiled = VocalSeparationModelInstaller.validCompiledModelURL(info: modelInfo) {
            setStatus(.ready(compiledModelURL: compiled))
            progress?(1.0)
            return compiled
        }

        let task = installTaskOrCreate {
            let info = self.modelInfo
            return Task<URL, Error> { [weak self] in
                try await VocalSeparationModelInstaller.ensureInstalled(
                    info: info,
                    progress: progress,
                    status: { status in self?.setStatus(status) })
            }
        }

        do {
            let url = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearInstallTask()
            return url
        } catch {
            clearInstallTask()
            throw error
        }
    }

    // MARK: 分离

    /// 把 `mediaURL` 分离为独立的 Float32 立体声 WAV：`toVocalURL` 与 `toInstrumentalURL`。
    /// 两个文件都与输入等长、44.1 kHz；instrumental = mix − vocal 残差。
    /// 模型未安装时会自动先安装，安装进度占 0...0.1，分离进度占 0.1...1.0。
    @discardableResult
    public func separate(mediaURL: URL,
                         toVocalURL vocalURL: URL,
                         toInstrumentalURL instrumentalURL: URL,
                         progress: ((Double) -> Void)? = nil) async throws -> VocalSeparationResult {

        let preinstalled = cachedCompiledModelURL()
        let compiled: URL
        let base: Double
        let scale: Double
        if let preinstalled {
            compiled = preinstalled
            base = 0
            scale = 1
        } else {
            compiled = try await ensureModel { value in progress?(value * 0.1) }
            base = 0.1
            scale = 0.9
        }

        let info = modelInfo
        let work = Task.detached(priority: .userInitiated) { () throws -> VocalSeparationResult in
            try Self.performSeparation(mediaURL: mediaURL,
                                       vocalURL: vocalURL,
                                       instrumentalURL: instrumentalURL,
                                       compiledModelURL: compiled,
                                       info: info,
                                       progress: { value in progress?(base + value * scale) })
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: 内部

    private func setStatus(_ status: VocalSeparationModelStatus) {
        lock.lock()
        _status = status
        lock.unlock()
    }

    private func clearInstallTask() {
        lock.lock()
        installTask = nil
        lock.unlock()
    }

    /// 同步的加锁辅助，避免在 async 上下文里直接调用 `NSLock.lock()`（Swift 6 会报错）。
    private func installTaskOrCreate(_ make: () -> Task<URL, Error>) -> Task<URL, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = installTask { return existing }
        let task = make()
        installTask = task
        return task
    }

    /// 全部为同步 CPU/GPU 工作，由 `separate` 在 detached task 里调用，避免占住主线程。
    static func performSeparation(mediaURL: URL,
                                  vocalURL: URL,
                                  instrumentalURL: URL,
                                  compiledModelURL: URL,
                                  info: VocalSeparationModelInfo,
                                  progress: ((Double) -> Void)?) throws -> VocalSeparationResult {
        var reporter = VocalSeparationProgressReporter(callback: progress)
        try Task.checkCancellation()

        try VocalSeparationPaths.validate(mediaURL: mediaURL, vocalURL: vocalURL, instrumentalURL: instrumentalURL)
        reporter.report(0.02)

        let decoded = try VocalStereoDecoder.decodeStereo(url: mediaURL)
        try Task.checkCancellation()
        reporter.report(0.10)

        guard let stft = VocalSeparationSTFT() else {
            throw VocalSeparationError.engineSetupFailed("无法创建 vDSP DFT setup")
        }
        let model: VocalSeparationCoreMLModel
        do {
            model = try VocalSeparationCoreMLModel(compiledModelURL: compiledModelURL, info: info)
        } catch let error as VocalSeparationError {
            throw error
        } catch {
            throw VocalSeparationError.engineSetupFailed(error.localizedDescription)
        }
        reporter.report(0.12)

        let (vocal, modelInstrumental) = try separateChunks(decoded.channels,
                                       model: model,
                                       stft: stft,
                                       info: info,
                                       progress: { value in reporter.report(0.12 + value * 0.78) })
        try Task.checkCancellation()

        // 残差保证 vocal + instrumental == mix；之后各自做峰值限制，避免单独使用伴奏时削波破音。
        let residual = VocalOverlapAdd.residual(mix: decoded.channels, vocal: vocal)
        let rawInstrumental: [[Float]]
        switch instrumentalSource {
        case .residual: rawInstrumental = residual
        case .model: rawInstrumental = modelInstrumental
        case .blend:
            rawInstrumental = zip(residual, modelInstrumental).map { a, b in
                zip(a, b).map { ($0 + $1) * 0.5 }
            }
        }
        let instrumental = VocalPeakLimiter.limited(rawInstrumental, sampleRate: decoded.sampleRate)
        let limitedVocal = VocalPeakLimiter.limited(vocal, sampleRate: decoded.sampleRate)
        reporter.report(0.92)

        try writeOutputs(vocal: limitedVocal,
                         instrumental: instrumental,
                         sampleRate: decoded.sampleRate,
                         vocalURL: vocalURL,
                         instrumentalURL: instrumentalURL)
        reporter.complete()

        return VocalSeparationResult(duration: decoded.duration,
                                     sampleRate: decoded.sampleRate,
                                     frameCount: decoded.frameCount,
                                     vocalURL: vocalURL,
                                     instrumentalURL: instrumentalURL)
    }

    /// STFT → Core ML → ISTFT → 50% 重叠相加。每个 chunk 检查取消。
    static func separateChunks(_ stereo: [[Float]],
                               model: VocalSeparationCoreMLModel,
                               stft: VocalSeparationSTFT,
                               info: VocalSeparationModelInfo,
                               progress: ((Double) -> Void)?) throws -> (vocal: [[Float]], instrumental: [[Float]]) {
        guard stereo.count >= 2, !stereo[0].isEmpty else {
            throw VocalSeparationError.audioEmpty
        }
        let n = stereo[0].count
        let chunk = info.chunkSampleCount
        let hop = chunk / max(2, overlap)
        let window = VocalSeparationChunking.hannWindow(length: chunk)
        let starts = VocalSeparationChunking.chunkStarts(sampleCount: n, chunk: chunk, hop: hop)

        var vocalSum = VocalOverlapAdd(sampleCount: n)
        var instrumentalSum = VocalOverlapAdd(sampleCount: n)
        let wantsModelInstrumental = instrumentalSource != .residual
        var reporter = VocalSeparationProgressReporter(callback: progress)
        let stemSize = info.dimF * info.frameCount * VocalSeparationCoreMLModel.specChannels

        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            let valid = min(chunk, n - start)
            let left = paddedChunk(stereo[0], start: start, length: chunk, valid: valid)
            let right = paddedChunk(stereo[1], start: start, length: chunk, valid: valid)

            let (spec, frames) = stft.forward([left, right])
            guard frames == info.frameCount else {
                throw VocalSeparationError.modelOutputUnexpected("STFT 帧数应为 \(info.frameCount)，实际 \(frames)")
            }

            // 让 Core ML 的错误原样抛出，绝不用静音 stem 伪装成功。
            let stems = try model.predict(spec)
            let vocalSpec = Array(stems[0..<stemSize])
            let vocalChunk = stft.inverse(vocalSpec, frames: frames)
            vocalSum.add(vocalChunk, at: start, validCount: valid, window: window)
            if wantsModelInstrumental {
                let instSpec = Array(stems[stemSize..<(2 * stemSize)])
                instrumentalSum.add(stft.inverse(instSpec, frames: frames), at: start, validCount: valid, window: window)
            }

            reporter.report(Double(index + 1) / Double(starts.count))
        }
        return (vocalSum.normalizedVocal(), wantsModelInstrumental ? instrumentalSum.normalizedVocal() : [])
    }

    private static func paddedChunk(_ x: [Float], start: Int, length: Int, valid: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for i in 0..<max(0, valid) { out[i] = x[start + i] }
        return out
    }

    /// 先写同目录隐藏临时文件，两个都成功后再发布到最终路径；
    /// 任一步失败只清本次临时文件，绝不删除用户已有输出。
    static func writeOutputs(vocal: [[Float]],
                             instrumental: [[Float]],
                             sampleRate: Double,
                             vocalURL: URL,
                             instrumentalURL: URL) throws {
        let fm = FileManager.default
        let tempVocal = VocalSeparationPaths.temporarySibling(for: vocalURL)
        let tempInstrumental = VocalSeparationPaths.temporarySibling(for: instrumentalURL)
        var didPublishVocal = false

        do {
            try VocalWAVWriter.write(channels: vocal, sampleRate: sampleRate, to: tempVocal)
            try Task.checkCancellation()
            try VocalWAVWriter.write(channels: instrumental, sampleRate: sampleRate, to: tempInstrumental)
            try Task.checkCancellation()

            try VocalSeparationPaths.publish(tempVocal, to: vocalURL)
            didPublishVocal = true
            try VocalSeparationPaths.publish(tempInstrumental, to: instrumentalURL)
        } catch {
            try? fm.removeItem(at: tempVocal)
            try? fm.removeItem(at: tempInstrumental)
            if didPublishVocal { try? fm.removeItem(at: vocalURL) }
            throw error
        }
        try? fm.removeItem(at: tempVocal)
        try? fm.removeItem(at: tempInstrumental)
    }
}
