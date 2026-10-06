import SwiftUI
import MaGiKaraKit

/// 歌词输入工作区。
///
/// 取代原来挤在左侧 140pt 侧栏里的窄输入框：占据**主要编辑区域**，
/// 只保留「粘贴歌词 → 生成 AI 歌词」这一条傻瓜流程，去掉实现细节与重复按钮。
struct LyricsWorkspace: View {
    @EnvironmentObject private var state: AppState
    @State private var draft: String = ""
    @State private var justApplied: Int?
    @State private var showsLyricsLookup = false
    @FocusState private var editorFocused: Bool

    private var parsedLineCount: Int {
        JapaneseReadingService.splitLyricLines(from: draft).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle().fill(Theme.divider).frame(height: 1)

            lyricContent
                .padding(.horizontal, 14)
                .padding(.top, 8)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panelSolid)
        .onAppear {
            syncDraftFromProject()
            editorFocused = true
        }
        .onChange(of: state.project.lyricLines.count) { _, _ in
            // 工程侧变化（打开工程/撤销）时同步草稿，但不要覆盖用户正在输入的内容
            if !editorFocused { syncDraftFromProject() }
        }
        .sheet(isPresented: $showsLyricsLookup) {
            LyricsCandidateSheet(initialTrackName: suggestedTrackName,
                                 mediaDurationSec: state.mediaInfo?.duration) { candidate in
                draft = candidate.lyricsText
                state.lyricsDraft = candidate.lyricsText
                state.applyLyrics(source: candidate.sourceInfo())
                justApplied = state.project.lyricLines.count
                state.autoGenerate()
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 1) {
                Text("歌词")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(showsNumberedLyrics ? "点击序号定位时间线" : "粘贴歌词 → 生成 AI 歌词")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if !state.hasMedia {
                Button {
                    state.importMedia()
                } label: {
                    Label("导入 MV / 音频", systemImage: "square.and.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.violet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.violet.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            // 分析进度 / 阶段 / 取消只在 RootView 的 analysisBanner 里出现，
            // header 不重复渲染；这里只保留分析完成后的 method 标签。
            if let method = state.project.analysis?.method {
                Text(method.shortLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(method.isAudioAutomaticAlignment ? Theme.violet : Theme.warning)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    // MARK: 输入区

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                // macOS 的 TextEditor 默认用 labelColor：系统处于深色模式时是白字，
                // 而这里背景是固定白色，于是出现白字白底。强制浅色外观 + 显式深色文字，
                // 选区仍用主题紫，保证选中文字可读。
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.violet)
                .colorScheme(.light)
                .scrollContentBackground(.hidden)
                .padding(10)
                .focused($editorFocused)

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("在这里粘贴日文歌词，一行一句")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .stroke(editorFocused ? Theme.violet.opacity(0.6) : Theme.divider, lineWidth: 1)
        )
    }

    /// 对轨完成后改用工程中的结构化歌词行展示序号，确保与时间线色块使用同一 order。
    /// 不在 TextEditor 文本前拼编号，避免编号进入歌词正文、对轨输入或导出内容。
    @ViewBuilder
    private var lyricContent: some View {
        if showsNumberedLyrics {
            numberedLyrics
        } else {
            editor
        }
    }

    private var showsNumberedLyrics: Bool {
        hasAnalysisResult && !state.project.sortedLines.isEmpty
    }

    private var numberedLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(state.project.sortedLines) { line in
                        let isSelected = state.selectedLineID == line.id
                        Button {
                            state.selectLineForEditing(line.id, seekToStart: true)
                        } label: {
                            HStack(alignment: .center, spacing: 9) {
                                Text("\(line.order)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(isSelected ? .white : Theme.violet)
                                    .frame(width: 27, height: 27)
                                    .background(
                                        isSelected ? Theme.violet : Theme.violet.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )

                                Text(line.displayText)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if line.needsReview {
                                    Circle()
                                        .fill(Theme.warning)
                                        .frame(width: 6, height: 6)
                                        .help("此句需要复核")
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Theme.violet.opacity(0.1) : .clear)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Theme.violet.opacity(0.28) : .clear, lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("第 \(line.order) 句 · 点击选中并定位时间线色块")
                        .id(line.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .onAppear {
                guard let id = state.selectedLineID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: state.selectedLineID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    // MARK: 底部操作 + 状态

    /// 左侧主操作区：未生成时点一次生成；已有 AI 结果时直接切到导出。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            primaryAction

            HStack(spacing: 8) {
                status
                Spacer(minLength: 0)
                if !showsNumberedLyrics {
                    Button {
                        showsLyricsLookup = true
                    } label: {
                        Label("在线搜歌词", systemImage: "magnifyingglass")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.violet)
                    .help("按歌曲名搜索歌词文本；时间戳会丢弃，之后仍由本机音频对轨")
                }
                if !draft.isEmpty && !showsNumberedLyrics {
                    Button("清空") {
                        draft = ""
                        justApplied = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// 底部主按钮按状态切换（RD §5.3）：
    /// - 已有 AI 分析结果：切到独立导出工作区（不再直接弹保存面板）；
    /// - 其余情况显示「AI 一键对轨」。
    /// 分析进行中的进度与取消由 RootView 的 analysisBanner 统一负责，不在这里重复。
    @ViewBuilder
    private var primaryAction: some View {
        if !state.isAnalyzing && hasAnalysisResult {
            Button {
                // 导出参数（画质/分辨率/帧率）和格式选择都在导出页完成。
                state.openExportWorkspace()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("去导出")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(canExport
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Theme.textTertiary.opacity(0.35)),
                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            }
            .buttonStyle(.plain)
            .disabled(!canExport)
            .help(exportHelp)
        } else {
            Button {
                generateFromDraft()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                    Text("AI 一键对轨")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(canGenerate
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Theme.textTertiary.opacity(0.35)),
                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate)
            .help(generateHelp)
        }
    }

    /// 是否可点「生成 AI 歌词」
    private var canGenerate: Bool {
        !state.isAnalyzing && state.hasMedia && (parsedLineCount > 0 || !state.project.lyricLines.isEmpty)
    }

    private var suggestedTrackName: String {
        let title = state.project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "未命名工程" else { return "" }
        return URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent
    }

    /// 是否已有一次可用的 AI 分析结果（RD §5.3 的 CTA 切换依据）。
    private var hasAnalysisResult: Bool { state.project.analysis != nil }

    /// 进入导出页的条件：必须有歌词和分析结果。
    /// 纯音频不再阻止进入导出页——导出页会禁用 MP4 并说明可导出 ASS/LRC/SRT。
    private var exportRequirementsMet: Bool {
        !state.project.lyricLines.isEmpty && hasAnalysisResult
    }

    private var canExport: Bool {
        exportRequirementsMet
    }

    private var exportHelp: String {
        if state.project.lyricLines.isEmpty { return "先粘贴或生成歌词" }
        if !hasAnalysisResult { return "先生成 AI 歌词" }
        return "进入导出工作区，选择画质 / 分辨率 / 帧率后导出"
    }

    private var generateHelp: String {
        if !state.hasMedia {
            return "先导入 MV 或音频"
        }
        if parsedLineCount > 0 {
            return "会自动应用粘贴的歌词，并生成演唱时间"
        }
        if state.project.lyricLines.isEmpty {
            return "先在上方粘贴歌词"
        }
        return "以粘贴的歌词为文本真值，用本地语音识别对齐出逐句与逐音拍时间"
    }

    /// 空 / 成功 / 错误三种状态，简短明确
    @ViewBuilder
    private var status: some View {
        if showsNumberedLyrics {
            Label("序号已对应 \(state.project.sortedLines.count) 句", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ok)
        } else if let n = justApplied {
            Label("已应用 \(n) 句", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ok)
        } else if parsedLineCount == 0 && state.project.lyricLines.isEmpty {
            Text("还没有歌词")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        } else if parsedLineCount == 0 {
            Text("已应用 \(state.project.lyricLines.count) 句")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text("将应用 \(parsedLineCount) 句")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: 行为

    private func syncDraftFromProject() {
        draft = state.project.sortedLines.map(\.displayText).joined(separator: "\n")
        if draft.isEmpty { justApplied = nil }
    }

    /// 入口只保留一个：用户粘贴歌词后点「生成 AI 歌词」即可自动应用并开始对轨。
    private func generateFromDraft() {
        if parsedLineCount > 0 {
            state.lyricsDraft = draft
            state.applyLyrics()
            justApplied = state.project.lyricLines.count
        }
        state.autoGenerate()
    }
}
