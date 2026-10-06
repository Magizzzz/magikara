import SwiftUI
import MaGiKaraKit

/// 顶部身份 / 操作横条。
///
/// 播放控制属于工作区，不占用窗口顶部的大面积空间。
/// 品牌字标靠左，星云与星点在标题栏和工作区导航间自然过渡。
struct TopBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            backdrop

            bottomTransition

            // 轻薄的白色雾面只负责托住文字，不再用厚材质把星空磨平。
            Rectangle().fill(.white.opacity(0.10))

            HStack(spacing: 18) {
                identityArea
                    .layoutPriority(1)

                Spacer(minLength: 24)

                actionArea
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Theme.topBarHeight)
        .zIndex(1)
    }

    private var bottomTransition: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Theme.blueViolet.opacity(0.070), location: 0.36),
                        .init(color: Theme.violet.opacity(0.050), location: 0.68),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
                .frame(height: 31)
                .blur(radius: 12)
                .offset(y: 13)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 背景

    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.panelSolid.opacity(0.42)

                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.36), location: 0),
                        .init(color: Theme.violet.opacity(0.16), location: 0.30),
                        .init(color: Theme.blueViolet.opacity(0.20), location: 0.60),
                        .init(color: Theme.violet.opacity(0.13), location: 0.80),
                        .init(color: Color.white.opacity(0.32), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing)

                RadialGradient(
                    colors: [Theme.violet.opacity(0.24), Theme.blueViolet.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.61, y: 0.48),
                    startRadius: 2,
                    endRadius: 260)

                RadialGradient(
                    colors: [Color.white.opacity(0.46), .clear],
                    center: UnitPoint(x: 0.48, y: 0.22),
                    startRadius: 1,
                    endRadius: 190)

                galaxyRibbon(in: proxy.size)
                starfield
            }
        }
        .accessibilityHidden(true)
    }

    /// 低对比度的散射光带暗示银河，不形成一根明确的横线。
    private func galaxyRibbon(in size: CGSize) -> some View {
        let ribbon = Path { path in
            path.move(to: CGPoint(x: size.width * 0.22, y: size.height * 1.18))
            path.addCurve(to: CGPoint(x: size.width * 0.88, y: -size.height * 0.16),
                          control1: CGPoint(x: size.width * 0.40, y: -size.height * 0.32),
                          control2: CGPoint(x: size.width * 0.69, y: size.height * 1.30))
        }
        return ZStack {
            ribbon
                .stroke(
                    LinearGradient(
                        colors: [.clear, Theme.violet.opacity(0.19), Theme.blueViolet.opacity(0.17), .clear],
                        startPoint: .leading,
                        endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 19, lineCap: .round))
                .blur(radius: 11)

            ribbon
                .stroke(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.17), Theme.violet.opacity(0.13), .clear],
                        startPoint: .leading,
                        endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .blur(radius: 1.7)
        }
        .allowsHitTesting(false)
    }

    /// 星点集中在标题栏中段，左右留出品牌文字和导出按钮的呼吸空间。
    private var starfield: some View {
        Canvas { context, size in
            let stars: [(x: CGFloat, y: CGFloat, radius: CGFloat, alpha: Double)] = [
                (0.28, 0.24, 1.6, 0.46), (0.36, 0.76, 1.9, 0.52),
                (0.43, 0.34, 2.7, 0.78), (0.51, 0.78, 1.6, 0.48),
                (0.58, 0.20, 1.8, 0.58), (0.64, 0.68, 2.3, 0.66),
                (0.71, 0.34, 1.6, 0.52), (0.77, 0.78, 2.0, 0.60),
                (0.83, 0.20, 2.6, 0.74), (0.89, 0.61, 1.7, 0.48),
            ]

            for star in stars {
                let center = CGPoint(x: size.width * star.x, y: size.height * star.y)
                let radius = star.radius
                let dot = CGRect(x: center.x - radius / 2,
                                 y: center.y - radius / 2,
                                 width: radius,
                                 height: radius)
                context.fill(Path(ellipseIn: dot),
                             with: .color(Theme.blueViolet.opacity(star.alpha)))

                if radius > 2.2 {
                    var glint = Path()
                    glint.move(to: CGPoint(x: center.x, y: center.y - 4.5))
                    glint.addLine(to: CGPoint(x: center.x, y: center.y + 4.5))
                    glint.move(to: CGPoint(x: center.x - 4.5, y: center.y))
                    glint.addLine(to: CGPoint(x: center.x + 4.5, y: center.y))
                    context.stroke(glint,
                                   with: .color(Color.white.opacity(star.alpha * 0.82)),
                                   lineWidth: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 身份区

    private var identityArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            brandWordmark
            Text(state.hasMedia
                 ? state.project.mediaURL.deletingPathExtension().lastPathComponent
                 : "直接粘贴歌词开始")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(0.25)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 210, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .help("MaGi Kara")
    }

    private var brandWordmark: some View {
        HStack(spacing: 3) {
            Text("MaGi")
                .foregroundStyle(Theme.textPrimary)
            Text("Kara")
                .foregroundStyle(Theme.accentGradient)
        }
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .tracking(-0.35)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sparkle")
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .offset(x: 4, y: -4)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 操作区

    private var actionArea: some View {
        HStack(spacing: 9) {
            exportButton

            Menu {
                Button("重新开始") { state.requestNewProject() }
                Button("打开工程…") { state.openProject() }
                Button("保存工程") { state.saveProject() }
                Button("工程另存为…") { state.saveProjectAs() }
                Divider()
                Button("导入媒体…") { state.importMedia() }
                Button("重新定位媒体…") { state.relocateMedia() }
                Divider()
                Toggle("使用 Mock 对齐器（仅 UI 测试）", isOn: Binding(
                    get: { state.useMockAligner },
                    set: { state.useMockAligner = $0 }))
            } label: {
                Image(systemName: "ellipsis")
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.black)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 25, height: 28)
                    .background(.white.opacity(0.38), in: Capsule())
            }
            .tint(.black)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多")
        }
    }

    /// 右上角「导出」主入口：直接打开完整导出工作区，
    /// MP4 / ASS / LRC / SRT 等格式统一在工作区内选择。
    private var exportButton: some View {
        Button {
            state.openExportWorkspace()
        } label: {
            HStack(spacing: 5) {
                if state.isExportingVideo {
                    ProgressView().controlSize(.small)
                }
                Text("导出")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerMedium)
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("打开导出工作区")
    }

}
