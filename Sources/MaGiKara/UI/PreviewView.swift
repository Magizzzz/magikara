import SwiftUI
import AVFoundation
import AppKit
import MaGiKaraKit

/// 排版缓存：Core Text 测量比较贵，按内容与样式指纹缓存，避免每帧重算。
final class LayoutCache {
    private var storage: [UUID: (key: String, layout: LineLayout)] = [:]

    func layout(for line: LyricLine, style: SubtitleStyle) -> LineLayout {
        let key = [
            line.displayText,
            "\(line.tokens.count)",
            line.tokens.map { $0.reading ?? "-" }.joined(separator: ","),
            line.tokens.map { $0.morae.count }.map(String.init).joined(separator: ","),
            line.tokens.map { token in
                (token.rubyOverrides ?? []).map { "\($0.surfaceStart):\($0.surfaceLength):\($0.reading)" }
                    .joined(separator: ",")
            }.joined(separator: ";"),
            "\(style.fontSize)", "\(style.rubySizeFactor)",
            style.fontName, style.rubyFontName, "\(style.fontWeight)",
        ].joined(separator: "|")

        if let entry = storage[line.id], entry.key == key { return entry.layout }
        let layout = KaraokeLayout.layout(line: line, style: style)
        storage[line.id] = (key, layout)
        return layout
    }

    func invalidate() { storage.removeAll() }
}

/// 视频预览 + 双行纯 K 字幕（RD §3.2）
///
/// 关键：字幕按 `KaraokeCanvas`（1920×1080）排版，再整体等比缩放到预览区。
/// 不这样做的话，72pt 的字号在只有几百点宽的预览里会显得巨大且位置偏上，
/// 预览与 ASS 导出也会对不上。
struct PreviewView: View {
    @EnvironmentObject private var state: AppState
    /// 画面上拖动字幕时记录手势起点和目标轨道。一个手势只对应一个撤销点，
    /// 位置写入当前选中句所属的全局轨道，而不是某一句歌词的 override。
    @State private var subtitleDragStart: CGPoint?
    @State private var subtitleDragLane: ScreenLane?
    /// 预览区原位 Ruby 编辑目标（点击某个汉字后出现）。
    @State private var rubyEdit: RubyInlineTarget?

    var body: some View {
        let activeLaneName = state.selectedLine?.lane.displayName ?? "当前"
        GeometryReader { geo in
            let canvas = Self.aspectFit(canvas: KaraokeCanvas.width / KaraokeCanvas.height,
                                        in: geo.size)
            let scale = canvas.width / KaraokeCanvas.width

            ZStack {
                Color(red: 0.075, green: 0.07, blue: 0.115)

                if state.hasMedia {
                    PlayerLayerView(player: state.playback.player)
                        .id(state.project.mediaURL)
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    placeholder
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                if !state.project.lyricLines.isEmpty {
                    KaraokeOverlay(
                        project: state.project,
                        style: state.project.style,
                        time: state.playhead,
                        selectedLineID: state.selectedLineID,
                        layoutProvider: { line in state.layout(for: line) })
                        .frame(width: KaraokeCanvas.width, height: KaraokeCanvas.height)
                        .scaleEffect(scale)
                        .frame(width: canvas.width, height: canvas.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    // 交互层放在视觉字幕之上：空间点击按上下两行的实际
                    // 屏幕位置选择句子，拖动仍然只调整当前选中轨道的全局位置。
                    // 不再依赖某一行的透明 Text 是否被 SwiftUI 命中。
                    Color.clear
                        .frame(width: canvas.width, height: canvas.height)
                        .contentShape(Rectangle())
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .gesture(subtitleDragGesture(scale: scale))
                        .simultaneousGesture(SpatialTapGesture().onEnded { value in
                            selectPreviewSubtitle(at: value.location, canvas: canvas, scale: scale)
                        })
                        .help(state.selectedLine == nil
                              ? "点击上行或下行字幕选择轨道，再拖动以统一调整位置"
                              : "拖动字幕：统一调整\(activeLaneName)所有歌词位置")

                    // Ruby 原位编辑浮层：点击汉字后紧贴字位上方出现。
                    if let target = rubyEdit {
                        RubyInlineEditor(characters: target.characters,
                                         reading: target.reading,
                                         onCommit: { reading in
                                             state.setRubyReading(lineID: target.lineID,
                                                                  tokenID: target.tokenID,
                                                                  surfaceStart: target.surfaceStart,
                                                                  surfaceLength: target.surfaceLength,
                                                                  reading: reading)
                                         },
                                         onDelete: {
                                             state.clearRubyBinding(lineID: target.lineID,
                                                                    tokenID: target.tokenID,
                                                                    surfaceStart: target.surfaceStart)
                                             rubyEdit = nil
                                         },
                                         onClose: { rubyEdit = nil })
                            .position(x: (geo.size.width - canvas.width) / 2 + target.canvasX,
                                      y: (geo.size.height - canvas.height) / 2 + target.canvasY - 26)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerLarge)
                    .stroke(Theme.dividerStrong, lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitleDragGesture(scale: CGFloat) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if subtitleDragStart == nil {
                    let lane = state.selectedLine?.lane ?? .upper
                    let position = state.project.style.position(for: lane)
                    subtitleDragLane = lane
                    subtitleDragStart = CGPoint(x: position.x, y: position.y)
                    state.beginStyleGesture()
                }
                guard let start = subtitleDragStart,
                      let lane = subtitleDragLane else { return }
                state.updateStyleLive { style in
                    style.setPosition(
                        (x: start.x + value.translation.width / scale,
                         y: start.y + value.translation.height / scale),
                        for: lane)
                }
            }
            .onEnded { _ in
                subtitleDragStart = nil
                subtitleDragLane = nil
            })
    }

    /// 预览点击只负责选中当前播放头所在的上行/下行歌词，
    /// 不依赖视觉文字本身是否能被 SwiftUI 命中。
    private func selectPreviewSubtitle(at location: CGPoint, canvas: CGSize, scale: CGFloat) {
        let pair = state.project.previewLines(at: state.playhead)
        let style = state.project.style
        let rowStep = max(22, (style.fontSize * 1.25 + style.lineGap) * scale)
        let centerY = canvas.height / 2
        let candidates: [(line: LyricLine, lane: ScreenLane, y: CGFloat)] = [
            pair.upper.map { ($0, .upper, centerY - rowStep / 2) },
            pair.lower.map { ($0, .lower, centerY + rowStep / 2) },
        ].compactMap { $0 }

        guard let nearest = candidates.min(by: {
            abs($0.y + style.position(for: $0.lane).y * scale - location.y)
                < abs($1.y + style.position(for: $1.lane).y * scale - location.y)
        }) else { return }

        let targetY = nearest.y + style.position(for: nearest.lane).y * scale
        guard abs(targetY - location.y) <= max(28, rowStep * 0.75) else { return }
        state.selectLineForEditing(nearest.line.id)
        state.seek(to: max(0, nearest.line.singStart))
        // 选中后如果点击落在某个汉字上，直接给出该汉字的原位 Ruby 编辑入口。
        rubyEdit = rubyTarget(at: location, canvas: canvas, scale: scale, line: nearest.line)
    }

    /// 把一次点击映射到「第几个汉字 / 哪段绑定」，用于预览区原位编辑。
    private func rubyTarget(at location: CGPoint,
                            canvas: CGSize,
                            scale: CGFloat,
                            line: LyricLine) -> RubyInlineTarget? {
        let style = state.project.style
        let rowStep = max(22, (style.fontSize * 1.25 + style.lineGap) * scale)
        let centerY = canvas.height / 2
            + (line.lane == .upper ? -rowStep / 2 : rowStep / 2)
            + style.position(for: line.lane).y * scale
        guard abs(location.y - centerY) <= max(28, rowStep * 0.75) else { return nil }

        let layout = state.layout(for: line)
        let lineCenterX = canvas.width / 2
        let font = KaraokeLayout.mainFont(style: style)

        for token in line.tokens {
            guard let geo = layout.tokenGeometry[token.id] else { continue }
            let tokenMinX = lineCenterX + CGFloat(geo.centerX - geo.width / 2)
            let tokenMaxX = tokenMinX + CGFloat(geo.width)
            guard location.x >= tokenMinX - 2, location.x <= tokenMaxX + 2 else { continue }

            let chars = Array(token.surface)
            var prefix = ""
            for (i, ch) in chars.enumerated() {
                let prefixWidth = CGFloat(KaraokeLayout.width(of: prefix, font: font))
                let charWidth = CGFloat(KaraokeLayout.width(of: String(ch), font: font))
                defer { prefix += String(ch) }
                guard JapaneseText.isKanji(ch) else { continue }
                guard location.x >= tokenMinX + prefixWidth - 3,
                      location.x <= tokenMinX + prefixWidth + charWidth + 3 else { continue }

                let resolved = RubyBindingResolver.resolve(for: token)
                let binding = resolved.bindings.first {
                    $0.surfaceStart <= i && i < $0.surfaceStart + $0.surfaceLength
                }
                let surfaceStart = binding?.surfaceStart ?? i
                let surfaceLength = binding?.surfaceLength ?? 1
                let start = max(0, min(chars.count, surfaceStart))
                let end = max(start, min(chars.count, start + surfaceLength))
                return RubyInlineTarget(lineID: line.id,
                                        tokenID: token.id,
                                        surfaceStart: surfaceStart,
                                        surfaceLength: surfaceLength,
                                        characters: String(chars[start..<end]),
                                        reading: binding?.reading ?? "",
                                        canvasX: tokenMinX + prefixWidth + charWidth / 2,
                                        canvasY: centerY)
            }
        }
        return nil
    }

    /// 在给定区域内找出保持设计宽高比的最大矩形（letterbox）。
    static func aspectFit(canvas aspect: Double, in size: CGSize) -> CGSize {
        guard size.width > 1, size.height > 1 else { return CGSize(width: 1, height: 1) }
        let byWidth = CGSize(width: size.width, height: size.width / aspect)
        if byWidth.height <= size.height { return byWidth }
        return CGSize(width: size.height * aspect, height: size.height)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if let image = MaGiKaraResources.logoImage() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .opacity(0.9)
            }
            Text("导入 MV、视频或音频开始制作")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("支持 mp4 / mov / mp3 / wav")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Button {
                state.importMedia()
            } label: {
                Text("导入媒体")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}

/// AVPlayerLayer 承载视图（比 AVKit 的 VideoPlayer 更容易做出无控件预览）
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.clear.cgColor
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - 预览区原位 Ruby 编辑

/// 预览点击命中的汉字 / 熟字訓段。
struct RubyInlineTarget: Equatable {
    var lineID: UUID
    var tokenID: UUID
    var surfaceStart: Int
    var surfaceLength: Int
    var characters: String
    var reading: String
    /// 画布坐标（未缩放）中的字符中心与基线。
    var canvasX: CGFloat
    var canvasY: CGFloat
}

/// 紧贴汉字上方的最小浮层：输入假名即保存，可删除绑定或关闭。
struct RubyInlineEditor: View {
    let characters: String
    let reading: String
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(characters: String,
         reading: String,
         onCommit: @escaping (String) -> Void,
         onDelete: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.characters = characters
        self.reading = reading
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onClose = onClose
        _draft = State(initialValue: reading)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(characters)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.violet)
            TextField("假名", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 64)
                .focused($focused)
                .onSubmit { onClose() }
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("删除该汉字的假名绑定")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.panelSolid, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.violet.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .onChange(of: draft) { _, newValue in onCommit(newValue) }
        .onAppear { focused = true }
        .onExitCommand { onClose() }
    }
}
