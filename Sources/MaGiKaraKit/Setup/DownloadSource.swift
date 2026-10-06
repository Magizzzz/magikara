import Foundation

// MARK: - 下载源
//
// 别人的电脑可能在国内：huggingface.co、GitHub（Python 安装包）、pypi.org 经常连不上或很慢。
// 配置单默认「自动」：先试官方源，几秒内连不上就整体切到国内镜像。
// 三类下载各有一组地址，同一次安装里保持一致，避免一半官方一半镜像难以排查。

public enum DownloadSourcePreference: String, CaseIterable, Sendable, Identifiable {
    case automatic, official, china

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "自动选择"
        case .official: return "官方源"
        case .china: return "国内镜像"
        }
    }

    private static let defaultsKey = "runtimeDownloadSource"

    public static var saved: DownloadSourcePreference {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(DownloadSourcePreference.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

public struct DownloadSource: Sendable, Equatable {
    public let name: String
    /// Hugging Face 兼容端点（模型权重）
    public let huggingFace: String
    /// PyPI 简单索引（torch 等依赖）
    public let pythonPackageIndex: String?
    /// uv 下载 Python 解释器的镜像（python-build-standalone）；nil 用 uv 默认的 GitHub
    public let pythonInstallMirror: String?

    public static let official = DownloadSource(
        name: "官方源",
        huggingFace: "https://huggingface.co",
        pythonPackageIndex: nil,
        pythonInstallMirror: nil)

    public static let china = DownloadSource(
        name: "国内镜像",
        huggingFace: "https://hf-mirror.com",
        pythonPackageIndex: "https://mirrors.aliyun.com/pypi/simple",
        pythonInstallMirror: "https://registry.npmmirror.com/-/binary/python-build-standalone")

    /// 按偏好决定下载源；「自动」时探测官方源能否在几秒内连上。
    public static func resolve(_ preference: DownloadSourcePreference) async -> DownloadSource {
        switch preference {
        case .official: return .official
        case .china: return .china
        case .automatic:
            async let hf = reachable("https://huggingface.co/api/models/NextFire/mms-300m-ForcedAligner-karaoke-ja-Latn")
            async let pypi = reachable("https://pypi.org/simple/pykakasi/")
            async let github = reachable("https://github.com/astral-sh/python-build-standalone/releases")
            let results = await [hf, pypi, github]
            return results.allSatisfy { $0 } ? .official : .china
        }
    }

    static func reachable(_ string: String, timeout: TimeInterval = 6) async -> Bool {
        guard let url = URL(string: string) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

/// 当前生效的 Hugging Face 端点。配置单选定下载源后改写；
/// 其它地方（例如分析时临时补装人声分离模型）也跟着走同一个源。
public enum DownloadEndpoints {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _huggingFace = "https://huggingface.co"

    public static var huggingFace: String {
        get { lock.lock(); defer { lock.unlock() }; return _huggingFace }
        set { lock.lock(); _huggingFace = newValue; lock.unlock() }
    }
}
