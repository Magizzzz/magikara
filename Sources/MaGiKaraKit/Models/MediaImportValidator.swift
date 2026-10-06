import Foundation
import UniformTypeIdentifiers

/// 导入媒体的校验结果。
public enum MediaImportDecision: Equatable, Sendable {
    case accept(kind: MediaKind)
    case reject(reason: String)

    public var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }

    public var message: String? {
        if case .reject(let r) = self { return r }
        return nil
    }
}

public enum MediaKind: String, Sendable {
    case video
    case audio

    public var displayName: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
}

/// 拖放/选择导入的校验器。
///
/// 单独抽出来是为了能写回归测试：拖入一个 .txt、拖入不存在的文件、
/// 拖入重复文件这些情况都不该让 UI 卡住或静默失败。
public enum MediaImportValidator {

    /// 支持的扩展名（RD §2：mp4 / mov / mp3 / wav，另含常见容器）
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac"]

    public static var allExtensions: Set<String> { videoExtensions.union(audioExtensions) }

    public static func kind(forExtension ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if videoExtensions.contains(e) { return .video }
        if audioExtensions.contains(e) { return .audio }
        return nil
    }

    /// 校验一个待导入的文件 URL。会检查：是本地文件、存在、是普通文件、扩展名受支持。
    public static func validate(_ url: URL,
                                fileManager: FileManager = .default) -> MediaImportDecision {
        guard url.isFileURL else {
            return .reject(reason: "只支持本地文件")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .reject(reason: "文件不存在：\(url.lastPathComponent)")
        }
        if isDirectory.boolValue {
            return .reject(reason: "这是一个文件夹，请拖入视频或音频文件")
        }
        guard let kind = kind(forExtension: url.pathExtension) else {
            let ext = url.pathExtension.isEmpty ? "（无扩展名）" : ".\(url.pathExtension)"
            return .reject(reason: "不支持的文件类型 \(ext)")
        }
        return .accept(kind: kind)
    }

    /// 从一组拖入的 URL 里挑第一个可用的。
    /// 返回 (可用的, 被拒绝的说明列表) —— 让界面能一次说清为什么没用。
    public static func firstAcceptable(from urls: [URL],
                                       fileManager: FileManager = .default)
        -> (accepted: (url: URL, kind: MediaKind)?, rejections: [String]) {
        var rejections: [String] = []
        for url in urls {
            switch validate(url, fileManager: fileManager) {
            case .accept(let kind):
                return ((url, kind), rejections)
            case .reject(let reason):
                rejections.append(reason)
            }
        }
        return (nil, rejections)
    }

    /// 拖动预览用的内容类型（只声明文件 URL，避免系统去解码内容）
    public static var dropContentTypes: [UTType] {
        [.fileURL]
    }
}
