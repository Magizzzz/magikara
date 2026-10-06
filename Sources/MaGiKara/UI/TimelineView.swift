import SwiftUI
import MaGiKaraKit

private enum TimelineCoordinateSpace {
    static let viewport = "timelineViewport"
}

@MainActor
private func timelineTime(atViewportX x: Double, state: AppState) -> Double {
    TimelineGeometry.time(forViewportX: x,
                          scrollX: state.scrollX,
                          pixelsPerSecond: state.pixelsPerSecond,
                          leadingPadding: Double(Theme.timelineLeadingInset))
}

/// 底部时间线（RD §3.3 固定层级）
///
/// 从上到下：视频 / 音频波形 / 歌词上行 / 歌词下行。
struct TimelineView: View {
    @EnvironmentObject private var state: AppState
    @State private var hoverViewportX: CGFloat?

    /// 假名在右侧字幕工作区编辑，不额外占一条轨道。
    static let baseTracksHeight = Theme.rulerHeight
        + Theme.videoTrackHeight
        + Theme.audioTrackHeight
        + Theme.lyricLaneHeight          // 倒计时轨道
        + Theme.lyricLaneHeight * 2
        + Theme.laneGroupGap * 2
        + Theme.laneGap

    private var tracksHeight: CGFloat {
        Self.baseTracksHeight + (state.validVocalSeparation == nil ? 0 : Theme.audioTrackHeight)
    }

    static let zoomRowHeight: CGFloat = 34
    static let statusBarHeight: CGFloat = 26

    private var panelHeight: CGFloat {
        Self.zoomRowHeight + 1
            + tracksHeight
            + 1 + Self.statusBarHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            zoomRow
            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack(spacing: 0) {
                // 固定轨道头列
                VStack(spacing: 0) {
                    Color.clear.frame(height: Theme.rulerHeight)
                    TrackHeader(track: .video, height: Theme.videoTrackHeight)
                    TrackHeader(track: .audio, height: Theme.audioTrackHeight,
                                title: state.validVocalSeparation == nil ? "音频" : "伴奏")
                    if state.validVocalSeparation != nil {
                        TrackHeader(track: .vocal, height: Theme.audioTrackHeight)
                    }
                    TrackHeader(track: .countdown, height: Theme.lyricLaneHeight)
                    Color.clear.frame(height: Theme.laneGroupGap)
                    TrackHeader(track: .lyricUpper, height: Theme.lyricLaneHeight)
                    Color.clear.frame(height: Theme.laneGroupGap)
                    TrackHeader(track: .lyricLower, height: Theme.lyricLaneHeight)
                    Color.clear.frame(height: Theme.laneGap)
                }
                .frame(width: Theme.trackHeaderWidth)

                Rectangle().fill(Theme.divider).frame(width: 1)

                // 自行管理的横向视口。
                //
                // 不用 ScrollView + ScrollViewReader：实测 scrollTo 定位不准
                // （会滚到 01:18 而不是 00:27）。自己算偏移量既准确，
                // 也顺便支持「拖动平移」和「播放时跟随播放头」。
                GeometryReader { vp in
                    content
                        .frame(width: state.contentWidth, alignment: .leading)
                        // 滚轮监听放在内容后方，避免覆盖歌词块的 hit region。
                        .background {
                            ScrollWheelCatcher(onScroll: { dx in
                                state.scrollX += dx
                                state.clampScrollX()
                            }, onZoom: { dy in
                                state.setZoom(state.pixelsPerSecond * (1 + dy * 0.01))
                            })
                        }
                        .offset(x: -state.scrollX)
                        .frame(width: vp.size.width, alignment: .leading)
                        .clipped()
                        .contentShape(Rectangle())
                        // 跟踪线直接使用鼠标相对可见视口的坐标，不参与横向滚动换算；
                        // 它与内容中的固定播放头分离，避免视觉上看起来“跟手偏移”。
                        .overlay(alignment: .topLeading) {
                            if let hoverViewportX {
                                Rectangle()
                                    .fill(Theme.timelineSkimmer)
                                    .frame(width: 1.5)
                                    .frame(maxHeight: .infinity)
                                    .offset(x: hoverViewportX - 0.75)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .center) {
                            if !state.hasMedia {
                                TimelineEmptyTip()
                                    .frame(maxWidth: min(430, max(0, vp.size.width - 32)))
                                    .allowsHitTesting(false)
                            }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hoverViewportX = location.x
                            case .ended: hoverViewportX = nil
                            }
                        }
                        .onAppear {
                            state.viewportWidth = Double(vp.size.width)
                            state.clampScrollX()
                            state.consumeScrollTarget()
                        }
                        .onChange(of: vp.size.width) { _, w in
                            state.viewportWidth = Double(w)
                            state.clampScrollX()
                        }
                        .onChange(of: state.scrollTarget) { _, _ in state.consumeScrollTarget() }
                        .onChange(of: state.playhead) { _, _ in state.followPlayheadIfNeeded() }
                }
                // 坐标原点固定在 GeometryReader（可见时间线视口），不随滚动内容的 offset 移动。
                .coordinateSpace(name: TimelineCoordinateSpace.viewport)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            statusBar
        }
        .frame(height: panelHeight)
        .background(.white.opacity(0.30))
        .overlay(alignment: .topTrailing) {
            if let hint = state.editingHint {
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.violet.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.trailing, 10)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 滚动内容

    private var content: some View {
        HStack(spacing: 0) {
            // 给时间 0 留一个明确的起点缓冲，固定轨道头不会再让开头看起来被吃掉。
            Color.clear.frame(width: Theme.timelineLeadingInset)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    TimeRuler(pixelsPerSecond: state.pixelsPerSecond, duration: state.timelineDuration)
                        .frame(height: Theme.rulerHeight)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture)

                    VideoTrackRow(pixelsPerSecond: state.pixelsPerSecond, duration: state.mediaDuration,
                                  thumbnails: state.project.trackStates.isVisible(.video)
                                      ? state.videoThumbnails : [])
                        .frame(height: Theme.videoTrackHeight)
                        .opacity(state.project.trackStates.isVisible(.video) ? 1 : 0.35)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture)

                    WaveformRow(peaks: state.project.trackStates.isVisible(.audio) ? state.waveformPeaks : [],
                                rms: state.project.trackStates.isVisible(.audio) ? state.waveformRMS : [],
                                duration: state.timelineDuration,
                                pixelsPerSecond: state.pixelsPerSecond)
                        .frame(height: Theme.audioTrackHeight)
                        .opacity(state.project.trackStates.isVisible(.audio) ? 1 : 0.35)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture)

                    if let stems = state.validVocalSeparation {
                        WaveformRow(peaks: state.project.trackStates.isVisible(.vocal) ? state.vocalWaveformPeaks : [],
                                    rms: state.project.trackStates.isVisible(.vocal) ? state.vocalWaveformRMS : [],
                                    duration: stems.duration,
                                    pixelsPerSecond: state.pixelsPerSecond,
                                    color: Theme.vocalTrack)
                            .frame(height: Theme.audioTrackHeight)
                            .opacity(state.project.trackStates.isVisible(.vocal) ? 1 : 0.35)
                            .contentShape(Rectangle())
                            .gesture(scrubGesture)
                    }

                    // 倒计时轨道：倒计时色块可选中、拖动、修剪；右键空白处可在播放头新增
                    CountdownLane()
                        .frame(height: Theme.lyricLaneHeight)

                    Color.clear.frame(height: Theme.laneGroupGap)

                    // 空白处 scrub / 点击定位；块在上面，块的拖动优先（ZStack 上层先拿手势）
                    LyricLane(lane: .upper)
                        .frame(height: Theme.lyricLaneHeight)

                    Color.clear.frame(height: Theme.laneGroupGap)
                    LyricLane(lane: .lower)
                        .frame(height: Theme.lyricLaneHeight)

                    Color.clear.frame(height: Theme.laneGap)
                }

                // 紫色播放头以 `AppState.playhead` 为唯一时间源：播放时跟随
                // AVPlayer 的 60Hz 时间观察者持续移动，拖动/跳转也即时同步。
                // 红色 skimmer 仍独立跟随鼠标悬停位置，两者互不干扰。
                // 未导入媒体且用户尚未点击定位时不显示，保持空时间线干净。
                if state.hasMedia || state.playhead != 0 || state.timelineClickMarkerTime != nil {
                    TimelinePlayhead(pixelsPerSecond: state.pixelsPerSecond,
                                     time: state.playhead,
                                     height: tracksHeight)
                }

                // 吸附提示线：吸住时在参考点上画一条亮黄竖线（FCPX 同款反馈）
                if let snap = state.snapIndicatorTime {
                    Rectangle()
                        .fill(Color(red: 1.0, green: 0.78, blue: 0.0))
                        .frame(width: 1.5, height: tracksHeight)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                        .offset(x: CGFloat(snap * state.pixelsPerSecond) - 0.75)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: tracksHeight, alignment: .top)
    }

    // MARK: 缩放行

    private var zoomRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .onTapGesture { state.setZoom(state.pixelsPerSecond * 0.8) }

            KaraokeSlider(value: Binding(
                get: { state.pixelsPerSecond },
                set: { state.setZoom($0) }), in: 4...400)
                .frame(width: 100, height: 16)

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .onTapGesture { state.setZoom(state.pixelsPerSecond * 1.25) }

            Divider().frame(height: 18).padding(.horizontal, 3)

            timelineTool("选择", icon: "cursorarrow", isOn: state.selectedLineID != nil,
                         help: "取消当前选择") {
                state.selectedLineID = nil
            }
            timelineTool("分割", icon: "scissors", enabled: state.canSplitSelected,
                         help: "在播放头处分割（⌘B）") {
                state.splitSelectedAtPlayhead()
            }
            timelineTool("删除", icon: "trash",
                         enabled: state.selectedLineID != nil && !state.isSelectionLocked,
                         help: "删除选中歌词块") {
                state.deleteSelectedLine()
            }
            timelineTool("复制", icon: "plus.rectangle.on.rectangle",
                         enabled: state.selectedLineID != nil && !state.isSelectionLocked,
                         help: "复制选中歌词块") {
                if let id = state.selectedLineID { state.duplicateLine(id: id) }
            }

            Divider().frame(height: 18).padding(.horizontal, 3)

            timelineTool("吸附", icon: "arrow.right.and.line.vertical.and.arrow.left",
                         isOn: state.snappingEnabled,
                         help: state.snappingEnabled
                            ? "吸附已开（N）：拖动时自动贴齐播放头、其它歌词和倒计时的边缘。点击关闭"
                            : "吸附已关（N）：点击开启，拖动时自动贴齐播放头和其它片段边缘") {
                state.toggleSnapping()
            }

            Divider().frame(height: 18).padding(.horizontal, 3)

            timelineTool("撤销", icon: "arrow.uturn.backward", enabled: state.canUndo,
                         help: "撤销（⌘Z）") { state.undo() }
            timelineTool("重做", icon: "arrow.uturn.forward", enabled: state.canRedo,
                         help: "重做（⌘⇧Z）") { state.redo() }

            Divider().frame(height: 18).padding(.horizontal, 3)

            timelineTool("重新对齐", icon: "wand.and.stars",
                         enabled: state.selectedLineID != nil && !state.isAnalyzing,
                         help: "重新对齐选中歌词") { state.realignSelectedLine() }
            timelineTool("漂移修正", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                         enabled: !state.isAnalyzing, help: "修正整曲时间漂移") {
                state.correctDrift()
            }

            Spacer(minLength: 4)

            Button {
                if state.isSeparatingVocal {
                    state.cancelVocalSeparation()
                } else {
                    state.startVocalSeparation()
                }
            } label: {
                HStack(spacing: 5) {
                    if state.isSeparatingVocal {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                        Text(state.vocalSeparationProgress < 0.12
                             ? "准备模型" : "分离 \(Int(state.vocalSeparationProgress * 100))%")
                    } else {
                        Image(systemName: "waveform")
                        Text(state.validVocalSeparation == nil ? "AI人声分离" : "重新分离")
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(Theme.accentGradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.7))
                .shadow(color: Theme.blueViolet.opacity(0.16), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .disabled((!state.hasMedia || state.project.duration <= 0) && !state.isSeparatingVocal)
            .opacity((state.hasMedia && state.project.duration > 0 || state.isSeparatingVocal) ? 1 : 0.48)
            .help(state.isSeparatingVocal
                  ? "点击取消人声分离"
                  : "在本机分离人声与伴奏；首次使用需下载约 42 MB 模型")

            Button { state.zoomToFit() } label: {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("缩放到整曲")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.zoomRowHeight)
        .background(.white.opacity(0.35))
    }

    private func timelineTool(_ title: String, icon: String,
                              isOn: Bool = false, enabled: Bool = true,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(!enabled ? Theme.textTertiary.opacity(0.48)
                             : (isOn ? Theme.violet : Theme.textSecondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Theme.violet.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: 点击/拖动定位播放头

    /// 统一使用可见视口坐标；内容滚动量与左侧起点留白由 AppState 显式换算。
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.viewport))
            .onChanged { value in
                state.isScrubbing = true
                state.seekFromTimeline(viewportX: Double(value.location.x))
            }
            .onEnded { _ in
                state.isScrubbing = false
                state.snapIndicatorTime = nil
            }
    }

    // MARK: 右下角版本标识

    private var statusBar: some View {
        HStack {
            Spacer()
            Text("MaGi kara beta v1.1")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.statusBarHeight)
    }
}

/// 未导入媒体时在空白轨道中央显示的轻量提示，不遮挡时间尺和轨道交互。
private struct TimelineEmptyTip: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Theme.violet.opacity(0.08))
                    .frame(width: 30, height: 30)
                Circle()
                    .strokeBorder(Theme.blueViolet.opacity(0.18),
                                  style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                    .frame(width: 30, height: 30)
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.violet.opacity(0.70))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("时间线 · 小提示")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(Theme.blueViolet.opacity(0.72))
                Text("在时间线上单击歌词块可选中，拖动主体移动、拖动左右边缘修剪")
                    .font(.system(size: 9.2, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Theme.violet.opacity(0.16),
                              style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
        .shadow(color: Theme.blueViolet.opacity(0.06), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 轨道头

struct TrackHeader: View {
    let track: TrackID
    let height: CGFloat
    var title: String? = nil
    @EnvironmentObject private var state: AppState

    private var st: TrackState { state.project.trackStates[track] }

    private var icon: String {
        switch track {
        case .video: return "film"
        case .audio: return "waveform"
        case .vocal: return "mic.fill"
        case .countdown: return "circle.dotted"
        case .rubyUpper, .rubyLower: return "link"
        case .lyricUpper, .lyricLower: return "textformat"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(st.isVisible
                                 ? Theme.violet.opacity(0.85)
                                 : Theme.textTertiary.opacity(0.4))
                .frame(width: 13)
            Text(title ?? track.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(st.isVisible ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            // 只保留三个开关：显隐 / 锁定 / 静音（不做嵌套层级）
            IconToggle(systemName: st.isVisible ? "eye" : "eye.slash", on: st.isVisible) {
                state.toggleTrackVisible(track)
            }
            .help(st.isVisible ? "隐藏该轨道" : "显示该轨道")
            IconToggle(systemName: st.isLocked ? "lock.fill" : "lock.open", on: st.isLocked) {
                state.toggleTrackLocked(track)
            }
            .help(st.isLocked ? "解锁（当前不可编辑）" : "锁定该轨道，防止误操作")
            if track.isEditableContent || track == .audio || track == .vocal {
                IconToggle(systemName: st.isMuted ? "speaker.slash.fill" : "speaker.wave.1", on: st.isMuted) {
                    state.toggleTrackMuted(track)
                }
                .help(st.isMuted ? "取消静音" : "静音")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: height)
        .background(st.isLocked ? Theme.violet.opacity(0.06) : Theme.trackBackground)
        .help(track.displayName)
    }
}

struct IconToggle: View {
    let systemName: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8))
                .foregroundStyle(on ? Theme.textTertiary : Theme.textTertiary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 时间尺

struct TimeRuler: View {
    let pixelsPerSecond: Double
    let duration: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.panelSolid.opacity(0.6)

            let step = tickStep()
            let count = Int((max(duration, 1) / step).rounded(.up)) + 1
            ForEach(0..<max(1, count), id: \.self) { i in
                let t = Double(i) * step
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Theme.dividerStrong)
                        .frame(width: 1, height: 6)
                    Text(t.rulerLabel)
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                .offset(x: t * pixelsPerSecond)
            }
        }
        .clipped()
    }

    private func tickStep() -> Double {
        let targetPixels = 74.0
        let raw = targetPixels / max(1, pixelsPerSecond)
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 >= raw } ?? 600
    }
}

// MARK: - 时间线播放头

/// 紫色播放头：位置由 `AppState.playhead` 驱动，播放/定位时持续移动。
struct TimelinePlayhead: View {
    let pixelsPerSecond: Double
    let time: Double
    let height: CGFloat

    var body: some View {
        // 视图本身就是那条 1.5pt 的线，`offset` 因此精确落在 `time * pixelsPerSecond`。
        // 顶部时间标签用 overlay 居中悬在线上、不参与布局宽度：
        // 若把标签和线放进同一个 ZStack，容器宽度会变成标签宽度（约 80pt），
        // 线被居中后向右偏移半个标签宽，播放头就不再对准点击位置，且标签越长偏得越多。
        Rectangle()
            .fill(Theme.violet)
            .frame(width: 1.5, height: height)
            .overlay(alignment: .top) {
                Text(time.timecode)
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.violet, in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .offset(y: -1)
            }
            .offset(x: time * pixelsPerSecond - 0.75)
            .allowsHitTesting(false)
    }
}

// MARK: - 视频轨

struct VideoTrackRow: View {
    let pixelsPerSecond: Double
    let duration: Double
    let thumbnails: [NSImage]

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.trackBackground
            if thumbnails.isEmpty, duration > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    Text("已加载媒体（无可抽取画面）")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, 10)
            } else if !thumbnails.isEmpty {
                // 剪辑软件的缩略图不是「一张图拉伸成整条片段」：每个小格保持
                // 原视频宽高比，沿片段循环铺开，缩放时仍能看出连续画面。
                GeometryReader { proxy in
                    let tileHeight = max(1, Theme.videoTrackHeight - 6)
                    let source = thumbnails[0].size
                    let aspect = max(0.5, min(3.0, source.width / max(1, source.height)))
                    let tileWidth = max(28, tileHeight * aspect)
                    let tileCount = max(1, Int(ceil((proxy.size.width - 6) / (tileWidth + 1))))

                    HStack(spacing: 1) {
                        ForEach(0..<tileCount, id: \.self) { index in
                            Image(nsImage: thumbnails[index % thumbnails.count])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: tileWidth, height: tileHeight)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 1)
    }
}

// MARK: - 音频波形轨

struct WaveformRow: View {
    let peaks: [Float]
    let rms: [Float]
    let duration: Double
    let pixelsPerSecond: Double
    var color: Color = Theme.violet

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.trackBackground
            if !peaks.isEmpty {
                // 分块绘制：整首歌一块 Canvas 时宽度可达数万像素，超过 GPU 单张纹理上限（16384 px），
                // 放大时整条波形直接不显示（看起来像人声分离没出结果）。每块限制在 1024 点以内。
                GeometryReader { geo in
                    let total = max(1, Double(geo.size.width))
                    let tileWidth = Self.tileWidth
                    let tileCount = Int((total / tileWidth).rounded(.up))
                    HStack(spacing: 0) {
                        ForEach(0..<tileCount, id: \.self) { tile in
                            let x0 = Double(tile) * tileWidth
                            let width = min(tileWidth, total - x0)
                            Canvas { context, size in
                                draw(in: &context, height: Double(size.height),
                                     from: x0, width: width, total: total)
                            }
                            .frame(width: CGFloat(width))
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 1)
    }

    static let tileWidth: Double = 1024

    /// 画 [x0, x0 + width) 这一段；x 按整条波形的总宽 `total` 映射到 peaks 下标，块与块无缝衔接。
    private func draw(in context: inout GraphicsContext, height: Double,
                      from x0: Double, width: Double, total: Double) {
        let mid = height / 2
        let halfHeight = height * 0.46
        // 外廓：峰值包络（很淡）
        var peakPath = Path()
        // 内部：RMS（实心）——被限幅压平的素材只有 RMS 才看得出起伏
        var rmsPath = Path()
        var x: Double = 0
        while x < width {
            let idx = min(peaks.count - 1, Int(((x0 + x) / total) * Double(peaks.count)))
            let peakAmp = Double(peaks[idx]) * halfHeight
            peakPath.move(to: CGPoint(x: x, y: mid - peakAmp))
            peakPath.addLine(to: CGPoint(x: x, y: mid + peakAmp))
            if idx < rms.count {
                let rmsAmp = max(0.5, Double(rms[idx]) * halfHeight)
                rmsPath.move(to: CGPoint(x: x, y: mid - rmsAmp))
                rmsPath.addLine(to: CGPoint(x: x, y: mid + rmsAmp))
            }
            x += 1
        }
        context.stroke(peakPath, with: .color(color.opacity(0.28)), lineWidth: 1)
        context.stroke(rmsPath, with: .color(color.opacity(0.85)), lineWidth: 1)
    }
}

// MARK: - 歌词主轨

struct LyricLane: View {
    let lane: ScreenLane
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            // scrub 只绑在**背景空白层**上。
            // 不能绑在整个轨道容器上（用 simultaneousGesture）：那样拖动歌词块会
            // 同时触发「移动片段」和「scrub」，正常 NLE 不会这样。
            // 绑在背景层后：块在 ZStack 上层，命中块时背景完全收不到事件。
            Theme.trackBackground
                .contentShape(Rectangle())
                .gesture(blankScrub)
            let track: TrackID = lane == .upper ? .lyricUpper : .lyricLower
            let lines = state.project.trackStates.isVisible(track)
                ? state.project.lines(in: lane) : []
            ForEach(lines) { line in
                LyricSegmentView(line: line, pixelsPerSecond: state.pixelsPerSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        // 轨道级点击兜底：片段自身 hit region 即使受 offset/外层手势影响，
        // 仍按视口中的实际点击位置定位并选中对应色块。
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named(TimelineCoordinateSpace.viewport))
                .onEnded { value in
                    let x = Double(value.location.x)
                    let time = timelineTime(atViewportX: x, state: state)
                    if let line = state.project.lines(in: lane).first(where: {
                        time >= $0.displayStart && time <= max($0.displayEnd, $0.singEnd)
                    }) {
                        state.selectLineForEditing(line.id)
                    }
                    state.seekFromTimeline(viewportX: x)
                }
        )
    }

    /// 空白处拖动 = scrub。
    private var blankScrub: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.viewport))
            .onChanged { value in
                state.isScrubbing = true
                state.seekFromTimeline(viewportX: Double(value.location.x))
            }
            .onEnded { value in
                let time = timelineTime(atViewportX: Double(value.location.x), state: state)
                if let line = state.project.lines(in: lane).first(where: {
                    time >= $0.displayStart &&
                    time <= max($0.displayEnd, $0.singEnd)
                }) {
                    state.selectLineForEditing(line.id)
                }
                state.isScrubbing = false
            }
    }
}

// MARK: - 主歌词片段（四段时间可视化 + 拖动）

struct LyricSegmentView: View {
    let line: LyricLine
    let pixelsPerSecond: Double
    @EnvironmentObject private var state: AppState

    enum Mode { case none, shift, displayStart, displayEnd, singStart, singEnd, sweepMove }
    @State private var mode: Mode = .none
    @State private var origin: LyricLine?

    private var isSelected: Bool { state.selectedLineID == line.id }
    /// 所在轨道是否被锁定（锁定后不可移动/修剪）
    private var isLocked: Bool { !state.project.isEditable(line) }

    var body: some View {
        let pps = CGFloat(pixelsPerSecond)
        let ready = line.singEnd > line.singStart
        // 呈现规则来自模型层：时间轴永远不显示完整歌词文字（RD §3.1）。
        let presentation = TimelineSegment.presentation(for: line,
                                                        selectedLineID: state.selectedLineID,
                                                        isLocked: isLocked)
        // 一句歌词只用一条连续紫色块表达，避免把“等待/演唱/停留”误读成
        // 多个可编辑片段。真实时间仍保留在模型里，颜色只承担“这是歌词轨道”的语义。
        let dispX = CGFloat(line.displayStart) * pps
        let dispW = max(8, CGFloat(max(line.displayEnd, line.singEnd) - line.displayStart) * pps)
        let singOffset = CGFloat(max(0, line.singStart - line.displayStart)) * pps
        let singW = max(6, CGFloat(line.singEnd - line.singStart) * pps)
        let blockHeight = Theme.lyricLaneHeight - 6

        ZStack(alignment: .topLeading) {
            if ready {
                // 1) 一条连续紫色歌词块（displayStart → displayEnd）。
                //    色块内不渲染任何歌词文字，只用长度表达出现时间。
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Theme.lyricSegmentSelected : Theme.lyricSegment)
                    .frame(width: dispW, height: blockHeight)

                // 状态描边
                if isLocked {
                    // 锁定轨道：斜纹 + 灰色描边，状态一眼可辨
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.textTertiary.opacity(0.18))
                        .frame(width: singW, height: blockHeight)
                        .offset(x: singOffset)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.textTertiary.opacity(0.8),
                                      style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(width: singW, height: blockHeight)
                        .offset(x: singOffset)
                }

                // 走轨（扫色区间）：未选中时只是淡淡的提示；选中后用强调色整段着色 + 粗边框，
                // 并在底部给一条实心「走轨条」——两端调范围、中间平移，时长 = 扫色速度。
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.violet.opacity(isSelected ? 0.24 : 0.05))
                    .frame(width: singW, height: blockHeight)
                    .offset(x: singOffset)
                    .allowsHitTesting(false)

                // 相邻同色块之间加一圈轻微白色描边，让块边界可辨；
                // 压在演唱区弱提示之上，避免描边被半透明填充削弱。
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.lyricSegmentStroke, lineWidth: 1)
                    .frame(width: dispW, height: blockHeight)
                    .allowsHitTesting(false)

                // 选中反馈对齐剪映：黄色外框包住整个片段，配一层很轻的
                // 紫色光晕提升对比度；未选中时只保留色块本身的白色细描边。
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.timelineSelectionBorder, lineWidth: 2.5)
                        .frame(width: dispW, height: blockHeight)
                        .shadow(color: Theme.timelineSelectionBorder.opacity(0.45), radius: 2)

                    if !isLocked {
                        // 走轨范围的强调边框
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.violet, lineWidth: 2)
                            .frame(width: singW, height: blockHeight)
                            .offset(x: singOffset)
                            .allowsHitTesting(false)
                        // 走轨条：可拖（两端 = 范围，中间 = 平移）
                        let strip = CGFloat(LyricBlockHitTest.sweepStripHeight)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.violet)
                            .frame(width: singW, height: strip)
                            .overlay {
                                if singW >= 64 {
                                    Text("走轨 \(String(format: "%.1f", line.singEnd - line.singStart))s")
                                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                            }
                            .offset(x: singOffset, y: blockHeight - strip)
                            .allowsHitTesting(false)
                    }
                }

                // 低干扰序号：只帮助定位，不是歌词文字（RD §3.1 允许）。
                if let label = presentation.sequenceLabel, dispW >= 20 {
                    Text(label)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: dispW, height: blockHeight, alignment: .center)
                        .allowsHitTesting(false)
                }

                // 4) 只在选中时显示拖动边界。未选中状态不再显示紫色隔断，
                // 但原有的四个拖动热区仍保留，选中后即可精修显示/演唱边界。
                if isSelected && !isLocked {
                    handle(at: 0, height: Theme.lyricLaneHeight)
                    handle(at: dispW, height: Theme.lyricLaneHeight)
                    handle(at: singOffset, height: Theme.lyricLaneHeight, strong: true)
                    handle(at: singOffset + singW, height: Theme.lyricLaneHeight, strong: true)
                }
            } else {
                // 还没有时间：明确显示为「未分析」，不显示歌词文字。
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.dividerStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 96, height: blockHeight)
                if let label = presentation.sequenceLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 96, height: blockHeight, alignment: .center)
                }
            }
        }
        .frame(width: ready ? dispW : 96, height: Theme.lyricLaneHeight, alignment: .leading)
        .contentShape(Rectangle())
        // 点击由 LyricLane 的同时手势统一选中，避免高优先级 Tap recognizer
        // 抢掉本片段的拖动；轻微位移仍由下方 DragGesture 处理。
        //
        // 注意顺序：手势必须挂在 `.offset` 之前。挂在 offset 之后时，SwiftUI 给手势的是
        // 「偏移前的父坐标空间」，localX 变成整条时间线上的绝对坐标（实测 1398 对 497 宽的块），
        // 于是任何不在时间 0 附近的块都会被判成「整块移动」，边缘修剪与走轨条完全点不中。
        .gesture(dragGesture)
        .offset(x: dispX)
        .contextMenu {
            Button("在播放头分割") {
                state.selectLineForEditing(line.id)
                state.splitSelectedAtPlayhead()
            }
            .disabled(!state.project.isEditable(line) || !LineSplitter.canSplit(line, at: state.playhead))
            Button("复制该句") { state.duplicateLine(id: line.id) }
                .disabled(!state.project.isEditable(line))
            Button("恢复自动显示时间") { state.resetDisplayWindowToAuto(lineID: line.id) }
                .disabled(!state.project.isEditable(line)
                          || !(line.displayStartIsManual || line.displayEndIsManual))
            Divider()
            Button("删除该句", role: .destructive) {
                state.selectLineForEditing(line.id)
                state.deleteSelectedLine()
            }
            .disabled(!state.project.isEditable(line))
        }
        .help("第 \(line.order) 句\n演唱 \(line.singStart.timecode)–\(line.singEnd.timecode)  显示 \(line.displayStart.timecode)–\(line.displayEnd.timecode)\n置信度 \(String(format: "%.2f", line.confidence))\n内容：\(line.displayText)")
    }

    private func handle(at offset: CGFloat, height: CGFloat, strong: Bool = false) -> some View {
        Rectangle()
            .fill(strong ? Theme.selectionBorder.opacity(0.85) : Theme.selectionBorder.opacity(isSelected ? 0.7 : 0.3))
            .frame(width: strong ? 2 : 3, height: height - 10)
            .offset(x: offset)
    }

    // MARK: 拖动（坐标全部相对本视图）

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !isLocked else { return }
                state.setDraggingTimelineItem(true)
                if mode == .none {
                    mode = zone(for: value.startLocation)
                    origin = line
                    if mode != .none { state.beginEdit("拖动歌词片段") }
                    state.selectLineForEditing(line.id)
                }
                guard let origin else { return }
                let rawDelta = Double(value.translation.width) / pixelsPerSecond
                switch mode {
                case .shift:
                    // 移动：保持时长，落点与鼠标位移直接对应；四条边任意一条都能吸附。
                    let delta = state.snappedDelta(
                        edges: [origin.displayStart, origin.singStart, origin.singEnd, origin.displayEnd],
                        delta: rawDelta, excludingLine: origin.id)
                    let target = origin.displayStart + delta
                    // 色块到哪里，画面歌词就到哪里：整块移动后也定住显示窗口
                    let moved = LineEditor.freezingDisplayWindow(
                        LineEditor.moved(origin, by: target - origin.displayStart,
                                         bounds: 0...max(0.1, state.timelineDuration)))
                    state.replaceLine(moved, note: "移动")
                    state.editingHint = String(format: "移动  演唱 %.2f–%.2f  时长 %.2fs",
                                               moved.singStart, moved.singEnd,
                                               moved.singEnd - moved.singStart)
                case .displayStart, .displayEnd, .singStart, .singEnd:
                    // 修剪：边界跟随鼠标；非法落点则忽略（保持上一次合法状态）
                    let current = origin.edgeTime(mode)
                    // 本块自己的其它边也作为吸附点（例如把走轨起点对齐色块起点）
                    let ownEdges = [origin.displayStart, origin.singStart, origin.singEnd, origin.displayEnd]
                        .filter { abs($0 - current) > 1e-9 }
                    let target = current + state.snappedDelta(edges: [current], delta: rawDelta,
                                                              excludingLine: origin.id,
                                                              extraCandidates: ownEdges)
                    if let trimmed = LineEditor.trimmed(origin, edge: mode.edge, to: target) {
                        let retimed = LineEditor.freezingDisplayWindow(
                            LineEditor.retimed(trimmed, from: origin.singStart...origin.singEnd))
                        state.replaceLine(retimed, note: "修剪\(mode.edge.displayName)")
                        // 走轨时长就是扫色速度：拖走轨边缘时把它显示出来
                        state.editingHint = String(format: "%@ → %.2fs   走轨 %.2f–%.2f（%.2fs）",
                                                   mode.edge.displayName, target,
                                                   retimed.singStart, retimed.singEnd,
                                                   retimed.singEnd - retimed.singStart)
                    }
                case .sweepMove:
                    // 在色块内平移走轨：时长（速度）不变，不会拖出色块
                    let delta = state.snappedDelta(edges: [origin.singStart, origin.singEnd],
                                                   delta: rawDelta, excludingLine: origin.id,
                                                   extraCandidates: [origin.displayStart, origin.displayEnd])
                    let moved = LineEditor.sweepMoved(origin, by: delta)
                    state.replaceLine(moved, note: "平移走轨")
                    state.editingHint = String(format: "走轨 %.2f–%.2f（%.2fs）",
                                               moved.singStart, moved.singEnd,
                                               moved.singEnd - moved.singStart)
                case .none:
                    break
                }
            }
            .onEnded { _ in
                state.setDraggingTimelineItem(false)
                if mode != .none {
                    state.refreshDisplayWindows()
                    state.markSelectionManuallyAdjusted(mode == .shift ? "拖动移动" : (mode == .sweepMove ? "平移走轨" : "边缘修剪"))
                    state.scheduleAutosave()
                }
                mode = .none
                origin = nil
                state.editingHint = nil
            }
    }

    /// 判定拖动意图。**全部相对视图原点**（视图原点 = displayStart），
    /// 判定规则收在 `LyricBlockHitTest` 里以便单测。
    private func zone(for point: CGPoint) -> Mode {
        let pps = CGFloat(pixelsPerSecond)
        let dispW = CGFloat(max(line.displayEnd, line.singEnd) - line.displayStart) * pps
        let singOffset = CGFloat(max(0, line.singStart - line.displayStart)) * pps
        let singW = max(6, CGFloat(line.singEnd - line.singStart) * pps)
        switch LyricBlockHitTest.zone(localX: Double(point.x),
                                      displayWidth: Double(dispW),
                                      singOffset: Double(singOffset),
                                      singWidth: Double(singW),
                                      isSelected: isSelected,
                                      localY: Double(point.y),
                                      blockHeight: Double(Theme.lyricLaneHeight - 6)) {
        case .move: return .shift
        case .displayStart: return .displayStart
        case .displayEnd: return .displayEnd
        case .singStart: return .singStart
        case .singEnd: return .singEnd
        case .sweepMove: return .sweepMove
        }
    }
}

extension LyricSegmentView.Mode {
    /// 拖动模式 → 可修剪的边
    var edge: LineEditor.Edge {
        switch self {
        case .displayStart: return .displayStart
        case .displayEnd: return .displayEnd
        case .singStart: return .singStart
        case .singEnd: return .singEnd
        case .shift, .none, .sweepMove: return .singStart
        }
    }
}

private extension LyricLine {
    func edgeTime(_ mode: LyricSegmentView.Mode) -> Double {
        switch mode {
        case .displayStart: return displayStart
        case .displayEnd: return displayEnd
        case .singStart: return singStart
        case .singEnd: return singEnd
        case .shift, .none, .sweepMove: return singStart
        }
    }
}


// MARK: - 倒计时轨道

/// 倒计时轨道：与歌词轨道同一套交互（点击选中并定位、空白处拖动 scrub）。
struct CountdownLane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            // scrub 只绑在背景空白层上，色块在上层优先拿到拖动
            Theme.trackBackground
                .contentShape(Rectangle())
                .gesture(blankScrub)
            if state.project.trackStates.isVisible(.countdown) {
                ForEach(state.project.countdowns) { item in
                    CountdownSegmentView(item: item, pixelsPerSecond: state.pixelsPerSecond)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named(TimelineCoordinateSpace.viewport))
                .onEnded { value in
                    let x = Double(value.location.x)
                    let time = timelineTime(atViewportX: x, state: state)
                    if let item = state.project.countdowns.first(where: { time >= $0.start && time <= $0.end }) {
                        state.selectCountdown(item.id)
                    }
                    state.seekFromTimeline(viewportX: x)
                }
        )
        .contextMenu {
            Button("在播放头添加倒计时") { state.addCountdown(at: state.playhead) }
                .disabled(state.project.trackStates.isLocked(.countdown))
            if !state.project.countdowns.contains(where: \.isAuto) && !state.project.lyricLines.isEmpty {
                Button("恢复开头自动倒计时") { state.restoreAutoOpeningCountdown() }
            }
        }
        .help("倒计时轨道：色块存在的这段时间，画面上显示倒计时圆点。右键可在播放头新增。")
    }

    private var blankScrub: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.viewport))
            .onChanged { value in
                state.isScrubbing = true
                state.seekFromTimeline(viewportX: Double(value.location.x))
            }
            .onEnded { value in
                let time = timelineTime(atViewportX: Double(value.location.x), state: state)
                if let item = state.project.countdowns.first(where: { time >= $0.start && time <= $0.end }) {
                    state.selectCountdown(item.id)
                }
                state.isScrubbing = false
            }
    }
}

/// 倒计时色块：长度 = 倒计时在画面上存在的时间；选中后左右边缘可修剪，主体可整体移动。
/// 里面画出 N 个小圆点作为示意，已「走轨」的部分用走轨色，一眼看出它是倒计时。
struct CountdownSegmentView: View {
    let item: CountdownItem
    let pixelsPerSecond: Double
    @EnvironmentObject private var state: AppState

    private enum Mode { case none, move, start, end }
    @State private var mode: Mode = .none
    @State private var origin: CountdownItem?

    private var isSelected: Bool { state.selectedCountdownID == item.id }
    private var isLocked: Bool { state.project.trackStates.isLocked(.countdown) }

    var body: some View {
        let pps = CGFloat(pixelsPerSecond)
        let width = max(10, CGFloat(item.duration) * pps)
        let height = Theme.lyricLaneHeight - 6
        let style = state.project.style
        let sweep = style.countdownSweepColor.swiftUIColor
        let unlit = style.countdownUnsungColor.swiftUIColor

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Theme.countdownSegmentSelected : Theme.countdownSegment)
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.lyricSegmentStroke, lineWidth: 1)
                .frame(width: width, height: height)
            // 小圆点示意：走轨模式下前半段用走轨色，熄灭模式下全部用未走轨色
            HStack(spacing: 4) {
                ForEach(0..<style.countdown.dotCount, id: \.self) { index in
                    Circle()
                        .fill(style.countdown.mode == .fill && index < (style.countdown.dotCount + 1) / 2
                              ? sweep : unlit)
                        .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: width, height: height, alignment: .center)
            .opacity(width >= 34 ? 1 : 0)
            if width >= 96 {
                Text(String(format: "倒计时 %.1fs", item.duration))
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary.opacity(0.75))
                    .frame(width: width, height: height, alignment: .bottomTrailing)
                    .padding(.trailing, 4)
                    .padding(.bottom, 1)
                    .allowsHitTesting(false)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.timelineSelectionBorder, lineWidth: 2.5)
                    .frame(width: width, height: height)
                    .shadow(color: Theme.timelineSelectionBorder.opacity(0.45), radius: 2)
                if !isLocked {
                    handle(at: 0)
                    handle(at: width)
                }
            }
        }
        .frame(width: width, height: Theme.lyricLaneHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        // 手势必须挂在 `.offset` 之前：挂在之后时 SwiftUI 给的是偏移前的父坐标，
        // localX 会变成整条时间线上的绝对坐标，边缘判定永远落空（上次踩过的坑）。
        .gesture(dragGesture)
        .offset(x: CGFloat(item.start) * pps)
        .contextMenu {
            Button("删除倒计时", role: .destructive) { state.deleteCountdown(id: item.id) }
                .disabled(isLocked)
        }
        .help(String(format: "倒计时 %.2f–%.2f（%.1f 秒）\n选中后拖两侧边缘调整出现/结束时间，拖主体整体移动", item.start, item.end, item.duration))
    }

    private func handle(at offset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.selectionBorder.opacity(0.85))
            .frame(width: 3, height: Theme.lyricLaneHeight - 12)
            .offset(x: offset - 1.5, y: 3)
    }

    private func zone(for x: CGFloat, width: CGFloat) -> Mode {
        let tolerance: CGFloat = 6
        if abs(x) <= tolerance { return .start }
        if abs(x - width) <= tolerance { return .end }
        return .move
    }

    /// 位移用时间线「视口坐标」计算，而不是色块自己的局部坐标。
    ///
    /// 局部坐标会随色块本身移动（拖动时色块在鼠标下面走，播放时时间线还在自动滚动），
    /// 位移里就混进了色块自己的运动，表现为点一下或拖动就跳。
    /// 视口坐标只反映鼠标本身的移动；起点相对色块的位置用「色块在视口里的位置」换算出来。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1,
                    coordinateSpace: .named(TimelineCoordinateSpace.viewport))
            .onChanged { value in
                guard !isLocked else { return }
                state.setDraggingTimelineItem(true)
                let pps = CGFloat(pixelsPerSecond)
                if mode == .none {
                    let blockX = CGFloat(TimelineGeometry.viewportX(
                        forTime: item.start,
                        scrollX: state.scrollX,
                        pixelsPerSecond: pixelsPerSecond,
                        leadingPadding: Double(Theme.timelineLeadingInset)))
                    mode = zone(for: value.startLocation.x - blockX,
                                width: max(10, CGFloat(item.duration) * pps))
                    origin = item
                    state.beginEdit("拖动倒计时")
                    state.selectCountdown(item.id)
                }
                guard let origin else { return }
                let rawDelta = Double(value.translation.width) / pixelsPerSecond
                let edges: [Double]
                switch mode {
                case .move: edges = [origin.start, origin.end]
                case .start: edges = [origin.start]
                case .end: edges = [origin.end]
                case .none: edges = []
                }
                let delta = state.snappedDelta(edges: edges, delta: rawDelta, excludingCountdown: origin.id)
                var edited = origin
                switch mode {
                case .move:
                    let length = origin.end - origin.start
                    edited.start = max(0, origin.start + delta)
                    edited.end = edited.start + length
                case .start:
                    edited.start = min(max(0, origin.start + delta), origin.end - CountdownItem.minimumDuration)
                case .end:
                    edited.end = max(origin.end + delta, origin.start + CountdownItem.minimumDuration)
                case .none:
                    return
                }
                state.replaceCountdown(edited)
                state.editingHint = String(format: "倒计时 %.2f–%.2f（%.2f 秒）",
                                           edited.start, edited.end, edited.end - edited.start)
            }
            .onEnded { _ in
                state.setDraggingTimelineItem(false)
                if mode != .none { state.scheduleAutosave() }
                mode = .none
                origin = nil
                state.editingHint = nil
            }
    }
}
