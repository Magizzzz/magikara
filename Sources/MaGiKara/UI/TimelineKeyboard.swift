import SwiftUI
import AppKit
import MaGiKaraKit

/// 时间线键盘层（对标剪映：空格播放/暂停、方向键逐帧、⌘B 分割、Esc 取消）。
///
/// 为什么用本地事件监听而不是 SwiftUI 的 `keyboardShortcut`：
/// 1. 方向键 / 删除 / Esc 这类没有菜单项的键，SwiftUI 在 macOS 上不好接；
/// 2. 需要「文本框聚焦时让位」这一层判断 —— 集中在一个地方判，入口不会漏。
///
/// 只在 keyDown 且未消费时才拦截，其余按键原样放行。
struct TimelineKeyboardLayer: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content
            .onAppear { TimelineKeyboardMonitor.shared.install(state: state) }
            .onDisappear { TimelineKeyboardMonitor.shared.uninstall() }
    }
}

extension View {
    func timelineKeyboard(_ state: AppState) -> some View {
        modifier(TimelineKeyboardLayer(state: state))
    }
}

@MainActor
final class TimelineKeyboardMonitor {
    static let shared = TimelineKeyboardMonitor()

    private var monitor: Any?
    private weak var state: AppState?

    func install(state: AppState) {
        self.state = state
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let state = self.state else { return event }
            return self.handle(event, state: state) ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = nil
    }

    /// 文本框是否正在输入。
    ///
    /// SwiftUI 的 `TextEditor` 用 `NSTextView` 当 firstResponder，
    /// `TextField` 用 field editor（也是 `NSTextView`），所以判 NSTextView 就够了。
    private var isTextEditing: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView, textView.isEditable { return true }
        if let view = responder as? NSView, view is NSTextField { return true }
        return false
    }

    /// 返回 true 表示事件已被消费
    private func handle(_ event: NSEvent, state: AppState) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let command = TimelineKeyMapper.command(
            characters: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        ) else { return false }

        if TimelineKeyMapper.shouldIgnore(command, isTextEditing: isTextEditing) { return false }

        // 撤销/重做交给 AppState（文本框聚焦时也允许，但让系统先处理文本自身的撤销）
        if isTextEditing, command == .undo || command == .redo { return false }

        state.perform(command)
        return true
    }
}
