import SwiftUI
import MaGiKaraKit

/// 双行纯 K 字幕叠加层。
///
/// 关键行为（RD §4 / §7）：
/// - 上下两条主轨是两个固定屏幕槽位，不是语言层；同一时刻通常显示当前句与下一句。
/// - 只有正在演唱的那一句发生扫色，另一句保持未唱色。
/// - 扫色在每句 `singStart → singEnd` 之间**匀速从左到右**，每个 token 依次覆盖，
///   不因音拍长短忽快忽慢（与 ASS 导出同一套边沿定义）。
/// - 主字幕整句一次排版、基线固定；假名作为独立浮层画在对应汉字段上方，
///   不会因为某几个 token 有假名就把主句挤得高低不齐。
/// - 第一句出现前显示简洁倒计时点，且只在没有歌词显示时出现。
struct KaraokeOverlay: View {
    let project: KaraProject
    let style: SubtitleStyle
    let time: Double
    let selectedLineID: UUID?
    let layoutProvider: (LyricLine) -> LineLayout

    var body: some View {
        let pair = project.previewLines(at: time)
        let singing = project.singingLine(at: time)
        // 倒计时轨道上此刻正在显示的色块，以及它该画在哪一行（下一句将出现的那一行）
        let countdown = KaraokeCountdown.activeItem(in: project, at: time)
        let countdownLane = countdown.map { KaraokeCountdown.lane(for: $0, in: project) }

        ZStack {
            VStack(spacing: style.lineGap) {
                slot(line: pair.upper, lane: .upper, singing: singing?.id,
                     selected: selectedLineID == pair.upper?.id,
                     countdown: countdownLane == .upper ? countdown : nil)
                slot(line: pair.lower, lane: .lower, singing: singing?.id,
                     selected: selectedLineID == pair.lower?.id,
                     countdown: countdownLane == .lower ? countdown : nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.016), value: time)
    }

    @ViewBuilder
    private func slot(line: LyricLine?, lane: ScreenLane, singing: UUID?, selected: Bool,
                      countdown: CountdownItem?) -> some View {
        let trackPosition = style.position(for: lane)
        if let line {
            let lineStyle = line.styleOverride?.applied(to: style) ?? style
            let lineLayout = layoutProvider(line)
            KaraokeLineView(
                line: line,
                style: lineStyle,
                layout: lineLayout,
                time: time,
                isSinging: singing == line.id,
                isSelected: selected)
                .opacity(transitionOpacity(for: line))
                // 水平位置按所在行的对齐方式（居中 / 靠左 / 靠右）计算，与 ASS 导出同一个公式
                .offset(x: CGFloat(lineStyle.lineCenterX(for: lane, lineWidth: lineLayout.lineWidth)),
                        y: trackPosition.y)
        } else {
            // 空槽位也占位，保证上下位置稳定；倒计时的点就画在这个槽位里
            Color.clear.frame(height: style.fontSize * 1.25)
                .overlay {
                    if let countdown {
                        countdownDots(item: countdown)
                    }
                }
                .offset(x: countdown == nil ? trackPosition.x : CGFloat(countdownCenterX(lane: lane)),
                        y: trackPosition.y)
        }
    }

    /// 全局轨道动效只作用在每句显示窗口的边界，不逐句配置。
    /// 这样预览与 ASS 导出的 \\fad 边界保持一致，并且不会让每个 token 反复闪烁。
    private func transitionOpacity(for line: LyricLine) -> Double {
        var value = 1.0
        if style.entryEffect == .fade {
            let duration = max(0.01, style.entryEffect.duration)
            value = min(value, max(0, min(1, (time - line.displayStart) / duration)))
        }
        if style.exitEffect == .fade {
            let duration = max(0.01, style.exitEffect.duration)
            value = min(value, max(0, min(1, (line.displayEnd - time) / duration)))
        }
        return value
    }

    /// 倒计时圆点整体按所在行的对齐方式放置（居中 / 靠左 / 靠右），和歌词行、ASS 导出一致。
    private func countdownCenterX(lane: ScreenLane) -> Double {
        let n = style.countdown.dotCount
        let diameter = KaraokeCountdown.dotDiameter(style: style)
        let width = Double(n) * diameter + Double(n - 1) * KaraokeCountdown.dotSpacing(style: style)
        return style.lineCenterX(for: lane, lineWidth: width)
    }

    /// 倒计时圆点：与导出的 ASS 共用 `KaraokeCountdown` 的全部参数。
    /// - 走轨模式：每个点依次被「走轨色」从左到右填满；
    /// - 熄灭模式：剩余的点保持亮，其余缩小并淡化。
    private func countdownDots(item: CountdownItem) -> some View {
        let cd = style.countdown
        let diameter = CGFloat(KaraokeCountdown.dotDiameter(style: style))
        let spacing = CGFloat(KaraokeCountdown.dotSpacing(style: style))
        let unlit = style.countdownUnsungColor.swiftUIColor
        let sweep = style.countdownSweepColor.swiftUIColor
        let lit = KaraokeCountdown.litDots(dotCount: cd.dotCount, item: item, at: time)

        return HStack(spacing: spacing) {
            ForEach(0..<cd.dotCount, id: \.self) { index in
                switch cd.mode {
                case .fill:
                    let progress = KaraokeCountdown.fillProgress(dot: index, dotCount: cd.dotCount,
                                                                 item: item, at: time)
                    Circle()
                        .fill(unlit)
                        .overlay {
                            Circle()
                                .fill(sweep)
                                .mask {
                                    Rectangle()
                                        .frame(width: CGFloat(progress) * diameter, height: diameter)
                                        .frame(width: diameter, height: diameter, alignment: .leading)
                                }
                        }
                        .frame(width: diameter, height: diameter)
                case .dwindle:
                    Circle()
                        .fill(index < lit
                              ? unlit
                              : unlit.opacity(KaraokeCountdown.unlitOpacity))
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(index < lit ? 1 : CGFloat(KaraokeCountdown.unlitScale))
                }
            }
        }
        .offset(x: CGFloat(cd.offsetX), y: CGFloat(cd.offsetY))
        .shadow(color: style.shadowColor.swiftUIColor.opacity(style.shadowOpacity),
                radius: style.shadowBlur * 0.4,
                x: style.shadowOffsetX,
                y: style.shadowOffsetY)
    }
}

/// 单行：整句一次排版 + 匀速扫色遮罩，假名独立浮层。
struct KaraokeLineView: View {
    let line: LyricLine
    let style: SubtitleStyle
    let layout: LineLayout
    let time: Double
    let isSinging: Bool
    let isSelected: Bool

    /// 主字幕行高只由字号决定，永远不受假名是否存在影响 —— 基线因此稳定。
    private var mainHeight: CGFloat { max(20, CGFloat(style.fontSize) * 1.22) }

    var body: some View {
        let lineWidth = CGFloat(max(1, layout.lineWidth))
        ZStack {
            // 主字幕：整句一次排版，所有 token 共用同一字体/字重/描边与同一基线
            mainSentence
                .frame(width: lineWidth, height: mainHeight, alignment: .center)

            // 假名：独立浮层，按 Core Text 算出的中心位置压在对应汉字段上方
            ForEach(Array(layout.rubies.enumerated()), id: \.offset) { _, ruby in
                rubyView(ruby)
                    .offset(x: CGFloat(ruby.centerX), y: rubyOffset(ruby))
            }
        }
        .padding(.horizontal, isSelected ? 8 : 0)
        .padding(.vertical, isSelected ? 4 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.82), lineWidth: 1.5)
                    }
                    .shadow(color: Theme.selectionBorder.opacity(0.35), radius: 5)
            }
        }
        // 深色阴影：系数 0.45 让它在复杂背景上真正起作用（0.22 实测几乎看不见）
        .shadow(color: style.shadowColor.swiftUIColor.opacity(style.shadowOpacity),
                radius: style.shadowBlur * 0.45,
                x: style.shadowOffsetX,
                y: style.shadowOffsetY)
    }

    private var mainSentence: some View {
        ZStack(alignment: .leading) {
            Text(attributed(line.displayText, fontName: style.fontName, size: style.fontSize))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(style.unsungColor.swiftUIColor)

            Text(attributed(line.displayText, fontName: style.fontName, size: style.fontSize))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(AnyShapeStyle(Theme.sungGradient(style)))
                .mask(sweepMask)
        }
    }

    /// 假名与主词共用同一个实时整句进度 `lineSweepProgress`，并用同样的「左侧遮罩」逐步扫色：
    /// 主词边缘走过这段汉字的区间时，假名同步从左到右变色。
    /// 之前假名读的是缓存排版里的旧时间、且整段一碰就变色，所以会比主词先变，看起来像单独走轨。
    private func rubyView(_ ruby: RubyPlacement) -> some View {
        let progress = layout.rubySweepProgress(ruby, sweepFraction: lineSweepProgress)
        let text = attributed(ruby.text, fontName: style.rubyFontName, size: ruby.fontSize)
        return ZStack(alignment: .leading) {
            Text(text)
                .kerning(ruby.letterSpacing)
                .foregroundStyle(style.unsungColor.swiftUIColor)
                .fixedSize()
            Text(text)
                .kerning(ruby.letterSpacing)
                .foregroundStyle(AnyShapeStyle(Theme.sungGradient(style)))
                .fixedSize()
                .mask(SweepMask(progress: progress))
        }
        .fixedSize()
    }

    private func rubyOffset(_ ruby: RubyPlacement) -> CGFloat {
        -(CGFloat(style.fontSize) * 0.5 + CGFloat(ruby.fontSize) * 0.55)
            + CGFloat(style.rubyVerticalOffset) * 0.25
    }

    /// 整句匀速扫色遮罩：从左侧裁出 `sweepFraction` 的比例。
    ///
    /// 进度直接来自 `line` 的 singStart/singEnd，而不是 `layout` 里缓存的时间，
    /// 这样用户拖动/修剪歌词块后预览立即跟手，不会用到过期的排版缓存。
    private var sweepMask: some View {
        SweepMask(progress: lineSweepProgress)
    }

    private var lineSweepProgress: Double {
        guard line.singEnd > line.singStart else { return time >= line.singEnd ? 1 : 0 }
        if time <= line.singStart { return 0 }
        if time >= line.singEnd { return 1 }
        return (time - line.singStart) / (line.singEnd - line.singStart)
    }

    /// 构造带描边的文本。
    ///
    /// SwiftUI 的 `strokeWidth` 是「相对字号的百分比」，所以这里用
    /// `strokeWidth / 字号` 换算 —— 这样主文字和更小的假名得到的是
    /// **相同的绝对描边宽度**，视觉上才统一。
    private func attributed(_ text: String, fontName: String, size: Double) -> AttributedString {
        var attr = AttributedString(text)
        // 与排版、ASS 导出用同一个 Core Text 字体（同一个字重的同一个字形），预览和成片才会一致
        attr.font = Font(KaraokeLayout.font(name: fontName, size: size, weight: style.fontWeight))
        if style.strokeWidth > 0.2 {
            attr.strokeWidth = style.strokeWidth / max(1, size) * 100
            attr.strokeColor = style.strokeColor.nsColor
        }
        return attr
    }
}

func swiftUIFontWeight(_ weight: Int) -> Font.Weight {
    switch weight {
    case ..<200: return .ultraLight
    case 200..<300: return .thin
    case 300..<400: return .light
    case 400..<500: return .regular
    case 500..<600: return .medium
    case 600..<700: return .semibold
    case 700..<800: return .bold
    case 800..<900: return .heavy
    default: return .black
    }
}

/// 扫色遮罩：从左侧裁出 `progress` 比例。
///
/// 描边、英文下伸字母（y、g）和撇号会画到文字框外面。遮罩如果和文字框一样高，
/// 框外那部分盖不到，已唱的字上下会露出底层的未唱色（白边）。所以上下各多出一截；
/// 已经开始唱时向左多盖一截、唱完时向右多盖一截，两端的描边也一起变色。
struct SweepMask: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let p = CGFloat(min(1, max(0, progress)))
            let pad = max(8, geo.size.height)
            let lead: CGFloat = p > 0 ? pad : 0
            let trail: CGFloat = p >= 1 ? pad : 0
            Rectangle()
                .frame(width: p * geo.size.width + lead + trail,
                       height: geo.size.height + pad * 2)
                .offset(x: -lead, y: -pad)
        }
    }
}
