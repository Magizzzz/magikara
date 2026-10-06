import Foundation

/// 歌词块内部的逐字排布（纯计算，便于测试）。
///
/// 规则（用户明确要求）：
/// 1. **不按文字宽度等距铺满** —— 每个字的位置来自它自己的 token/音拍 start；
/// 2. 字符中心落在自己的音拍区间内，不再用“最小步进 + 整组压缩”伪造位置；
/// 3. 正常歌词块使用统一字号，只有极窄块才退化为缩小/单字标记；
/// 4. 所有字符都限制在演唱块内，避免半个日文被边界裁掉。
public enum LyricBlockLayout {

    public struct Item: Sendable, Equatable {
        public var character: Character
        /// 相对块左边缘的横向位置（点）
        public var x: Double
        public var hasTokenEvidence: Bool
    }

    public struct Result: Sendable, Equatable {
        public var items: [Item]
        public var fontSize: Double
    }

    /// 小于这个宽度就放不下任何一个字。
    ///
    /// 真实工程里存在演唱区间只有 0.06 秒的句子（自动对轨里没有证据、
    /// 由相邻句插值出来的句子），在 64 px/秒 下块宽只有 3–5 像素。
    /// 这种情况下**不画字**：块本身仍按真实区间绘制（并带待确认描边），
    /// 硬把 11 个字压进 3 像素只会糊成一团，反而误导。
    public static let minimumUsableWidth: Double = 9

    public static func layout(line: LyricLine,
                              pixelsPerSecond: Double,
                              originTime: Double,
                              width: Double) -> Result {
        let chars = LyricCharTiming.characters(of: line)
        guard !chars.isEmpty, width > 1, pixelsPerSecond > 0 else {
            return Result(items: [], fontSize: 10)
        }
        guard width >= minimumUsableWidth else {
            // 放不下字：只保留第一个字的信息，位置归零，字号取最小值
            return Result(items: [Item(character: chars[0].character, x: 0,
                                       hasTokenEvidence: chars[0].hasTokenEvidence)],
                          fontSize: 6)
        }
        let pps = pixelsPerSecond
        // 时间线是编辑视图，不应该因为每句字数不同而忽大忽小。
        // 统一 10pt；真正窄到放不下时，上层的短块标签再做整体缩放。
        let fontSize = 10.0

        var items: [Item] = []
        var lastX = 0.0
        for (i, tc) in chars.enumerated() {
            let center = tc.start.flatMap { start in
                tc.end.map { end in ((start + end) * 0.5 - originTime) * pps }
            } ?? lastX + fontSize * 0.5
            // 以音拍中心放字，既能让字落在真正演唱的区间，又不会让字形
            // 因为 Text 的左对齐而整体偏到后一个字的时间上。
            let desired = center - fontSize * 0.5
            let x = i == 0
                ? max(0, min(width - fontSize, desired))
                : max(lastX, min(width - fontSize, desired))
            items.append(Item(character: tc.character, x: x, hasTokenEvidence: tc.hasTokenEvidence))
            lastX = x
        }
        return Result(items: items, fontSize: fontSize)
    }
}
