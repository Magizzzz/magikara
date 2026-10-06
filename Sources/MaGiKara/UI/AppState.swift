import Foundation
import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers
import MaGiKaraKit

enum SidebarSection: String, CaseIterable, Identifiable {
    case project, lyrics, style, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: return "媒体"
        case .lyrics: return "歌词"
        case .style: return "字幕模版"
        case .export: return "导出"
        }
    }
    var icon: String {
        switch self {
        case .project: return "folder"
        case .lyrics: return "music.note.list"
        case .style: return "paintbrush"
        case .export: return "square.and.arrow.up"
        }
    }

    /// 顶部 Dock 正常显示的工作区分页。
    /// 导出不再是普通工作区 tab，只从右上角「导出」主入口进入，
    /// 但 `.export` 仍保留为页面路由（`sidebarSection == .export`）。
    static var workspaceCases: [SidebarSection] { [.project, .lyrics, .style] }
}

/// 从 AVAsset 读到的媒体展示信息（全部可选，读不到就由界面回退成「源媒体」）。
struct MediaDisplayInfo: Equatable, Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var duration: Double?
    var hasVideo: Bool = false
}

@MainActor
final class MenuState: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var hasSelectedLine = false
    @Published private(set) var hasLyrics = false

    func update(canUndo: Bool, canRedo: Bool, isAnalyzing: Bool, hasSelectedLine: Bool, hasLyrics: Bool) {
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
        if self.isAnalyzing != isAnalyzing { self.isAnalyzing = isAnalyzing }
        if self.hasSelectedLine != hasSelectedLine { self.hasSelectedLine = hasSelectedLine }
        if self.hasLyrics != hasLyrics { self.hasLyrics = hasLyrics }
    }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: 工程

    @Published var project = KaraProject()
    @Published var projectURL: URL?
    @Published var selectedLineID: UUID?
    /// 时间线「倒计时」轨道上选中的色块；与选中歌词句互斥。
    @Published var selectedCountdownID: UUID?
    @Published var lyricsDraft: String = ""

    // MARK: 播放

    let playback = PlaybackEngine()
    @Published var playhead: Double = 0
    private var cancellables = Set<AnyCancellable>()

    // MARK: 时间线视图状态

    @Published var pixelsPerSecond: Double = 64
    @Published var timelineWidth: Double = 900

    // MARK: 分析

    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var analysisStage: String = ""
    @Published private(set) var isExportingVideo = false
    /// 导出进度 0…1；nil 表示刚开始或时长未知，界面显示不定进度。
    @Published private(set) var exportProgress: Double?
    private var exportCancellation: VideoExporter.Cancellation?
    /// 导出设置（画质 / 分辨率 / 帧率 / 音频质量），默认中画质、源分辨率、源帧率、普通音频。
    @Published var videoExportSettings = VideoExportSettings()
    private var analysisTask: Task<Void, Never>?
    /// 当前有效的分析会话 ID（RD §10.2 提交闸门）。
    /// 每次开始会产生后台结果的分析时生成；取消或提交后清空，
    /// 旧会话晚到的回调一律丢弃，不得写回工程或状态。
    private var activeAnalysisSessionID: UUID?
    /// 仅用于 UI 测试：默认必须是 false（RD §8.4）。
    @Published var useMockAligner = false
    /// 当前对轨能力的可用状态与说明，必须在 UI 上显示出来。
    @Published var alignmentAvailability: ASRAvailability = .unavailable("尚未检查")
    @Published var alignmentDetail: String = ""
    @Published var alignmentProviders: [AlignmentProviderInfo] = []

    // MARK: 媒体派生数据

    @Published var waveformPeaks: [Float] = []
    @Published var waveformRMS: [Float] = []
    @Published var vocalWaveformPeaks: [Float] = []
    @Published var vocalWaveformRMS: [Float] = []
    @Published var videoThumbnails: [NSImage] = []
    /// 媒体分辨率 / 帧率 / 时长（异步探测，拿不到时为 nil，界面显示「源媒体」）。
    @Published var mediaInfo: MediaDisplayInfo?
    /// 音频侧的人声段起点（吸附候选之一，来自与 ASR 无关的能量/似然检测）
    @Published var audioOnsets: [Double] = []

    // MARK: 人声分离

    @Published private(set) var isSeparatingVocal = false
    @Published private(set) var vocalSeparationProgress = 0.0
    @Published private(set) var vocalSeparationStage = ""
    private var vocalSeparationTask: Task<Void, Never>?
    private var activeVocalSeparationID: UUID?

    /// 仅当结果仍对应当前素材且两条文件都存在时，才向界面暴露为有效分轨。
    var validVocalSeparation: VocalSeparationAssets? {
        guard let assets = project.vocalSeparation,
              assets.sourceFingerprint == project.mediaFingerprint(),
              FileManager.default.fileExists(atPath: assets.vocalURL.path),
              FileManager.default.fileExists(atPath: assets.instrumentalURL.path) else { return nil }
        return assets
    }

    // MARK: 界面

    // 产品入口是“歌词 → 生成 AI 歌词”，不是工程管理；启动默认落在歌词工作区。
    @Published var sidebarSection: SidebarSection = .lyrics
    /// 右上角导出按钮打开的模态导出工作区；不切走主编辑工作区。
    @Published var isExportWorkspacePresented = false
    /// 运行环境配置单（缺模型 / 缺对轨环境时启动即弹出，菜单里也能再打开）。
    @Published var isRuntimeSetupPresented = !RuntimeSetup.isComplete
    let runtimeSetup = RuntimeSetupModel()
    /// 右侧只有两个主 Tab：文本（统一样式）/ 字幕（当前片段）。
    /// 默认落在「文本」，未选中色块时「字幕」显示空状态。
    @Published var inspectorTab: InspectorPrimaryTab = .text
    @Published var statusMessage = "直接粘贴歌词，导入 MV 后点「生成 AI 歌词」"
    @Published var errorMessage: String?
    @Published var showLyricEditor = false
    @Published var editingLineID: UUID?
    @Published var analysisNotes: [String] = []
    @Published var isScrubbing = false
    /// 程序化跳转（打开工程 / 跳到待确认 / 分析结束）时，请求时间线滚动到该句。
    /// 时间线自己消费完就清空，避免一直把视图拉回去。
    @Published var scrollTarget: UUID?
    /// 时间线横向滚动位置（点）。自己管理而不是交给 ScrollView：
    /// ScrollViewReader 的 scrollTo 在这里定位不准（实测会滚到 01:18 而不是 00:27）。
    @Published var scrollX: Double = 0
    /// 最近一次鼠标点击/拖动定位的时间；用于空工程里保留手动定位标记的可见性。
    /// 实际播放头位置与缩放锚点均以 `playhead` 为准。
    @Published var timelineClickMarkerTime: Double?
    /// 时间线可视宽度，由 TimelineView 汇报
    var viewportWidth: Double = 900

    private let undoStack = UndoStack()
    private let autosaver = Autosaver()
    private let vocalSeparator = VocalSeparator()
    /// 连续输入（文案 / 时间 / Ruby）的撤销合并键：
    /// 同一个键的连续修改只记录一次撤销点，切换片段或停止输入后才重新记录。
    private var activeBurstKey: String?
    private var mediaLoadTask: Task<Void, Never>?
    private var mediaInfoTask: Task<Void, Never>?
    /// 启动参数只处理一次（applicationDidFinishLaunching 与 RootView.onAppear 都会调用）
    private var didOpenLaunchProject = false
    /// 排版缓存（Core Text 测量较贵，避免每帧重算）
    let layoutCache = LayoutCache()

    /// 取某一行的排版结果（预览与 ASS 导出共用同一套计算）
    func layout(for line: LyricLine) -> LineLayout {
        layoutCache.layout(for: line, style: project.style)
    }

    /// 当前会用的对齐器名称（用于 UI 显示）
    var alignerName: String {
        if useMockAligner { return "Mock（仅 UI 测试）" }
        return alignmentDetail.isEmpty ? "ASR 强制对齐（本地离线）" : alignmentDetail
    }

    /// 刷新对轨能力状态（进入 AI 面板时调用）
    func refreshAlignmentAvailability() {
        Task { @MainActor in
            alignmentProviders = await AlignmentEngineFactory.providers()
            alignmentAvailability = await AlignmentEngineFactory.currentAvailability()
        }
    }

    init() {
        playback.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                if !self.isScrubbing { self.playhead = t }
            }
            .store(in: &cancellables)
        // objectWillChange 在改值之前发出，下一轮主循环再读，拿到的是改完之后的值。
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &cancellables)
    }

    /// 菜单栏只关心这几个开关；单独放一个对象，播放头每帧变化时菜单不用跟着重建。
    let menuState = MenuState()

    private func refreshMenuState() {
        menuState.update(canUndo: canUndo,
                         canRedo: canRedo,
                         isAnalyzing: isAnalyzing,
                         hasSelectedLine: selectedLineID != nil,
                         hasLyrics: !project.lyricLines.isEmpty)
    }

    // MARK: - 派生

    var sortedLines: [LyricLine] { project.sortedLines }
    var selectedLine: LyricLine? {
        guard let id = selectedLineID else { return nil }
        return project.lyricLines.first { $0.id == id }
    }
    var reviewLines: [LyricLine] { project.linesNeedingReview }
    var hasMedia: Bool { project.hasMedia && project.mediaExists }
    var duration: Double { max(project.duration, playback.duration, 1) }
    /// 工程或播放器记录的实际时长；空工程保持为 0，供媒体信息与占位文案判断。
    var mediaDuration: Double { max(project.duration, playback.duration) }
    /// 空工程仍提供可编辑的 5 分钟时间线；有媒体时沿用真实时长，并容纳超出媒体尾部的歌词。
    var timelineDuration: Double {
        let lyricEnd = project.lyricLines.map(\.displayEnd).max() ?? 0
        if mediaDuration > 0 { return max(mediaDuration, lyricEnd) }
        return max(300, lyricEnd)
    }

    // MARK: - 导出派生（供导出工作区展示）

    /// 兼容旧代码：码率就是导出设置里的画质档。
    var videoExportBitrate: VideoExportBitrate {
        get { videoExportSettings.bitrate }
        set { videoExportSettings.bitrate = newValue }
    }

    /// 预估文件大小（字节）：始终用有效时长（至少 1 秒）计算，不显示空值。
    var estimatedExportSize: Double {
        videoExportSettings.estimatedFileSize(duration: duration)
    }

    /// 预估文件大小的人类可读文本。
    var estimatedExportSizeText: String {
        Self.formatBytes(estimatedExportSize)
    }

    static func formatBytes(_ bytes: Double) -> String {
        guard bytes > 0, bytes.isFinite else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// 导出 MP4 的素材条件：真实存在的视频，或真实存在的音频（纯音频用黑底画布承载字幕）。
    var hasExportableVideo: Bool {
        guard project.hasMedia, project.mediaExists else { return false }
        return MediaImportValidator.kind(forExtension: project.mediaURL.pathExtension) != nil
    }

    var exportResolutionText: String {
        guard let info = mediaInfo,
              let w = info.pixelWidth, let h = info.pixelHeight, w > 0, h > 0 else {
            return "源媒体"
        }
        return "\(w) × \(h)"
    }

    var exportFrameRateText: String {
        guard let fps = mediaInfo?.frameRate, fps > 0 else { return "源媒体" }
        return String(format: "%.2f fps", fps)
    }

    var exportDurationText: String {
        guard project.duration > 0 || playback.duration > 0 else { return "源媒体" }
        return duration.timecode
    }

    var effectiveStyle: SubtitleStyle {
        guard let line = selectedLine, let o = line.styleOverride else { return project.style }
        return o.applied(to: project.style)
    }

    // MARK: - 运行环境配置单

    func openRuntimeSetup() {
        runtimeSetup.refresh()
        if case .running = runtimeSetup.phase {} else { runtimeSetup.backToOverview() }
        isRuntimeSetupPresented = true
    }

    func closeRuntimeSetup() {
        if case .running = runtimeSetup.phase { runtimeSetup.cancel() }
        isRuntimeSetupPresented = false
    }

    // MARK: - 导出工作区

    func openExportWorkspace() {
        isExportWorkspacePresented = true
    }

    func closeExportWorkspace() {
        isExportWorkspacePresented = false
        if sidebarSection == .export {
            sidebarSection = .lyrics
        }
    }

    // MARK: - 撤销

    func beginEdit(_ label: String) {
        undoStack.record(project, label: label)
    }

    func undo() {
        let previousSeparation = project.vocalSeparation
        guard let p = undoStack.undo(current: project) else { return }
        project = p
        if previousSeparation != p.vocalSeparation { reloadProjectAudio() }
        statusMessage = "已撤销"
        scheduleAutosave()
    }

    func redo() {
        let previousSeparation = project.vocalSeparation
        guard let p = undoStack.redo(current: project) else { return }
        project = p
        if previousSeparation != p.vocalSeparation { reloadProjectAudio() }
        statusMessage = "已重做"
        scheduleAutosave()
    }

    private func reloadProjectAudio() {
        guard project.hasMedia, project.mediaExists else { return }
        if let stems = validVocalSeparation {
            do {
                try playback.loadSeparated(url: project.mediaURL,
                                           vocalURL: stems.vocalURL,
                                           instrumentalURL: stems.instrumentalURL,
                                           audioMuted: project.trackStates.isMuted(.audio),
                                           vocalMuted: project.trackStates.isMuted(.vocal))
            } catch {
                project.vocalSeparation = nil
                playback.load(url: project.mediaURL,
                              audioMuted: project.trackStates.isMuted(.audio))
                errorMessage = "分离音轨载入失败：\(error.localizedDescription)"
            }
        } else {
            playback.load(url: project.mediaURL,
                          audioMuted: project.trackStates.isMuted(.audio))
            vocalWaveformPeaks = []
            vocalWaveformRMS = []
        }
        playback.seek(to: playhead)
        loadDerivedMediaData(url: project.mediaURL, preferredDuration: project.duration)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    func scheduleAutosave() {
        guard let url = projectURL else { return }
        let snapshot = project
        autosaver.schedule(url: url, provider: { snapshot })
    }

    // MARK: - 媒体导入

    func importMedia() {
        let panel = NSOpenPanel()
        panel.title = "导入 MV / 视频 / 音频"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.mediaTypes
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadMedia(url: url)
    }

    static var mediaTypes: [UTType] {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .mp3, .wav, .audio]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let aiff = UTType(filenameExtension: "aiff") { types.append(aiff) }
        if let aif = UTType(filenameExtension: "aif") { types.append(aif) }
        return types
    }

    func loadMedia(url: URL) {
        cancelVocalSeparation()
        beginEdit("导入媒体")
        timelineClickMarkerTime = nil
        scrollX = 0
        playhead = 0
        project.mediaURL = url
        project.vocalSeparation = nil
        vocalWaveformPeaks = []
        vocalWaveformRMS = []
        project.mediaBookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
        if project.title == "未命名工程" {
            project.title = url.deletingPathExtension().lastPathComponent
        }
        playback.load(url: url, audioMuted: project.trackStates.isMuted(.audio))
        // AVPlayerLayer 在从未播放也从未 seek 过时不一定会画出首帧，
        // 所以这里显式 seek 一次，保证预览立刻有画面。
        playback.seek(to: 0)
        statusMessage = "已导入 \(url.lastPathComponent)"
        loadDerivedMediaData(url: url, preferredDuration: project.duration)
        refreshMediaInfo()
        scheduleAutosave()
    }

    /// 生成视频轨缩略图（纯音频媒体返回空数组）。
    ///
    /// 注意：这里**不能**用 semaphore 等一个内部 Task 去取 asset 时长。
    /// 之前那样写会在协作线程池里自锁，导致整个媒体加载任务卡住，
    /// 表现为「缩略图、波形、时长全都没有」。所以时长由调用方传入，函数保持纯同步。
    nonisolated static func makeThumbnails(url: URL, duration: Double, count: Int) -> [NSImage] {
        guard duration > 1 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var images: [NSImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        return images
    }

    /// 载入媒体派生数据（时长、波形、缩略图）。
    /// 分三次回主线程赋值，任何一步失败都不会连带丢掉其它结果。
    private func loadDerivedMediaData(url: URL, preferredDuration: Double) {
        mediaLoadTask?.cancel()
        let separation = validVocalSeparation
        DebugLog.write("media: 开始加载 \(url.path)")
        mediaLoadTask = Task.detached(priority: .utility) { [weak self] in
            let probed = await AudioDecoder.duration(of: url)
            let duration = probed > 0 ? probed : preferredDuration
            DebugLog.write("media: 时长探测 = \(probed) (fallback \(preferredDuration))")

            var peakList: [Float] = []
            var rmsList: [Float] = []
            var vocalPeakList: [Float] = []
            var vocalRMSList: [Float] = []
            var onsets: [Double] = []
            do {
                let decoded = try AudioDecoder.decode(url: url, peakBuckets: 4000)
                peakList = decoded.peaks
                rmsList = decoded.rms
                // 顺便取人声段起点，作为时间线吸附的候选（与 ASR 无关的音频侧参考）
                let features = AudioFeatureExtractor.extract(from: decoded)
                onsets = OnsetSnapper.islandOnsets(features: features)
                DebugLog.write("media: 解码成功 samples=\(decoded.samples.count) 人声段起点=\(onsets.count)")
            } catch {
                DebugLog.write("media: 解码失败 \(error.localizedDescription)")
            }

            // 已分离工程直接恢复伴奏/人声波形；任何一路文件损坏都回退显示原媒体波形。
            if let separation {
                do {
                    let instrumental = try AudioDecoder.decode(url: separation.instrumentalURL,
                                                               peakBuckets: 4000)
                    let vocal = try AudioDecoder.decode(url: separation.vocalURL,
                                                        peakBuckets: 4000)
                    peakList = instrumental.peaks
                    rmsList = instrumental.rms
                    vocalPeakList = vocal.peaks
                    vocalRMSList = vocal.rms
                } catch {
                    DebugLog.write("stem: 恢复波形失败 \(error.localizedDescription)")
                }
            }

            // MainActor.run 的闭包是 @Sendable，不能引用外部可变变量；
            // 解码结果此后不再变化，冻结成不可变局部再传回主线程。
            let peaks = peakList
            let rms = rmsList
            let vocalPeaks = vocalPeakList
            let vocalRMS = vocalRMSList
            let onsetTimes = onsets

            await MainActor.run { [weak self] in
                guard let self else { return }
                if duration > 0 {
                    self.project.duration = duration
                    self.playback.setDuration(duration)
                }
                self.waveformPeaks = peaks
                self.waveformRMS = rms
                self.vocalWaveformPeaks = vocalPeaks
                self.vocalWaveformRMS = vocalRMS
                self.audioOnsets = onsetTimes
                self.scheduleAutosave()
            }
            DebugLog.write("media: 波形已回填 count=\(peakList.count)")

            let thumbs = Self.makeThumbnails(url: url, duration: duration, count: 14)
            DebugLog.write("media: 缩略图 = \(thumbs.count) 张")
            await MainActor.run { [weak self] in
                self?.videoThumbnails = thumbs
            }
            DebugLog.write("media: 完成")
        }
    }

    // MARK: - AI 人声分离

    func startVocalSeparation() {
        guard hasMedia else {
            statusMessage = "请先导入 MV 或音频"
            return
        }
        guard !isSeparatingVocal else { return }
        guard !isAnalyzing else {
            statusMessage = "请等待当前歌词分析完成，再开始人声分离"
            return
        }
        guard project.duration > 0,
              let sourceFingerprint = project.mediaFingerprint() else {
            statusMessage = "正在读取媒体信息，请稍后再试"
            return
        }

        let sourceURL = project.mediaURL
        let sessionID = UUID()
        let outputDirectory: URL
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
            outputDirectory = support
                .appendingPathComponent("MaGiKara/SeparatedAudio/\(sessionID.uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            errorMessage = "无法创建人声分离缓存：\(error.localizedDescription)"
            return
        }

        let vocalURL = outputDirectory.appendingPathComponent("vocal.wav")
        let instrumentalURL = outputDirectory.appendingPathComponent("instrumental.wav")
        activeVocalSeparationID = sessionID
        isSeparatingVocal = true
        vocalSeparationProgress = 0
        vocalSeparationStage = "准备本地分离模型"
        statusMessage = "正在准备 AI 人声分离（首次使用会下载约 42 MB 模型）"

        vocalSeparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await vocalSeparator.ensureModel { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeVocalSeparationID == sessionID else { return }
                        self.vocalSeparationStage = "首次安装本地模型"
                        self.vocalSeparationProgress = min(0.12, fraction * 0.12)
                    }
                }
                guard activeVocalSeparationID == sessionID else { throw CancellationError() }
                vocalSeparationStage = "AI 正在分离人声与伴奏"

                let result = try await vocalSeparator.separate(
                    mediaURL: sourceURL,
                    toVocalURL: vocalURL,
                    toInstrumentalURL: instrumentalURL) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeVocalSeparationID == sessionID else { return }
                            self.vocalSeparationProgress = 0.12 + min(1, max(0, fraction)) * 0.88
                        }
                    }

                let waveforms = try await Task.detached(priority: .utility) {
                    let instrumental = try AudioDecoder.decode(url: result.instrumentalURL,
                                                               peakBuckets: 4000)
                    let vocal = try AudioDecoder.decode(url: result.vocalURL, peakBuckets: 4000)
                    return (instrumental, vocal)
                }.value

                guard activeVocalSeparationID == sessionID,
                      project.mediaURL.standardizedFileURL == sourceURL.standardizedFileURL,
                      project.mediaFingerprint() == sourceFingerprint else {
                    try? FileManager.default.removeItem(at: outputDirectory)
                    throw CancellationError()
                }

                let assets = VocalSeparationAssets(vocalURL: result.vocalURL,
                                                   instrumentalURL: result.instrumentalURL,
                                                   sourceFingerprint: sourceFingerprint,
                                                   modelID: vocalSeparator.modelInfo.compiledCacheKey,
                                                   sampleRate: result.sampleRate,
                                                   duration: result.duration)
                playback.pause()
                try playback.loadSeparated(url: sourceURL,
                                           vocalURL: assets.vocalURL,
                                           instrumentalURL: assets.instrumentalURL,
                                           audioMuted: project.trackStates.isMuted(.audio),
                                           vocalMuted: project.trackStates.isMuted(.vocal))
                playback.seek(to: playhead)

                beginEdit("AI人声分离")
                project.vocalSeparation = assets
                waveformPeaks = waveforms.0.peaks
                waveformRMS = waveforms.0.rms
                vocalWaveformPeaks = waveforms.1.peaks
                vocalWaveformRMS = waveforms.1.rms
                vocalSeparationProgress = 1
                statusMessage = "AI 人声分离完成：人声与伴奏已加入时间线"
                isSeparatingVocal = false
                vocalSeparationStage = ""
                activeVocalSeparationID = nil
                vocalSeparationTask = nil
                scheduleAutosave()
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputDirectory)
                if activeVocalSeparationID == sessionID {
                    isSeparatingVocal = false
                    vocalSeparationStage = ""
                    activeVocalSeparationID = nil
                    vocalSeparationTask = nil
                    statusMessage = "已取消 AI 人声分离"
                }
            } catch {
                try? FileManager.default.removeItem(at: outputDirectory)
                if activeVocalSeparationID == sessionID {
                    isSeparatingVocal = false
                    vocalSeparationStage = ""
                    activeVocalSeparationID = nil
                    vocalSeparationTask = nil
                    errorMessage = "AI 人声分离失败：\(error.localizedDescription)"
                    statusMessage = "人声分离没有写入时间线"
                }
            }
        }
    }

    func cancelVocalSeparation() {
        guard isSeparatingVocal else { return }
        activeVocalSeparationID = nil
        vocalSeparationTask?.cancel()
        vocalSeparationTask = nil
        isSeparatingVocal = false
        vocalSeparationStage = ""
        statusMessage = "正在取消人声分离…"
    }

    /// 异步读取媒体分辨率 / 帧率 / 时长，供导出页展示。
    ///
    /// 纯音频、无法解析或读取失败时保留 nil，界面统一回退成「源媒体」，
    /// 不会让导出页崩溃或显示空白。
    func refreshMediaInfo() {
        mediaInfoTask?.cancel()
        guard project.hasMedia, project.mediaExists else {
            mediaInfo = nil
            return
        }
        let url = project.mediaURL
        mediaInfoTask = Task.detached(priority: .utility) { [weak self] in
            let asset = AVURLAsset(url: url)
            var info = MediaDisplayInfo()
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 { info.duration = seconds }
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                info.hasVideo = true
                if let size = try? await track.load(.naturalSize) {
                    let transform = (try? await track.load(.preferredTransform)) ?? .identity
                    let oriented = size.applying(transform)
                    let width = Int(abs(oriented.width).rounded())
                    let height = Int(abs(oriented.height).rounded())
                    if width > 0, height > 0 {
                        info.pixelWidth = width
                        info.pixelHeight = height
                    }
                }
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    info.frameRate = Double(fps)
                }
            }
            // MainActor.run 的闭包是 @Sendable，不能引用外部可变变量；
            // 探测结果此后不再变化，冻结成不可变局部再传回主线程。
            let probedInfo = info
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.mediaInfo = probedInfo
            }
        }
    }

    // MARK: - 拖放导入

    /// 处理从 Finder 拖入的文件。
    ///
    /// 只接受受支持且真实存在的媒体文件；无效文件给出简短原因，不阻塞界面。
    /// 载入过程本身是后台任务，拖放不会卡住 UI。
    @discardableResult
    func handleDroppedFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let (accepted, rejections) = MediaImportValidator.firstAcceptable(from: urls)
        guard let accepted else {
            errorMessage = rejections.first ?? "没有可导入的文件"
            statusMessage = "拖入的文件无法导入"
            return false
        }
        if accepted.url.standardizedFileURL == project.mediaURL.standardizedFileURL {
            // 重复拖入同一个文件：不重新加载，避免白跑一次解码
            statusMessage = "这个文件已经导入过了"
            return true
        }
        loadMedia(url: accepted.url)
        statusMessage = "已拖入\(accepted.kind.displayName)：\(accepted.url.lastPathComponent)"
        return true
    }

    func relocateMedia() {
        let panel = NSOpenPanel()
        panel.title = "重新定位媒体文件"
        panel.allowedContentTypes = Self.mediaTypes
        panel.prompt = "定位"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginEdit("重新定位媒体")
        project.mediaURL = url
        project.mediaBookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
        playback.load(url: url)
        loadMedia(url: url)
        statusMessage = "媒体已重新定位"
    }

    // MARK: - 歌词

    func applyLyrics(source: LyricsSourceInfo? = nil) {
        let lines = AnalysisCoordinator.makeLines(from: lyricsDraft, dictionary: project.dictionary)
        guard !lines.isEmpty else {
            errorMessage = "没有解析出歌词行"
            return
        }
        beginEdit("应用歌词")
        let existing = project.sortedLines
        let contentChanged = existing.map(\.displayText) != lines.map(\.displayText)
        if contentChanged {
            // Lyrics are the alignment transcript. Reusing old timings by row index
            // can stretch a newly repeated outro over stale timing from the prior text.
            project.lyricLines = lines
            project.analysis = nil
            project.lyricsSource = source
        } else {
            project.lyricLines = existing
            if let source { project.lyricsSource = source }
        }
        project.renumber()
        if !project.lyricLines.isEmpty {
            DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        }
        project.enforceAllInvariants()
        project.syncOpeningCountdown()
        statusMessage = "已应用 \(project.lyricLines.count) 句歌词"
        scheduleAutosave()
    }

    func updateLineText(id: UUID, text: String) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("修改歌词")
        project.lyricLines[idx].displayText = text
        AnalysisCoordinator.refreshTokens(for: &project.lyricLines[idx], dictionary: project.dictionary)
        scheduleAutosave()
    }

    func updateReading(lineID: UUID, tokenID: UUID, reading: String) {
        guard let li = project.lyricLines.firstIndex(where: { $0.id == lineID }),
              let ti = project.lyricLines[li].tokens.firstIndex(where: { $0.id == tokenID }) else { return }
        beginEdit("修改读音")
        let normalized = JapaneseText.normalizeReading(reading)
        let surface = project.lyricLines[li].tokens[ti].surface
        project.lyricLines[li].tokens[ti].reading = normalized.isEmpty ? nil : normalized
        // 用户修正写入项目词典（RD §6.1）
        if !normalized.isEmpty {
            project.dictionary[surface] = normalized
        } else {
            project.dictionary.removeValue(forKey: surface)
        }
        project.lyricLines[li].needsReview = true
        project.lyricLines[li].reviewReasons = ["读音已修改，建议重新对齐该句"]
        scheduleAutosave()
    }

    // MARK: - 选中 / 双 Tab 联动（RD §3.3 / §4.1）

    /// 点击任意时间轴色块或预览字幕：设置选中，并自动激活「字幕」Tab。
    func selectLineForEditing(_ id: UUID, seekToStart: Bool = false) {
        // 切换片段前先结束上一段连续输入，保证已输入内容不被静默丢弃。
        endEditBurst()
        selectedCountdownID = nil
        selectedLineID = id
        inspectorTab = SubtitleEditorRouting.tab(afterSelectingLine: id, from: inspectorTab)
        if seekToStart, let line = project.lyricLines.first(where: { $0.id == id }) {
            seek(to: max(0, line.displayStart))
        }
    }

    /// 右侧 Tab 切换（选中状态保留，不因为切 Tab 丢失 selectedLineID）。
    func setInspectorTab(_ tab: InspectorPrimaryTab) {
        endEditBurst()
        inspectorTab = tab
    }

    func clearSelection() {
        endEditBurst()
        selectedCountdownID = nil
        selectedLineID = nil
        inspectorTab = SubtitleEditorRouting.tab(afterSelectionChangeTo: nil, from: inspectorTab)
    }

    /// 连续输入期间只记录一次撤销点。
    func beginEditBurst(key: String, label: String) {
        if activeBurstKey != key {
            undoStack.record(project, label: label)
        }
        activeBurstKey = key
    }

    /// 结束连续输入（切换片段 / Tab / 提交时调用）。
    func endEditBurst() {
        activeBurstKey = nil
    }

    // MARK: - 字幕 Tab：文案 / 上下行 / 层级

    /// 修改单行文案。保留仍能对上的 Ruby 覆盖，失效绑定自动清理（RD §6.3）。
    func setLineText(id: UUID, text: String) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        guard project.lyricLines[idx].displayText != text else { return }
        beginEditBurst(key: "text-\(id.uuidString)", label: "修改文案")

        var overridesBySurface: [String: [RubyOverride]] = [:]
        for token in project.lyricLines[idx].tokens {
            let overrides = token.sanitizedRubyOverrides()
            if !overrides.isEmpty { overridesBySurface[token.surface] = overrides }
        }

        project.lyricLines[idx].displayText = text
        AnalysisCoordinator.refreshTokens(for: &project.lyricLines[idx], dictionary: project.dictionary)

        for ti in project.lyricLines[idx].tokens.indices {
            let surface = project.lyricLines[idx].tokens[ti].surface
            if let kept = overridesBySurface[surface] {
                project.lyricLines[idx].tokens[ti].rubyOverrides = kept
            }
        }
        scheduleAutosave()
    }

    /// 切换上下行并标记为手工指定，后续 renumber 不会改回去。
    func setLineLane(id: UUID, lane: ScreenLane) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        guard project.lyricLines[idx].lane != lane || !project.lyricLines[idx].laneIsManual else { return }
        beginEdit("切换上下行")
        project.lyricLines[idx].lane = lane
        project.lyricLines[idx].laneIsManual = true
        statusMessage = "第 \(project.lyricLines[idx].order) 句已移动到\(lane.displayName)"
        scheduleAutosave()
    }

    func setLineLayer(id: UUID, layer: Int) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(99, layer))
        guard project.lyricLines[idx].layer != clamped else { return }
        beginEdit("修改层级")
        project.lyricLines[idx].layer = clamped
        scheduleAutosave()
    }

    // MARK: - Ruby 逐段人工修正（RD §4.4 / §6.3）

    /// 给某个 token 内的一段汉字设置 Ruby；`reading` 为空表示删除该段绑定（保留可恢复槽位）。
    func setRubyReading(lineID: UUID,
                        tokenID: UUID,
                        surfaceStart: Int,
                        surfaceLength: Int,
                        reading: String) {
        guard let li = project.lyricLines.firstIndex(where: { $0.id == lineID }),
              let ti = project.lyricLines[li].tokens.firstIndex(where: { $0.id == tokenID }) else { return }
        beginEditBurst(key: "ruby-\(tokenID.uuidString)-\(surfaceStart)", label: "修改假名")
        project.lyricLines[li].tokens[ti].setRubyOverride(surfaceStart: surfaceStart,
                                                          surfaceLength: surfaceLength,
                                                          reading: reading)
        project.lyricLines[li].needsReview = true
        project.lyricLines[li].reviewReasons = ["假名已人工修改，建议核对"]
        scheduleAutosave()
    }

    /// 删除该段绑定（抑制自动注音）；槽位仍保留，可重新填写。
    func clearRubyBinding(lineID: UUID, tokenID: UUID, surfaceStart: Int) {
        setRubyReading(lineID: lineID, tokenID: tokenID,
                       surfaceStart: surfaceStart, surfaceLength: 1, reading: "")
    }

    /// 恢复该段为自动对齐结果。
    func restoreRubyBinding(lineID: UUID, tokenID: UUID, surfaceStart: Int) {
        guard let li = project.lyricLines.firstIndex(where: { $0.id == lineID }),
              let ti = project.lyricLines[li].tokens.firstIndex(where: { $0.id == tokenID }) else { return }
        beginEdit("恢复自动假名")
        project.lyricLines[li].tokens[ti].removeRubyOverride(surfaceStart: surfaceStart)
        scheduleAutosave()
    }

    /// 清空该句全部人工 Ruby，回到自动对齐结果。
    func resetRubyOverrides(lineID: UUID) {
        guard let li = project.lyricLines.firstIndex(where: { $0.id == lineID }) else { return }
        guard project.lyricLines[li].tokens.contains(where: { !$0.sanitizedRubyOverrides().isEmpty }) else { return }
        beginEdit("重置假名")
        for ti in project.lyricLines[li].tokens.indices {
            project.lyricLines[li].tokens[ti].rubyOverrides = nil
        }
        scheduleAutosave()
    }

    // MARK: - 字幕 Tab：时间编辑（四时间模型，不合并 display / sing）

    /// 同轨相邻可见区间（排除自己），用于重叠校验。
    func sameLaneNeighbors(for line: LyricLine) -> [(start: Double, end: Double)] {
        project.lines(in: line.lane)
            .filter { $0.id != line.id }
            .map { (start: $0.displayStart, end: max($0.displayEnd, $0.singEnd)) }
    }

    func applyDisplayTimeEdit(lineID: UUID, start: Double?, end: Double?) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == lineID }) else { return }
        let line = project.lyricLines[idx]
        let result = LineTimeEditor.displayRange(
            desiredStart: start ?? line.displayStart,
            desiredEnd: end ?? line.displayEnd,
            singStart: line.singStart,
            singEnd: line.singEnd,
            duration: timelineDuration,
            sameLaneNeighbors: sameLaneNeighbors(for: line),
            movingEdge: start != nil ? .start : .end)
        guard !result.rejected else {
            statusMessage = result.message ?? "时间修改被拒绝"
            return
        }
        beginEditBurst(key: "displayTime-\(lineID.uuidString)", label: "修改字幕时间")
        applyTimeResult(result, to: idx)
        if let message = result.message { statusMessage = message }
        scheduleAutosave()
    }

    func applySingTimeEdit(lineID: UUID, start: Double?, end: Double?) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == lineID }) else { return }
        let line = project.lyricLines[idx]
        let result = LineTimeEditor.singRange(
            desiredStart: start ?? line.singStart,
            desiredEnd: end ?? line.singEnd,
            displayStart: line.displayStart,
            displayEnd: line.displayEnd,
            duration: timelineDuration,
            movingEdge: start != nil ? .start : .end)
        guard !result.rejected else {
            statusMessage = result.message ?? "扫色时间修改被拒绝"
            return
        }
        let oldSing = line.singStart...max(line.singStart + 1e-6, line.singEnd)
        beginEditBurst(key: "singTime-\(lineID.uuidString)", label: "修改扫色时间")
        applyTimeResult(result, to: idx)
        project.lyricLines[idx].rescaleMorae(from: oldSing,
                                             to: result.singStart...max(result.singStart + 1e-6, result.singEnd))
        if let message = result.message { statusMessage = message }
        scheduleAutosave()
    }

    private func applyTimeResult(_ result: LineTimeEditResult, to idx: Int) {
        project.lyricLines[idx].displayStart = result.displayStart
        project.lyricLines[idx].displayEnd = result.displayEnd
        project.lyricLines[idx].singStart = result.singStart
        project.lyricLines[idx].singEnd = result.singEnd
        project.lyricLines[idx].enforceInvariants()
    }

    func deleteLine(id: UUID) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("删除歌词句")
        // 删除主句即完成，不需要另外清理附轨（RD §9.3）
        project.lyricLines.remove(at: idx)
        project.renumber()
        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        if selectedLineID == id { clearSelection() }
        statusMessage = "已删除 1 句"
        scheduleAutosave()
    }

    func duplicateLine(id: UUID) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("复制歌词句")
        var copy = project.lyricLines[idx]
        // 深拷贝 token 与音拍时间，并生成新 UUID（RD §9.3）
        copy.id = UUID()
        copy.tokens = copy.tokens.map { token in
            var t = token
            t.id = UUID()
            t.morae = t.morae.map { MoraTiming(mora: $0.mora, start: $0.start, end: $0.end, confidence: $0.confidence) }
            return t
        }
        copy.order = project.lyricLines.count + 1
        copy.lane = ScreenLane.lane(forOrder: copy.order)
        copy.displayStart += 0.01
        project.lyricLines.append(copy)
        project.renumber()
        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        selectLineForEditing(copy.id)
        scheduleAutosave()
    }

    // MARK: - 生成 AI 歌词

    func autoGenerate() {
        guard !isAnalyzing else { return }
        guard project.mediaExists else {
            errorMessage = project.hasMedia ? "媒体文件找不到，请先重新定位" : "请先导入媒体文件"
            return
        }
        guard !project.lyricLines.isEmpty else {
            errorMessage = "请先粘贴并应用日文歌词"
            return
        }

        let snapshot = project
        let useMock = useMockAligner
        let sessionID = UUID()
        activeAnalysisSessionID = sessionID
        isAnalyzing = true
        analysisProgress = 0
        analysisStage = "正在准备音频…"
        statusMessage = "正在准备对轨…"
        errorMessage = nil
        analysisNotes = []

        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 产品路径：macOS 26+ 用 ASR 强制对齐；更老系统明确降级并说明
                let selection: AlignmentEngineFactory.Selection
                if useMock {
                    selection = .init(aligner: MockLyricAligner(),
                                      availability: .unavailable("Mock"),
                                      detail: "Mock（仅 UI 测试）")
                } else {
                    selection = await AlignmentEngineFactory.makeDefault()
                }
                await MainActor.run { [weak self] in
                    guard let self, self.isCurrentAnalysisSession(sessionID) else { return }
                    self.alignmentDetail = selection.detail
                    self.alignmentAvailability = selection.availability
                    self.statusMessage = selection.detail
                }
                // 进度回调是同步的 @Sendable 闭包。若直接在它内部用 `[weak self]`
                // 构造 Task，会在并发代码里引用外部可变捕获。这里先在 detached
                // 主体（非并发上下文）把 weak self 的读取冻结成一个 @MainActor 闭包，
                // 再在 Task 中调用；仍然保持 weak + session 闸门语义不变。
                let applyProgress: @MainActor @Sendable (AlignProgress) -> Void = { [weak self] p in
                    guard let self, self.isCurrentAnalysisSession(sessionID) else { return }
                    self.analysisProgress = p.fraction
                    self.analysisStage = p.message
                }
                let outcome = try await AnalysisCoordinator.analyze(project: snapshot, aligner: selection.aligner) { p in
                    Task { @MainActor in
                        applyProgress(p)
                    }
                }
                await MainActor.run { [weak self] in
                    self?.finishAnalysis(outcome, sessionID: sessionID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failAnalysis(error, sessionID: sessionID)
                }
            }
        }
    }

    func cancelAnalysis() {
        // 先让当前会话失效，再取消底层任务：即使 ASR 不能立即停止，
        // 旧任务晚到的回调也会因 session 不匹配而被丢弃（RD §10.2）。
        activeAnalysisSessionID = nil
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        analysisStage = ""
        statusMessage = "分析已取消，工程保持不变"
    }

    /// 当前分析会话是否仍然有效（RD §10.2 提交闸门）。
    private func isCurrentAnalysisSession(_ sessionID: UUID) -> Bool {
        activeAnalysisSessionID == sessionID
    }

    /// 提交 AI 分析结果。只有当前会话能提交成功，且提交后立即清空会话，
    /// 保证一次分析只提交一次。
    private func finishAnalysis(_ outcome: AnalysisCoordinator.Outcome, sessionID: UUID) {
        guard isCurrentAnalysisSession(sessionID) else { return }
        activeAnalysisSessionID = nil
        // 失败不破坏工程：这里只在成功时整体替换
        beginEdit("生成 AI 歌词")
        project = outcome.project
        project.syncOpeningCountdown()
        isAnalyzing = false
        analysisProgress = 1
        analysisStage = ""
        analysisNotes = outcome.summary.notes
        let n = outcome.summary.lowConfidenceCount
        let methodLabel = outcome.summary.method?.shortLabel ?? "未知方法"
        statusMessage = String(format: "%@ · %d 句 · %d 处待确认 · %.1f 秒",
                               methodLabel, outcome.summary.totalLines, n, outcome.summary.elapsedSeconds)
        // 分析结束直接跳到置信度最低的第一处（RD §8.1）
        if let worst = project.sortedLines.filter(\.needsReview).min(by: { $0.confidence < $1.confidence }) {
            selectedLineID = worst.id
            seek(to: max(0, worst.singStart - 0.4))
        } else if let first = project.sortedLines.first {
            selectedLineID = first.id
            seek(to: defaultPreviewTime())
        }
        scrollTarget = selectedLineID
        scheduleAutosave()
    }

    /// 上报分析失败。只有当前会话能改错误状态；失败即结束会话。
    private func failAnalysis(_ error: Error, sessionID: UUID) {
        guard isCurrentAnalysisSession(sessionID) else { return }
        activeAnalysisSessionID = nil
        isAnalyzing = false
        analysisStage = ""
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        statusMessage = "自动分析失败：\(message)。工程未被修改，可以手动调整或单句重试。"
    }

    // MARK: - 单句重试与漂移修正

    func realignSelectedLine() {
        guard !isAnalyzing else { return }
        guard let line = selectedLine else { return }
        guard project.mediaExists else {
            errorMessage = "媒体文件找不到，无法重新对齐"
            return
        }
        let url = project.mediaURL
        var tokens = line.tokens
        tokens = tokens.map { var t = $0; t.morae = []; return t }
        if tokens.isEmpty {
            tokens = JapaneseReadingService().tokens(for: line.displayText, dictionary: project.dictionary)
        }
        let draft = LyricLineDraft(id: line.id, order: line.order, text: line.displayText, tokens: tokens)
        let window = max(0, line.singStart - 1.5)...(line.singEnd + 1.5)
        let lineID = line.id
        let sessionID = UUID()
        activeAnalysisSessionID = sessionID
        isAnalyzing = true
        analysisStage = "正在重新对齐该句…"
        analysisProgress = 0.3
        statusMessage = "重新对齐第 \(line.order) 句…"

        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 单句重对齐：整首跑一次 ASR（有缓存），再取该句结果
                let selection = await AlignmentEngineFactory.makeDefault()
                if selection.aligner.method == .asrForcedAlign || selection.aligner.method == .qualityFirst {
                    let snapshot = await MainActor.run { [weak self] in self?.project ?? KaraProject() }
                    let outcome = try await AnalysisCoordinator.analyze(project: snapshot,
                                                                       aligner: selection.aligner)
                    await MainActor.run { [weak self] in
                        guard let self, self.isCurrentAnalysisSession(sessionID) else { return }
                        self.activeAnalysisSessionID = nil
                        self.project = outcome.project
                        self.isAnalyzing = false
                        self.analysisStage = ""
                        self.statusMessage = "已用 ASR 重新对齐整首（单句精调待后续版本）"
                        self.scheduleAutosave()
                    }
                    return
                }
                let legacy = LocalLyricAligner()
                let lineDraft = draft
                let aligned = try await legacy.realign(line: lineDraft, audioURL: url, window: window)
                await MainActor.run { [weak self] in
                    guard let self, self.isCurrentAnalysisSession(sessionID) else { return }
                    self.activeAnalysisSessionID = nil
                    self.beginEdit("重新对齐单句")
                    if let idx = self.project.lyricLines.firstIndex(where: { $0.id == lineID }) {
                        self.project.lyricLines[idx].tokens = aligned.tokens
                        self.project.lyricLines[idx].singStart = aligned.singStart
                        self.project.lyricLines[idx].singEnd = aligned.singEnd
                        self.project.lyricLines[idx].confidence = aligned.confidence
                        self.project.lyricLines[idx].needsReview = ConfidenceLevel.from(aligned.confidence) != .normal
                        self.project.lyricLines[idx].reviewReasons = aligned.reasons
                    }
                    DisplayScheduler.applyDisplayWindows(to: &self.project.lyricLines, policy: self.project.displayPolicy)
                    self.project.enforceAllInvariants()
                    self.isAnalyzing = false
                    self.analysisStage = ""
                    self.statusMessage = String(format: "第 %d 句已重新对齐（置信度 %.2f）", line.order, aligned.confidence)
                    self.scheduleAutosave()
                }
            } catch {
                await MainActor.run { [weak self] in self?.failAnalysis(error, sessionID: sessionID) }
            }
        }
    }

    func correctDrift() {
        guard !isAnalyzing else { return }
        guard project.mediaExists, !project.lyricLines.isEmpty else { return }
        let url = project.mediaURL
        let snapshot = project
        let sessionID = UUID()
        activeAnalysisSessionID = sessionID
        isAnalyzing = true
        analysisStage = "正在估计整体偏移与漂移…"
        analysisProgress = 0.4

        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let estimate = try DriftCorrector.estimate(project: snapshot, audioURL: url)
                await MainActor.run { [weak self] in
                    guard let self, self.isCurrentAnalysisSession(sessionID) else { return }
                    self.activeAnalysisSessionID = nil
                    self.isAnalyzing = false
                    self.analysisStage = ""
                    guard estimate.isUsable else {
                        self.errorMessage = String(format: "样本不足（%d 句，残差 %.0f ms），没有执行修正",
                                                   estimate.sampleCount, estimate.residualStd * 1000)
                        return
                    }
                    var p = self.project
                    let changed = DriftCorrector.apply(estimate, to: &p)
                    if changed > 0 {
                        self.beginEdit("修正整体偏移与漂移")
                        self.project = p
                        self.statusMessage = String(format: "已修正 %d 句：整体偏移 %+.0f ms，漂移 %+.3f 秒/秒",
                                                    changed, estimate.offset * 1000, estimate.slope)
                        self.scheduleAutosave()
                    } else {
                        self.statusMessage = String(format: "偏移 %+.0f ms，无需修正", estimate.offset * 1000)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in self?.failAnalysis(error, sessionID: sessionID) }
            }
        }
    }

    // MARK: - 播放

    func togglePlay() { playback.toggle() }
    func seek(to t: Double) {
        playback.seek(to: t)
        playhead = t
    }
    /// 前往开头（顶部 ⏮ 按钮 / Home）
    func seekToStart() {
        seek(to: 0)
        statusMessage = "已前往开头"
    }

    /// 前往结尾（顶部 ⏭ 按钮 / End）
    func seekToEnd() {
        seek(to: timelineDuration)
        statusMessage = "已前往结尾"
    }

    func stepPlayhead(by d: Double) {
        playback.pause()
        seek(to: playhead + d)
    }
    /// 跳到下一处低置信度片段（RD §8.5）
    func jumpToNextReview() {
        let pending = project.sortedLines.filter(\.needsReview)
        guard !pending.isEmpty else {
            statusMessage = "没有待确认的片段"
            return
        }
        let next = pending.first { $0.singStart > playhead + 0.05 } ?? pending[0]
        selectLineForEditing(next.id)
        seek(to: max(0, next.singStart - 0.4))
        scrollTarget = next.id
        statusMessage = String(format: "跳到第 %d 句（置信度 %.2f）", next.order, next.confidence)
    }

    // MARK: - 工程读写

    /// 有内容但还没有工程路径：自动保存不会落盘，此时新建／打开／退出都会丢失工作。
    /// 已有路径的工程由自动保存兜底（1 秒防抖），不在此列。
    var hasUnsavedWork: Bool {
        guard projectURL == nil else { return false }
        return !project.lyricLines.isEmpty || project.mediaURL.path != "/"
    }

    /// 离开当前工程前的确认。返回 true 表示可以继续（已保存或用户选择不保存）。
    func confirmLeavingCurrentProject(action: String) -> Bool {
        guard hasUnsavedWork else { return true }
        let alert = NSAlert()
        alert.messageText = "当前工程还没有保存"
        alert.informativeText = "\(action)会丢失现有的素材、歌词和时间调整。要先保存吗？"
        alert.addButton(withTitle: "保存…")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProjectAs()
            return projectURL != nil   // 用户在保存面板里取消或写入失败时不继续
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 菜单／按钮入口：先确认再清空。`newProject()` 保持无提示，供内部与测试使用。
    func requestNewProject() {
        guard confirmLeavingCurrentProject(action: "重新开始") else { return }
        newProject()
    }

    /// 退出前同步落盘。已有路径的工程立即保存，避免丢掉最后 1 秒内尚未触发的自动保存。
    func flushProjectBeforeQuit() {
        guard let url = projectURL else { return }
        do {
            try autosaver.flush(url: url, project: project)
        } catch {
            NSLog("退出前保存失败：\(error.localizedDescription)")
        }
    }

    func newProject() {
        cancelVocalSeparation()
        beginEdit("新建工程")
        timelineClickMarkerTime = nil
        scrollX = 0
        playhead = 0
        project = KaraProject()
        projectURL = nil
        selectedLineID = nil
        inspectorTab = .text
        activeBurstKey = nil
        lyricsDraft = ""
        waveformPeaks = []
        videoThumbnails = []
        vocalWaveformPeaks = []
        vocalWaveformRMS = []
        mediaInfo = nil
        playback.clear()
        undoStack.clear()
        sidebarSection = .lyrics
        statusMessage = "准备好了，直接粘贴歌词"
    }

    func openProject() {
        guard confirmLeavingCurrentProject(action: "打开另一个工程") else { return }
        let panel = NSOpenPanel()
        panel.title = "打开工程"
        panel.allowedContentTypes = [UTType(filenameExtension: KaraProject.fileExtension) ?? .json]
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// 从指定路径打开工程（也用于启动参数与 Finder 打开）。
    func openProject(at url: URL) {
        cancelVocalSeparation()
        do {
            var loaded = try ProjectStore.load(from: url)
            var didMigrateDisplayWindows = false
            // 旧版本曾把同轨下一句的起点当作 displayEnd，导致超长无歌词空档被
            // 一整条紫色块填满。仅迁移紧接歌词间隔超过阈值、且尾留明显异常的旧句；
            // 短间隔下合法的双行保留即使较长，也不能被误判。
            let sortedLines = loaded.sortedLines
            let longSilenceLineIDs = Set(zip(sortedLines, sortedLines.dropFirst()).compactMap { current, next in
                next.singStart - current.singEnd > DisplayScheduler.maximumHandoffGap
                    ? current.id : nil
            })
            let hasRunawayDisplayWindow = loaded.lyricLines.contains {
                longSilenceLineIDs.contains($0.id)
                    && $0.displayEnd > $0.singEnd + loaded.displayPolicy.lastHoldOut + 2.0
            }
            if hasRunawayDisplayWindow {
                DisplayScheduler.applyDisplayWindows(to: &loaded.lyricLines,
                                                      policy: loaded.displayPolicy)
                didMigrateDisplayWindows = true
            }
            loaded.syncOpeningCountdown()
            project = loaded
            selectedCountdownID = nil
            timelineClickMarkerTime = nil
            scrollX = 0
            playhead = 0
            projectURL = url
            if didMigrateDisplayWindows {
                // 迁移不能只停留在内存，否则下次重新打开还会恢复旧的长条。
                scheduleAutosave()
            }
            lyricsDraft = loaded.sortedLines.map(\.displayText).joined(separator: "\n")
            undoStack.clear()
            if loaded.mediaExists {
                if let stems = validVocalSeparation {
                    do {
                        try playback.loadSeparated(url: loaded.mediaURL,
                                                   vocalURL: stems.vocalURL,
                                                   instrumentalURL: stems.instrumentalURL,
                                                   audioMuted: project.trackStates.isMuted(.audio),
                                                   vocalMuted: project.trackStates.isMuted(.vocal))
                    } catch {
                        project.vocalSeparation = nil
                        playback.load(url: loaded.mediaURL,
                                      audioMuted: project.trackStates.isMuted(.audio))
                        errorMessage = "分离音轨载入失败，已回退到原音频：\(error.localizedDescription)"
                        scheduleAutosave()
                    }
                } else {
                    playback.load(url: loaded.mediaURL,
                                  audioMuted: project.trackStates.isMuted(.audio))
                    if project.vocalSeparation != nil {
                        project.vocalSeparation = nil
                        scheduleAutosave()
                    }
                }
                playback.seek(to: 0)
                loadDerivedMediaData(url: loaded.mediaURL, preferredDuration: loaded.duration)
                refreshMediaInfo()
                statusMessage = "已打开 \(url.lastPathComponent)"
                // 定位到第一处待确认；若全部正常，则跳到第一句，让用户立刻看到字幕
                if let worst = loaded.sortedLines.filter(\.needsReview)
                    .min(by: { $0.confidence < $1.confidence }) {
                    selectedLineID = worst.id
                    seek(to: max(0, worst.singStart - 0.2))
                } else if let first = loaded.sortedLines.first {
                    selectedLineID = first.id
                    seek(to: defaultPreviewTime())
                }
                scrollTarget = selectedLineID
            } else {
                statusMessage = "已打开工程，但媒体文件找不到，请点「重新定位媒体」"
                errorMessage = "媒体文件找不到：\(loaded.mediaURL.lastPathComponent)"
            }
        } catch {
            errorMessage = "工程打开失败：\(error.localizedDescription)"
        }
    }

    /// 处理启动参数里的工程路径（只会真正执行一次）。
    ///
    /// 同时支持 `--at <秒>`：打开后把播放头定位到指定时刻。
    /// 这是给 UI smoke check / 截图用的确定性入口 ——
    /// 靠模拟按键不可靠（其它应用会抢走焦点），指定时刻才能稳定复现同一帧。
    func openProjectFromLaunchArguments() {
        guard !didOpenLaunchProject else { return }
        didOpenLaunchProject = true

        let args = Array(CommandLine.arguments.dropFirst())
        var startAt: Double?
        if let i = args.firstIndex(of: "--at"), i + 1 < args.count {
            startAt = Double(args[i + 1])
        }
        // --section <project|lyrics|style|export>：直接打开指定侧栏分区。
        // 给 UI smoke check 用：靠模拟点击不可靠，直接指定分区才能一次启动就截到目标界面。
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let section = SidebarSection(rawValue: args[i + 1]) {
            sidebarSection = section
        }

        for arg in args where arg.hasSuffix(".\(KaraProject.fileExtension)") {
            let url = URL(fileURLWithPath: arg)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            openProject(at: url)
            if let startAt {
                // openProject 内部已经 seek 过一次，这里再覆盖成指定时刻
                seek(to: startAt)
                selectedLineID = project.sortedLines.last { $0.displayStart <= startAt }?.id
                scrollTarget = selectedLineID
            }
            return
        }
    }

    func saveProject() {
        if let url = projectURL {
            do {
                try ProjectStore.save(project, to: url)
                statusMessage = "已保存到 \(url.lastPathComponent)"
            } catch {
                errorMessage = "保存失败：\(error.localizedDescription)"
            }
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.title = "保存工程"
        panel.nameFieldStringValue = "\(project.title).\(KaraProject.fileExtension)"
        if let type = UTType(filenameExtension: KaraProject.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.prompt = "保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.save(project, to: url)
            projectURL = url
            statusMessage = "已保存到 \(url.lastPathComponent)"
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 导出

    func exportASS() {
        guard !project.lyricLines.isEmpty else {
            errorMessage = "工程里没有歌词，无法导出 ASS"
            return
        }
        var options = AssExporter.Options()
        options.title = project.title
        // 导出前检查（RD §11.2）
        let invalid = project.lyricLines.filter { !$0.hasValidTiming }
        if !invalid.isEmpty {
            errorMessage = "有 \(invalid.count) 句的四段时间顺序不合法，已自动修正后再导出"
            project.enforceAllInvariants()
        }

        let panel = NSSavePanel()
        panel.title = "导出 ASS 字幕"
        panel.nameFieldStringValue = "\(project.title).ass"
        if let type = UTType(filenameExtension: "ass") { panel.allowedContentTypes = [type] }
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AssExporter.write(project: project, to: url, options: options)
            let rubyCount = project.sortedLines.reduce(0) { $0 + $1.rubyTokens.count }
            statusMessage = "已导出 ASS：\(project.lyricLines.count) 句，\(rubyCount) 个假名事件"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 默认出口是带字幕的 MP4；ASS/LRC/SRT 仍作为辅助格式保留。
    func exportVideo() {
        guard !project.lyricLines.isEmpty else {
            errorMessage = "工程里没有歌词，无法导出视频"
            return
        }
        guard hasExportableVideo else {
            errorMessage = project.hasMedia
                ? "媒体文件找不到，请先重新定位媒体"
                : "请先导入视频或音频素材，MP4 导出会把卡拉 OK 字幕直接烧录到画面里"
            return
        }
        guard !isExportingVideo else { return }

        let panel = NSSavePanel()
        panel.title = "导出 MP4 视频"
        panel.nameFieldStringValue = "\(project.title).mp4"
        if let type = UTType(filenameExtension: "mp4") { panel.allowedContentTypes = [type] }
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = project
        let settings = videoExportSettings
        let cancellation = VideoExporter.Cancellation()
        exportCancellation = cancellation
        exportProgress = nil
        isExportingVideo = true
        statusMessage = "正在生成 MP4（\(settings.bitrate.displayName)画质 · \(settings.resolution.displayName) · \(settings.frameRate.displayName) · \(settings.audioQuality.displayName)音频）…"

        let applyProgress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            self?.exportProgress = fraction
        }
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try VideoExporter.export(project: snapshot, settings: settings, to: url,
                                             cancellation: cancellation,
                                             progress: { fraction in
                        Task { @MainActor in applyProgress(fraction) }
                    })
                }.value
                guard let self else { return }
                self.finishVideoExport()
                self.statusMessage = "已导出 MP4：\(url.lastPathComponent)（\(settings.bitrate.displayName)画质 · \(settings.resolution.displayName) · \(settings.audioQuality.displayName)音频）"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch let error as VideoExporter.ExportError where error.isCancellation {
                self?.finishVideoExport()
                self?.statusMessage = "已取消导出，没有生成文件"
            } catch {
                guard let self else { return }
                self.finishVideoExport()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 退出前：正在导出时先确认，确认后取消并等待 ffmpeg 退出、临时文件清理完毕。
    func confirmAbortingVideoExport() -> Bool {
        guard isExportingVideo else { return true }
        let alert = NSAlert()
        alert.messageText = "正在导出 MP4"
        alert.informativeText = "现在退出会中止导出，已生成的部分不会保留。"
        alert.addButton(withTitle: "继续导出")
        alert.addButton(withTitle: "中止并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        cancelVideoExport()
        let deadline = Date().addingTimeInterval(3)
        while isExportingVideo, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    func cancelVideoExport() {
        exportCancellation?.cancel()
        statusMessage = "正在取消导出…"
    }

    private func finishVideoExport() {
        isExportingVideo = false
        exportProgress = nil
        exportCancellation = nil
    }

    func exportLRC() {
        exportTextFile(title: "导出 LRC 歌词", fileExtension: "lrc") {
            LyricTextExporter.lrc(project: project)
        }
    }

    func exportSRT() {
        exportTextFile(title: "导出 SRT 字幕", fileExtension: "srt") {
            LyricTextExporter.srt(project: project)
        }
    }

    private func exportTextFile(title: String,
                                fileExtension: String,
                                contents: () -> String) {
        guard !project.lyricLines.isEmpty else {
            errorMessage = "工程里没有歌词，无法导出"
            return
        }
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = "\(project.title).\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出 \(fileExtension.uppercased())：\(project.lyricLines.count) 句"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 样式

    func applyPreset(_ preset: SubtitleStyle.Preset) {
        beginEdit("应用模版 \(preset.displayName)")
        var style = preset.style
        // 倒计时的样式和总开关是独立设置：换歌词模版不应该把它们重置
        style.countdown = project.style.countdown
        style.countdownEnabled = project.style.countdownEnabled
        project.style = style
        // 模版同时带着换行节奏（滚动 / 翻页、提前量、下行延后）；手动调过显示起止的句子保持不变
        project.displayPolicy = preset.displayPolicy
        refreshDisplayWindows()
        scheduleAutosave()
        statusMessage = "已应用模版「\(preset.displayName)」：\(preset.summary)"
    }

    /// 修改换行节奏（模式、提前量、下行延后……），并立刻按新节奏重排所有句子的显示时间。
    /// 手动调过显示起止的句子保持不变。
    func updateDisplayPolicy(_ mutate: (inout DisplayPolicy) -> Void) {
        beginEditBurst(key: "displayPolicy", label: "修改换行节奏")
        mutate(&project.displayPolicy)
        refreshDisplayWindows()
        scheduleAutosave()
    }

    /// 样式改动（不触发重新分析，RD §8.1 阶段级缓存）
    func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        beginEdit("修改样式")
        mutate(&project.style)
        scheduleAutosave()
    }

    /// 开始一次连续的画面拖动。拖动过程中只记录一个撤销点，避免每一帧
    /// 都生成一条“修改样式”历史记录。
    func beginStyleGesture(_ label: String = "拖动画面字幕位置") {
        beginEdit(label)
    }

    /// 样式拖动中的轻量更新：保持预览实时响应，但把撤销点留给手势开始处。
    func updateStyleLive(_ mutate: (inout SubtitleStyle) -> Void) {
        mutate(&project.style)
        scheduleAutosave()
    }

    func addLine(at time: Double) {
        beginEdit("新增歌词句")
        var line = LyricLine(order: project.lyricLines.count + 1,
                             displayText: "新しい行",
                             displayStart: time,
                             singStart: time + 0.3,
                             singEnd: time + 1.8,
                             displayEnd: time + 2.4)
        line.tokens = JapaneseReadingService().tokens(for: line.displayText, dictionary: project.dictionary)
        line.needsReview = true
        line.reviewReasons = ["手动新增，尚未对齐"]
        project.lyricLines.append(line)
        project.renumber()
        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        selectLineForEditing(line.id)
        scheduleAutosave()
    }

    /// 默认预览起点。
    ///
    /// 验收要求「同时显示上下两行、当前句与下一句并存」，
    /// 所以不要只停在第 1 句的 35%（那时下行槽位还没进入画面）。
    /// 取「第 1 句演唱中」与「下行首次进入画面」两者较晚的时刻，
    /// 并保证不越过第 1 句的显示区。
    func defaultPreviewTime() -> Double {
        let lines = project.sortedLines
        guard let first = lines.first else { return 0 }
        var t = first.singStart + first.singDuration * 0.35
        if let lower = project.lines(in: .lower).first {
            t = max(t, lower.displayStart + 0.35)
        }
        t = min(t, max(first.displayStart, first.displayEnd - 0.1))
        return max(0, t)
    }

    // MARK: - 时间线滚动

    var contentWidth: Double {
        TimelineGeometry.contentWidth(duration: timelineDuration,
                                      pixelsPerSecond: pixelsPerSecond,
                                      viewportWidth: viewportWidth,
                                      leadingPadding: Theme.timelineLeadingInset)
    }

    func clampScrollX() {
        scrollX = TimelineGeometry.clampScrollX(scrollX,
                                                contentWidth: contentWidth,
                                                viewportWidth: viewportWidth)
    }

    /// 时间线视口坐标 → 时间；统一纳入横向滚动与 0:00 左侧留白。
    func seekFromTimeline(viewportX: Double) {
        let t = TimelineGeometry.seekTime(forViewportX: viewportX,
                                          scrollX: scrollX,
                                          pixelsPerSecond: pixelsPerSecond,
                                          duration: timelineDuration,
                                          leadingPadding: Theme.timelineLeadingInset)
        var target: Double?
        var time = t
        if snappingEnabled {
            let snapped = TimelineSnapper.snap(time: t,
                                               candidates: TimelineSnapper.candidates(project: project, playhead: nil),
                                               pixelsPerSecond: pixelsPerSecond)
            time = snapped.time
            target = snapped.target
        }
        snapIndicatorTime = isScrubbing ? target : nil
        timelineClickMarkerTime = time
        seek(to: time)
    }

    /// 把某个时刻放到视口中央。
    func centerOn(time: Double) {
        let maxX = max(0, contentWidth - viewportWidth)
        scrollX = (TimelineGeometry.contentX(forTime: time,
                                             pixelsPerSecond: pixelsPerSecond,
                                             leadingPadding: Theme.timelineLeadingInset) - viewportWidth / 2)
            .clamped(to: 0...maxX)
    }

    /// 消费一次滚动请求。延迟到下一个 runloop，避免在视图更新过程中改 @Published。
    func consumeScrollTarget() {
        guard let target = scrollTarget else { return }
        scrollTarget = nil
        guard let line = project.lyricLines.first(where: { $0.id == target }) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.centerOn(time: max(0, line.displayStart - 0.3))
        }
    }

    /// 播放时让播放头保持在视口内（超出才重新居中，避免每一帧都跳）。
    func followPlayheadIfNeeded() {
        let x = TimelineGeometry.contentX(forTime: playhead,
                                          pixelsPerSecond: pixelsPerSecond,
                                          leadingPadding: Theme.timelineLeadingInset)
        guard TimelineAutoFollow.shouldFollow(isPlaying: playback.isPlaying,
                                              isInteracting: isInteractingWithTimelineItem || isScrubbing,
                                              viewportWidth: viewportWidth,
                                              playheadContentX: x,
                                              scrollX: scrollX) else { return }
        centerOn(time: playhead)
    }

    /// 正在拖动 / 修剪色块（歌词块、倒计时块）。期间时间线不自动跟随播放头。
    /// 用时间戳而不是纯布尔：万一拖动过程中视图被移除、`onEnded` 没触发，3 秒后自动恢复，不会卡死。
    private var timelineItemDragStamp: Date?
    var isInteractingWithTimelineItem: Bool {
        guard let stamp = timelineItemDragStamp else { return false }
        return Date().timeIntervalSince(stamp) < 3
    }

    /// 色块拖动每一帧调用；松手时传 false。
    func setDraggingTimelineItem(_ dragging: Bool) {
        timelineItemDragStamp = dragging ? Date() : nil
        if !dragging { snapIndicatorTime = nil }
    }

    // MARK: - 吸附（FCPX 同款，快捷键 N）

    private static let snappingDefaultsKey = "timelineSnappingEnabled"

    /// 吸附开关；属于用户习惯，记在偏好里而不是工程里。默认开（与 FCPX 一致）。
    @Published var snappingEnabled: Bool =
        UserDefaults.standard.object(forKey: AppState.snappingDefaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(snappingEnabled, forKey: Self.snappingDefaultsKey)
            if !snappingEnabled { snapIndicatorTime = nil }
        }
    }

    /// 当前吸住的参考时间，时间线上画一条竖线提示；nil 表示没吸附。
    @Published var snapIndicatorTime: Double?

    func toggleSnapping() {
        snappingEnabled.toggle()
        statusMessage = snappingEnabled ? "吸附已开启（N）" : "吸附已关闭（N）"
    }

    /// 拖动中的吸附：给出原始位移，返回吸附后的位移，并更新提示竖线。
    func snappedDelta(edges: [Double], delta: Double,
                      excludingLine: UUID? = nil, excludingCountdown: UUID? = nil,
                      extraCandidates: [Double] = []) -> Double {
        guard snappingEnabled else {
            snapIndicatorTime = nil
            return delta
        }
        let result = TimelineSnapper.snap(
            edges: edges, delta: delta,
            candidates: TimelineSnapper.candidates(project: project,
                                                   excludingLine: excludingLine,
                                                   excludingCountdown: excludingCountdown,
                                                   playhead: playhead) + extraCandidates,
            pixelsPerSecond: pixelsPerSecond)
        if snapIndicatorTime != result.target { snapIndicatorTime = result.target }
        return result.delta
    }

    // MARK: - 缩放（保持锚点，修复缩放后坐标错位）

    /// 以「播放头在视口里的相对位置」为锚点缩放，避免缩放时整条时间线乱跑。
    ///
    /// 锚点必须用**视口坐标**（含 leading inset）算，否则每缩放一次
    /// 整条时间线就会平移一个 inset，播放头与点击定位随之错位。
    func setZoom(_ newPixelsPerSecond: Double) {
        let clamped = newPixelsPerSecond.clamped(to: 4...400)
        guard abs(clamped - pixelsPerSecond) > 1e-9 else { return }
        let viewport = max(1, viewportWidth)
        let anchorTime = playhead
        let anchorViewportX = TimelineGeometry.viewportX(
            forTime: anchorTime,
            scrollX: scrollX,
            pixelsPerSecond: pixelsPerSecond,
            leadingPadding: Theme.timelineLeadingInset)
        let anchorFraction = min(max(anchorViewportX / viewport, 0), 1)
        let newContentWidth = TimelineGeometry.contentWidth(duration: timelineDuration,
                                                           pixelsPerSecond: clamped,
                                                           viewportWidth: viewport,
                                                           leadingPadding: Theme.timelineLeadingInset)
        pixelsPerSecond = clamped
        scrollX = TimelineGeometry.scrollXKeepingAnchor(
            anchorTime: anchorTime,
            anchorViewportFraction: anchorFraction,
            newPixelsPerSecond: clamped,
            viewportWidth: viewport,
            contentWidth: newContentWidth,
            leadingPadding: Theme.timelineLeadingInset)
    }

    func zoomToFit() {
        let d = timelineDuration
        guard d > 0, viewportWidth > 100 else { return }
        setZoom((viewportWidth - 24) / d)
        scrollX = 0
    }

    /// 全部歌词（含走轨）整体提前 / 延后。
    func shiftAllLines(by delta: Double) {
        guard !project.lyricLines.isEmpty else { return }
        beginEdit("整体平移歌词")
        let applied = project.shiftAllLines(by: delta)
        guard abs(applied) > 1e-9 else {
            statusMessage = "已经到 0 秒，不能再提前"
            return
        }
        statusMessage = String(format: "全部歌词已整体%@ %.2f 秒", applied < 0 ? "提前" : "延后", abs(applied))
        scheduleAutosave()
    }

    /// 时间线拖动主片段（四个时间一起平移，音拍同步）
    func shiftLine(id: UUID, by delta: Double) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        let maxEnd = max(timelineDuration, project.lyricLines[idx].displayEnd)
        var d = delta
        let line = project.lyricLines[idx]
        if line.displayStart + d < 0 { d = -line.displayStart }
        if line.displayEnd + d > maxEnd { d = maxEnd - line.displayEnd }
        guard abs(d) > 1e-9 else { return }
        project.lyricLines[idx].shift(by: d)
        project.lyricLines[idx].enforceInvariants()
    }

    func setLineDisplayRange(id: UUID, start: Double?, end: Double?) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        if let start { project.lyricLines[idx].displayStart = max(0, min(start, project.lyricLines[idx].singStart)) }
        if let end { project.lyricLines[idx].displayEnd = max(end, project.lyricLines[idx].singEnd) }
        project.lyricLines[idx].enforceInvariants()
    }

    func setLineSingRange(id: UUID, start: Double?, end: Double?) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        var s = project.lyricLines[idx].singStart
        var e = project.lyricLines[idx].singEnd
        if let start { s = start }
        if let end { e = end }
        project.lyricLines[idx].setSingRange(start: s, end: e)
    }

    /// 拖动时重新排布显示区（保持四段时间合法）
    func refreshDisplayWindows() {
        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines, policy: project.displayPolicy)
        project.enforceAllInvariants()
        // 第一句的出现时间可能变了：自动生成的开头倒计时要跟着贴合
        project.syncOpeningCountdown()
    }

    // MARK: - 倒计时轨道

    var selectedCountdown: CountdownItem? {
        guard let id = selectedCountdownID else { return nil }
        return project.countdowns.first { $0.id == id }
    }

    func selectCountdown(_ id: UUID) {
        endEditBurst()
        selectedLineID = nil
        selectedCountdownID = id
    }

    /// 在播放头处新增一个倒计时（默认 3 秒），可在时间线上继续拖动、修剪。
    func addCountdown(at time: Double) {
        beginEdit("添加倒计时")
        let start = max(0, time)
        let item = CountdownItem(start: start, end: start + KaraokeCountdown.defaultDuration)
        project.countdowns.append(item)
        project.countdowns.sort { $0.start < $1.start }
        selectCountdown(item.id)
        statusMessage = "已添加倒计时，可在时间线「倒计时」轨道上拖动或修剪"
        scheduleAutosave()
    }

    func deleteCountdown(id: UUID) {
        guard let index = project.countdowns.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("删除倒计时")
        if project.countdowns[index].isAuto { project.countdownAutoDismissed = true }
        project.countdowns.remove(at: index)
        if selectedCountdownID == id { selectedCountdownID = nil }
        statusMessage = "已删除倒计时"
        scheduleAutosave()
    }

    /// 拖动 / 修剪过程中替换色块（撤销点由拖动开始处记录一次）。
    /// 用户一旦碰过自动生成的开头倒计时，它就变成普通倒计时，不再被自动改回、也不会被补回。
    func replaceCountdown(_ item: CountdownItem) {
        project.replaceCountdown(item)
    }

    /// 检查面板里输入开始 / 结束时间。
    func setCountdownTimes(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard var item = project.countdowns.first(where: { $0.id == id }) else { return }
        beginEditBurst(key: "countdownTime-\(id.uuidString)", label: "修改倒计时时间")
        if let start { item.start = start }
        if let end { item.end = end }
        replaceCountdown(item)
        scheduleAutosave()
    }

    /// 把开头倒计时恢复成自动模式（跟随第一句）：删掉被用户改过的开头倒计时，重新自动生成。
    func restoreAutoOpeningCountdown() {
        beginEdit("恢复自动开头倒计时")
        project.countdowns.removeAll { $0.isAuto }
        project.countdownAutoDismissed = false
        // 把离第一句最近的手动倒计时让位给自动的
        if let first = project.sortedLines.first {
            project.countdowns.removeAll { !$0.isAuto && abs($0.end - first.displayStart) < 0.05 }
        }
        project.syncOpeningCountdown()
        selectedCountdownID = project.countdowns.first(where: \.isAuto)?.id
        scheduleAutosave()
    }

    /// 取消某句手动指定的显示边界，改回自动排程（提前量 + 保持到同槽位下一句出现）。
    func resetDisplayWindowToAuto(lineID: UUID) {
        guard let index = project.lyricLines.firstIndex(where: { $0.id == lineID }),
              project.lyricLines[index].displayStartIsManual || project.lyricLines[index].displayEndIsManual
        else { return }
        beginEdit("恢复自动显示时间")
        project.lyricLines[index].displayStartIsManual = false
        project.lyricLines[index].displayEndIsManual = false
        refreshDisplayWindows()
        scheduleAutosave()
        statusMessage = "已恢复第 \(project.lyricLines[index].order) 句的自动显示时间"
    }

    // MARK: - 时间线直接编辑（拖动过程中不记录撤销，开始拖动时记录一次）

    /// 按绝对时间设置某句的四段时间；调整演唱区时会等比重映射音拍时间。
    func applyLineTimes(id: UUID,
                        displayStart: Double? = nil,
                        singStart: Double? = nil,
                        singEnd: Double? = nil,
                        displayEnd: Double? = nil) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        var line = project.lyricLines[idx]
        let oldSingLo = line.singStart
        let oldSingHi = max(line.singStart + 1e-6, line.singEnd)

        if let v = singStart { line.singStart = max(0, v) }
        if let v = singEnd { line.singEnd = max(0, v) }
        if let v = displayStart { line.displayStart = max(0, v); line.displayStartIsManual = true }
        if let v = displayEnd { line.displayEnd = max(0, v); line.displayEndIsManual = true }
        line.enforceInvariants()

        if singStart != nil || singEnd != nil {
            let newHi = max(line.singStart + 1e-6, line.singEnd)
            line.rescaleMorae(from: oldSingLo...oldSingHi, to: line.singStart...newHi)
        }
        project.lyricLines[idx] = line
    }

    func shiftTokenMorae(lineID: UUID, tokenID: UUID, by delta: Double) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == lineID }) else { return }
        project.lyricLines[idx].shiftTokenMorae(tokenID: tokenID, by: delta)
    }

    /// 整句平移：从拖动开始时的快照出发，四个时间值与全部音拍一起平移（RD §4 / §9.3）。
    func applyShiftedLine(id: UUID, origin: LyricLine, delta: Double) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        var line = origin
        line.shift(by: delta)
        line.enforceInvariants()
        project.lyricLines[idx] = line
    }

    func setTokenBoundary(lineID: UUID, tokenID: UUID, isStart: Bool, time: Double) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == lineID }) else { return }
        project.lyricLines[idx].setTokenBoundary(tokenID: tokenID, isStart: isStart, time: time)
    }

    // MARK: - 拖动过程中的编辑提示（修剪/移动时显示时间）

    /// 拖动时显示的时间提示（nil = 不显示）
    @Published var editingHint: String?

    /// 用一个新的行替换工程里的同一行（拖动/修剪走这里，保证只有一处写入口）
    func replaceLine(_ line: LyricLine, note: String) {
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == line.id }) else { return }
        project.lyricLines[idx] = line
    }

    /// 拖动结束后把该句标记为「手动调整」，并记录原因。
    /// 标记过的句子不会被后续自动分析覆盖（见 AnalysisCoordinator.merge）。
    func markSelectionManuallyAdjusted(_ note: String) {
        guard let id = selectedLineID,
              let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return }
        project.lyricLines[idx].markManuallyAdjusted(note)
    }

    // MARK: - 分割 / 删除（对标剪映 Cmd+B）

    /// 当前选中的句子能否在播放头处分割
    var canSplitSelected: Bool {
        guard let line = selectedLine, line.tokens.isEmpty == false else { return false }
        guard project.isEditable(line) else { return false }
        return LineSplitter.canSplit(line, at: playhead)
    }

    /// 在播放头处分割选中的歌词句。
    @discardableResult
    func splitSelectedAtPlayhead() -> Bool {
        guard let id = selectedLineID,
              let line = project.lyricLines.first(where: { $0.id == id }) else {
            statusMessage = "先选中一个歌词块"
            return false
        }
        guard project.isEditable(line) else {
            statusMessage = "轨道已锁定，无法分割"
            return false
        }
        guard let parts = LineSplitter.split(line, at: playhead) else {
            statusMessage = "播放头不在该句的演唱区间内，无法分割"
            return false
        }
        beginEdit("分割歌词句")
        var left = parts.left
        var right = parts.right
        left.markManuallyAdjusted("分割")
        right.markManuallyAdjusted("分割")
        guard let idx = project.lyricLines.firstIndex(where: { $0.id == id }) else { return false }
        project.lyricLines[idx] = left
        project.lyricLines.insert(right, at: idx + 1)
        project.renumber()
        selectLineForEditing(right.id)
        statusMessage = "已在播放头分割"
        scheduleAutosave()
        return true
    }

    /// 删除选中的句子（调用方负责二次确认）。
    func deleteSelectedLine() {
        guard let id = selectedLineID,
              let line = project.lyricLines.first(where: { $0.id == id }) else { return }
        guard project.isEditable(line) else {
            statusMessage = "轨道已锁定，无法删除"
            return
        }
        deleteLine(id: id)
        clearSelection()
    }

    // MARK: - 轨道状态（显隐 / 锁定 / 静音）

    func toggleTrackVisible(_ track: TrackID) {
        project.trackStates.toggleVisible(track)
        statusMessage = "\(track.displayName) \(project.trackStates.isVisible(track) ? "已显示" : "已隐藏")"
        scheduleAutosave()
    }

    func toggleTrackLocked(_ track: TrackID) {
        project.trackStates.toggleLocked(track)
        if project.trackStates.isLocked(track), track.isEditableContent {
            // 锁定后如果选中的句子在该轨道上，取消选中，避免误操作
            let lane: ScreenLane = track == .lyricUpper ? .upper : .lower
            if let line = selectedLine, line.lane == lane {
                clearSelection()
            }
        }
        statusMessage = "\(track.displayName) \(project.trackStates.isLocked(track) ? "已锁定" : "已解锁")"
        scheduleAutosave()
    }

    func toggleTrackMuted(_ track: TrackID) {
        project.trackStates.toggleMuted(track)
        applyMuteState()
        statusMessage = "\(track.displayName) \(project.trackStates.isMuted(track) ? "已静音" : "已取消静音")"
        scheduleAutosave()
    }

    /// 把轨道静音状态落到播放器上。
    /// 音频轨静音 = 播放器整体静音（本产品只有一条音频轨）。
    func applyMuteState() {
        playback.setTrackMutes(audioMuted: project.trackStates.isMuted(.audio),
                               vocalMuted: project.trackStates.isMuted(.vocal))
    }

    /// 当前选中的句子所在轨道是否被锁定（UI 用来置灰/禁止拖动）
    var isSelectionLocked: Bool {
        guard let line = selectedLine else { return false }
        return !project.isEditable(line)
    }

    // MARK: - 键盘命令

    /// 执行一条时间线命令（键盘与按钮共用同一入口）。
    func perform(_ command: TimelineKeyCommand) {
        switch command {
        case .togglePlay: togglePlay()
        case .stepBackward: stepPlayhead(by: -TimelineKeyMapper.frameStep)
        case .stepForward: stepPlayhead(by: TimelineKeyMapper.frameStep)
        case .stepBackwardLarge: stepPlayhead(by: -TimelineKeyMapper.largeStep)
        case .stepForwardLarge: stepPlayhead(by: TimelineKeyMapper.largeStep)
        case .splitAtPlayhead: splitSelectedAtPlayhead()
        case .deleteSelection: deleteSelectedLine()
        case .cancel:
            isScrubbing = false
            clearSelection()
            statusMessage = "已取消选择"
        case .undo: undo()
        case .redo: redo()
        case .previousLine: selectAdjacentLine(offset: -1)
        case .nextLine: selectAdjacentLine(offset: 1)
        case .toggleSnapping: toggleSnapping()
        }
    }

    private func selectAdjacentLine(offset: Int) {
        let lines = project.sortedLines
        guard !lines.isEmpty else { return }
        let current = lines.firstIndex { $0.id == selectedLineID } ?? (offset > 0 ? -1 : lines.count)
        let next = current + offset
        guard next >= 0, next < lines.count else { return }
        selectLineForEditing(lines[next].id)
        seek(to: max(0, lines[next].singStart))
    }

}
