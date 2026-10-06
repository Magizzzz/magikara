import Foundation
import CoreText
import AppKit

/// 一个音拍在整行里的横向范围（相对行中心，单位点），用于扫色。
public struct MoraBox: Sendable {
    public var tokenID: UUID
    public var indexInToken: Int
    public var text: String
    public var start: Double
    public var end: Double
    public var minX: Double
    public var maxX: Double
}

/// 一个假名（Ruby）的排版结果。
///
/// 现在**一段连续汉字**对应一个 Ruby（例如「勝ち筋」→「か」压在「勝」、「すじ」压在「筋」），
/// 而不是整词一个 Ruby，所以同一个 tokenID 可能出现多条。
public struct RubyPlacement: Sendable {
    public var tokenID: UUID
    public var text: String
    /// Ruby 相对行中心的中心位置
    public var centerX: Double
    /// Ruby 实际绘制宽度
    public var width: Double
    /// 该段汉字实际占据的宽度（用于对比）
    public var tokenWidth: Double
    /// 由 Core Text 计算出的字号（宽于汉字时会略缩）
    public var fontSize: Double
    /// 字间距（RD §6.2：读音宽于汉字时先加字距）
    public var letterSpacing: Double
    /// 该段汉字在 token 内的字符偏移（用于测试与调试）
    public var surfaceStart: Int
    /// 该段汉字对应读音在完整 reading 中的字符偏移
    public var readingStart: Int
    /// 该段假名的扫色时间窗（来自音拍证据，可为空）。
    /// 仅供音拍调试与兼容旧测试；预览与 ASS 的假名扫色不再使用它，
    /// 否则假名会按音拍节奏走、主词按字宽匀速走，两条轨道对不齐。
    public var start: Double?
    public var end: Double?
    /// 这段汉字在整行宽度中占据的比例区间（0...1）。
    ///
    /// 主词扫色边缘在整行上按字宽匀速推进，边缘走过 `sweepStart → sweepEnd` 的这段时间，
    /// 正是该段汉字被扫过的时间。假名用同一区间做自己的扫色，与主词天然同步。
    public var sweepStart: Double = 0
    public var sweepEnd: Double = 0
}

/// 整行的排版结果。
public struct LineLayout: Sendable {
    public var lineWidth: Double
    public var fontSize: Double
    public var rubyFontSize: Double
    /// 每个音拍的横向范围，按时间顺序
    public var moraBoxes: [MoraBox]
    public var rubies: [RubyPlacement]
    /// tokenID → 该 token 相对行中心的中心位置与宽度
    public var tokenGeometry: [UUID: (centerX: Double, width: Double)]
    /// tokenID → 该 token 在整行里的横向起止比例（0...1）。
    /// 匀速扫色把「整句时间进度」线性映射到这个比例上。
    public var tokenSweepFractions: [UUID: (start: Double, end: Double)]
    /// 这句的演唱时间窗（扫色只在其中推进）
    public var singStart: Double
    public var singEnd: Double
    /// 是否存在自动对齐不可靠、需要人工确认的 Ruby。
    public var rubyNeedsConfirmation: Bool

    public init(lineWidth: Double,
                fontSize: Double,
                rubyFontSize: Double,
                moraBoxes: [MoraBox] = [],
                rubies: [RubyPlacement] = [],
                tokenGeometry: [UUID: (centerX: Double, width: Double)] = [:],
                tokenSweepFractions: [UUID: (start: Double, end: Double)] = [:],
                singStart: Double = 0,
                singEnd: Double = 0,
                rubyNeedsConfirmation: Bool = false) {
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.rubyFontSize = rubyFontSize
        self.moraBoxes = moraBoxes
        self.rubies = rubies
        self.tokenGeometry = tokenGeometry
        self.tokenSweepFractions = tokenSweepFractions
        self.singStart = singStart
        self.singEnd = singEnd
        self.rubyNeedsConfirmation = rubyNeedsConfirmation
    }

    public static let empty = LineLayout(lineWidth: 0, fontSize: 0, rubyFontSize: 0)

    /// 整句匀速扫色进度：0 = 还没开始，1 = 已唱完。
    ///
    /// 这里刻意**不看音拍长短** —— 音拍只决定 token 的先后顺序，
    /// 实际扫色边缘在整行上匀速从左走到右（本轮验收要求）。
    public func sweepFraction(at t: Double) -> Double {
        guard singEnd > singStart else { return t >= singEnd ? 1 : 0 }
        if t <= singStart { return 0 }
        if t >= singEnd { return 1 }
        return (t - singStart) / (singEnd - singStart)
    }

    /// 在时间 t 时扫色边缘相对行中心的 x 位置（匀速整句）。
    public func sweepX(at t: Double, line: LyricLine) -> Double {
        let half = lineWidth / 2
        let p = sweepFraction(at: t)
        return -half + lineWidth * p
    }

    /// 某个 token 是否正在被扫色边缘覆盖（用于同步高亮 Ruby）。
    public func isTokenActive(tokenID: UUID, at t: Double) -> Bool {
        if let range = tokenSweepFractions[tokenID] {
            let p = sweepFraction(at: t)
            return p >= range.start && p < range.end
        }
        // 没有横向比例（例如空 surface）时退化到音拍时间
        let boxes = moraBoxes.filter { $0.tokenID == tokenID }
        guard let first = boxes.first, let last = boxes.last else { return false }
        return t >= first.start && t < last.end
    }

    /// 某一段 Ruby 随整句匀速扫色的进度（0...1），按布局缓存里的演唱时间计算。
    ///
    /// 注意：布局可能被缓存，其中的 `singStart/singEnd` 会在歌词时间被修改后过期。
    /// 需要和主词严格同步的地方（预览）应改用 `rubySweepProgress(_:sweepFraction:)`，
    /// 传入由实时歌词行算出的同一个整句进度。
    public func rubySweepProgress(_ ruby: RubyPlacement, at t: Double) -> Double {
        rubySweepProgress(ruby, sweepFraction: sweepFraction(at: t))
    }

    /// 某一段 Ruby 的扫色进度：整句扫色边缘 `p`（0...1）走过这段汉字所占的比例区间时，
    /// 假名同步从 0 扫到 1。与主词共用同一个 `p`，因此永远同步。
    public func rubySweepProgress(_ ruby: RubyPlacement, sweepFraction p: Double) -> Double {
        let span = ruby.sweepEnd - ruby.sweepStart
        guard span > 1e-9 else { return p >= ruby.sweepEnd ? 1 : 0 }
        return max(0, min(1, (p - ruby.sweepStart) / span))
    }
}

/// 扫色进度计算 —— 预览与测试共用同一份实现。
///
/// 验收要求「整句 singStart→singEnd 匀速从左到右，每个 token 依次扫过，
/// 不能整句瞬间变色」。因为要按 token 的**渲染宽度**分配时间，
/// 所以必须结合 `LineLayout` 才能算，不能只藏在 View 里。
public enum SweepProgress {

    /// 某个 token 在时间 t 的扫色进度（0...1）。
    ///
    /// - 正在演唱的句子：边缘在整句上匀速推进，token 进度 = 边缘进入它多少；
    /// - 已唱完的句子：整句保持全亮；
    /// - 还没唱的句子：保持全暗。
    public static func forToken(_ token: LyricToken,
                                in line: LyricLine,
                                layout: LineLayout,
                                at t: Double) -> Double {
        if t <= line.singStart { return 0 }
        if t >= line.singEnd { return 1 }
        let p = layout.sweepFraction(at: t)
        guard let range = layout.tokenSweepFractions[token.id] else {
            // 没有横向信息（空 surface 等）：按整句进度退化
            return p
        }
        let span = range.end - range.start
        guard span > 1e-9 else { return p >= range.end ? 1 : 0 }
        return max(0, min(1, (p - range.start) / span))
    }

    /// 整行所有 token 的进度（按 token 顺序）。
    public static func forLine(_ line: LyricLine, layout: LineLayout, at t: Double) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for token in line.tokens {
            out[token.id] = forToken(token, in: line, layout: layout, at: t)
        }
        return out
    }
}

/// 使用 Core Text 计算主字幕与 Ruby 的排版。
/// 预览与 ASS 导出共用这一套结果，避免两边各算一次导致不一致。
public enum KaraokeLayout {

    /// 主字体
    public static func mainFont(style: SubtitleStyle) -> CTFont {
        font(name: style.fontName, size: style.fontSize, weight: style.fontWeight)
    }

    public static func rubyFont(style: SubtitleStyle, size: Double) -> CTFont {
        font(name: style.rubyFontName, size: size, weight: style.fontWeight)
    }

    /// ASS 里要写的字体：具体字重的 PostScript 名 + 字号换算系数。
    ///
    /// 两处差异都会让导出与预览对不上：
    /// 1. libass 把 Fontsize 当成字体 OS/2 的 winAscent + winDescent 总高，而 Core Text / SwiftUI
    ///    当成 em。Hiragino Sans W8 的总高是 1.449 em，同样写 76，导出的字只有预览的约 70%。
    /// 2. 只写家族名 + Bold 标记时，libass 会自己挑字重，不一定是预览用的那个（W3/W6/W8）。
    /// 所以写死 PostScript 名、去掉 Bold，字号乘上这个字体自己的总高比例。
    public struct AssFace: Equatable, Sendable {
        public let name: String
        public let sizeScale: Double
    }

    public static func assFace(for font: CTFont) -> AssFace {
        let name = CTFontCopyPostScriptName(font) as String
        func u16(_ d: Data, _ o: Int) -> Int { d.count > o + 1 ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           let head = CTFontCopyTable(font, CTFontTableTag(kCTFontTableHead), []) as Data? {
            let upm = u16(head, 18)
            let total = u16(os2, 74) + u16(os2, 76)
            if upm > 0, total > 0 { return AssFace(name: name, sizeScale: Double(total) / Double(upm)) }
        }
        // 没有 OS/2 表时 libass 退回 hhea 的上伸 + 下伸
        let size = max(1, CTFontGetSize(font))
        let hhea = (CTFontGetAscent(font) + CTFontGetDescent(font)) / size
        return AssFace(name: name, sizeScale: hhea > 0.1 ? Double(hhea) : 1)
    }

    /// 字体缓存。
    ///
    /// 两个作用：
    /// 1. Core Text 造字体很贵，预览每帧都可能要取同一批字体，缓存后省掉重复创建；
    /// 2. **串行化 Core Text 的字体创建** —— 并发地从多个线程首次创建同一批字体
    ///    会死锁（实测 ExportTests 与 AcceptanceTests 两个 Core Text 密集的 suite
    ///    一起并发跑时整套测试挂死，单独跑都正常）。
    private static let fontLock = NSLock()
    private static var fontCache: [String: CTFont] = [:]

    public static func font(name: String, size: Double, weight: Int) -> CTFont {
        let key = "\(name)|\(size)|\(weight)"
        fontLock.lock()
        defer { fontLock.unlock() }
        if let cached = fontCache[key] { return cached }
        let created = makeFont(name: name, size: size, weight: weight)
        fontCache[key] = created
        return created
    }

    /// 只在持有 fontLock 时调用。
    ///
    /// 在字体家族里挑「粗细值」最接近目标的那个字重。原来的做法（给描述符加 weight trait）
    /// 对 Hiragino Sans 不生效，800 也拿到 W3 细体：排版宽度、ASS 导出都按 W3 算，
    /// 预览却由 SwiftUI 显示成 W7，三处对不上。
    private static func makeFont(name: String, size: Double, weight: Int) -> CTFont {
        let base = CTFontCreateWithName(name as CFString, size, nil)
        // 用户直接指定了某个具体字重（PostScript 名）时尊重它
        if (CTFontCopyPostScriptName(base) as String) == name { return base }

        let family = CTFontCopyFamilyName(base) as String
        let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let members = (CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor]) ?? []
        let target = cssWeightTrait(weight)
        var best: (font: CTFont, distance: Double)?
        for descriptor in members {
            let candidate = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            let symbolic = CTFontGetSymbolicTraits(candidate)
            if symbolic.contains(.traitItalic) || symbolic.contains(.traitCondensed) { continue }
            let traits = CTFontCopyTraits(candidate) as NSDictionary
            let w = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let distance = abs(w - target)
            if best == nil || distance < best!.distance - 1e-6 {
                best = (candidate, distance)
            }
        }
        return best?.font ?? base
    }

    /// CSS 字重 → Core Text 粗细值（与 SwiftUI Font.Weight 一致：heavy = 0.56，black = 0.62）。
    static func cssWeightTrait(_ weight: Int) -> Double {
        let table: [(Int, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23),
                                      (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        if weight <= 100 { return -0.8 }
        if weight >= 900 { return 0.62 }
        for i in 1..<table.count where weight <= table[i].0 {
            let (w0, t0) = table[i - 1], (w1, t1) = table[i]
            return t0 + (t1 - t0) * Double(weight - w0) / Double(w1 - w0)
        }
        return 0
    }

    public static func width(of text: String, font: CTFont) -> Double {
        guard !text.isEmpty else { return 0 }
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else {
            return 0
        }
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// 计算整行排版（token 位置、Ruby 位置、匀速扫色比例）。
    public static func layout(line: LyricLine, style: SubtitleStyle) -> LineLayout {
        let text = line.displayText
        guard !text.isEmpty, !line.tokens.isEmpty else { return .empty }

        let mFont = mainFont(style: style)
        let lineWidth = width(of: text, font: mFont)
        let rubySize = style.fontSize * style.rubySizeFactor

        // 每个 token 的绝对 x 区间：用前缀宽度算，天然包含空格与标点
        let ns = text as NSString
        var geometry: [UUID: (centerX: Double, width: Double)] = [:]
        var tokenRanges: [(token: LyricToken, minX: Double, maxX: Double)] = []

        for token in line.tokens {
            let start = max(0, min(ns.length, token.sourceStart))
            let len = max(0, min(ns.length - start, token.sourceLength))
            let prefix = ns.substring(with: NSRange(location: 0, length: start))
            let body = len > 0 ? ns.substring(with: NSRange(location: start, length: len)) : token.surface
            let x0 = width(of: prefix, font: mFont)
            let w = width(of: body, font: mFont)
            let minX = x0 - lineWidth / 2
            let maxX = minX + w
            tokenRanges.append((token, minX, maxX))
            geometry[token.id] = (centerX: (minX + maxX) / 2, width: w)
        }

        // 匀速扫色：把整行宽度按 token 实际占宽切成比例区间。
        // 只要边缘在 [0,1] 上匀速走，token 就会依次被扫过，且不受音拍长短影响。
        var tokenSweepFractions: [UUID: (start: Double, end: Double)] = [:]
        if lineWidth > 1e-9 {
            for (token, minX, maxX) in tokenRanges {
                let a = (minX + lineWidth / 2) / lineWidth
                let b = (maxX + lineWidth / 2) / lineWidth
                tokenSweepFractions[token.id] = (start: max(0, min(1, a)),
                                                 end: max(0, min(1, max(b, a + 1e-6))))
            }
        }

        // 音拍横向范围：把 token 宽度按各音拍读音宽度加权切分。
        // 这份数据仍保留，供逐音拍调试与兼容旧测试使用。
        var moraBoxes: [MoraBox] = []
        for (token, minX, maxX) in tokenRanges {
            let morae = token.morae
            guard !morae.isEmpty else { continue }
            let tokenWidth = maxX - minX
            let weights = morae.map { max(0.05, width(of: $0.mora, font: mFont)) }
            let total = weights.reduce(0, +)
            var cursor = minX
            for (i, m) in morae.enumerated() {
                let w = total > 0 ? tokenWidth * weights[i] / total : tokenWidth / Double(morae.count)
                moraBoxes.append(MoraBox(tokenID: token.id,
                                         indexInToken: i,
                                         text: m.mora,
                                         start: m.start,
                                         end: m.end,
                                         minX: cursor,
                                         maxX: cursor + w))
                cursor += w
            }
        }
        // 没有音拍的 token（例如对齐缺失的助词/标点）也必须被扫色覆盖，
        // 否则整行的扫色会在最后一个音拍处提前停住。把相邻音拍的范围向外延伸过去。
        for (token, minX, maxX) in tokenRanges where token.morae.isEmpty && token.surface.count > 0 {
            if let idx = moraBoxes.lastIndex(where: { $0.maxX <= minX + 1e-6 }) {
                moraBoxes[idx].maxX = max(moraBoxes[idx].maxX, maxX)
            } else if let idx = moraBoxes.firstIndex(where: { $0.minX >= maxX - 1e-6 }) {
                moraBoxes[idx].minX = min(moraBoxes[idx].minX, minX)
            }
        }
        moraBoxes.sort { $0.start < $1.start }

        // Ruby 排版：**只给连续汉字段注音**，假名不重复注音。
        // 每段汉字相对它自己的宽度做居中 / 加字距 / 轻微缩字号，互不影响主句排版。
        var rubies: [RubyPlacement] = []
        var rubyNeedsConfirmation = false
        for (token, minX, _) in tokenRanges {
            // 统一走 RubyBindingResolver：人工覆盖优先；自动对齐不可靠时返回空绑定，
            // 绝不把整词读音压到「漢字 + 送假名」上（例如 勝ち筋 → かちすじ）。
            let resolved = RubyBindingResolver.resolve(for: token)
            if resolved.needsConfirmation { rubyNeedsConfirmation = true }
            guard !resolved.bindings.isEmpty else { continue }

            let surfaceChars = Array(token.surface)
            for binding in resolved.bindings {
                guard !binding.reading.isEmpty else { continue }
                let surfaceStart = max(0, min(surfaceChars.count, binding.surfaceStart))
                let surfaceEnd = max(surfaceStart, min(surfaceChars.count, surfaceStart + binding.surfaceLength))
                let prefix = String(surfaceChars[0..<surfaceStart])
                let runSurface = String(surfaceChars[surfaceStart..<surfaceEnd])
                let runMinX = minX + width(of: prefix, font: mFont)
                let runMaxX = runMinX + width(of: runSurface, font: mFont)
                let runWidth = max(0.01, runMaxX - runMinX)
                let runCenter = (runMinX + runMaxX) / 2

                let (size, spacing) = rubyMetrics(reading: binding.reading,
                                                  runWidth: runWidth,
                                                  rubySize: rubySize,
                                                  style: style)
                let totalRubyWidth = width(of: binding.reading,
                                           font: rubyFont(style: style, size: size))
                    + spacing * Double(max(0, binding.reading.count - 1))
                let window = binding.readingStart >= 0
                    ? rubyTimeWindow(readingStart: binding.readingStart,
                                     readingLength: binding.reading.count,
                                     morae: token.morae)
                    : nil
                var placement = RubyPlacement(tokenID: token.id,
                                              text: binding.reading,
                                              centerX: runCenter,
                                              width: totalRubyWidth,
                                              tokenWidth: runWidth,
                                              fontSize: size,
                                              letterSpacing: spacing,
                                              surfaceStart: surfaceStart,
                                              readingStart: binding.readingStart,
                                              start: window?.0,
                                              end: window?.1)
                if lineWidth > 1e-9 {
                    let a = (runMinX + lineWidth / 2) / lineWidth
                    let b = (runMaxX + lineWidth / 2) / lineWidth
                    placement.sweepStart = max(0, min(1, a))
                    placement.sweepEnd = max(placement.sweepStart, min(1, b))
                }
                rubies.append(placement)
            }
        }

        return LineLayout(lineWidth: lineWidth,
                          fontSize: style.fontSize,
                          rubyFontSize: rubySize,
                          moraBoxes: moraBoxes,
                          rubies: rubies,
                          tokenGeometry: geometry,
                          tokenSweepFractions: tokenSweepFractions,
                          singStart: line.singStart,
                          singEnd: line.singEnd,
                          rubyNeedsConfirmation: rubyNeedsConfirmation)
    }

    /// 读音宽于汉字时的排版策略：先加字距，仍不够再轻微缩字号。
    static func rubyMetrics(reading: String,
                            runWidth: Double,
                            rubySize: Double,
                            style: SubtitleStyle) -> (size: Double, spacing: Double) {
        func measure(_ size: Double) -> Double {
            width(of: reading, font: rubyFont(style: style, size: size))
        }
        var size = rubySize
        var rw = measure(size)
        var spacing = 0.0
        let count = max(1, reading.count)

        if rw > runWidth * 1.02, count > 1 {
            let needed = (rw - runWidth) / Double(count - 1)
            let maxSpacing = style.fontSize * 0.12
            if needed <= maxSpacing {
                spacing = needed
            } else {
                spacing = maxSpacing
                var tries = 0
                while tries < 8, rw + spacing * Double(count - 1) > runWidth * 1.15,
                      size > style.fontSize * 0.20 {
                    size *= 0.94
                    rw = measure(size)
                    tries += 1
                }
            }
        }
        return (size, spacing)
    }

    /// 把一段读音在完整 reading 里的字符偏移映射成音拍时间窗。
    static func rubyTimeWindow(readingStart: Int,
                               readingLength: Int,
                               morae: [MoraTiming]) -> (Double, Double)? {
        guard !morae.isEmpty, readingLength > 0 else { return nil }
        var cursor = 0
        var lo: Int?
        var hi: Int?
        for (idx, m) in morae.enumerated() {
            let chars = max(1, m.mora.count)
            let next = cursor + chars
            if lo == nil, readingStart < next { lo = idx }
            if readingStart + readingLength > cursor { hi = idx }
            cursor = next
        }
        guard let a = lo, let b = hi, a <= b, a < morae.count else { return nil }
        return (morae[a].start, morae[min(b, morae.count - 1)].end)
    }
}
