import Foundation

/// 歌词块的命中区域（正常 NLE 的拖动规则）。
///
/// - 主体 = 移动整块
/// - 左右边缘 = 修剪（决定画面歌词何时出现/消失）
/// - 选中后：底部「走轨条」两端 = 调走轨范围，中间 = 在块内平移走轨
/// - 假名/歌词轨的**空白处** = scrub（不在这个枚举里，见 TimelineView 的 blankScrub）
public enum LyricBlockZone: String, Sendable, Equatable {
    case move
    case displayStart
    case displayEnd
    case singStart
    case singEnd
    /// 在色块内部平移走轨（扫色区间），走轨时长（速度）不变。
    case sweepMove

    /// 是否是修剪（改某条边的时间）而不是整体移动
    public var isTrim: Bool {
        switch self {
        case .move, .sweepMove: return false
        case .displayStart, .displayEnd, .singStart, .singEnd: return true
        }
    }

    public var displayName: String {
        switch self {
        case .move: return "移动"
        case .displayStart: return "显示开始"
        case .displayEnd: return "显示结束"
        case .singStart: return "演唱开始"
        case .singEnd: return "演唱结束"
        case .sweepMove: return "走轨平移"
        }
    }
}

/// 把「块内的横坐标」映射成拖动意图。
///
/// 抽成纯函数是为了能测：早期实现里拖动区域的判定用的是**视图内坐标**
/// 去和「绝对时间 × pps」比较，只有 `displayStart == 0` 的句子才碰巧正确。
public enum LyricBlockHitTest {

    /// 边缘判定容差（点）
    public static let tolerance: Double = 6

    /// 选中时块底部「走轨条」的高度（点）。
    public static let sweepStripHeight: Double = 12

    /// - Parameters:
    ///   - localX: 相对块左边缘（= displayStart）的横坐标
    ///   - displayWidth: 块总宽（displayStart→max(displayEnd, singEnd)）
    ///   - singOffset: 演唱起点相对块左边缘的偏移
    ///   - singWidth: 演唱区宽度
    ///   - isSelected: 未选中时不暴露内部演唱区边缘手柄（避免误触）
    ///   - localY / blockHeight: 提供时，选中状态下底部「走轨条」的中间区域判为 `.sweepMove`
    public static func zone(localX: Double,
                            displayWidth: Double,
                            singOffset: Double,
                            singWidth: Double,
                            isSelected: Bool,
                            localY: Double? = nil,
                            blockHeight: Double? = nil,
                            tolerance: Double = tolerance) -> LyricBlockZone {
        let tol = max(1, tolerance)
        let singRight = singOffset + singWidth

        // 内部演唱区边缘：只在选中时可拖，且优先于外框边缘
        if isSelected {
            if abs(localX - singOffset) <= tol { return .singStart }
            if abs(localX - singRight) <= tol { return .singEnd }
        }
        // 走轨条中间：在块内平移走轨（边缘手柄已在上面优先处理）
        if isSelected, let y = localY, let height = blockHeight,
           y >= height - sweepStripHeight, y <= height,
           localX > singOffset + tol, localX < singRight - tol {
            return .sweepMove
        }
        // 外框左右边缘 = 显示起止
        if abs(localX - 0) <= tol { return .displayStart }
        if abs(localX - displayWidth) <= tol { return .displayEnd }
        // 其余为主体
        return .move
    }
}

/// 滚轮 → 时间线平移/缩放的映射（纯函数，便于测试「滚轮与 Shift+滚轮都是平移」）。
public enum TimelineScrollMapper {

    public struct Result: Equatable, Sendable {
        /// 横向平移像素（正 = 内容向左走，即看更靠后的时间）
        public var panPixels: Double
        /// 缩放增量（>0 放大），nil = 不缩放
        public var zoomDelta: Double?

        public init(panPixels: Double = 0, zoomDelta: Double? = nil) {
            self.panPixels = panPixels
            self.zoomDelta = zoomDelta
        }
    }

    public static func map(deltaX: Double,
                           deltaY: Double,
                           shift: Bool,
                           command: Bool,
                           precise: Bool) -> Result {
        // ⌘+滚轮 = 缩放
        if command { return Result(panPixels: 0, zoomDelta: deltaY) }

        let raw: Double
        if shift {
            // Shift+滚轮：纵向也要变成横向平移，保证「Shift+滚轮一定平移」
            raw = deltaX != 0 ? deltaX : deltaY
        } else {
            raw = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
        }
        guard abs(raw) > 0.01 else { return Result() }
        let scale = precise ? 1.0 : 12.0
        return Result(panPixels: raw * scale)
    }
}
