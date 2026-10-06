import SwiftUI
import MaGiKaraKit

/// 主界面骨架（RD §3.2）：
/// 顶部工具条 / 左侧分区 / 中部预览 / 右侧属性面板 / 底部时间线。
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 参考剪映：最上方只留一条窄 title bar（左身份 / 右操作）。
            TopBar()
            // 顶部只切换工作区；编辑操作集中在下方时间线工具栏。
            TopDock()

            // 分析进度是主界面的一部分，必须占自己的布局空间。
            // 之前用 overlay(alignment: .top) 叠在窗口最上沿，会压住标题栏和 Dock。
            if state.isAnalyzing {
                analysisBanner
                    .workspacePanel(cornerRadius: Theme.cornerMedium)
                    .padding(.horizontal, Theme.workspaceGap)
                    .padding(.top, Theme.workspaceGap)
            }

            // 三栏工作区：左侧歌词/工作区、中央预览、右侧字幕模版/属性，
            // 三块面板用统一间距分开，互不粘连。导出以模态小工作区浮在其上，
            // 不切走主编辑界面。
            workspace
            .padding(Theme.workspaceGap)

            // 底部时间线：独立圆角面板，与左右面板之间有明显间距。
            TimelineView()
                .workspacePanel()
                .mediaDropTarget()
                .padding(.horizontal, Theme.workspaceGap)
                .padding(.bottom, Theme.workspaceGap)
        }
        .background {
            ZStack {
                Theme.windowBackground
                CosmicBackdrop()
            }
            .ignoresSafeArea()
        }
        .overlay {
            if state.isExportWorkspacePresented || state.sidebarSection == .export {
                exportWorkspaceOverlay
            }
        }
        .overlay {
            if state.isRuntimeSetupPresented {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    RuntimeSetupView(model: state.runtimeSetup) { state.closeRuntimeSetup() }
                }
                .zIndex(30)
                .transition(.opacity)
            }
        }
        .focusable()
        .focused($keyboardFocused)
        .timelineKeyboard(state)
        .onAppear {
            keyboardFocused = true
            state.openProjectFromLaunchArguments()
        }
        .onKeyPress(.space) {
            state.togglePlay()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            state.stepPlayhead(by: -0.1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            state.stepPlayhead(by: 0.1)
            return .handled
        }
        .alert("出错了", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("好") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    /// 参考 FCPX 的导出文件面板：保留编辑界面作为背景，只在中央弹出紧凑工作区。
    private var exportWorkspaceOverlay: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.closeExportWorkspace()
                    }

                ExportWorkspace()
                    .frame(
                        width: min(max(680, proxy.size.width - 72), 860),
                        height: min(max(500, proxy.size.height - 72), 600))
                    .background(Theme.panelSolid,
                                in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .zIndex(20)
        .transition(.opacity)
    }

    // MARK: - 三栏工作区

    private var workspace: some View {
        HStack(spacing: Theme.workspaceGap) {
            leftPanel

            // 预览**全局常驻**：切到项目/歌词/样式/导出都不消失，只自适应缩小。
            centerPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            InspectorPanel()
                .frame(width: Theme.inspectorWidth)
                .frame(maxHeight: .infinity)
                .workspacePanel()
        }
        .frame(maxHeight: .infinity)
    }

    /// 左侧面板：歌词分区用完整歌词工作区，其余分区用信息侧栏。
    @ViewBuilder
    private var leftPanel: some View {
        Group {
            if state.sidebarSection == .lyrics {
                LyricsWorkspace()
            } else {
                SidebarView()
            }
        }
        .frame(width: state.sidebarSection == .lyrics
               ? Theme.lyricsWorkspaceWidth
               : Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .workspacePanel()
    }

    /// 中央面板：预览 + 紧贴预览底部的播放控制/进度条。
    private var centerPanel: some View {
        VStack(spacing: 0) {
            PreviewView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            // 播放进度贴在视频下方、时间线之前，符合剪辑软件的空间关系。
            PlaybackTimelineStrip()

            Rectangle().fill(Theme.divider).frame(height: 1)
            ToolStrip()
        }
        .workspacePanel()
        // 从 Finder 拖入视频/音频即可导入（文件选择器仍保留为兜底）；时间线上同样可以拖入
        .mediaDropTarget()
    }

    /// 分析进行中的独立进度行：占位而不覆盖任何已有 UI。
    @ViewBuilder
    private var analysisBanner: some View {
        VStack(spacing: 0) {
            ProgressView(value: max(0.02, state.analysisProgress))
                .progressViewStyle(.linear)
                .tint(Theme.violet)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(state.analysisStage.isEmpty ? "分析中…" : state.analysisStage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("取消") { state.cancelAnalysis() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.violet)
            }
            .padding(.horizontal, 14)
            .frame(height: 25)
        }
        .background(Theme.panelSolid.opacity(0.92))
    }
}

/// 预览下方的播放控制与进度条。
///
/// 播放控制与连续拖动播放位置集中在视频与时间线之间，
/// 用户可以直接把“画面”和“时间”对应起来。
struct PlaybackTimelineStrip: View {
    @EnvironmentObject private var state: AppState

    private var playheadBinding: Binding<Double> {
        Binding(
            get: { state.playhead },
            set: { state.seek(to: $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            transportButton("backward.end.fill", help: "前往开头（00:00）") {
                state.seekToStart()
            }
            .accessibilityLabel("前往开头")

            Button {
                state.togglePlay()
            } label: {
                Image(systemName: state.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 28)
                    .background(.white.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(Theme.dividerStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(state.playback.isPlaying ? "暂停（空格）" : "播放（空格）")

            transportButton("forward.end.fill", help: "前往结尾（\(state.timelineDuration.timecode)）") {
                state.seekToEnd()
            }
            .accessibilityLabel("前往结尾")

            Text(state.playhead.timecode)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 58, alignment: .trailing)

            KaraokeSlider(value: playheadBinding, in: 0...max(0.1, state.timelineDuration))
                .frame(height: 16)
                .layoutPriority(1)
                .disabled(!state.hasMedia)
                .help("播放进度")

            Text(state.timelineDuration.timecode)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 58, alignment: .leading)

            Spacer(minLength: 6)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            KaraokeSlider(value: volumeBinding, in: 0...1)
                .frame(width: 92, height: 14)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.panelSolid)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { state.playback.volume },
            set: { state.playback.volume = $0 })
    }

    private func transportButton(_ name: String,
                                 help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 预览下方的上下文工具条（对应视觉参考里的图标行）。
/// 独立的导出页面在 `ExportWorkspace.swift` 中，不再嵌在这里。
struct ToolStrip: View {
    @EnvironmentObject private var state: AppState

    /// 预览区下方仅显示当前选中状态和上下文提示；所有编辑命令集中在时间线工具栏。
    var body: some View {
        HStack(spacing: 10) {
            if let line = state.selectedLine {
                HStack(spacing: 5) {
                    Image(systemName: "text.cursor").font(.system(size: 10))
                    Text("第 \(line.order) 句").font(.system(size: 11, weight: .medium))
                    if !state.project.isEditable(line) {
                        Label("已锁定", systemImage: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.warning)
                    } else if line.isManuallyAdjusted {
                        Label("已手动调整", systemImage: "hand.raised.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.violet)
                    }
                }
                .foregroundStyle(Theme.textSecondary)

            } else if state.hasMedia {
                Text("在时间线上单击歌词块可选中，拖动主体移动、拖动左右边缘修剪")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Text(state.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.white.opacity(0.45))
    }

    private func iconButton(_ systemName: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}


// MARK: - 拖入导入

/// 从 Finder 把视频/音频拖到这个区域即可导入，并在悬停时给出「松手即可导入」的提示。
///
/// 预览区和时间线都挂同一个修饰器：剪辑软件里把素材拖到时间线上本来就是最自然的导入方式。
/// 只接受受支持的媒体文件，规则全部在 `AppState.handleDroppedFiles` 里（拖入歌词文本等不受影响）。
struct MediaDropTarget: ViewModifier {
    @EnvironmentObject private var state: AppState
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                state.handleDroppedFiles(urls)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Theme.cornerLarge)
                        .strokeBorder(Theme.violet, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Theme.violet.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
                        .overlay(
                            Label("松手即可导入", systemImage: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.violet)
                        )
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func mediaDropTarget() -> some View { modifier(MediaDropTarget()) }
}
