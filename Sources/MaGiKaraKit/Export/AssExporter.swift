import Foundation
import CoreText

/// 字幕排版与导出的统一设计画布。
/// 预览按这个尺寸等比缩放到播放器区域，ASS 也用它作为 PlayRes，
/// 这样「预览所见」与「导出所得」的位置与比例完全一致。
public enum KaraokeCanvas {
    public static let width: Double = 1920
    public static let height: Double = 1080
    public static var aspect: Double { width / height }
}

/// ASS 导出（RD §11.2 第一阶段导出目标）。
///
/// 设计要点：
///
/// 1. **等待区 / 演唱区 / 唱后停留区分成独立事件**。
///    纯 K 需要「先显示不扫色 → 到点开始扫 → 唱完继续停留」。
///    用 ASS 的空 `\k` 块表达等待区在部分播放器上不一定可靠，
///    所以这里改成三段事件（静态等待 / `\k` 扫色 / 静态停留），
///    位置与文字完全一致，播放器兼容性最好。
///
/// 2. **扫色方向约定**。
///    ASS 的 `\k` 让文字从 SecondaryColour 变为 PrimaryColour。
///    因此事件里显式写 `\2c`（未唱）与 `\1c`（已唱），
///    不依赖样式表里的默认值。若播放器方向相反，把 `swapKaraokeColors` 打开即可。
///
/// 3. **Ruby 用上方独立定位事件**，位置由 `KaraokeLayout` 用 Core Text 算出，
///    与预览共用同一套排版结果（RD §11.2 明确允许这种降级方式）。
///
/// 4. 渐变无法在 ASS 单色文本上表达，已唱色会退化为渐变起点色。
public enum AssExporter {

    public enum KaraokeTag: String, Sendable {
        case k = "k"
        case kf = "kf"
    }

    public struct Options: Sendable {
        public var playResX: Int = Int(KaraokeCanvas.width)
        public var playResY: Int = Int(KaraokeCanvas.height)
        public var title: String = "MaGi Kara"
        public var karaokeTag: KaraokeTag = .kf
        /// 三段式独立事件（推荐）。关掉则退化为单一事件 + 空 \k 块。
        public var splitPhases: Bool = true
        /// 导出 Ruby 事件
        public var includeRuby: Bool = true
        /// 播放器扫色方向相反时打开
        public var swapKaraokeColors: Bool = false

        public init() {}
        public static let `default` = Options()
    }

    public enum ExportError: LocalizedError {
        case noLines
        public var errorDescription: String? {
            if case .noLines = self { return "工程里没有歌词，无法导出 ASS" }
            return nil
        }
    }

    // MARK: 时间格式

    /// ASS 时间格式 H:MM:SS.CC
    ///
    /// 先用「厘秒」整数做全部运算，避免 3725.99 这类值因浮点误差算成 .98。
    public static func timestamp(_ seconds: Double) -> String {
        let totalCentis = Int((max(0, seconds) * 100).rounded())
        let cs = totalCentis % 100
        let totalSeconds = totalCentis / 100
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    /// ASS 覆盖标签里的字号/颜色文本
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    // MARK: 生成

    public static func export(project: KaraProject, options: Options = .default) -> String {
        let style = project.style
        let lines = project.sortedLines
        let resolution = (x: Double(options.playResX), y: Double(options.playResY))

        let sungColor = options.swapKaraokeColors ? style.unsungColor : style.sungColor
        let unsungColor = options.swapKaraokeColors ? style.sungColor : style.unsungColor

        var out = ""

        let methodLine = project.analysis?.method?.displayName ?? "未记录（旧工程）"
        let evidenceLine = (project.analysis?.evidenceCounts ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\(AlignmentEvidence(rawValue: $0.key)?.displayName ?? $0.key) \($0.value) 句" }
            .joined(separator: "，")
        let evidenceText = evidenceLine.isEmpty ? "未记录" : evidenceLine

        // ---- Script Info ----
        out += """
        ; MaGi Kara 导出
        ; 对齐方法：\(methodLine)
        ; 证据分布：\(evidenceText)
        ; 扫色约定：\\2c=未唱色 -> \\1c=已唱色（ASS 标准 \\k 行为）
        ; 等待区与唱后停留区使用独立静态事件，位置与文字与扫色事件完全一致。
        ; 已唱色在 ASS 中为单色，渐变已退化为起点色。

        [Script Info]
        ScriptType: v4.00+
        Title: \(options.title)
        PlayResX: \(options.playResX)
        PlayResY: \(options.playResY)
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        Collisions: Normal
        Timer: 100.0000

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding

        """

        // ---- 主字幕样式 ----
        // 字重已经由 PostScript 名确定，不能再让 libass 按 Bold 标记另挑一个（见 KaraokeLayout.assFace）
        let bold = 0
        let mainFace = KaraokeLayout.assFace(for: KaraokeLayout.mainFont(style: style))
        let countdownFace = KaraokeLayout.assFace(for: KaraokeLayout.font(name: style.fontName, size: 100, weight: 400))
        // 注意不要在这里再做一次取反：
        // `RGBAColor.assColor` 内部已经把「不透明度」换算成 ASS 的 alpha
        // （ASS 里 0x00 = 不透明、0xFF = 全透明）。
        // 之前这里传的是 1-opacity，等于取反两次，导出的阴影只剩 30% 可见，
        // 与预览里看到的（70%）不一致。
        let backColor = RGBAColor(style.shadowColor.r, style.shadowColor.g, style.shadowColor.b,
                                  style.shadowOpacity)
        // Alignment 5 = 正中锚点，位置完全由 \pos 决定
        out += "Style: Main,\(mainFace.name),\(fmt(style.fontSize * mainFace.sizeScale)),"
        out += "\(sungColor.assColor),\(unsungColor.assColor),\(style.strokeColor.assColor),\(backColor.assColor),"
        out += "\(bold),0,0,0,100,100,0,0,1,\(fmt(style.strokeWidth)),\(fmt(shadowDistance(style))),5,0,0,0,1\n"

        // ---- 倒计时样式（只用来承载绘图事件，字体无关紧要）----
        out += "Style: Countdown,\(countdownFace.name),\(fmt(style.fontSize * countdownFace.sizeScale)),"
        out += "\(unsungColor.assColor),\(unsungColor.assColor),\(style.strokeColor.assColor),\(backColor.assColor),"
        out += "0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1\n"

        // ---- Ruby 样式 ----
        let rubySize = style.fontSize * style.rubySizeFactor
        let rubyFace = KaraokeLayout.assFace(for: KaraokeLayout.rubyFont(style: style, size: rubySize))
        out += "Style: Ruby,\(rubyFace.name),\(fmt(rubySize * rubyFace.sizeScale)),"
        out += "\(sungColor.assColor),\(unsungColor.assColor),\(style.strokeColor.assColor),\(backColor.assColor),"
        out += "\(bold),0,0,0,100,100,0,0,1,\(fmt(max(1, style.strokeWidth * 0.7))),0,5,0,0,0,1\n"

        // ---- Events ----
        out += """

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """

        let halfLine = (style.fontSize + style.lineGap) / 2

        // 倒计时轨道上的每个色块：画在「下一句歌词将出现的位置」，与预览一致。
        out += countdownEvents(project: project,
                               resolution: resolution,
                               halfLine: halfLine,
                               swapColors: options.swapKaraokeColors)

        for line in lines {
            // 预览允许上行/下行独立拖动；这里必须使用同一份轨道偏移，
            // 否则预览位置与导出视频/ASS 会再次分叉。
            let trackPosition = style.position(for: line.lane)
            let centerY = resolution.y / 2 + trackPosition.y
            let lineY = centerY + (line.lane == .upper ? -halfLine : halfLine)

            let layout = KaraokeLayout.layout(line: line, style: style)
            // 行中心的水平位置：居中 / 靠左 / 靠右（错开排版）由 `lineCenterX` 统一计算，与预览一致
            let lineX = resolution.x / 2 + style.lineCenterX(for: line.lane,
                                                              lineWidth: layout.lineWidth,
                                                              canvasWidth: resolution.x)
            let body = sanitize(line.displayText)

            let leadIn = line.leadIn
            let holdOut = line.holdOut
            let singDur = line.singDuration

            let posTag = "\\an5\\pos(\(fmt(lineX)),\(fmt(lineY)))"
            let unsungTag = "\\1c\(unsungColor.assColor)\\2c\(unsungColor.assColor)"

            if options.splitPhases {
                // 1) 等待区：显示但不扫色
                if leadIn > 0.02 {
                    out += dialogue(layer: max(0, line.layer),
                                    start: line.displayStart,
                                    end: line.singStart,
                                    style: "Main",
                                    text: "{\(posTag)\(unsungTag)\(fadeTag(style, includeIn: true, includeOut: false))\\alpha&H00&}\(body)")
                }
                // 2) 演唱区：\k 扫色（按字符宽度匀速分配时间）
                let from = leadIn > 0.02 ? line.singStart : line.displayStart
                let to = holdOut > 0.02 ? line.singEnd : line.displayEnd
                let singingFade = fadeTag(style,
                                          includeIn: leadIn <= 0.02,
                                          includeOut: holdOut <= 0.02)
                out += dialogue(layer: max(0, line.layer),
                                start: from,
                                end: to,
                                style: "Main",
                                text: "{\(posTag)\(singingFade)\\1c\(sungColor.assColor)\\2c\(unsungColor.assColor)}\(karaokeBody(line: line, style: style, tag: options.karaokeTag, total: max(0.05, singDur)))")
                // 3) 唱后停留：保持已唱状态
                if holdOut > 0.02 {
                    out += dialogue(layer: max(0, line.layer),
                                    start: line.singEnd,
                                    end: line.displayEnd,
                                    style: "Main",
                                    text: "{\(posTag)\(fadeTag(style, includeIn: false, includeOut: true))\\1c\(sungColor.assColor)\\2c\(sungColor.assColor)}\(body)")
                }
            } else {
                // 退化路径：单事件 + 空 \k 块表达等待区
                var text = "{\(posTag)\(fadeTag(style, includeIn: true, includeOut: true))\\1c\(sungColor.assColor)\\2c\(unsungColor.assColor)}"
                if leadIn > 0.02 { text += "{\\k\(cs(leadIn))}" }
                text += karaokeBody(line: line, style: style, tag: options.karaokeTag, total: max(0.05, singDur))
                if holdOut > 0.02 { text += "{\\k\(cs(holdOut))}" }
                out += dialogue(layer: max(0, line.layer),
                                start: line.displayStart,
                                end: line.displayEnd,
                                style: "Main",
                                text: text)
            }

            // 4) Ruby：每段连续汉字一个独立定位事件。
            // 扫色时间窗由主词的整句匀速扫色推出：主词边缘走过这段汉字所占的宽度比例，
            // 假名就在同一时间段内从左到右扫完，因此与主词严格同步（不再按音拍节奏单独走轨）。
            guard options.includeRuby else { continue }
            let rubyY = lineY - style.fontSize * 0.5 - rubySize * 0.55 + style.rubyVerticalOffset
            let firstRubyIndex = layout.rubies.indices.first
            let lastRubyIndex = layout.rubies.indices.last
            for (rubyIndex, ruby) in layout.rubies.enumerated() {
                let x = lineX + ruby.centerX
                let spacing = ruby.letterSpacing > 0.01 ? "\\fsp\(fmt(ruby.letterSpacing))" : ""
                let sizeTag = abs(ruby.fontSize - rubySize) > 0.5
                    ? "\\fs\(fmt(ruby.fontSize * rubyFace.sizeScale))" : ""
                let rubyPos = "\\an5\\pos(\(fmt(x)),\(fmt(rubyY)))\(sizeTag)\(spacing)"
                let rubyText = sanitize(ruby.text)
                let isFirstRuby = rubyIndex == firstRubyIndex
                let isLastRuby = rubyIndex == lastRubyIndex

                let rubyStart = line.singStart + ruby.sweepStart * singDur
                let rubyEnd = line.singStart + ruby.sweepEnd * singDur

                if singDur > 0.01, rubyEnd > rubyStart {
                    // 该段在整句等待区里也要显示（未唱色），否则行首的假名会在等待区消失。
                    let hasWaitingPhase = line.displayStart < rubyStart - 0.02
                    let waitingFade = fadeTag(style, includeIn: isFirstRuby, includeOut: false)
                    let karaokeFade = fadeTag(style,
                                              includeIn: isFirstRuby && !hasWaitingPhase,
                                              includeOut: isLastRuby && line.displayEnd <= rubyEnd + 0.02)
                    if hasWaitingPhase {
                        out += dialogue(layer: max(0, line.layer) + 1,
                                        start: line.displayStart,
                                        end: rubyStart,
                                        style: "Ruby",
                                        text: "{\(rubyPos)\(waitingFade)\\1c\(unsungColor.assColor)\\2c\(unsungColor.assColor)}\(rubyText)")
                    }
                    // 该段扫色：按字符渲染宽度均匀分配时间，整段匀速从左到右
                    let kBody = uniformBody(text: ruby.text,
                                            font: KaraokeLayout.rubyFont(style: style, size: ruby.fontSize),
                                            tag: options.karaokeTag,
                                            total: max(0.05, rubyEnd - rubyStart))
                    out += dialogue(layer: max(0, line.layer) + 1,
                                    start: rubyStart,
                                    end: max(rubyStart + 0.05, rubyEnd),
                                    style: "Ruby",
                                    text: "{\(rubyPos)\(karaokeFade)\\1c\(sungColor.assColor)\\2c\(unsungColor.assColor)}\(kBody)")
                    // 扫完之后保持已唱色直到整句显示结束，和主词的「唱后停留」一致
                    if line.displayEnd > rubyEnd + 0.02 {
                        out += dialogue(layer: max(0, line.layer) + 1,
                                        start: rubyEnd,
                                        end: line.displayEnd,
                                        style: "Ruby",
                                        text: "{\(rubyPos)\(fadeTag(style, includeIn: false, includeOut: isLastRuby))\\1c\(sungColor.assColor)\\2c\(sungColor.assColor)}\(rubyText)")
                    }
                } else {
                    // 演唱时长异常（≈0）：整句区间内直接显示未唱色
                    let rubyFade = fadeTag(style, includeIn: isFirstRuby, includeOut: isLastRuby)
                    out += dialogue(layer: max(0, line.layer) + 1,
                                    start: line.displayStart,
                                    end: line.displayEnd,
                                    style: "Ruby",
                                    text: "{\(rubyPos)\(rubyFade)\\1c\(unsungColor.assColor)\\2c\(unsungColor.assColor)}\(rubyText)")
                }
            }
        }

        return out
    }

    public static func write(project: KaraProject, to url: URL, options: Options = .default) throws {
        let text = export(project: project, options: options)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 辅助

    /// 生成主字幕的 \k 序列。
    ///
    /// **画面显示的是「表记」（汉字原样），不是读音** —— 这一点很关键：
    /// 直接拿音拍文本当文字会让整行变成「すばらしきせかい」。
    /// 时间按每个字符的渲染宽度成比例分配，保证扫色边缘在整句上匀速从左到右，
    /// 不会因为音拍长短忽快忽慢；字符顺序严格等于 displayText。
    static func karaokeBody(line: LyricLine, style: SubtitleStyle, tag: KaraokeTag, total: Double) -> String {
        uniformBody(text: line.displayText,
                    font: KaraokeLayout.mainFont(style: style),
                    tag: tag,
                    total: total)
    }

    /// 把一段文字按字符渲染宽度均匀分配 `\k` 时长。
    ///
    /// 例如两个字符宽度比 1:3，就分到 1:3 的时间，边缘因此匀速。
    /// 最后一个字符吸收取整误差，保证 `\k` 之和精确等于总时长（厘秒）。
    static func uniformBody(text: String, font: CTFont, tag: KaraokeTag, total: Double) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }
        let totalCs = cs(total)
        let weights = chars.map { max(0.05, KaraokeLayout.width(of: String($0), font: font)) }
        let weightSum = weights.reduce(0, +)

        var body = ""
        var assigned = 0
        for (i, ch) in chars.enumerated() {
            let remaining = max(0, totalCs - assigned)
            let d: Int
            if i == chars.count - 1 {
                d = remaining
            } else if weightSum > 0 {
                d = min(remaining, max(0, Int((Double(totalCs) * weights[i] / weightSum).rounded())))
            } else {
                d = min(remaining, totalCs / chars.count)
            }
            assigned += d
            body += "{\\\(tag.rawValue)\(d)}\(sanitize(String(ch)))"
        }
        return body
    }

    /// 秒 → 厘秒
    static func cs(_ seconds: Double) -> Int {
        max(0, Int((seconds * 100).rounded()))
    }

    static func fmt(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.01 { return String(Int(v.rounded())) }
        return String(format: "%.2f", v)
    }

    static func shadowDistance(_ style: SubtitleStyle) -> Double {
        max(0, (style.shadowOffsetX * style.shadowOffsetX + style.shadowOffsetY * style.shadowOffsetY).squareRoot())
    }

    /// 生成全局字幕轨道的 ASS 淡化标签。
    /// 只有轨道边界事件携带淡化，避免逐 token 重复淡入造成闪烁。
    static func fadeTag(_ style: SubtitleStyle,
                        includeIn: Bool,
                        includeOut: Bool) -> String {
        let fadeIn = includeIn && style.entryEffect == .fade
            ? Int((style.entryEffect.duration * 1000).rounded()) : 0
        let fadeOut = includeOut && style.exitEffect == .fade
            ? Int((style.exitEffect.duration * 1000).rounded()) : 0
        guard fadeIn > 0 || fadeOut > 0 else { return "" }
        return "\\fad(\(fadeIn),\(fadeOut))"
    }

    /// 倒计时用的图层：独立一层，永远不与歌词事件抢层。
    static let countdownLayer = 8

    /// 倒计时轨道上每个色块的 ASS 事件。
    ///
    /// - `fill`（逐点走轨填色）：每个点一个事件，用 `\kf` 让「●」在自己的 1/N 时间里被走轨色填满，
    ///   前面的点用一个空的 `\k` 占位等待；
    /// - `dwindle`（逐点熄灭）：按时间段分别画亮点与淡化的点。
    ///
    /// 圆点用文字字符「●」而不是 ASS 绘图命令：导出只能是字幕层（不含任何绘图/图片），
    /// 文字事件在各种播放器里也更稳。尺寸与预览共用 `KaraokeCountdown`。
    static func countdownEvents(project: KaraProject,
                                resolution: (x: Double, y: Double),
                                halfLine: Double,
                                swapColors: Bool) -> String {
        let style = project.style
        guard style.countdownEnabled, !project.countdowns.isEmpty else { return "" }
        let cd = style.countdown
        let unlitColor = swapColors ? style.countdownSweepColor : style.countdownUnsungColor
        let sweepColor = swapColors ? style.countdownUnsungColor : style.countdownSweepColor
        let diameter = KaraokeCountdown.dotDiameter(style: style)
        let pitch = diameter + KaraokeCountdown.dotSpacing(style: style)
        // 字号换算：让「●」的墨迹直径等于 diameter（不同字体里这个圆的大小不一样）
        // 再乘 libass 的字号换算系数（见 KaraokeLayout.assFace），否则导出的点比预览小一圈
        let dotFace = KaraokeLayout.assFace(for: KaraokeLayout.font(name: style.fontName, size: 100, weight: 400))
        let fontSizeForDot = diameter / glyphInkRatio(fontName: style.fontName) * dotFace.sizeScale
        let n = cd.dotCount

        var out = ""
        for item in project.countdowns.sorted(by: { $0.start < $1.start }) where item.duration > 0 {
            let lane = KaraokeCountdown.lane(for: item, in: project)
            let trackPosition = style.position(for: lane)
            // 圆点整体的宽度，按所在行的对齐方式（居中 / 靠左 / 靠右）放置，和歌词行一致
            let groupWidth = Double(n) * diameter + Double(n - 1) * (pitch - diameter)
            let centerX = resolution.x / 2
                + style.lineCenterX(for: lane, lineWidth: groupWidth, canvasWidth: resolution.x)
                + cd.offsetX
            let centerY = resolution.y / 2 + trackPosition.y
                + (lane == .upper ? -halfLine : halfLine) + cd.offsetY
            func dotX(_ index: Int) -> Double {
                centerX + (Double(index) - Double(n - 1) / 2) * pitch
            }

            switch cd.mode {
            case .fill:
                let slotCs = max(1, cs(item.duration / Double(n)))
                for index in 0..<n {
                    let wait = index > 0 ? "{\\k\(index * slotCs)}" : ""
                    let tags = "\\an5\\pos(\(fmt(dotX(index))),\(fmt(centerY)))\\fs\(fmt(fontSizeForDot))"
                        + "\\1c\(sweepColor.assColor)\\2c\(unlitColor.assColor)\\bord3"
                    out += dialogue(layer: countdownLayer,
                                    start: item.start,
                                    end: item.end,
                                    style: "Countdown",
                                    text: "{\(tags)}\(wait){\\kf\(slotCs)}●")
                }
            case .dwindle:
                for segment in KaraokeCountdown.dwindleSegments(dotCount: n, item: item) {
                    for index in 0..<n {
                        let lit = index < segment.dots
                        let size = lit ? fontSizeForDot : fontSizeForDot * KaraokeCountdown.unlitScale
                        // 没亮的点：22% 不透明（ASS 的 alpha 是反的：0x00 不透明、0xFF 全透明）
                        let alpha = Int(((1 - KaraokeCountdown.unlitOpacity) * 255).rounded())
                        let alphaHex = String(format: "&H%02X&", alpha)
                        let fade = lit ? "" : "\\1a\(alphaHex)\\3a\(alphaHex)\\4a\(alphaHex)"
                        let tags = "\\an5\\pos(\(fmt(dotX(index))),\(fmt(centerY)))\\fs\(fmt(size))"
                            + "\\1c\(unlitColor.assColor)\\bord3\(fade)"
                        out += dialogue(layer: countdownLayer,
                                        start: segment.start,
                                        end: segment.end,
                                        style: "Countdown",
                                        text: "{\(tags)}●")
                    }
                }
            }
        }
        return out
    }

    /// 「●」在该字体里墨迹直径占字号的比例（用 Core Text 实测；取不到时用 0.6）。
    static func glyphInkRatio(fontName: String) -> Double {
        let font = KaraokeLayout.font(name: fontName, size: 100, weight: 400)
        let attributed = CFAttributedStringCreate(
            nil, "●" as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetImageBounds(line, nil).width
        return width > 1 ? Double(width) / 100 : 0.6
    }

    static func dialogue(layer: Int, start: Double, end: Double, style: String, text: String) -> String {
        let e = max(end, start + 0.01)
        return "Dialogue: \(layer),\(timestamp(start)),\(timestamp(e)),\(style),,0,0,0,,\(text)\n"
    }
}
