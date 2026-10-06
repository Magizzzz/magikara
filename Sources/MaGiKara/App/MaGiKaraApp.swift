import SwiftUI
import AppKit
import MaGiKaraKit

/// 说明：这个 App 没有 Xcode，`.app` 是 `Scripts/build.sh` 手工组装的。
/// 刚组装出来的 bundle 未必已经注册到 LaunchServices，
/// 这种情况下 SwiftUI 的 `WindowGroup` 会静默地不创建窗口
/// （实测：进程活着、菜单栏出现，但窗口数为 0）。
///
/// 因此这里：
///   1. 由 AppDelegate 持有唯一的 AppState，供场景与兜底窗口共用；
///   2. 启动后检查是否真的出现了可见窗口，没有就自己建一个 NSWindow + NSHostingView；
///   3. build.sh 在打包后会调用 lsregister 注册 bundle（正常双击路径）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var fallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 整个界面是写死的浅色设计（Theme 里全是固定色）。系统处于深色模式时，
        // 输入框、取消按钮、警告框等系统控件会用白色文字，落在浅色底上就看不见了，
        // 所以让 App 始终使用浅色外观，系统控件与自绘界面保持一致。
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 给 SwiftUI 场景一点时间创建窗口；若仍然没有，就自己兜底
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
            if !hasVisibleWindow {
                self.openFallbackWindow()
            }
            self.state.openProjectFromLaunchArguments()
        }
    }

    private func openFallbackWindow() {
        let hosting = NSHostingView(rootView: RootView().environmentObject(state))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "MaGi Kara"
        window.contentView = hosting
        window.minSize = NSSize(width: 1120, height: 720)
        window.center()
        window.setFrameAutosaveName("MaGiKaraMainWindow")
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 关最后一个窗口也会走这里：未保存的新工程先确认，已有路径的工程同步落盘。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.confirmLeavingCurrentProject(action: "退出") else { return .terminateCancel }
        guard state.confirmAbortingVideoExport() else { return .terminateCancel }
        state.flushProjectBeforeQuit()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openFallbackWindow() }
        return true
    }
}

@main
struct MaGiKaraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MaGi Kara") {
            RootView()
                .environmentObject(appDelegate.state)
                .preferredColorScheme(.light)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            MaGiKaraCommands(state: appDelegate.state, menu: appDelegate.state.menuState)
        }
    }
}

/// 菜单必须监听状态：直接在 App.body 里读 appDelegate.state 不会刷新，
/// 「撤销」「重做」和「分析」菜单会一直停在启动时的启用 / 禁用状态。
/// 只监听 MenuState，避免播放头每帧变化都重建菜单。
struct MaGiKaraCommands: Commands {
    let state: AppState
    @ObservedObject var menu: MenuState

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { state.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!menu.canUndo)
            Button("重做") { state.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!menu.canRedo)
        }
        CommandGroup(after: .appInfo) {
            Button("运行环境配置单…") { state.openRuntimeSetup() }
        }
        CommandGroup(replacing: .newItem) {
            Button("重新开始") { state.requestNewProject() }
                .keyboardShortcut("n", modifiers: .command)
            Button("打开工程…") { state.openProject() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存工程") { state.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
            Button("工程另存为…") { state.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("导入媒体…") { state.importMedia() }
                .keyboardShortcut("i", modifiers: .command)
            Button("导出 ASS…") { state.exportASS() }
                .keyboardShortcut("e", modifiers: .command)
        }
        CommandMenu("分析") {
            Button("生成 AI 歌词") { state.autoGenerate() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(menu.isAnalyzing)
            Button("取消分析") { state.cancelAnalysis() }
                .disabled(!menu.isAnalyzing)
            Divider()
            Button("重新对齐选中句") { state.realignSelectedLine() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!menu.hasSelectedLine)
            Button("修正整体偏移与漂移") { state.correctDrift() }
                .disabled(!menu.hasLyrics)
            Button("跳到下一处待确认") { state.jumpToNextReview() }
                .keyboardShortcut("j", modifiers: .command)
        }
    }
}
