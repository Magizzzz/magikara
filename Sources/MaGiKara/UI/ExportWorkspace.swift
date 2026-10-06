import SwiftUI
import MaGiKaraKit

/// 模态导出工作区（视觉参考 FCPX：左侧预览 + 右侧参数）。
///
/// 设计目标：
/// - 参数简单明了：质量（低/中/高）、分辨率、帧率、预估大小、音频与字幕说明；
/// - 不照搬专业软件：一屏之内看完，不需要滚动也能点到主导出按钮；
/// - 画质 / 分辨率 / 帧率真正接进 `VideoExporter`，不是装饰。
///
/// 进入方式只有两个：右上角「导出」菜单，或歌词工作区分析完成后的「去导出」。
/// 它浮在主编辑工作区之上，关闭后不丢失当前编辑上下文。
struct ExportWorkspace: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack(spacing: 0) {
                previewColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                Rectangle().fill(Theme.divider).frame(width: 1)

                settingsColumn
                    .frame(width: 330)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspacePanel()
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.violet)

            VStack(alignment: .leading, spacing: 1) {
                Text("导出文件")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("导出带卡拉 OK 字幕的成片，或辅助字幕文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            Button {
                state.closeExportWorkspace()
            } label: {
                Label("取消", systemImage: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.violet)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.violet.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("回到歌词编辑工作区")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    // MARK: - 左：预览 + 播放控制

    /// 预览与播放控制保持原四区 UI 的空间关系：播放控制在预览正下方。
    private var previewColumn: some View {
        VStack(spacing: 0) {
            PreviewView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            PlaybackTimelineStrip()
        }
    }

    // MARK: - 右：导出参数

    private var settingsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let warning = blockingWarning {
                    warningBanner(warning)
                }

                // 主导出按钮放在最上面：窗口再矮也能直接点到，不必先滚动。
                actionSection
                Divider().overlay(Theme.divider)
                formatSection
                qualitySection
                audioQualitySection
                resolutionSection
                frameRateSection
                Divider().overlay(Theme.divider)
                estimateSection
                mediaInfoSection
                Divider().overlay(Theme.divider)
                notesSection
            }
            .padding(16)
        }
        .background(.white.opacity(0.35))
    }

    // MARK: 格式

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("导出格式")
            HStack(spacing: 8) {
                Label("MP4", systemImage: "film")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                Text("H.264 · AAC \(state.videoExportSettings.audioQuality.audioBitrate)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: 质量

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("质量", detail: "越低体积越小，越高画面越清晰")
            optionRow(selection: $state.videoExportSettings.bitrate,
                      options: VideoExportBitrate.allCases,
                      label: { $0.displayName })
        }
    }

    // MARK: 音频质量

    private var audioQualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("音频质量", detail: "普通适合日常导出，优质保留更多细节")
            optionRow(selection: $state.videoExportSettings.audioQuality,
                      options: VideoExportAudioQuality.allCases,
                      label: { $0.displayName })
        }
    }

    // MARK: 分辨率

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("分辨率", detail: "1080p / 4K 保持 16:9，非 16:9 素材居中补边")
            optionRow(selection: $state.videoExportSettings.resolution,
                      options: VideoExportResolution.allCases,
                      label: { $0.displayName })
        }
    }

    // MARK: 帧率

    private var frameRateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("帧率", detail: "源帧率保持原片节奏")
            optionRow(selection: $state.videoExportSettings.frameRate,
                      options: VideoExportFrameRate.allCases,
                      label: { $0.displayName })
        }
    }

    // MARK: 预估大小

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("预估文件大小")
            Text(state.estimatedExportSizeText)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text("按时长 \(state.exportDurationText) × （\(state.videoExportSettings.bitrate.displayName)画质视频码率 + \(state.videoExportSettings.audioQuality.displayName)音频 \(state.videoExportSettings.audioQuality.audioBitrate)）估算，实际会略有浮动。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 媒体信息

    private var mediaInfoSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("媒体信息")
            infoRow("时长", state.exportDurationText)
            infoRow("分辨率", state.exportResolutionText)
            infoRow("帧率", state.exportFrameRateText)
            infoRow("歌词", "\(state.project.lyricLines.count) 句")
        }
    }

    // MARK: 音频与字幕说明

    /// 与 `VideoExporter.audioMappingArguments` 的三种实际行为一一对应。
    private var audioNote: String {
        let quality = "AAC \(state.videoExportSettings.audioQuality.audioBitrate)（\(state.videoExportSettings.audioQuality.displayName)）"
        let project = state.project
        if VideoExporter.usesSeparatedAudio(project: project) {
            let instrumentalMuted = project.trackStates.isMuted(.audio)
            let vocalMuted = project.trackStates.isMuted(.vocal)
            switch (instrumentalMuted, vocalMuted) {
            case (false, false): return "混合伴奏与人声，\(quality)"
            case (false, true): return "仅伴奏（人声已静音），\(quality)"
            case (true, false): return "仅人声（伴奏已静音），\(quality)"
            case (true, true): return "导出无声音（伴奏和人声均已静音）"
            }
        }
        if project.trackStates.isMuted(.audio) { return "导出无声音（音频轨已静音）" }
        if VideoExporter.isAudioOnly(project: project) {
            return "纯音频素材：以黑底 1920×1080 画面承载字幕，\(quality)"
        }
        return "保留原音轨，\(quality)"
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("音频与字幕")
            Label(audioNote, systemImage: "waveform")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
            Text("逐字扫色、上下双轨与假名效果直接烧录进画面，导出后无需外挂字幕。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 主操作

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                state.exportVideo()
            } label: {
                HStack(spacing: 6) {
                    if state.isExportingVideo {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(state.isExportingVideo ? "正在导出…" : "导出 MP4")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(canExportVideo
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Theme.textTertiary.opacity(0.35)),
                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            }
            .buttonStyle(.plain)
            .disabled(!canExportVideo)
            .help(exportHelp)

            if state.isExportingVideo {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = state.exportProgress {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(Theme.violet)
                        Text("已完成 \(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Theme.violet)
                        Text("正在准备…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Button("取消导出") { state.cancelVideoExport() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.violet)
                }
            }

            Text("辅助格式")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 8) {
                auxiliaryButton("ASS", help: "保留逐字扫色与假名事件，可继续交给剪辑软件") {
                    state.exportASS()
                }
                auxiliaryButton("LRC", help: "逐行歌词时间轴，适合播放器与剪辑软件") {
                    state.exportLRC()
                }
                auxiliaryButton("SRT", help: "通用字幕格式，适合视频平台") {
                    state.exportSRT()
                }
            }
        }
    }

    private var canExportSubtitles: Bool { !state.project.lyricLines.isEmpty }

    /// 辅助格式按钮：用自定义描边按钮，避免系统 bordered 样式在本面板里不渲染。
    private func auxiliaryButton(_ title: String,
                                 help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(canExportSubtitles ? Theme.violet : Theme.textTertiary.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall)
                        .stroke(Theme.dividerStrong, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExportSubtitles)
        .help(help)
    }

    // MARK: - 状态与文案

    /// 无法导出 MP4 时的原因；nil 表示可以导出。
    private var exportBlockReason: String? {
        if state.project.lyricLines.isEmpty { return "还没有歌词，先在歌词工作区粘贴并生成 AI 歌词。" }
        if !state.project.hasMedia { return "还没有媒体素材，先导入 MV 或音频。" }
        if !state.project.mediaExists { return "媒体文件找不到，请先重新定位媒体。" }
        if !state.hasExportableVideo { return "媒体文件格式不受支持，可改用下方 ASS / LRC / SRT。" }
        if state.isExportingVideo { return "正在导出，请稍候…" }
        return nil
    }

    private var canExportVideo: Bool { exportBlockReason == nil }

    private var exportHelp: String {
        exportBlockReason ?? "按当前画质 / 分辨率 / 帧率导出带字幕的 MP4"
    }

    /// 顶部提示条：只提示真正影响导出的阻塞项。
    private var blockingWarning: String? {
        guard let reason = exportBlockReason else { return nil }
        // 导出进行中不是错误，不重复显示提示条。
        return state.isExportingVideo ? nil : reason
    }

    // MARK: - 小组件

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// 自定义分档选择器：等宽按钮替代系统 Picker，
    /// 保证三档/四档在同一行完整可见（本机 SwiftUI Picker 在这个面板里渲染异常）。
    private func optionRow<T: Hashable>(selection: Binding<T>,
                                        options: [T],
                                        label: @escaping (T) -> String) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isOn = selection.wrappedValue == option
                Button {
                    selection.wrappedValue = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? .white : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn
                                    ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Theme.controlFill),
                                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label(option))
            }
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
    }
}
