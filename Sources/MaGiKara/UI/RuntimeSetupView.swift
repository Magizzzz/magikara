import SwiftUI
import AppKit
import MaGiKaraKit

// MARK: - 配置单状态

/// 运行环境配置单：首次启动发现缺模型 / 缺对轨环境时弹出，一键下载安装。
@MainActor
final class RuntimeSetupModel: ObservableObject {

    enum Phase: Equatable {
        case overview, running, finished, failed(String)
    }

    @Published private(set) var phase: Phase = .overview
    @Published private(set) var components: [RuntimeComponent] = RuntimeSetup.components()
    @Published var preference: DownloadSourcePreference = .saved {
        didSet { DownloadSourcePreference.saved = preference }
    }
    @Published var licenseAccepted = false

    @Published private(set) var currentStep: RuntimeSetupStep?
    @Published private(set) var finishedSteps: Set<RuntimeSetupStep> = []
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var bytesTotal: Int64?
    @Published private(set) var bytesPerSecond: Double?
    @Published private(set) var currentItem = ""
    @Published private(set) var sourceName: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?

    private var task: Task<Void, Never>?
    private var speedSample: (time: Date, bytes: Int64)?

    var isComplete: Bool { components.allSatisfy(\.isReady) }
    var missing: [RuntimeComponent] { components.filter { !$0.isReady } }
    var needsLicense: Bool { missing.contains { $0.id == .alignerModel } }
    var downloadBytes: Int64 { missing.reduce(0) { $0 + $1.downloadBytes } }

    func refresh() {
        components = RuntimeSetup.components()
    }

    func start() {
        guard task == nil else { return }
        phase = .running
        currentStep = nil
        finishedSteps = []
        bytesDone = 0
        bytesTotal = nil
        bytesPerSecond = nil
        currentItem = ""
        sourceName = nil
        logs = []
        startedAt = Date()
        finishedAt = nil

        let runner = RuntimeSetupRunner { [weak self] event in
            // 事件来自下载 / 子进程线程；按顺序回到主线程
            DispatchQueue.main.async { self?.handle(event) }
        }
        let preference = self.preference
        task = Task { [weak self] in
            do {
                try await runner.run(preference: preference)
                await MainActor.run { self?.finish(error: nil) }
            } catch {
                await MainActor.run { self?.finish(error: error) }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func backToOverview() {
        refresh()
        phase = .overview
    }

    private func finish(error: Error?) {
        task = nil
        finishedAt = Date()
        refresh()
        if let currentStep, error == nil { finishedSteps.insert(currentStep) }
        if error == nil {
            phase = .finished
        } else if error is CancellationError {
            appendLog("已取消。已下载的部分会保留，下次继续。")
            phase = .overview
        } else {
            let message = error?.localizedDescription ?? "未知错误"
            appendLog("失败：\(message)")
            phase = .failed(message)
        }
    }

    private func handle(_ event: RuntimeSetupEvent) {
        switch event {
        case .stepStarted(let step):
            if let currentStep { finishedSteps.insert(currentStep) }
            currentStep = step
            bytesDone = 0
            bytesTotal = nil
            bytesPerSecond = nil
            speedSample = nil
            currentItem = ""
            appendLog("== \(step.title) ==")
        case .stepSkipped(let step):
            if let currentStep { finishedSteps.insert(currentStep) }
            currentStep = nil
            finishedSteps.insert(step)
            appendLog("== \(step.title)：已就绪，跳过 ==")
        case .source(let name):
            sourceName = name
        case .bytes(let done, let total):
            let now = Date()
            if let sample = speedSample {
                let interval = now.timeIntervalSince(sample.time)
                if interval >= 1 {
                    let instant = Double(done - sample.bytes) / interval
                    if instant >= 0 {
                        bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
                    }
                    speedSample = (now, done)
                }
            } else {
                speedSample = (now, done)
            }
            bytesDone = done
            bytesTotal = total
        case .item(let item):
            currentItem = item
        case .log(let line):
            appendLog(line)
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
    }
}

// MARK: - 配置单界面

struct RuntimeSetupView: View {
    @ObservedObject var model: RuntimeSetupModel
    var onClose: () -> Void

    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .overview: overview
            case .running: running
            case .finished: finished
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 620)
        .background(Theme.panelSolid, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    // MARK: 配置单

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("运行环境配置单")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.isComplete
                         ? "所有组件都已就绪，可以直接使用。"
                         : "首次使用需要下载下面缺少的组件。全部装在你的用户目录里，不影响系统和其它软件。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(model.components.enumerated()), id: \.element.id) { index, component in
                    if index > 0 { Rectangle().fill(Theme.divider).frame(height: 1) }
                    componentRow(component)
                }
            }
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 1))

            if !model.isComplete {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("需要下载约 \(RuntimeSetup.formatBytes(model.downloadBytes))，视网络情况约 3–15 分钟")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 10) {
                    Text("下载源")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $model.preference) {
                        ForEach(DownloadSourcePreference.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Text("国内网络选「自动」即可")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                if model.needsLicense {
                    Toggle(isOn: $model.licenseAccepted) {
                        Text("我了解 Yohane 对轨模型采用 CC BY-NC-SA 4.0 许可，仅限个人非商业使用")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                if model.isComplete {
                    primaryButton("完成", action: onClose)
                } else {
                    Button("稍后再说", action: onClose)
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                    primaryButton("一键安装") { model.start() }
                        .disabled(model.needsLicense && !model.licenseAccepted)
                        .opacity(model.needsLicense && !model.licenseAccepted ? 0.5 : 1)
                }
            }
        }
        .padding(24)
    }

    private func componentRow(_ component: RuntimeComponent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: component.isReady ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(component.isReady ? Theme.violet : Theme.textTertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(component.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text("许可：\(component.license)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Text(statusText(component))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(component.isReady ? Theme.violet : Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusText(_ component: RuntimeComponent) -> String {
        if component.isReady { return component.isBundled ? "内置" : "已就绪" }
        if component.id == .ffmpeg { return "缺失" }
        return RuntimeSetup.formatBytes(component.downloadBytes)
    }

    // MARK: 安装中

    private var running: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.regular)
                Text(model.currentStep.map { "正在\($0.title)…" } ?? "正在准备…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("已用时 \(Self.duration(context.date.timeIntervalSince(model.startedAt ?? context.date)))"
                         + (model.sourceName.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                stepBar
                byteProgress
                if !model.currentItem.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(model.currentItem)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.panelBorder, lineWidth: 1))

            Button("取消") { model.cancel() }
                .controlSize(.large)

            Text("首次运行需要准备对轨环境和模型，可能需要几分钟。中途断网或取消，下次会接着下载。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            logDisclosure
        }
        .padding(24)
    }

    private var stepBar: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(RuntimeSetupStep.allCases) { step in
                let done = model.finishedSteps.contains(step)
                let active = model.currentStep == step
                VStack(spacing: 7) {
                    Capsule()
                        .fill(done || active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.divider))
                        .frame(height: 4)
                    Group {
                        if done {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.violet)
                        } else if active {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 14)
                    Text(step.title)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var byteProgress: some View {
        let total = model.bytesTotal ?? 0
        let fraction = total > 0 ? min(1, Double(model.bytesDone) / Double(total)) : 0
        let remaining = max(0, total - model.bytesDone)
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.divider)
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            HStack(spacing: 0) {
                stat(total > 0
                     ? "\(RuntimeSetup.formatBytes(model.bytesDone)) / \(RuntimeSetup.formatBytes(total))"
                     : "—")
                stat(total > 0 ? "剩余 \(RuntimeSetup.formatBytes(remaining))" : "—")
                stat(model.bytesPerSecond.map { "\(RuntimeSetup.formatBytes(Int64($0)))/s" } ?? "—")
                stat(eta(remaining: remaining))
            }
        }
    }

    private func eta(remaining: Int64) -> String {
        guard let speed = model.bytesPerSecond, speed > 1, remaining > 0 else { return "—" }
        return "约 \(Self.duration(Double(remaining) / speed))"
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 完成 / 失败

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentGradient)
            Text("环境已就绪")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let startedAt = model.startedAt, let finishedAt = model.finishedAt {
                Text("用时 \(Self.duration(finishedAt.timeIntervalSince(startedAt)))。导入歌曲，点「生成 AI 歌词」就能开始。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            primaryButton("开始使用", action: onClose)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.warning)
            Text("安装没有完成")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("可以在下载源里换成「国内镜像」或「官方源」再试。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 12) {
                Button("返回配置单") { model.backToOverview() }
                    .controlSize(.large)
                primaryButton("重试") { model.start() }
            }
            logDisclosure
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    // MARK: 日志

    private var logDisclosure: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() }
                } label: {
                    Label(showLog ? "收起日志" : "显示日志", systemImage: showLog ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                if showLog {
                    Button("复制日志") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.violet)
                }
            }
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                        .textSelection(.enabled)
                    }
                    .frame(height: 160)
                    .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: model.logs.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: 辅助

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total / 3600) 小时 \(total % 3600 / 60) 分"
    }
}
