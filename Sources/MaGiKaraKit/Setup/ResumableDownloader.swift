import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 可续传下载
//
// 对轨模型有 1.26 GB，别人家里网络断一次就从头来是不能接受的。
// 这里边下边写 `<目标>.part`，再次开始时带 `Range` 从已有字节续传；
// 完成后校验长度（和可选的 SHA-256），通过才改名为正式文件。

public enum ResumableDownloadError: LocalizedError {
    case http(Int, URL)
    case lengthMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "下载失败（HTTP \(code)）：\(url.lastPathComponent)"
        case .lengthMismatch(let expected, let actual):
            return "文件大小不对（应为 \(expected) 字节，实际 \(actual)）"
        case .digestMismatch: return "文件校验失败（SHA-256 不一致），已删除，请重试"
        case .transport(let message): return "网络错误：\(message)"
        }
    }
}

public final class ResumableDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// (本文件已下载字节, 本文件总字节；未知为 nil)
    public typealias Progress = @Sendable (Int64, Int64?) -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var onProgress: Progress?
    private var lastReport = Date.distantPast
    private var userCancelled = false

    public override init() {}

    /// 下载到 `destination`。`expectedBytes` 有值时同时用于续传判断与最终校验。
    public func download(from url: URL,
                         to destination: URL,
                         expectedBytes: Int64? = nil,
                         sha256: String? = nil,
                         progress: Progress? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }
        var existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expectedBytes, existing > expectedBytes {
            try? fm.removeItem(at: part)
            fm.createFile(atPath: part.path, contents: nil)
            existing = 0
        }

        if let expectedBytes, existing == expectedBytes {
            progress?(existing, expectedBytes)
        } else {
            try await fetch(url: url, part: part, offset: existing, expectedBytes: expectedBytes, progress: progress)
        }

        let actual = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
        if let expectedBytes, actual != expectedBytes {
            // 长度不对时 .part 很可能被中间人页面污染，留着只会一直续传失败
            try? fm.removeItem(at: part)
            throw ResumableDownloadError.lengthMismatch(expected: expectedBytes, actual: actual)
        }
        if let sha256 {
            let digest = try Self.sha256Hex(of: part)
            guard digest == sha256.lowercased() else {
                try? fm.removeItem(at: part)
                throw ResumableDownloadError.digestMismatch
            }
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: part, to: destination)
    }

    private func fetch(url: URL, part: URL, offset: Int64, expectedBytes: Int64?, progress: Progress?) async throws {
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        lock.withLock {
            self.handle = handle
            self.received = offset
            self.total = expectedBytes
            self.failure = nil
            self.userCancelled = false
            self.onProgress = progress
        }
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 6 * 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.userCancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession,
                           dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        switch http.statusCode {
        case 206:
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/"),
               let size = Int64(range[range.index(after: slash)...]) {
                total = size
            }
            completionHandler(.allow)
        case 200:
            // 服务器不支持续传：从头写
            if received > 0 {
                try? handle?.truncate(atOffset: 0)
                received = 0
            }
            if http.expectedContentLength > 0 { total = http.expectedContentLength }
            completionHandler(.allow)
        case 416:
            // 已经下完（Range 超出末尾），交给长度校验
            total = received
            completionHandler(.cancel)
        default:
            failure = ResumableDownloadError.http(http.statusCode, http.url ?? URL(fileURLWithPath: "/"))
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastReport) > 0.2
        if shouldReport { lastReport = now }
        let received = self.received, total = self.total, callback = onProgress
        lock.unlock()
        if shouldReport { callback?(received, total) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let received = self.received, total = self.total, callback = onProgress
        let userCancelled = self.userCancelled
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        callback?(received, total)

        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                // 416 也会走到这里：当作完成，交给长度校验
                if userCancelled { continuation?.resume(throwing: CancellationError()) }
                else if let total, received >= total { continuation?.resume() }
                else { continuation?.resume(throwing: CancellationError()) }
            } else {
                continuation?.resume(throwing: ResumableDownloadError.transport(error.localizedDescription))
            }
        } else {
            continuation?.resume()
        }
    }

    // MARK: 校验

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
