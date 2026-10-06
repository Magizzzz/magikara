import SwiftUI
import MaGiKaraKit

struct LyricsCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trackName: String
    @State private var artistName = ""
    @State private var candidates: [LyricsCandidate] = []
    @State private var selectedID: Int?
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let client = LRCLIBClient()
    private let mediaDurationSec: Double?
    private let onUse: (LyricsCandidate) -> Void

    init(initialTrackName: String,
         mediaDurationSec: Double?,
         onUse: @escaping (LyricsCandidate) -> Void) {
        _trackName = State(initialValue: initialTrackName)
        self.mediaDurationSec = mediaDurationSec
        self.onUse = onUse
    }

    private var selectedCandidate: LyricsCandidate? {
        candidates.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("在线搜索歌词")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("只导入歌词文本与重复行；所有演唱时间仍由本机音频计算。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 搜索条件：每个输入框上方都标注它是什么
            HStack(alignment: .bottom, spacing: 10) {
                fieldWithCaption("歌曲名", help: "要搜索的歌曲名称（必填）") {
                    TextField("", text: $trackName,
                              prompt: Text("输入歌曲名").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit { search() }
                        .accessibilityLabel("歌曲名")
                }
                fieldWithCaption("歌手（可选）", help: "补充歌手名可以让结果更准确，不填也能搜") {
                    TextField("", text: $artistName,
                              prompt: Text("输入歌手名").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit { search() }
                        .accessibilityLabel("歌手")
                }
                Button(action: search) {
                    if isSearching {
                        ProgressView().controlSize(.small).frame(width: 66)
                    } else {
                        Text("搜索").frame(width: 66)
                    }
                }
                .disabled(isSearching || trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .help("按歌曲名（和歌手）在 LRCLIB 在线搜索歌词，回车也可以")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 带歌手名没搜到、自动改成只按歌曲名搜时，提醒用户这些结果不一定是同一位歌手
            if candidates.first?.matchesRequestedArtist == false {
                Label("没有找到这位歌手的结果，已改为只按歌曲名搜索，并按素材时长排序。使用前请核对歌手和版本。",
                      systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if candidates.isEmpty && !isSearching {
                // 不用 ContentUnavailableView：它的文字用系统颜色，深色模式下会变成白字
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.textTertiary)
                    Text("搜索匹配的歌词")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("可修改歌曲名或补充歌手名后重试。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(candidates) { candidate in
                            candidateCard(candidate)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Text("来源：LRCLIB · 不使用线上时间戳")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(Theme.textPrimary)
                    .help("关闭，不导入任何歌词")
                Button("使用歌词并开始对轨") {
                    guard let selectedCandidate else { return }
                    onUse(selectedCandidate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
                .disabled(selectedCandidate == nil || isSearching)
                .help(selectedCandidate == nil
                      ? "先在上面的结果里选一条歌词"
                      : "把选中的歌词填入歌词栏，并立即开始自动对轨（只取文字，不用线上时间戳）")
            }
        }
        .padding(20)
        .frame(width: 660, height: 610)
        .background(Theme.panelSolid)
        .preferredColorScheme(.light)
    }

    /// 输入框上方带一行说明文字，让用户一眼看出每个框是填什么的。
    private func fieldWithCaption<Content: View>(_ caption: String,
                                                 help: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .help(help)
    }

    /// 结果卡片里的小标注：「标签 值」，标签用次要色，值用主色。
    private func labeled(_ label: String, _ value: String, valueColor: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(value).foregroundStyle(valueColor)
        }
    }

    private func candidateCard(_ candidate: LyricsCandidate) -> some View {
        let isSelected = selectedID == candidate.id
        let preview = candidate.lyricsText
            .components(separatedBy: .newlines)
            .prefix(4)
            .joined(separator: " · ")

        return Button {
            selectedID = candidate.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.trackName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(candidate.artistName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let duration = candidate.durationSec {
                        labeled("时长", durationLabel(duration))
                            .font(.system(size: 11).monospacedDigit())
                            .help("这条歌词对应的歌曲时长，和你的素材时长越接近越可能是同一版本")
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.violet : Theme.textTertiary)
                }
                if let albumName = candidate.albumName, !albumName.isEmpty {
                    labeled("专辑", albumName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                labeled("歌词开头", preview, valueColor: Theme.textPrimary)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                    Text("共 \(candidate.lyricsText.components(separatedBy: .newlines).count) 行")
                    Text("·")
                    Text(candidate.textSource == .synchronized ? "含重复行结构，时间戳已丢弃" : "纯文本")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.violet)
            }
            .padding(12)
            .background(isSelected ? Theme.violet.opacity(0.08) : .white,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Theme.violet.opacity(0.45) : Theme.divider, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func search() {
        let track = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        candidates = []
        selectedID = nil
        let artist = artistName
        let duration = mediaDurationSec

        Task {
            defer { isSearching = false }
            do {
                let found = try await client.search(trackName: track,
                                                    artistName: artist,
                                                    mediaDurationSec: duration)
                candidates = found
                selectedID = found.first?.id
                if found.isEmpty { errorMessage = "没有找到带歌词的匹配结果，请调整歌曲名或歌手名。" }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
