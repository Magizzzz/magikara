import Foundation

/// 字幕对齐方式（水平）。
public enum SubtitleAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing

    public var displayName: String {
        switch self {
        case .leading: return "左对齐"
        case .center: return "居中"
        case .trailing: return "右对齐"
        }
    }
}

/// 全局字幕轨道的入场/出场方式。
///
/// 这是一个面向“傻瓜式一键生成”的全局设置：不让用户逐句调动画，
/// 只把同一种常用效果一次应用到所有字幕片段。后续可以在这里继续增加
/// 少量稳定、可导出的效果，而不会把时间线变成复杂的特效编辑器。
public enum SubtitleTransitionEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case hardCut
    case fade

    public var displayName: String {
        switch self {
        case .hardCut: return "硬切"
        case .fade: return "淡入淡出"
        }
    }

    /// 预览与 ASS 导出共用的淡化时长。
    public var duration: Double {
        switch self {
        case .hardCut: return 0
        case .fade: return 0.18
        }
    }
}

/// MVP 只提供 RD §10 列出的属性。
public struct SubtitleStyle: Codable, Hashable, Sendable {

    // 主字体
    public var fontName: String
    public var fontSize: Double
    public var fontWeight: Int          // 100...900
    /// 兼容旧工程的统一对齐；新的排版用 `upperAlignment` / `lowerAlignment`。
    public var alignment: SubtitleAlignment
    /// 上下两行各自的水平对齐。上行靠左、下行靠右就是 ニコカラ 常见的「错开」排版。
    /// 旧工程没有这两个字段，解码时都取 `alignment`，所以升级后画面不会变。
    public var upperAlignment: SubtitleAlignment
    public var lowerAlignment: SubtitleAlignment
    /// 靠左 / 靠右对齐时离画面左右边缘的距离（画布 1920 宽下的点）。
    public var horizontalMargin: Double
    public var positionX: Double        // 相对画面中心，点
    public var positionY: Double        // 相对画面中心，点（负值向上）
    /// 上下两条字幕轨道的独立位置偏移。
    ///
    /// 旧工程只有 positionX/positionY，解码时会把旧值复制到两条轨道，
    /// 因此升级后画面不会跳动；之后在预览里拖动只改当前选中的轨道。
    public var upperPositionX: Double
    public var upperPositionY: Double
    public var lowerPositionX: Double
    public var lowerPositionY: Double
    public var lineGap: Double          // 两行间距

    // 全局字幕轨道效果（一次应用到所有歌词片段）
    public var entryEffect: SubtitleTransitionEffect
    public var exitEffect: SubtitleTransitionEffect
    /// 倒计时总开关（关掉后预览与导出都不显示任何倒计时块）。
    public var countdownEnabled: Bool
    /// 倒计时的样式（点数、大小、间距、位置、走轨色……），所有倒计时块共用。
    public var countdown: CountdownStyle

    // 颜色
    public var unsungColor: RGBAColor
    public var sungColor: RGBAColor
    public var sungGradientEnabled: Bool
    public var sungGradientEndColor: RGBAColor

    // 描边
    public var strokeColor: RGBAColor
    public var strokeWidth: Double

    // 阴影
    public var shadowColor: RGBAColor
    public var shadowBlur: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shadowOpacity: Double

    // 假名
    public var rubyFontName: String
    public var rubySizeFactor: Double   // 相对主字号，默认 0.40 (RD: 38%–45%)
    public var rubyVerticalOffset: Double

    /// 把双行字幕块放进「底部安全区」所需的 positionY。
    ///
    /// 坐标系与 ASS 导出一致：画布 1920×1080，每行用 \an5（中心锚点），
    /// 块中心 = canvasHeight/2 + positionY。要让块底边落在
    /// canvasHeight × (1 - bottomMarginRatio) 之上，就得到下面的公式。
    ///
    /// 预览与 ASS 都用这个值，所以「预览所见 = 导出所得」。
    public static func bottomSafeAreaPositionY(fontSize: Double,
                                               lineGap: Double,
                                               canvasHeight: Double = 1080,
                                               bottomMarginRatio: Double = 0.08) -> Double {
        let halfLine = (fontSize + lineGap) / 2
        let bottomEdge = canvasHeight * (1 - bottomMarginRatio)
        let centerY = bottomEdge - halfLine - fontSize * 0.6
        return centerY - canvasHeight / 2
    }

    public init(fontName: String = "Hiragino Sans",
                fontSize: Double = 72,
                fontWeight: Int = 700,
                alignment: SubtitleAlignment = .center,
                upperAlignment: SubtitleAlignment? = nil,
                lowerAlignment: SubtitleAlignment? = nil,
                horizontalMargin: Double = 140,
                positionX: Double = 0,
                positionY: Double = SubtitleStyle.bottomSafeAreaPositionY(fontSize: 72, lineGap: 14),
                upperPositionX: Double? = nil,
                upperPositionY: Double? = nil,
                lowerPositionX: Double? = nil,
                lowerPositionY: Double? = nil,
                lineGap: Double = 14,
                unsungColor: RGBAColor = RGBAColor(1, 1, 1, 1),
                sungColor: RGBAColor = RGBAColor(0.545, 0.482, 0.910, 1),
                sungGradientEnabled: Bool = true,
                sungGradientEndColor: RGBAColor = RGBAColor(0.404, 0.478, 0.937, 1),
                strokeColor: RGBAColor = RGBAColor(0.03, 0.02, 0.05, 1),
                // 7 ≈ 字号的 10%。实测 3 与 5 在真实动画画面上都偏细，
                // 对比源视频自带的字幕（约 11% 的白描边）后定到 10%。
                strokeWidth: Double = 7,
                shadowColor: RGBAColor = RGBAColor(0.10, 0.07, 0.22, 1),
                shadowBlur: Double = 30,
                shadowOffsetX: Double = 0,
                shadowOffsetY: Double = 3,
                shadowOpacity: Double = 0.7,
                rubyFontName: String = "Hiragino Sans",
                rubySizeFactor: Double = 0.40,
                rubyVerticalOffset: Double = -22,
                entryEffect: SubtitleTransitionEffect = .hardCut,
                exitEffect: SubtitleTransitionEffect = .hardCut,
                countdownEnabled: Bool = true,
                countdown: CountdownStyle = CountdownStyle()) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.alignment = alignment
        self.upperAlignment = upperAlignment ?? alignment
        self.lowerAlignment = lowerAlignment ?? alignment
        self.horizontalMargin = horizontalMargin
        self.positionX = positionX
        self.positionY = positionY
        self.upperPositionX = upperPositionX ?? positionX
        self.upperPositionY = upperPositionY ?? positionY
        self.lowerPositionX = lowerPositionX ?? positionX
        self.lowerPositionY = lowerPositionY ?? positionY
        self.lineGap = lineGap
        self.entryEffect = entryEffect
        self.exitEffect = exitEffect
        self.countdownEnabled = countdownEnabled
        self.countdown = countdown
        self.unsungColor = unsungColor
        self.sungColor = sungColor
        self.sungGradientEnabled = sungGradientEnabled
        self.sungGradientEndColor = sungGradientEndColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadowColor = shadowColor
        self.shadowBlur = shadowBlur
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.shadowOpacity = shadowOpacity
        self.rubyFontName = rubyFontName
        self.rubySizeFactor = rubySizeFactor
        self.rubyVerticalOffset = rubyVerticalOffset
    }

    // 容错解码，方便旧工程迁移。
    public init(from decoder: Decoder) throws {
        let d = SubtitleStyle()   // 旧默认值（居中）：缺字段的旧工程必须保持原样，不能被新默认悄悄改掉
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        fontWeight = try c.decodeIfPresent(Int.self, forKey: .fontWeight) ?? d.fontWeight
        alignment = try c.decodeIfPresent(SubtitleAlignment.self, forKey: .alignment) ?? d.alignment
        upperAlignment = try c.decodeIfPresent(SubtitleAlignment.self, forKey: .upperAlignment) ?? alignment
        lowerAlignment = try c.decodeIfPresent(SubtitleAlignment.self, forKey: .lowerAlignment) ?? alignment
        horizontalMargin = try c.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? d.horizontalMargin
        positionX = try c.decodeIfPresent(Double.self, forKey: .positionX) ?? d.positionX
        positionY = try c.decodeIfPresent(Double.self, forKey: .positionY) ?? d.positionY
        upperPositionX = try c.decodeIfPresent(Double.self, forKey: .upperPositionX) ?? positionX
        upperPositionY = try c.decodeIfPresent(Double.self, forKey: .upperPositionY) ?? positionY
        lowerPositionX = try c.decodeIfPresent(Double.self, forKey: .lowerPositionX) ?? positionX
        lowerPositionY = try c.decodeIfPresent(Double.self, forKey: .lowerPositionY) ?? positionY
        lineGap = try c.decodeIfPresent(Double.self, forKey: .lineGap) ?? d.lineGap
        entryEffect = try c.decodeIfPresent(SubtitleTransitionEffect.self, forKey: .entryEffect) ?? d.entryEffect
        exitEffect = try c.decodeIfPresent(SubtitleTransitionEffect.self, forKey: .exitEffect) ?? d.exitEffect
        countdownEnabled = try c.decodeIfPresent(Bool.self, forKey: .countdownEnabled) ?? d.countdownEnabled
        countdown = try c.decodeIfPresent(CountdownStyle.self, forKey: .countdown) ?? d.countdown
        unsungColor = try c.decodeIfPresent(RGBAColor.self, forKey: .unsungColor) ?? d.unsungColor
        sungColor = try c.decodeIfPresent(RGBAColor.self, forKey: .sungColor) ?? d.sungColor
        sungGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .sungGradientEnabled) ?? d.sungGradientEnabled
        sungGradientEndColor = try c.decodeIfPresent(RGBAColor.self, forKey: .sungGradientEndColor) ?? d.sungGradientEndColor
        strokeColor = try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? d.strokeColor
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        shadowColor = try c.decodeIfPresent(RGBAColor.self, forKey: .shadowColor) ?? d.shadowColor
        shadowBlur = try c.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? d.shadowBlur
        shadowOffsetX = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetX) ?? d.shadowOffsetX
        shadowOffsetY = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY) ?? d.shadowOffsetY
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? d.shadowOpacity
        rubyFontName = try c.decodeIfPresent(String.self, forKey: .rubyFontName) ?? d.rubyFontName
        rubySizeFactor = try c.decodeIfPresent(Double.self, forKey: .rubySizeFactor) ?? d.rubySizeFactor
        rubyVerticalOffset = try c.decodeIfPresent(Double.self, forKey: .rubyVerticalOffset) ?? d.rubyVerticalOffset
    }

    /// 新项目的默认样式：参考 ニコカラ 的常见版式——上行靠左、下行靠右（错开），
    /// 行距按「假名放得下」算，整块放进底部安全区。原来的两行都居中不再是默认。
    public static let `default` = Preset.classicKaraoke.style

    /// 旧版本的默认样式（两行都居中）。只给解码旧工程时补缺失字段用。
    public static let legacyDefault = SubtitleStyle()

    /// 某条字幕轨道的水平对齐。
    public func alignment(for lane: ScreenLane) -> SubtitleAlignment {
        lane == .upper ? upperAlignment : lowerAlignment
    }

    /// 一行字幕的**中心**相对画面中心的水平偏移（画布坐标）。预览、ASS 导出和倒计时共用这一个公式，
    /// 所以三处位置永远一致。
    ///
    /// - 居中：就是轨道的 X 偏移；
    /// - 靠左 / 靠右：行的左（右）边缘贴着离画面边缘 `horizontalMargin` 的位置，轨道 X 偏移作为微调；
    /// - 行比可用宽度还宽时退回居中，避免被推出画面。
    public func lineCenterX(for lane: ScreenLane, lineWidth: Double, canvasWidth: Double = 1920) -> Double {
        let offset = position(for: lane).x
        let available = canvasWidth - 2 * horizontalMargin
        switch alignment(for: lane) {
        case .center:
            return offset
        case .leading:
            return lineWidth >= available ? offset : -canvasWidth / 2 + horizontalMargin + lineWidth / 2 + offset
        case .trailing:
            return lineWidth >= available ? offset : canvasWidth / 2 - horizontalMargin - lineWidth / 2 + offset
        }
    }

    /// 读取某条字幕轨道的位置偏移。
    public func position(for lane: ScreenLane) -> (x: Double, y: Double) {
        switch lane {
        case .upper: return (upperPositionX, upperPositionY)
        case .lower: return (lowerPositionX, lowerPositionY)
        }
    }

    /// 只更新某条字幕轨道的位置，不影响另一条轨道。
    public mutating func setPosition(_ position: (x: Double, y: Double), for lane: ScreenLane) {
        switch lane {
        case .upper:
            upperPositionX = position.x
            upperPositionY = position.y
        case .lower:
            lowerPositionX = position.x
            lowerPositionY = position.y
        }
    }

    /// 把两条轨道一起设置为同一位置，用于预设和“吸附到底部安全区”。
    public mutating func setPositionForAllTracks(x: Double? = nil, y: Double? = nil) {
        if let x {
            positionX = x
            upperPositionX = x
            lowerPositionX = x
        }
        if let y {
            positionY = y
            upperPositionY = y
            lowerPositionY = y
        }
    }

    // MARK: 预设（歌词模版）

    /// 歌词模版：一套样式 + 一套换行节奏。前三套是原有的；后面几套参考 ニコカラ 合集的常见做法
    /// （大字粗描边、上行靠左下行靠右、翻页换行、提前约 1.5 秒进场）。
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case classicKaraoke, vocaloidPurpleBlue, minimalMV
        case nicokaraBlue, nicokaraPink, nicokaraGold
        case minchoElegant, roundCute, handwrittenKlee, neonCyber, invertedLight

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .classicKaraoke: return "纯 K 经典"
            case .vocaloidPurpleBlue: return "Vocaloid 紫蓝"
            case .minimalMV: return "极简 MV"
            case .nicokaraBlue: return "ニコカラ·经典蓝"
            case .nicokaraPink: return "ニコカラ·樱粉"
            case .nicokaraGold: return "ニコカラ·金黄"
            case .minchoElegant: return "明朝·文艺"
            case .roundCute: return "圆体·可爱"
            case .handwrittenKlee: return "手写·Klee"
            case .neonCyber: return "霓虹·电子"
            case .invertedLight: return "浅底·深字"
            }
        }

        /// 一句话说明，显示在模版按钮的提示里。
        public var summary: String {
            switch self {
            case .classicKaraoke: return "白字紫扫色，上行靠左、下行靠右，滚动换行"
            case .vocaloidPurpleBlue: return "冷白字紫蓝渐变扫色，辉光阴影，上左下右，滚动换行"
            case .minimalMV: return "细描边、小字号、居中，适合 MV 画面"
            case .nicokaraBlue: return "白字蓝扫色、粗黑描边；翻页换行，提前 1.5 秒，下行晚 0.8 秒"
            case .nicokaraPink: return "圆体、白字粉扫色；翻页换行，提前 1.5 秒，下行晚 0.8 秒"
            case .nicokaraGold: return "白字金黄扫色；翻页换行，提前 1.5 秒，下行晚 0.8 秒"
            case .minchoElegant: return "明朝体、象牙白字朱红扫色；翻页换行，提前 1.2 秒"
            case .roundCute: return "圆体、白字青蓝扫色、深蓝描边；翻页换行"
            case .handwrittenKlee: return "Klee 手写体、奶油白字橙扫色；滚动换行"
            case .neonCyber: return "霓虹粉青渐变、青色辉光；翻页换行"
            case .invertedLight: return "深色字白描边，适合明亮 / 白色背景"
            }
        }

        /// 这套模版的换行节奏：前三套保持原来的滚动；ニコカラ 系列是翻页式。
        public var displayPolicy: DisplayPolicy {
            switch self {
            case .classicKaraoke, .vocaloidPurpleBlue, .minimalMV, .handwrittenKlee, .invertedLight:
                return DisplayPolicy()
            case .minchoElegant:
                return DisplayPolicy(leadIn: 1.2, lastHoldOut: 1.2, adaptToGap: true, mode: .pageFlip,
                                     lowerLineDelay: 0.6, pageGap: 0.4, pageHoldOut: 0.5)
            case .nicokaraBlue, .nicokaraPink, .nicokaraGold, .roundCute, .neonCyber:
                return DisplayPolicy(leadIn: 1.5, lastHoldOut: 1.2, adaptToGap: true, mode: .pageFlip,
                                     lowerLineDelay: 0.8, pageGap: 0.4, pageHoldOut: 0.5)
            }
        }

        /// 模版按钮里的小预览：背景是深色还是浅色。
        public var previewOnLightBackground: Bool { self == .invertedLight }

        /// 上下两行的版式：true = 上行靠左、下行靠右（错开），false = 都居中。
        var staggered: Bool { self != .minimalMV }

        public var style: SubtitleStyle {
            func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> RGBAColor { RGBAColor(r, g, b, a) }
            switch self {
            case .classicKaraoke:
                return Self.make(font: "Hiragino Sans", size: 72, weight: 700,
                                 unsung: rgba(1, 1, 1, 1), sung: rgba(0.545, 0.482, 0.910, 1),
                                 sungEnd: rgba(0.404, 0.478, 0.937, 1),
                                 stroke: rgba(0.03, 0.02, 0.05, 1), strokeWidth: 7,
                                 shadow: rgba(0.10, 0.07, 0.22, 1), shadowBlur: 34, shadowOpacity: 0.7,
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .vocaloidPurpleBlue:
                return Self.make(font: "Hiragino Sans", size: 78, weight: 800,
                                 unsung: rgba(0.93, 0.94, 1.0, 1), sung: rgba(0.63, 0.45, 0.98, 1),
                                 sungEnd: rgba(0.29, 0.68, 0.99, 1),
                                 stroke: rgba(0.05, 0.03, 0.12, 1), strokeWidth: 8,
                                 shadow: rgba(0.45, 0.35, 0.95, 1), shadowBlur: 36, shadowOpacity: 0.8,
                                 rubyFactor: 0.42, rubyOffset: -24, staggered: staggered)
            case .minimalMV:
                return Self.make(font: "Hiragino Sans", size: 58, weight: 500, gapFactor: 0.5,
                                 unsung: rgba(1, 1, 1, 0.95), sung: rgba(0.85, 0.88, 0.98, 1),
                                 sungEnd: rgba(0.85, 0.88, 0.98, 1), gradient: false,
                                 stroke: rgba(0, 0, 0, 0.75), strokeWidth: 4,
                                 shadow: rgba(0, 0, 0, 1), shadowBlur: 14, shadowOpacity: 0.5, shadowY: 2,
                                 rubyFactor: 0.38, rubyOffset: -18, staggered: staggered)
            case .nicokaraBlue:
                return Self.make(font: "Hiragino Sans", size: 76, weight: 800,
                                 unsung: rgba(1, 1, 1, 1), sung: rgba(0.16, 0.43, 1.0, 1),
                                 sungEnd: rgba(0.35, 0.75, 1.0, 1),
                                 stroke: rgba(0.02, 0.02, 0.08, 1), strokeWidth: 9,
                                 shadow: rgba(0, 0, 0, 1), shadowBlur: 10, shadowOpacity: 0.6,
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .nicokaraPink:
                return Self.make(font: "Hiragino Maru Gothic ProN", size: 76, weight: 700,
                                 unsung: rgba(1, 0.97, 0.98, 1), sung: rgba(1.0, 0.30, 0.55, 1),
                                 sungEnd: rgba(1.0, 0.55, 0.75, 1),
                                 stroke: rgba(0.28, 0.04, 0.18, 1), strokeWidth: 9,
                                 shadow: rgba(0.3, 0.0, 0.15, 1), shadowBlur: 12, shadowOpacity: 0.55,
                                 rubyFont: "Hiragino Maru Gothic ProN",
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .nicokaraGold:
                return Self.make(font: "Hiragino Sans", size: 76, weight: 800,
                                 unsung: rgba(1, 1, 1, 1), sung: rgba(1.0, 0.80, 0.10, 1),
                                 sungEnd: rgba(1.0, 0.55, 0.10, 1),
                                 stroke: rgba(0.25, 0.12, 0.02, 1), strokeWidth: 9,
                                 shadow: rgba(0.2, 0.1, 0.0, 1), shadowBlur: 12, shadowOpacity: 0.6,
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .minchoElegant:
                return Self.make(font: "Hiragino Mincho ProN", size: 72, weight: 700,
                                 unsung: rgba(0.98, 0.96, 0.90, 1), sung: rgba(0.85, 0.18, 0.20, 1),
                                 sungEnd: rgba(0.95, 0.45, 0.25, 1),
                                 stroke: rgba(0.12, 0.06, 0.06, 1), strokeWidth: 6,
                                 shadow: rgba(0, 0, 0, 1), shadowBlur: 12, shadowOpacity: 0.5,
                                 rubyFont: "Hiragino Mincho ProN",
                                 rubyFactor: 0.40, rubyOffset: -20, staggered: staggered)
            case .roundCute:
                return Self.make(font: "Hiragino Maru Gothic ProN", size: 78, weight: 700,
                                 unsung: rgba(1, 1, 1, 1), sung: rgba(0.15, 0.80, 0.75, 1),
                                 sungEnd: rgba(0.35, 0.65, 1.0, 1),
                                 stroke: rgba(0.08, 0.18, 0.38, 1), strokeWidth: 10,
                                 shadow: rgba(0.05, 0.1, 0.3, 1), shadowBlur: 8, shadowOpacity: 0.5,
                                 rubyFont: "Hiragino Maru Gothic ProN",
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .handwrittenKlee:
                return Self.make(font: "Klee", size: 72, weight: 600,
                                 unsung: rgba(1.0, 0.97, 0.88, 1), sung: rgba(1.0, 0.45, 0.25, 1),
                                 sungEnd: rgba(1.0, 0.70, 0.30, 1),
                                 stroke: rgba(0.35, 0.18, 0.08, 1), strokeWidth: 7,
                                 shadow: rgba(0.2, 0.1, 0.0, 1), shadowBlur: 10, shadowOpacity: 0.5,
                                 rubyFont: "Klee", rubyFactor: 0.40, rubyOffset: -20, staggered: staggered)
            case .neonCyber:
                return Self.make(font: "Hiragino Sans", size: 76, weight: 800,
                                 unsung: rgba(0.85, 1.0, 1.0, 1), sung: rgba(1.0, 0.20, 0.80, 1),
                                 sungEnd: rgba(0.20, 0.90, 1.0, 1),
                                 stroke: rgba(0.02, 0.02, 0.18, 1), strokeWidth: 9,
                                 shadow: rgba(0.20, 0.90, 1.0, 1), shadowBlur: 44, shadowOpacity: 0.9, shadowY: 0,
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            case .invertedLight:
                return Self.make(font: "Hiragino Sans", size: 76, weight: 800,
                                 unsung: rgba(0.12, 0.12, 0.18, 1), sung: rgba(0.90, 0.12, 0.25, 1),
                                 sungEnd: rgba(1.0, 0.40, 0.30, 1),
                                 stroke: rgba(1, 1, 1, 1), strokeWidth: 8,
                                 shadow: rgba(1, 1, 1, 1), shadowBlur: 8, shadowOpacity: 0.5, shadowY: 0,
                                 rubyFactor: 0.40, rubyOffset: -22, staggered: staggered)
            }
        }

        /// 统一的构造：行距按「假名要放得下」算（字号 × gapFactor），整块放进底部安全区；
        /// 错开排版 = 上行靠左、下行靠右。
        private static func make(font: String, size: Double, weight: Int, gapFactor: Double = 0.8,
                                 unsung: RGBAColor, sung: RGBAColor, sungEnd: RGBAColor, gradient: Bool = true,
                                 stroke: RGBAColor, strokeWidth: Double,
                                 shadow: RGBAColor, shadowBlur: Double, shadowOpacity: Double, shadowY: Double = 3,
                                 rubyFont: String = "Hiragino Sans", rubyFactor: Double, rubyOffset: Double,
                                 staggered: Bool) -> SubtitleStyle {
            let gap = (size * gapFactor).rounded()
            return SubtitleStyle(
                fontName: font, fontSize: size, fontWeight: weight,
                alignment: staggered ? .leading : .center,
                upperAlignment: staggered ? .leading : .center,
                lowerAlignment: staggered ? .trailing : .center,
                positionX: 0,
                positionY: SubtitleStyle.bottomSafeAreaPositionY(fontSize: size, lineGap: gap),
                lineGap: gap,
                unsungColor: unsung, sungColor: sung,
                sungGradientEnabled: gradient, sungGradientEndColor: sungEnd,
                strokeColor: stroke, strokeWidth: strokeWidth,
                shadowColor: shadow, shadowBlur: shadowBlur,
                shadowOffsetX: 0, shadowOffsetY: shadowY, shadowOpacity: shadowOpacity,
                rubyFontName: rubyFont, rubySizeFactor: rubyFactor, rubyVerticalOffset: rubyOffset)
        }
    }
}

/// 上下两行的整体版式（对齐的四种常用组合）。
public enum SubtitleLineLayout: String, CaseIterable, Sendable {
    case center, left, right
    /// 错开：上行靠左、下行靠右（ニコカラ 常见）。
    case staggered

    public var displayName: String {
        switch self {
        case .center: return "居中"
        case .left: return "左对齐"
        case .right: return "右对齐"
        case .staggered: return "错开"
        }
    }

    public var upper: SubtitleAlignment {
        switch self {
        case .center: return .center
        case .left, .staggered: return .leading
        case .right: return .trailing
        }
    }

    public var lower: SubtitleAlignment {
        switch self {
        case .center: return .center
        case .left: return .leading
        case .right, .staggered: return .trailing
        }
    }
}

extension SubtitleStyle {
    /// 当前上下行对齐对应的整体版式；两行是别的组合时为 nil。
    public var lineLayout: SubtitleLineLayout? {
        SubtitleLineLayout.allCases.first { $0.upper == upperAlignment && $0.lower == lowerAlignment }
    }

    public mutating func setLineLayout(_ layout: SubtitleLineLayout) {
        upperAlignment = layout.upper
        lowerAlignment = layout.lower
        alignment = layout.upper   // 兼容旧字段
    }
}

/// 单句样式覆盖：只存被改过的字段。
public struct SubtitleStyleOverride: Codable, Hashable, Sendable {
    public var fontSize: Double?
    public var positionX: Double?
    public var positionY: Double?
    public var unsungColor: RGBAColor?
    public var sungColor: RGBAColor?

    public init(fontSize: Double? = nil,
                positionX: Double? = nil,
                positionY: Double? = nil,
                unsungColor: RGBAColor? = nil,
                sungColor: RGBAColor? = nil) {
        self.fontSize = fontSize
        self.positionX = positionX
        self.positionY = positionY
        self.unsungColor = unsungColor
        self.sungColor = sungColor
    }

    public var isEmpty: Bool {
        fontSize == nil && positionX == nil && positionY == nil && unsungColor == nil && sungColor == nil
    }

    public func applied(to base: SubtitleStyle) -> SubtitleStyle {
        var s = base
        if let v = fontSize { s.fontSize = v }
        if let v = positionX { s.positionX = v }
        if let v = positionY { s.positionY = v }
        if let v = unsungColor { s.unsungColor = v }
        if let v = sungColor { s.sungColor = v }
        return s
    }
}

extension SubtitleStyle {
    /// 倒计时圆点「未走轨」的颜色：未单独设置时跟随歌词未唱色。
    public var countdownUnsungColor: RGBAColor { countdown.unsungColor ?? unsungColor }
    /// 倒计时「走轨」的颜色：未单独设置时跟随歌词已唱色。
    public var countdownSweepColor: RGBAColor { countdown.sweepColor ?? sungColor }
}
