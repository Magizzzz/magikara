import SwiftUI
import MaGiKaraKit

/// MaGi 系列视觉系统（RD §3.1）。
///
/// 白色磨砂主体、淡紫蓝渐变、克制圆角、细分隔线；
/// 不使用绿色主题，不做深色 FCPX 风格。
enum Theme {

    // MARK: 颜色

    /// 主强调色：淡紫蓝 → 蓝紫
    static let violet = Color(red: 0.545, green: 0.482, blue: 0.910)
    static let blueViolet = Color(red: 0.404, green: 0.478, blue: 0.937)

    /// 选中边框
    static let selectionBorder = Color(red: 0.545, green: 0.482, blue: 0.910)
    /// 时间线交互反馈：FCP 风格的黄色选中轮廓与红色鼠标跟踪线。
    static let timelineSelectionBorder = Color(red: 0.98, green: 0.72, blue: 0.12)
    static let timelineSkimmer = Color(red: 0.96, green: 0.25, blue: 0.25)
    /// 时间线歌词片段：加深淡紫以提升浅色工作区中的可辨识度。
    static let lyricSegment = Color(red: 0.75, green: 0.70, blue: 0.93)
    /// 倒计时色块：暖色，和紫色的歌词块一眼区分。
    static let countdownSegment = Color(red: 0.98, green: 0.84, blue: 0.58)
    static let countdownSegmentSelected = Color(red: 0.96, green: 0.72, blue: 0.34)
    static let lyricSegmentSelected = Color(red: 0.60, green: 0.53, blue: 0.88)
    /// 相邻歌词色块之间的轻微白色描边，让同色块边界可辨。
    static let lyricSegmentStroke = Color.white.opacity(0.65)
    /// 人声轨专用青蓝色，与紫色伴奏波形形成一眼可辨的双轨。
    static let vocalTrack = Color(red: 0.28, green: 0.62, blue: 0.84)


    /// 警告：少量暖黄；错误：克制红
    static let warning = Color(red: 0.851, green: 0.643, blue: 0.255)
    static let warningSoft = Color(red: 0.965, green: 0.878, blue: 0.690)
    static let error = Color(red: 0.816, green: 0.353, blue: 0.353)
    static let errorSoft = Color(red: 0.953, green: 0.753, blue: 0.753)
    static let ok = Color(red: 0.545, green: 0.482, blue: 0.910)

    /// 文本
    static let textPrimary = Color(red: 0.169, green: 0.169, blue: 0.235)
    static let textSecondary = Color(red: 0.478, green: 0.478, blue: 0.573)
    static let textTertiary = Color(red: 0.639, green: 0.639, blue: 0.706)

    /// 分隔线（细分隔线）
    static let divider = Color(red: 0.925, green: 0.925, blue: 0.965)
    static let dividerStrong = Color(red: 0.878, green: 0.878, blue: 0.933)

    /// 面板底色
    static let panel = Color.white.opacity(0.55)
    static let panelSolid = Color(red: 0.980, green: 0.980, blue: 0.996)
    static let controlFill = Color(red: 0.949, green: 0.949, blue: 0.984)
    static let controlFillHover = Color(red: 0.925, green: 0.925, blue: 0.976)
    /// 模板预设按钮比普通控件稍明显，并配深色字，避免白字落在浅色块上。
    static let presetButtonFill = Color(red: 0.91, green: 0.89, blue: 0.98)
    static let presetButtonBorder = Color(red: 0.82, green: 0.78, blue: 0.95)

    /// 四区统一面板：浅色淡紫底 + 细边框，浮在窗口渐变之上。
    static let panelSurface = Color(red: 0.980, green: 0.976, blue: 0.998)
    static let panelBorder = Color(red: 0.886, green: 0.878, blue: 0.945)

    /// 时间线轨道底色
    static let trackBackground = Color.white.opacity(0.35)

    // MARK: 渐变

    /// 窗口主体：白色磨砂 + 淡紫蓝渐变
    static var windowBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.988, green: 0.984, blue: 1.0),
                Color(red: 0.957, green: 0.961, blue: 0.996),
                Color(red: 0.937, green: 0.945, blue: 0.992),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    /// 主按钮：淡紫蓝 → 蓝紫
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [violet, blueViolet], startPoint: .leading, endPoint: .trailing)
    }

    /// 已唱色渐变（预览用）
    static func sungGradient(_ style: SubtitleStyle) -> LinearGradient {
        if style.sungGradientEnabled {
            return LinearGradient(colors: [style.sungColor.swiftUIColor, style.sungGradientEndColor.swiftUIColor],
                                  startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [style.sungColor.swiftUIColor, style.sungColor.swiftUIColor],
                              startPoint: .leading, endPoint: .trailing)
    }

    // MARK: 尺寸

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14

    /// 顶部只保留身份与操作；播放控制属于工作区，避免挤占预览面积。
    /// 参考剪映：title bar 只是一条窄横条，不再放大面积播放控制。
    static let topBarHeight: CGFloat = 48
    /// 工作区切换条高度；编辑工具已移入时间线工具栏。
    static let topDockHeight: CGFloat = 36
    /// 四个工作区面板之间的间距（面板内部边距由各视图自己控制）。
    static let workspaceGap: CGFloat = 10
    static let sidebarWidth: CGFloat = 140
    /// 歌词工作区独立放在左侧时的宽度，保证输入区可读且给 MV 留出完整预览空间。
    static let lyricsWorkspaceWidth: CGFloat = 292
    static let inspectorWidth: CGFloat = 232
    static let trackHeaderWidth: CGFloat = 116
    /// 时间 0 的安全起点，避免时间线贴在固定轨道头边缘时看起来被遮住。
    static let timelineLeadingInset: Double = 16

    static let lyricLaneHeight: CGFloat = 34
    static let videoTrackHeight: CGFloat = 38
    static let audioTrackHeight: CGFloat = 34
    static let rulerHeight: CGFloat = 24
    static let laneGap: CGFloat = 3
    static let laneGroupGap: CGFloat = 7
}

extension RGBAColor {
    var swiftUIColor: Color { Color(red: r, green: g, blue: b).opacity(a) }
}

extension View {
    /// 四区（左歌词/工作区、中央预览、右字幕模版/属性、底部时间线）统一面板外观：
    /// 圆角矩形 + 细边框 + 浅色淡紫底。业务内容完全不动，只加一层外壳。
    func workspacePanel(cornerRadius: CGFloat = Theme.cornerLarge) -> some View {
        background(Theme.panelSurface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.panelBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
