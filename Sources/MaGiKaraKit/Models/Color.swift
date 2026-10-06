import Foundation
import AppKit

/// 与平台无关的 RGBA 颜色，工程文件里直接 Codable 保存。
public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let white = RGBAColor(1, 1, 1, 1)
    public static let black = RGBAColor(0, 0, 0, 1)
    public static let clear = RGBAColor(0, 0, 0, 0)

    /// MaGi 系列主强调色：淡紫蓝
    public static let magiViolet = RGBAColor(0.545, 0.482, 0.910)
    /// MaGi 系列次强调色：蓝紫
    public static let magiBlue = RGBAColor(0.404, 0.478, 0.937)

    /// ASS 使用 &HAABBGGRR，且 **alpha 是反的**：0x00 = 完全不透明，0xFF = 全透明。
    public var assColor: String {
        func c(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        let alphaByte = c(1 - a)      // 不透明度 1 → 0x00
        return String(format: "&H%02X%02X%02X%02X", alphaByte, c(b), c(g), c(r))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    /// 与另一个颜色做线性插值，t=0 返回 self。
    public func mixed(with other: RGBAColor, t: Double) -> RGBAColor {
        let k = max(0, min(1, t))
        return RGBAColor(r + (other.r - r) * k,
                         g + (other.g - g) * k,
                         b + (other.b - b) * k,
                         a + (other.a - a) * k)
    }

    public var hexString: String {
        func c(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

// MARK: - 通用数值/时间格式工具（App 与 Kit 共用）

public extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    /// 00:42.3 形式的时间码
    var timecode: String {
        let t = max(0, self)
        let m = Int(t) / 60
        let s = Int(t) % 60
        let d = Int(((t - floor(t)) * 10).rounded(.down))
        return String(format: "%02d:%02d.%d", m, s, min(9, d))
    }

    /// 00:00 形式（时间尺用）
    var rulerLabel: String {
        let t = max(0, self)
        return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
