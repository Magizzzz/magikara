import Foundation
import CoreGraphics

// 打印指定进程名下最大的可见窗口的 window number。
// 供 Scripts/capture-window.sh 使用。
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MaGiKara"

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

var best: (id: Int, area: Double) = (0, 0)
for entry in list {
    guard let name = entry[kCGWindowOwnerName as String] as? String, name == owner else { continue }
    guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
    // 跳过没有尺寸的辅助窗口
    var area: Double = 0
    if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
       let w = boundsDict["Width"] as? Double,
       let h = boundsDict["Height"] as? Double {
        area = w * h
    }
    if area > best.area { best = (number, area) }
}

if best.id > 0 {
    print(best.id)
} else {
    exit(2)
}
