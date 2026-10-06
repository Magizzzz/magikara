import Foundation
import AppKit

/// 打包资源访问。App 既可能以 SwiftPM 可执行文件运行（Bundle.module），
/// 也可能在手工组装的 .app 里运行（Contents/Resources），这里都试一遍。
public enum MaGiKaraResources {

    /// 顶部播放器的银河/角色背景。它是装饰层，找不到时 UI 会自动退回纯玻璃背景。
    public static func headerImage() -> NSImage? {
        image(named: "magikara-header-cosmic-character-v1", extension: "png")
    }

    public static func logoImage() -> NSImage? {
        image(named: "logo", extension: "png")
    }

    public static var logoURL: URL? {
        imageURL(named: "logo", extension: "png")
    }

    private static func image(named name: String, extension: String) -> NSImage? {
        guard let url = imageURL(named: name, extension: `extension`) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func imageURL(named name: String, extension: String) -> URL? {
        for bundle in [Bundle.module, Bundle.main] {
            if let url = bundle.url(forResource: name, withExtension: `extension`) { return url }
        }

        // 手工组装的 .app 将设计资源放在 Contents/Resources；开发态则放在工程根目录。
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let exeDir = executable.deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("\(name).\(`extension`)", isDirectory: false),
            exeDir.appendingPathComponent("MaGiKara_MaGiKaraKit.bundle/\(name).\(`extension`)", isDirectory: false),
            exeDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("\(name).\(`extension`)", isDirectory: false),
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}
