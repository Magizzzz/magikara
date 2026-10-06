import Foundation

/// 时间线坐标 ↔ 时间的映射。
///
/// 抽成纯函数是为了能写回归测试：时间线的点击定位、缩放后的映射、
/// 边界处理都是纯数学，不该只靠肉眼验证。
///
/// ## 坐标约定（本轮统一）
///
/// - **bodyX**：时间线内容「正文」自身的横坐标，`0` 就是时间 0，
///   也是各轨道视图手势拿到的本地坐标。时间 t ↔ `bodyX = t * pps`。
/// - **contentX**：可滚动内容坐标，左边缘为 0；
///   `contentX = leadingPadding + bodyX`。`leadingPadding` 是正文左边
///   为 0:00 预留的安全起点（`Theme.timelineLeadingInset`）。
/// - **viewportX**：用户看到/点击处的横坐标，`viewportX = contentX - scrollX`。
///
/// 统一这三个量之后，seek / scroll / zoom 都只用同一套换算，
/// 不会再出现「只改了视觉、点击和缩放却按另一套坐标算」的错位。
public enum TimelineGeometry {

    // MARK: bodyX（时间 0 = 0）

    /// bodyX → 时间
    public static func time(forBodyX bodyX: Double, pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return bodyX / pixelsPerSecond
    }

    /// 时间 → bodyX
    public static func bodyX(forTime time: Double, pixelsPerSecond: Double) -> Double {
        time * pixelsPerSecond
    }

    // MARK: contentX（含 leading inset）

    /// 内容坐标 → 时间
    public static func time(forContentX contentX: Double,
                            pixelsPerSecond: Double,
                            leadingPadding: Double = 0) -> Double {
        time(forBodyX: contentX - leadingPadding, pixelsPerSecond: pixelsPerSecond)
    }

    /// 时间 → 内容坐标
    public static func contentX(forTime time: Double,
                                pixelsPerSecond: Double,
                                leadingPadding: Double = 0) -> Double {
        leadingPadding + bodyX(forTime: time, pixelsPerSecond: pixelsPerSecond)
    }

    // MARK: viewportX（含滚动）

    /// 视口坐标 → 时间（已考虑 leading inset 与横向滚动）
    public static func time(forViewportX viewportX: Double,
                            scrollX: Double,
                            pixelsPerSecond: Double,
                            leadingPadding: Double = 0) -> Double {
        time(forContentX: viewportX + scrollX,
             pixelsPerSecond: pixelsPerSecond,
             leadingPadding: leadingPadding)
    }

    /// 时间 → 视口坐标
    public static func viewportX(forTime time: Double,
                                 scrollX: Double,
                                 pixelsPerSecond: Double,
                                 leadingPadding: Double = 0) -> Double {
        contentX(forTime: time, pixelsPerSecond: pixelsPerSecond, leadingPadding: leadingPadding) - scrollX
    }

    /// 把时间夹到 [0, duration]。duration <= 0 时只保证非负。
    public static func clampTime(_ time: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }

    /// 点击定位用：视口坐标 → 夹好的时间。
    public static func seekTime(forViewportX viewportX: Double,
                                scrollX: Double,
                                pixelsPerSecond: Double,
                                duration: Double,
                                leadingPadding: Double = 0) -> Double {
        clampTime(time(forViewportX: viewportX,
                       scrollX: scrollX,
                       pixelsPerSecond: pixelsPerSecond,
                       leadingPadding: leadingPadding),
                  duration: duration)
    }

    /// 内容总宽
    public static func contentWidth(duration: Double,
                                    pixelsPerSecond: Double,
                                    viewportWidth: Double,
                                    leadingPadding: Double = 0,
                                    trailingPadding: Double = 40) -> Double {
        max(viewportWidth, leadingPadding + duration * pixelsPerSecond + trailingPadding)
    }

    /// 最大可滚动量
    public static func maxScrollX(contentWidth: Double, viewportWidth: Double) -> Double {
        max(0, contentWidth - viewportWidth)
    }

    /// 把 scrollX 夹到合法范围
    public static func clampScrollX(_ scrollX: Double, contentWidth: Double, viewportWidth: Double) -> Double {
        min(max(0, scrollX), maxScrollX(contentWidth: contentWidth, viewportWidth: viewportWidth))
    }

    /// 缩放时保持某个时间点在视口里的相对位置不变。
    ///
    /// 这是「缩放后坐标映射错位」的正解：直接改 pixelsPerSecond 会让
    /// 左边缘对应的时间跳变，用户会觉得整条时间线乱跑。
    /// 注意锚点用的是**视口坐标**，包含了 leadingPadding；
    /// 之前漏掉它会让缩放一次就整体平移一个 inset。
    public static func scrollXKeepingAnchor(anchorTime: Double,
                                            anchorViewportFraction: Double,
                                            newPixelsPerSecond: Double,
                                            viewportWidth: Double,
                                            contentWidth: Double,
                                            leadingPadding: Double = 0) -> Double {
        let anchorX = contentX(forTime: anchorTime,
                               pixelsPerSecond: newPixelsPerSecond,
                               leadingPadding: leadingPadding)
        let desired = anchorX - anchorViewportFraction * viewportWidth
        return clampScrollX(desired, contentWidth: contentWidth, viewportWidth: viewportWidth)
    }
}

/// 播放时时间线是否要自动滚动去跟随播放头。
///
/// 拖动色块 / 拖动播放头（scrub）期间一律不滚：色块在鼠标下面跑，根本没法拖准。
/// 拖完后若播放头已经跑出视口，会立刻重新居中（正常的跟随行为）。
public enum TimelineAutoFollow {
    /// 播放头离视口左右边缘的安全边距占视口宽度的比例。
    public static let marginFraction: Double = 0.12

    public static func shouldFollow(isPlaying: Bool,
                                    isInteracting: Bool,
                                    viewportWidth: Double,
                                    playheadContentX: Double,
                                    scrollX: Double) -> Bool {
        guard isPlaying, !isInteracting, viewportWidth > 100 else { return false }
        let margin = viewportWidth * marginFraction
        return playheadContentX < scrollX + margin
            || playheadContentX > scrollX + viewportWidth - margin
    }
}
