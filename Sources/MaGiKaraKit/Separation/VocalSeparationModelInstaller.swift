import CoreML
import Foundation

// MARK: - 安装记录
//
// 只有「marker 存在 + revision/长度/摘要匹配 + 已编译产物存在」才算安装有效。
// 任何一步不符都会走重新安装，不会拿旧/半成品文件冒充有效模型。

struct VocalSeparationInstallRecord: Codable {
    let revision: String
    let fileName: String
    let byteCount: Int
    let sha256: String
    let installedAt: Date
}

// MARK: - 模型安装器

enum VocalSeparationModelInstaller {

    static let installSubdirectory = "MaGiKara/VocalSeparation"

    // MARK: 路径

    /// 安装根目录（应用 Caches 之下；编译产物与解压后的模型都放这里）。
    static func installRoot() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MAGIKARA_SUPPORT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("VocalSeparation", isDirectory: true)
        }
        let base = try FileManager.default.url(for: .cachesDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent(installSubdirectory, isDirectory: true)
    }

    static func compiledModelsDirectory(root: URL) -> URL {
        root.appendingPathComponent("CompiledModels", isDirectory: true)
    }

    static func installedPackageURL(root: URL, info: VocalSeparationModelInfo) -> URL {
        root.appendingPathComponent(info.packageName, isDirectory: true)
    }

    static func compiledModelURL(root: URL, info: VocalSeparationModelInfo) -> URL {
        compiledModelsDirectory(root: root)
            .appendingPathComponent("\(info.compiledCacheKey).mlmodelc", isDirectory: true)
    }

    static func recordURL(root: URL) -> URL {
        root.appendingPathComponent("Installation.json")
    }

    static func loadRecord(root: URL) -> VocalSeparationInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL(root: root)) else { return nil }
        return try? JSONDecoder().decode(VocalSeparationInstallRecord.self, from: data)
    }

    /// 已安装且可直接用于推理时返回编译产物 URL，否则 nil。
    static func validCompiledModelURL(info: VocalSeparationModelInfo) -> URL? {
        guard let root = try? installRoot(),
              let record = loadRecord(root: root),
              record.revision == info.revision,
              record.sha256 == info.expectedSHA256,
              record.byteCount == info.expectedByteCount else { return nil }

        let compiled = compiledModelURL(root: root, info: info)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: compiled.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return compiled
    }

    // MARK: 安装

    /// 首次安装：下载 → 校验长度/摘要 → 安全解压 → 编译 → 写 marker。
    /// 进度单调 0...1；任何失败都会清掉本次 staging（不碰用户已有文件）。
    static func ensureInstalled(
        info: VocalSeparationModelInfo = .mdx23cInstVocHQ,
        progress: ((Double) -> Void)? = nil,
        status: ((VocalSeparationModelStatus) -> Void)? = nil
    ) async throws -> URL {
        var reporter = VocalSeparationProgressReporter(callback: progress)

        if let compiled = validCompiledModelURL(info: info) {
            reporter.complete()
            status?(.ready(compiledModelURL: compiled))
            return compiled
        }

        let fm = FileManager.default
        let root = try installRoot()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let compiledDir = compiledModelsDirectory(root: root)
        try fm.createDirectory(at: compiledDir, withIntermediateDirectories: true)

        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let workDir = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent(info.fileName)
        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        let installedPackage = installedPackageURL(root: root, info: info)
        let compiledDest = compiledModelURL(root: root, info: info)

        // 已解压的 mlpackage 仍然匹配当前 revision/摘要时，直接重新编译，
        // 不重复下载 40 MB（例如只剩编译缓存被系统清理掉了）。
        let record = loadRecord(root: root)
        let markerMatches = record?.revision == info.revision
            && record?.sha256 == info.expectedSHA256
            && record?.byteCount == info.expectedByteCount
        if markerMatches, fm.fileExists(atPath: installedPackage.path) {
            status?(.compiling)
            let compiledTemp: URL
            do {
                compiledTemp = try await MLModel.compileModel(at: installedPackage)
            } catch {
                throw VocalSeparationError.modelCompileFailed(error.localizedDescription)
            }
            if fm.fileExists(atPath: compiledDest.path) {
                try? fm.removeItem(at: compiledTemp)
            } else {
                try fm.moveItem(at: compiledTemp, to: compiledDest)
            }
            reporter.complete()
            status?(.ready(compiledModelURL: compiledDest))
            return compiledDest
        }

        do {
            // 1. 下载
            status?(.downloading(progress: 0))
            let downloader = VocalModelDownloader(stagingURL: zipURL) { fraction in
                status?(.downloading(progress: fraction))
                reporter.report(fraction * 0.8)
            }
            try await downloader.download(from: info.downloadURL)
            try Task.checkCancellation()

            // 2. 校验长度 + 摘要
            status?(.verifying)
            let attributes = try? fm.attributesOfItem(atPath: zipURL.path)
            let actualSize = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            guard actualSize == info.expectedByteCount else {
                throw VocalSeparationError.downloadLengthMismatch(expected: info.expectedByteCount, actual: actualSize)
            }
            let digest = try VocalSeparationIntegrity.sha256Hex(of: zipURL)
            guard digest == info.expectedSHA256 else {
                throw VocalSeparationError.downloadDigestMismatch(expected: info.expectedSHA256, actual: digest)
            }
            reporter.report(0.85)

            // 3. 安全解压，只接受预期 mlpackage 顶层
            status?(.extracting)
            let packageURL = try VocalSeparationArchive.extractPackage(zipURL: zipURL,
                                                                       into: extractDir,
                                                                       expectedTopLevel: info.packageName)
            try Task.checkCancellation()
            reporter.report(0.92)

            // 4. 放入安装目录。到这里已确认没有有效安装，替换半成品是安全的。
            if fm.fileExists(atPath: installedPackage.path) {
                try fm.removeItem(at: installedPackage)
            }
            try fm.moveItem(at: packageURL, to: installedPackage)

            // 5. 编译并缓存
            status?(.compiling)
            let compiledTemp: URL
            do {
                compiledTemp = try await MLModel.compileModel(at: installedPackage)
            } catch {
                throw VocalSeparationError.modelCompileFailed(error.localizedDescription)
            }
            if fm.fileExists(atPath: compiledDest.path) {
                try? fm.removeItem(at: compiledTemp)
            } else {
                try fm.moveItem(at: compiledTemp, to: compiledDest)
            }
            reporter.report(0.99)

            // 6. marker（只有走到这里才算安装完成）
            let newRecord = VocalSeparationInstallRecord(revision: info.revision,
                                                         fileName: info.fileName,
                                                         byteCount: info.expectedByteCount,
                                                         sha256: info.expectedSHA256,
                                                         installedAt: Date())
            let encoded = try JSONEncoder().encode(newRecord)
            try encoded.write(to: recordURL(root: root), options: .atomic)

            reporter.complete()
            status?(.ready(compiledModelURL: compiledDest))
            return compiledDest
        } catch is CancellationError {
            cleanUpIncompleteInstall(fm: fm, root: root, installedPackage: installedPackage, compiledDest: compiledDest)
            status?(.notInstalled)
            throw CancellationError()
        } catch {
            cleanUpIncompleteInstall(fm: fm, root: root, installedPackage: installedPackage, compiledDest: compiledDest)
            status?(.failed(message: error.localizedDescription))
            throw error
        }
    }

    /// 只清理「本次未写 marker」的半成品，绝不删除已记录的有效安装。
    private static func cleanUpIncompleteInstall(fm: FileManager, root: URL, installedPackage: URL, compiledDest: URL) {
        guard !fm.fileExists(atPath: recordURL(root: root).path) else { return }
        try? fm.removeItem(at: installedPackage)
        try? fm.removeItem(at: compiledDest)
    }
}

// MARK: - 下载器
//
// 用 URLSessionDownloadDelegate 做「可取消 + 带进度」的下载，下载到 staging
// 临时文件；校验交给调用方。不吞取消：取消时抛 CancellationError。

final class VocalModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let stagingURL: URL
    private let onProgress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var settled = false

    init(stagingURL: URL, onProgress: @escaping (Double) -> Void) {
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        settle(.failure(CancellationError()))
    }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: stagingURL)
            try fm.moveItem(at: location, to: stagingURL)
        } catch {
            settle(.failure(VocalSeparationError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                settle(.failure(CancellationError()))
            } else {
                settle(.failure(VocalSeparationError.downloadFailed(error.localizedDescription)))
            }
            return
        }
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            settle(.success(()))
        } else {
            settle(.failure(VocalSeparationError.downloadFailed("下载完成但没有临时文件")))
        }
    }
}
