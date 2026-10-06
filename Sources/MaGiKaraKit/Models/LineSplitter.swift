import Foundation

/// 在播放头处分割歌词句（对标剪映/CapCut 的「字幕在播放头分割」）。
///
/// 规则：
/// - 分割点必须落在**演唱区间内部**，且左右两段都不短于 `minimumDuration`；否则拒绝。
/// - 文字按 token 切分：整段在分割点之前的 token 归左句，之后的归右句；
///   跨过分割点的 token 按音拍切（音拍是扫色的最小单位）。
/// - **不丢字、不重复**：左句文字 + 右句文字 == 原句文字。
/// - 音拍时间整体保留（不做缩放），因此 ASR 的真实声学时间不被改写。
/// - 右句拿新 UUID；左句保留原 UUID（撤销/引用不至于错乱）。
public enum LineSplitter {

    public struct Config: Sendable {
        /// 两段各自的最短演唱时长
        public var minimumDuration: Double = 0.12
        /// 是否把切割点吸附到最近的音拍边界（默认开）。
        ///
        /// 为什么必须吸附：音拍是扫色的最小单位。若正好切在音拍中间，
        /// 那个音拍必须同时属于两侧，它对应的字就会**在两段里各出现一次**
        /// （实测：「きみのうた」在 の 中间切会得到「きみの」+「のうた」）。
        /// 吸附到音拍边界后，文字与音拍都能干净地一分为二。
        ///
        /// 采用「总是吸附」而不是「超出容差就拒绝」：慢歌里一个音拍可能长到 1 秒，
        /// 用容差会让用户觉得「这里为什么不能切」。吸附后位置仍可预期，
        /// 真正的非法情况（切完某段过短）才拒绝。
        public var snapToMoraBoundary: Bool = true
        public init() {}
        public static let `default` = Config()
    }

    /// 能否在 t 处分割（用于 UI 置灰按钮）。
    public static func canSplit(_ line: LyricLine, at t: Double, config: Config = .default) -> Bool {
        split(line, at: t, config: config) != nil
    }

    public static func split(_ line: LyricLine, at t: Double, config: Config = .default) -> (left: LyricLine, right: LyricLine)? {
        let lo = line.singStart
        let hi = line.singEnd
        guard hi > lo else { return nil }
        guard t > lo + config.minimumDuration, t < hi - config.minimumDuration else { return nil }
        guard !line.tokens.isEmpty else { return nil }

        // 切割点吸附到最近的音拍边界（见 Config.boundaryTolerance 的说明）
        let moraeTimeline = line.tokens.flatMap(\.morae).sorted { $0.start < $1.start }
        guard !moraeTimeline.isEmpty else { return nil }
        var boundaries: [Double] = [moraeTimeline[0].start]
        boundaries.append(contentsOf: moraeTimeline.map(\.end))
        let snapped = boundaries.min(by: { abs($0 - t) < abs($1 - t) }) ?? t
        let cut = config.snapToMoraBoundary ? snapped : t
        guard cut > lo + config.minimumDuration, cut < hi - config.minimumDuration else { return nil }

        var leftTokens: [LyricToken] = []
        var rightTokens: [LyricToken] = []

        for token in line.tokens {
            let morae = token.morae
            if morae.isEmpty {
                // 没有音拍证据：按 token 的 sourceStart/sourceLength 无法定位时间，
                // 保守做法是整段归到离它更近的一侧（用显示文字顺序均分时间做判断）。
                if leftTokens.isEmpty { leftTokens.append(token) } else { rightTokens.append(token) }
                continue
            }
            // 吸附后切割点一定落在音拍边界上：结束 <= cut 归左，起始 >= cut 归右
            let leftMorae = morae.filter { $0.end <= cut + 1e-9 }
            let rightMorae = morae.filter { $0.start >= cut - 1e-9 }
            if rightMorae.isEmpty {
                leftTokens.append(token)
            } else if leftMorae.isEmpty {
                rightTokens.append(token)
            } else {
                leftTokens.append(splitToken(token, keeping: leftMorae))
                rightTokens.append(splitToken(token, keeping: rightMorae))
            }
        }

        leftTokens = leftTokens.filter { !$0.surface.isEmpty }
        rightTokens = rightTokens.filter { !$0.surface.isEmpty }
        let leftText = leftTokens.map(\.surface).joined()
        let rightText = rightTokens.map(\.surface).joined()
        // 不丢字、不重复
        guard !leftText.isEmpty, !rightText.isEmpty,
              leftText + rightText == line.displayText else { return nil }

        var left = line
        left.tokens = leftTokens
        left.displayText = leftText
        left.singEnd = cut
        left.displayEnd = max(cut, min(line.displayEnd, cut + Self.displayTail(of: line, at: cut)))
        left.enforceInvariants()

        var right = line
        right.id = UUID()
        right.tokens = rightTokens.map { renumber($0, from: leftTokens.count) }
        right.displayText = rightText
        right.singStart = cut
        right.displayStart = min(cut, max(line.displayStart, cut - Self.displayHead(of: line, at: cut)))
        right.enforceInvariants()

        return (left, right)
    }

    /// 保留 token 的一部分音拍；surface 按「音拍数 → 字数」比例切出来。
    private static func splitToken(_ token: LyricToken, keeping morae: [MoraTiming]) -> LyricToken {
        var copy = token
        copy.morae = morae
        let chars = Array(token.surface)
        guard !chars.isEmpty, !morae.isEmpty, !token.morae.isEmpty else {
            if morae.isEmpty { copy.surface = "" }
            return copy
        }
        // 用「保留的音拍在原音拍序列中的位置」映射回字符
        var keptIndices: [Int] = []
        // 只做精确匹配：用「名称相同」这种模糊回退会让被切开的音拍在两侧都命中，
        // 同一个字就会在两段里各出现一次。
        for (i, m) in token.morae.enumerated() {
            if morae.contains(where: { abs($0.start - m.start) < 1e-6 && abs($0.end - m.end) < 1e-6 }) {
                keptIndices.append(i)
            }
        }
        guard let first = keptIndices.first, let last = keptIndices.last else {
            copy.surface = ""
            return copy
        }
        let n = token.morae.count
        let m = chars.count
        let lo = first * m / n
        let hi = min(m, (last + 1) * m / n)
        copy.surface = String(chars[lo..<max(lo, hi)])
        return copy
    }

    private static func renumber(_ token: LyricToken, from offset: Int) -> LyricToken {
        var copy = token
        copy.sourceStart = token.sourceStart + 0
        return copy
    }

    /// 左段保留多长的显示尾巴（保持「唱完停留」的观感）
    private static func displayTail(of line: LyricLine, at t: Double) -> Double {
        let total = max(0.01, line.displayEnd - line.singEnd)
        let singTotal = max(0.01, line.singEnd - line.singStart)
        let fraction = (t - line.singStart) / singTotal
        return total * (1 - fraction)
    }

    private static func displayHead(of line: LyricLine, at t: Double) -> Double {
        let total = max(0.01, line.singStart - line.displayStart)
        let singTotal = max(0.01, line.singEnd - line.singStart)
        let fraction = (line.singEnd - t) / singTotal
        return total * (1 - fraction)
    }
}
