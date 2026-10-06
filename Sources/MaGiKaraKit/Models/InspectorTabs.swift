import Foundation

/// 右侧属性面板的两个主 Tab（RD §3、P0 验收 2）。
///
/// 只保留两个：`文本`（统一样式层）与 `字幕`（当前实例层）。
/// Ruby 原位编辑放在 `字幕` Tab 内，不新增第三个主 Tab。
public enum InspectorPrimaryTab: String, CaseIterable, Identifiable, Sendable {
    case text
    case subtitle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: return "文本"
        case .subtitle: return "字幕"
        }
    }

    public var icon: String {
        switch self {
        case .text: return "textformat"
        case .subtitle: return "captions.bubble"
        }
    }
}

/// 右侧面板的选中联动规则（纯函数，便于测试）。
public enum SubtitleEditorRouting {

    /// 未选中任何色块时的空状态文案。
    public static let emptySelectionHint = "点击时间轴色块开始编辑"

    /// 点击时间轴色块：设置选中并自动激活「字幕」Tab。
    public static func tab(afterSelectingLine id: UUID,
                           from current: InspectorPrimaryTab) -> InspectorPrimaryTab {
        .subtitle
    }

    /// 选中状态变化时：选中新片段 → 字幕 Tab；清空选择 → 保持当前 Tab。
    public static func tab(afterSelectionChangeTo id: UUID?,
                           from current: InspectorPrimaryTab) -> InspectorPrimaryTab {
        id == nil ? current : .subtitle
    }
}
