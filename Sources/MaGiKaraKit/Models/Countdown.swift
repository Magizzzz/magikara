import Foundation

/// 倒计时的表现方式。
public enum CountdownMode: String, Codable, CaseIterable, Sendable {
    /// 圆点随时间被「走轨色」逐个填满（像歌词扫色一样）。
    case fill
    /// 圆点逐个熄灭（3 → 2 → 1）。
    case dwindle

    public var displayName: String {
        switch self {
        case .fill: return "逐点走轨填色"
        case .dwindle: return "逐点熄灭"
        }
    }
}

/// 倒计时的样式（全局，所有倒计时块共用；在检查面板里编辑）。
public struct CountdownStyle: Codable, Hashable, Sendable {
    public static let dotCountRange = 1...6

    public var mode: CountdownMode
    public var dotCount: Int
    /// 圆点直径 = 主字号 × sizeFactor（最小 8）。
    public var sizeFactor: Double
    /// 圆点之间的空隙 = 主字号 × spacingFactor。
    public var spacingFactor: Double
    /// 相对「下一句歌词所在位置」的偏移（画布像素，1920×1080）。
    public var offsetX: Double
    public var offsetY: Double
    /// 未走轨的颜色；nil = 跟随歌词的未唱色。
    public var unsungColor: RGBAColor?
    /// 走轨（填满）的颜色；nil = 跟随歌词的已唱色。
    public var sweepColor: RGBAColor?

    public init(mode: CountdownMode = .fill,
                dotCount: Int = 3,
                sizeFactor: Double = 0.26,
                spacingFactor: Double = 0.22,
                offsetX: Double = 0,
                offsetY: Double = 0,
                unsungColor: RGBAColor? = nil,
                sweepColor: RGBAColor? = nil) {
        self.mode = mode
        self.dotCount = min(max(dotCount, Self.dotCountRange.lowerBound), Self.dotCountRange.upperBound)
        self.sizeFactor = sizeFactor
        self.spacingFactor = spacingFactor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.unsungColor = unsungColor
        self.sweepColor = sweepColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CountdownStyle()
        mode = try c.decodeIfPresent(CountdownMode.self, forKey: .mode) ?? d.mode
        let count = try c.decodeIfPresent(Int.self, forKey: .dotCount) ?? d.dotCount
        dotCount = min(max(count, Self.dotCountRange.lowerBound), Self.dotCountRange.upperBound)
        sizeFactor = try c.decodeIfPresent(Double.self, forKey: .sizeFactor) ?? d.sizeFactor
        spacingFactor = try c.decodeIfPresent(Double.self, forKey: .spacingFactor) ?? d.spacingFactor
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
        unsungColor = try c.decodeIfPresent(RGBAColor.self, forKey: .unsungColor)
        sweepColor = try c.decodeIfPresent(RGBAColor.self, forKey: .sweepColor)
    }
}

/// 时间线「倒计时」轨道上的一个色块：色块存在的这段时间，画面上显示倒计时圆点。
public struct CountdownItem: Codable, Identifiable, Equatable, Sendable {
    public static let minimumDuration: Double = 0.3

    public var id: UUID
    public var start: Double
    public var end: Double
    /// 自动生成并跟随第一句歌词的开头倒计时。用户一旦手动改动它，就变成普通倒计时、不再被自动改回。
    public var isAuto: Bool

    public init(id: UUID = UUID(), start: Double, end: Double, isAuto: Bool = false) {
        self.id = id
        self.start = start
        self.end = max(end, start + Self.minimumDuration)
        self.isAuto = isAuto
    }

    public var duration: Double { max(0, end - start) }
}
