import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 模型元数据
//
// 纯本地 MDX23C Core ML 人声分离后端。这里只描述「模型是什么」，
// 不包含任何下载/推理副作用，方便 UI 与单元测试在无网络、无权重时引用。
//
// 契约来源：Hugging Face `huggingsounds/nubeaudio-mdx` 模型卡
// （`mdx23c_instvoc_hq.mlpackage.zip`，固定 revision）。
public struct VocalSeparationModelInfo: Sendable, Equatable {

    /// 仓库 id（Hugging Face）
    public let repository: String
    /// 固定 revision（commit hash），保证下载内容可复现
    public let revision: String
    /// 压缩包文件名
    public let fileName: String
    /// 解压后顶层 `.mlpackage` 目录名（也是唯一允许出现的顶层路径）
    public let packageName: String
    /// 官方声明的字节数；下载后必须逐字节匹配
    public let expectedByteCount: Int
    /// 官方 LFS 对象的 SHA-256（十六进制小写）；下载后必须匹配
    public let expectedSHA256: String
    /// 许可（模型卡声明 MIT）
    public let licenseName: String

    /// 模型原生采样率（Hz）
    public let sampleRate: Double
    /// STFT 窗长
    public let nFFT: Int
    /// STFT hop
    public let hopLength: Int
    /// 截断后的频点数（丢弃 Nyquist，4097 → 4096）
    public let dimF: Int
    /// 单个 chunk 的采样数
    public let chunkSampleCount: Int
    /// 固定时间帧数
    public let frameCount: Int
    /// Core ML 输入特征名
    public let inputName: String
    /// Core ML 输出特征名
    public let outputName: String
    /// 输出 stem 顺序，索引 0/1
    public let stemNames: [String]

    /// 下载地址（固定 revision；端点跟随配置单选定的下载源）
    public var downloadURL: URL { downloadURL(endpoint: DownloadEndpoints.huggingFace) }

    public func downloadURL(endpoint: String) -> URL {
        URL(string: "\(endpoint)/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    /// 编译产物缓存键：revision + 摘要前缀，避免不同权重互相覆盖。
    public var compiledCacheKey: String {
        "\(packageName)-\(expectedSHA256.prefix(12))"
    }

    /// 本实现固定使用的模型。
    public static let mdx23cInstVocHQ = VocalSeparationModelInfo(
        repository: "huggingsounds/nubeaudio-mdx",
        revision: "a133c157760773700ecbdaadcba755d7e94739c3",
        fileName: "mdx23c_instvoc_hq.mlpackage.zip",
        packageName: "mdx23c_instvoc_hq.mlpackage",
        expectedByteCount: 41_797_322,
        expectedSHA256: "c1d4c475f1d43b64f9e48b8b8e5defe6f41ead6289d1feb9da6480c25246c674",
        licenseName: "MIT",
        sampleRate: 44_100,
        nFFT: 8192,
        hopLength: 1024,
        dimF: 4096,
        chunkSampleCount: 261_120,
        frameCount: 256,
        inputName: "spectrogram",
        outputName: "stems",
        stemNames: ["vocals", "instrumental"])
}

// MARK: - 安装状态

/// 首次安装 / 模型准备状态，供 UI 驱动进度显示。
public enum VocalSeparationModelStatus: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case extracting
    case compiling
    case ready(compiledModelURL: URL)
    case failed(message: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 单调的 0...1 进度值；未知阶段返回 nil。
    public var progressValue: Double? {
        switch self {
        case .notInstalled: return 0
        case .downloading(let p): return max(0, min(1, p))
        case .verifying: return 0.85
        case .extracting: return 0.92
        case .compiling: return 0.97
        case .ready: return 1
        case .failed: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .notInstalled: return "未安装"
        case .downloading: return "下载模型"
        case .verifying: return "校验模型"
        case .extracting: return "解压模型"
        case .compiling: return "编译模型"
        case .ready: return "就绪"
        case .failed(let message): return "失败：\(message)"
        }
    }
}

// MARK: - 结果

/// 分离完成后的可核对信息；两个 WAV 都保证与输入等长、44.1 kHz、Float32 立体声。
public struct VocalSeparationResult: Sendable {
    /// 媒体时长（秒），由实际解出的采样数决定
    public let duration: TimeInterval
    /// 输出采样率（模型原生 44100）
    public let sampleRate: Double
    /// 每个声道的采样数（两个文件一致）
    public let frameCount: Int
    public let vocalURL: URL
    public let instrumentalURL: URL
}

// MARK: - 错误

public enum VocalSeparationError: LocalizedError, Equatable {
    // 安装
    case modelNotInstalled
    case downloadFailed(String)
    case downloadLengthMismatch(expected: Int, actual: Int)
    case downloadDigestMismatch(expected: String, actual: String)
    case archiveUnsupported(String)
    case archiveCorrupt(String)
    case archiveUnsafeEntry(String)
    case archiveMissingPackage(String)
    case modelCompileFailed(String)
    // 推理
    case engineSetupFailed(String)
    case modelPredictionFailed(String)
    case modelOutputUnexpected(String)
    // 媒体
    case mediaMissing(URL)
    case mediaHasNoAudioTrack
    case mediaDecodeFailed(String)
    case audioEmpty
    // 输出
    case invalidOutputPath(String)
    case outputDirectoryMissing(URL)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "分离模型尚未安装，请先调用 ensureModel(progress:)"
        case .downloadFailed(let m):
            return "模型下载失败：\(m)"
        case .downloadLengthMismatch(let expected, let actual):
            return "模型下载长度不匹配（应为 \(expected) 字节，实际 \(actual) 字节），已中止"
        case .downloadDigestMismatch(let expected, let actual):
            return "模型下载摘要不匹配（应为 \(expected)，实际 \(actual)），已中止"
        case .archiveUnsupported(let m):
            return "不支持的模型压缩包：\(m)"
        case .archiveCorrupt(let m):
            return "模型压缩包损坏：\(m)"
        case .archiveUnsafeEntry(let name):
            return "模型压缩包包含不安全的路径，已拒绝：\(name)"
        case .archiveMissingPackage(let name):
            return "模型压缩包里找不到预期的 \(name)"
        case .modelCompileFailed(let m):
            return "模型编译失败：\(m)"
        case .engineSetupFailed(let m):
            return "分离引擎初始化失败：\(m)"
        case .modelPredictionFailed(let m):
            return "Core ML 推理失败：\(m)"
        case .modelOutputUnexpected(let m):
            return "Core ML 输出不符合契约：\(m)"
        case .mediaMissing(let url):
            return "媒体文件不存在或不可读：\(url.lastPathComponent)"
        case .mediaHasNoAudioTrack:
            return "媒体里没有音频轨道"
        case .mediaDecodeFailed(let m):
            return "媒体解码失败：\(m)"
        case .audioEmpty:
            return "解码出的音频为空"
        case .invalidOutputPath(let m):
            return "输出路径不合法：\(m)"
        case .outputDirectoryMissing(let url):
            return "输出目录不存在：\(url.path)"
        case .writeFailed(let m):
            return "写入 WAV 失败：\(m)"
        }
    }
}

// MARK: - 进度上报
//
// 把「下载 / 校验 / 解压 / 编译 / 分块推理」各阶段的进度安全地压进
// 单调不减的 0...1，避免 UI 进度条因阶段复位而后退。纯函数式，可单测。

struct VocalSeparationProgressReporter {
    private var last: Double = -1
    private let callback: ((Double) -> Void)?

    init(callback: ((Double) -> Void)? = nil) {
        self.callback = callback
    }

    /// 只在数值上升时转发；自动夹到 0...1。
    mutating func report(_ value: Double) {
        let clamped = max(0, min(1, value))
        guard clamped > last + 1e-9 else { return }
        last = clamped
        callback?(clamped)
    }

    mutating func complete() {
        report(1.0)
    }
}

// MARK: - 摘要校验

enum VocalSeparationIntegrity {
    /// 流式计算文件 SHA-256（十六进制小写）；不一次性把文件读进内存。
    static func sha256Hex(of url: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw VocalSeparationError.modelCompileFailed("本平台缺少 CryptoKit，无法校验模型摘要")
        #endif
    }
}
