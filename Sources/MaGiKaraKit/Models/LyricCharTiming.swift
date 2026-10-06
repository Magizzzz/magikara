import Foundation

/// 句内逐字时间。
///
/// 用途：时间线上的歌词块**不按文字宽度等距铺满**，而是按每个假名/最小 token 的
/// 真实 start/end 摆放，字距允许不一致（用户明确要求）。
///
/// 时间来源优先级（与 RD §8.2 一致，禁止伪造精度）：
/// 1. **ASR token / 音拍时间戳** —— 每个 token 的 morae 按字数比例切给它的每个字；
/// 2. 该 token 没有 morae 时，用相邻有时间的字做**保守线性插值**，并标记 `hasTokenEvidence = false`；
/// 3. 整行都没有时间时，全部为 nil，由调用方按整行区间退化处理。
public struct TimedCharacter: Sendable, Hashable {
    public var character: Character
    public var start: Double?
    public var end: Double?
    /// 该字的时间是否来自真实的 token/音拍证据（false = 插值）
    public var hasTokenEvidence: Bool
}

public enum LyricCharTiming {

    /// 把一行拆成带时间的字符序列。
    public static func characters(of line: LyricLine) -> [TimedCharacter] {
        // 以 displayText 为唯一的文字顺序。旧实现直接把 token.surface 串起来，
        // 一旦 ASR 分词漏掉空格、标点，或某个 token 的 surface 长度与 sourceLength
        // 不一致，时间线里的字就会“整体错位”——看起来像唱的是另一处歌词。
        // sourceStart/sourceLength 才是 token 对回原句的稳定坐标。
        let displayChars = Array(line.displayText)
        guard !displayChars.isEmpty else { return [] }

        var out = displayChars.map {
            TimedCharacter(character: $0, start: nil, end: nil, hasTokenEvidence: false)
        }
        var fallbackCursor = 0

        for token in line.tokens {
            let tokenChars = Array(token.surface)
            let declaredLength = token.sourceLength > 0 ? token.sourceLength : tokenChars.count
            guard declaredLength > 0 else { continue }

            let startIndex: Int
            if token.sourceLength > 0 {
                startIndex = max(0, token.sourceStart)
            } else {
                // 兼容早期旧工程中没有 source range 的 token。
                startIndex = fallbackCursor
            }
            let endIndex = min(displayChars.count, startIndex + declaredLength)
            guard startIndex < endIndex else { continue }
            fallbackCursor = max(fallbackCursor, endIndex)

            let morae = token.morae
            if morae.isEmpty {
                continue
            }
            let n = morae.count
            let m = endIndex - startIndex
            for j in 0..<m {
                let lo = j * n / m
                let hi = (j + 1) * n / m
                if hi > lo, lo < n {
                    let start = morae[lo].start
                    let end = morae[min(hi, n) - 1].end
                    let index = startIndex + j
                    // source range 是主索引；字符本身始终取 displayText，
                    // 避免 ASR 的 surface 误写把时间线文字替换成别的字。
                    out[index].start = start
                    out[index].end = max(start + 0.01, end)
                    out[index].hasTokenEvidence = true
                }
            }
        }
        fillGaps(&out, fallback: (line.singStart, line.singEnd))
        return out
    }

    /// 把没有时间的字用相邻有时间的字线性插值补上（并保持 hasTokenEvidence = false）。
    static func fillGaps(_ chars: inout [TimedCharacter], fallback: (Double, Double)) {
        guard !chars.isEmpty else { return }
        let known = chars.indices.filter { chars[$0].start != nil }
        if known.isEmpty {
            // 整行都没有证据：按整行区间均匀退化，并明确标记不是 token 证据
            let n = chars.count
            let span = max(0.05, fallback.1 - fallback.0)
            for i in chars.indices {
                chars[i].start = fallback.0 + span * Double(i) / Double(n)
                chars[i].end = fallback.0 + span * Double(i + 1) / Double(n)
                chars[i].hasTokenEvidence = false
            }
            return
        }
        for i in chars.indices where chars[i].start == nil {
            let prev = known.last { $0 < i }
            let next = known.first { $0 > i }
            let lo = prev.flatMap { chars[$0].end } ?? fallback.0
            let hi = next.flatMap { chars[$0].start } ?? fallback.1
            let span = max(0.02, hi - lo)
            let from = (prev ?? -1) + 1
            let to = next ?? chars.count
            let group = Array(from..<to)
            let k = group.firstIndex(of: i) ?? 0
            let count = max(1, group.count)
            chars[i].start = lo + span * Double(k) / Double(count)
            chars[i].end = lo + span * Double(k + 1) / Double(count)
            chars[i].hasTokenEvidence = false
        }
    }

    /// 行内是否所有字都有真实 token 证据。
    public static func hasFullTokenEvidence(_ line: LyricLine) -> Bool {
        let chars = characters(of: line)
        return !chars.isEmpty && chars.allSatisfy(\.hasTokenEvidence)
    }
}
