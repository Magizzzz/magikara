import SwiftUI
import AppKit
import MaGiKaraKit

/// 横向滚轮/触控板平移时间线。
///
/// 为什么需要：轨道区域的拖动已经被「拖动 scrub」占用（用户要求轨道可拖动定位），
/// 如果把平移也绑在拖动上就会互相抢手势。macOS 上横向滚动本来就是最自然的平移方式，
/// 所以把平移交给滚轮，拖动交给 scrub，两者不冲突。
///
/// 触控板的 scrollWheel / magnify 事件不一定会经过 SwiftUI 的透明叠层，
/// 因此这里额外安装窗口级 local monitor，并且只消费时间线区域内的事件。
struct ScrollWheelCatcher: NSViewRepresentable {
    /// 横向滚动增量（像素）
    let onScroll: (Double) -> Void
    /// 捏合/⌘滚轮的缩放增量
    var onZoom: ((Double) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CatcherView else { return }
        v.onScroll = onScroll
        v.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?
        var onZoom: ((Double) -> Void)?
        private var localMonitor: Any?

        deinit {
            removeLocalMonitor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeLocalMonitor()
            guard window != nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func removeLocalMonitor() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        private func isInsideTimeline(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point)
        }

        private func handle(_ event: NSEvent) {
            guard isInsideTimeline(event) else { return }

            if event.type == .magnify {
                // 双指向外张开放大、向内收缩缩小；回调单位是百分比增量。
                let delta = Double(event.magnification) * 100
                guard abs(delta) > 0.01 else { return }
                onZoom?(delta)
                return
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 滚轮 / 双指滚动 = 平移；⌘+滚动 = 缩放。
            let mapped = TimelineScrollMapper.map(
                deltaX: Double(event.scrollingDeltaX),
                deltaY: Double(event.scrollingDeltaY),
                shift: flags.contains(.shift),
                command: flags.contains(.command),
                precise: event.hasPreciseScrollingDeltas)
            if let zoom = mapped.zoomDelta {
                onZoom?(zoom)
            } else if mapped.panPixels != 0 {
                onScroll?(mapped.panPixels)
            }
        }

        // 鼠标点击/拖动全部透传给下面的 SwiftUI 视图；滚动由 local monitor 接收。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

    }
}
