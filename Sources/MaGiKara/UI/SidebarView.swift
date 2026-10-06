import SwiftUI
import MaGiKaraKit

/// 左侧信息栏。
///
/// 导航（项目 / 歌词 / 字幕模版 / 导出）已经统一收到**顶部 Dock**，
/// 这里不再重复一套导航按钮，只保留当前工作区必需的**项目信息 / 轨道信息**。
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    private var sectionTitleText: String {
        switch state.sidebarSection {
        case .project: return "媒体"
        case .lyrics: return "歌词"
        case .style: return "字幕模版"
        case .export: return "导出"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sectionTitleText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider().overlay(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch state.sidebarSection {
                    case .project: ProjectSection()
                    case .lyrics: LyricsSection()
                    case .style: StyleSection()
                    case .export: ExportSection()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 1) {
                Text("MaGi Kara")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text("歌い続ける限り、きっとまた出会える！")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.white.opacity(0.40))
    }
}

// MARK: - 项目

struct ProjectSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("媒体")

            Button {
                state.importMedia()
            } label: {
                Label("导入媒体", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
            .buttonStyle(.plain)

            if state.project.hasMedia {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.project.mediaURL.lastPathComponent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    if !state.project.mediaExists {
                        Button("重新定位媒体…") { state.relocateMedia() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.error)
                    }
                }
            }

            keyValue("时长", state.mediaDuration > 0 ? state.mediaDuration.timecode : "—")
            keyValue("歌词句数", "\(state.project.lyricLines.count)")
            keyValue("待确认", "\(state.reviewLines.count)")
            keyValue("平均置信度", state.project.lyricLines.isEmpty
                     ? "—" : String(format: "%.2f", state.project.averageConfidence))
            keyValue("对齐器", state.alignerName)
            if let method = state.project.analysis?.method {
                keyValue("对轨方法", method.shortLabel)
            }

        }
    }
}

// MARK: - 歌词

struct LyricsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if state.project.lyricLines.isEmpty {
                Text("5 分钟生成卡拉 OK")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                step("1", "导入 MV 或音频")
                step("2", "在中间粘贴歌词")
                step("3", "点「生成 AI 歌词」")
                Text("每行一句歌词，AI 会自动对齐演唱时间。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                keyValue("已应用", "\(state.project.lyricLines.count) 句")
                Divider().overlay(Theme.divider)
                ForEach(state.project.sortedLines) { line in
                    Button {
                        state.selectLineForEditing(line.id)
                        state.seek(to: max(0, line.singStart))
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(confidenceColor(line.confidence))
                                .frame(width: 5, height: 5)
                            Text("\(line.order)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Text(line.displayText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(state.selectedLineID == line.id ? Theme.violet.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Theme.violet, in: Circle())
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - 样式

struct StyleSection: View {
    @EnvironmentObject private var state: AppState

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("歌词模版")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(SubtitleStyle.Preset.allCases) { preset in
                    Button {
                        state.applyPreset(preset)
                    } label: {
                        PresetTile(preset: preset)
                    }
                    .buttonStyle(.plain)
                    .help(preset.summary)
                }
            }
            Text("模版同时带着换行节奏（滚动 / 翻页、提前量、下行延后）。完整属性在右侧「字幕」面板中调整。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 模版按钮：一小块用该模版的字体与颜色画出的示例（左半「已唱」、右半「未唱」），下面是名字。
struct PresetTile: View {
    let preset: SubtitleStyle.Preset

    var body: some View {
        let style = preset.style
        let light = preset.previewOnLightBackground
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(light ? Color(white: 0.93) : Color(red: 0.14, green: 0.14, blue: 0.22))
                HStack(spacing: 0) {
                    Text("カラ")
                        .foregroundStyle(style.sungColor.swiftUIColor)
                    Text("オケ")
                        .foregroundStyle(style.unsungColor.swiftUIColor)
                }
                .font(.custom(style.fontName, size: 14).weight(swiftUIFontWeight(style.fontWeight)))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .shadow(color: style.strokeColor.swiftUIColor, radius: 0.6)
                .shadow(color: style.strokeColor.swiftUIColor, radius: 0.6)
            }
            .frame(height: 38)
            // 名字允许两行：「ニコカラ·经典蓝」「ニコカラ·樱粉」这类前缀相同的名字不能被截成同一个样子
            Text(preset.displayName)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .top)
        }
        .padding(5)
        .background(Theme.presetButtonFill, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerSmall)
                .strokeBorder(Theme.presetButtonBorder, lineWidth: 1)
        }
    }
}

// MARK: - 导出

struct ExportSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("导出")
            Button {
                state.exportVideo()
            } label: {
                Label(state.isExportingVideo ? "生成 MP4 中…" : "导出 MP4 视频", systemImage: "film")
                    .font(.system(size: 11.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(state.isExportingVideo)

            HStack {
                Text("视频画质")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Picker("视频画质", selection: $state.videoExportSettings.bitrate) {
                    ForEach(VideoExportBitrate.allCases, id: \.self) { bitrate in
                        Text(bitrate.displayName).tag(bitrate)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 72)
            }

            HStack {
                Text("音频质量")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Picker("音频质量", selection: $state.videoExportSettings.audioQuality) {
                    ForEach(VideoExportAudioQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 72)
            }

            Text("MP4 会把逐字扫色、双轨位置和假名效果直接烧录进视频。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 6) {
                Button("LRC") { state.exportLRC() }
                    .buttonStyle(.bordered)
                Button("SRT") { state.exportSRT() }
                    .buttonStyle(.bordered)
            }

            Divider().overlay(Theme.divider)
            sectionTitle("辅助格式")
            Text("ASS 保留逐字扫色与假名事件；LRC / SRT 适合继续交给剪辑软件处理。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - 共用小组件

@ViewBuilder
func sectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .textCase(.uppercase)
}

@ViewBuilder
func keyValue(_ key: String, _ value: String) -> some View {
    HStack(spacing: 4) {
        Text(key)
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
        Spacer(minLength: 2)
        Text(value)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

func confidenceColor(_ c: Double) -> Color {
    switch ConfidenceLevel.from(c) {
    case .normal: return Theme.ok
    case .warning: return Theme.warning
    case .low: return Theme.error
    }
}
