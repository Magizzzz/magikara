import Foundation

/// 极简诊断日志。
///
/// 这个 App 是手工组装的 bundle，直接 `open` 启动时看不到 stdout/stderr，
/// 媒体加载这类异步路径出问题时很难定位。所以把关键步骤写到固定文件里，
/// 便于在终端直接 tail。
enum DebugLog {
    static let path = "/tmp/magikara-debug.log"
    private static let queue = DispatchQueue(label: "com.magi.magikara.debuglog")

    static func write(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
