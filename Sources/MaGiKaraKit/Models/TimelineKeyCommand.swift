import Foundation

/// 时间线键盘命令（对标剪映：空格播放/暂停、方向键逐帧、Cmd+B 分割、Esc 取消）。
///
/// 单独抽成纯函数的原因：
/// 1. 可以单元测试「文本框聚焦时是否抢快捷键」这种容易出错的分支；
/// 2. 让键盘入口和按钮入口走同一套命令，行为不会分叉。
public enum TimelineKeyCommand: Equatable, Sendable {
    case togglePlay
    case stepBackward
    case stepForward
    case stepBackwardLarge
    case stepForwardLarge
    case splitAtPlayhead
    case deleteSelection
    case cancel
    case undo
    case redo
    /// 上一句 / 下一句
    case previousLine
    case nextLine
    /// 吸附开关（FCPX 同款快捷键 N）
    case toggleSnapping
}

public enum TimelineKeyMapper {

    /// 逐帧步长。工程按 30 fps 计，方向键走一帧。
    public static let frameStep: Double = 1.0 / 30.0
    /// 带 Shift 的大步长
    public static let largeStep: Double = 1.0

    /// 文本输入是否聚焦。聚焦时**除了撤销/重做**，其余时间线快捷键一律让位，
    /// 否则用户在歌词框里按空格就打不出空格了。
    public static func shouldIgnore(_ command: TimelineKeyCommand, isTextEditing: Bool) -> Bool {
        guard isTextEditing else { return false }
        switch command {
        case .undo, .redo:
            return false          // 文本框里也希望能撤销，交给系统处理
        default:
            return true
        }
    }

    /// 把一次按键映射成命令。
    /// - Parameters:
    ///   - characters: `event.charactersIgnoringModifiers`
    ///   - keyCode: 用于区分左右方向键
    ///   - command/shift/option/control: 修饰键
    public static func command(characters: String?,
                               keyCode: UInt16,
                               command: Bool,
                               shift: Bool,
                               option: Bool,
                               control: Bool) -> TimelineKeyCommand? {
        // Cmd 组合
        if command {
            switch characters?.lowercased() {
            case "b": return .splitAtPlayhead
            case "z": return shift ? .redo : .undo
            case "y": return .redo
            default: return nil
            }
        }
        if control || option { return nil }

        switch keyCode {
        case 49:  return .togglePlay        // Space
        case 123: return shift ? .stepBackwardLarge : .stepBackward   // ←
        case 124: return shift ? .stepForwardLarge : .stepForward     // →
        case 125: return .nextLine          // ↓
        case 126: return .previousLine      // ↑
        case 51, 117: return .deleteSelection  // Delete / Forward Delete
        case 53:  return .cancel            // Esc
        default: break
        }
        if !shift, characters?.lowercased() == "n" { return .toggleSnapping }
        return nil
    }
}
