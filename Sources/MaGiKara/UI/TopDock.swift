import SwiftUI

/// 顶部只负责切换工作区；编辑命令集中放在时间线工具栏。
struct TopDock: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarSection.workspaceCases) { section in
                Button {
                    state.sidebarSection = section
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.system(size: 10.5, weight: .medium))
                        Text(section == .style ? "字幕模版" : section.title)
                            .font(.system(size: 11,
                                          weight: state.sidebarSection == section ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(state.sidebarSection == section ? .white : Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if state.sidebarSection == section {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("工作区：\(section.title)")
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                japaneseSignature

                if state.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.topDockHeight)
    }

    /// 将日文品牌签名放在导航栏右侧留白，轻量悬浮，不与导出按钮争抢焦点。
    private var japaneseSignature: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.accentGradient)
                .accessibilityHidden(true)

            Text("歌い続ける限り、きっとまた出会える！")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.84)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(LinearGradient(
                    colors: [.white.opacity(0.32), Theme.violet.opacity(0.055)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .overlay {
                    Capsule().stroke(.white.opacity(0.62), lineWidth: 0.75)
                }
        }
        .help("歌い続ける限り、きっとまた出会える！")
        .offset(y: 4)
    }
}
