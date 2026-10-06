import Testing
import Foundation
@testable import MaGiKaraKit

/// 效果验收（来自产品方给出的目标成片标准）。
///
/// 这一组测试的目的不是「跑通」，而是把验收条款变成可断言的事实：
/// 1. 字幕固定在底部安全区
/// 2. 上下两行并存，唱完停留到同槽位下下句替换
/// 3. 未唱白 / 已唱蓝紫，整句匀速连续扫色，不整句瞬间变色
/// 4. 黑色粗描边 + 深色阴影
/// 5. 假名只加在含汉字的 token 上，按词宽绑定，不整句平均铺开
@Suite struct AcceptanceTests {

    // MARK: 验收 1：底部安全区

    @Test func defaultStyleSitsInBottomSafeArea() {
        let s = SubtitleStyle.default
        let canvas = KaraokeCanvas.height
        let halfLine = (s.fontSize + s.lineGap) / 2
        let blockCenter = canvas / 2 + s.positionY
        let blockBottom = blockCenter + halfLine + s.fontSize * 0.6
        let blockTop = blockCenter - halfLine - s.fontSize * 0.6

        // 底部安全区：整块应落在画面下方约 10% 之内，且不越界
        #expect(blockBottom <= canvas * 0.95, "字幕块底边 \(Int(blockBottom)) 太低，超出安全区")
        #expect(blockBottom >= canvas * 0.85, "字幕块底边 \(Int(blockBottom)) 偏高，不在底部安全区")
        #expect(blockTop > canvas * 0.6, "字幕块不应侵入画面中部")
        #expect(blockBottom < canvas, "字幕块不能超出画面")
    }

    @Test func bottomSafeAreaHelperTracksFontSize() {
        // 字号越大，为了让底边保持在安全区，块中心必须越往上
        let small = SubtitleStyle.bottomSafeAreaPositionY(fontSize: 48, lineGap: 10)
        let large = SubtitleStyle.bottomSafeAreaPositionY(fontSize: 96, lineGap: 10)
        #expect(large < small, "字号变大时 positionY 应变小（更靠上）")

        // 所有内置预设都必须落在底部安全区
        for preset in SubtitleStyle.Preset.allCases {
            let s = preset.style
            let halfLine = (s.fontSize + s.lineGap) / 2
            let bottom = KaraokeCanvas.height / 2 + s.positionY + halfLine + s.fontSize * 0.6
            #expect(bottom <= KaraokeCanvas.height * 0.96,
                    "预设「\(preset.displayName)」底边 \(Int(bottom)) 越界")
            #expect(bottom >= KaraokeCanvas.height * 0.82,
                    "预设「\(preset.displayName)」底边 \(Int(bottom)) 不在底部区域")
        }
    }

    @Test func assExportPlacesLinesInBottomSafeArea() {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 20, title: "t")
        project.lyricLines = [
            LyricLine(order: 1, lane: .upper, displayText: "上行テスト",
                      displayStart: 1, singStart: 2, singEnd: 3, displayEnd: 4),
            LyricLine(order: 2, lane: .lower, displayText: "下行テスト",
                      displayStart: 1, singStart: 3, singEnd: 4, displayEnd: 5),
        ]
        let ass = AssExporter.export(project: project)

        // 从 ASS 里取出主字幕的 \pos(x,y)，确认 y 落在底部安全区
        var ys: [Double] = []
        for line in ass.split(separator: "\n") where line.hasPrefix("Dialogue: 0,") {
            guard let r = line.range(of: "\\pos(") else { continue }
            let rest = line[r.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { continue }
            let parts = rest[..<close].split(separator: ",")
            if parts.count == 2, let y = Double(parts[1]) { ys.append(y) }
        }
        #expect(!ys.isEmpty, "ASS 里没有找到定位")
        for y in ys {
            #expect(y > KaraokeCanvas.height * 0.75, "ASS 字幕 y=\(Int(y)) 不在底部区域")
            #expect(y < KaraokeCanvas.height, "ASS 字幕 y=\(Int(y)) 超出画面")
        }
        // 上行必须在画面的上半部分（y 更小），下行在下半部分
        let unique = Set(ys).sorted()
        #expect(unique.count == 2, "应有两行不同位置，实际 \(unique)")
        if unique.count == 2 {
            #expect(unique[0] < unique[1], "上行 y 必须小于下行 y")
            #expect(unique[1] - unique[0] > project.style.fontSize * 0.8,
                    "两行间距过小，可能重叠")
        }
    }

    // MARK: 验收 2：两行并存 + 唱完短暂停留 + 长空白留白

    @Test func lanesDoNotOccupyLongSilentGaps() {
        // 8 句之间的实际无歌词间隔超过 10 秒，走真实的显示区调度
        var lines: [LyricLine] = []
        for i in 1...8 {
            let t = 2.0 + Double(i) * 12.0
            lines.append(LyricLine(order: i, lane: ScreenLane.lane(forOrder: i),
                                   displayText: "行\(i)", singStart: t, singEnd: t + 1.6))
        }
        DisplayScheduler.applyDisplayWindows(to: &lines)
        var project = KaraProject()
        project.lyricLines = lines

        for line in lines {
            #expect(line.displayEnd <= line.singEnd + 1.2 + 1e-6,
                    "第 \(line.order) 句不应跨过长空白区")
        }

        // 第一、三句同属上行；第一句唱完后到第三句进入前，上行应自然留白，
        // 而不是把第一句拉成长条填满这段时间。
        let silentTime = lines[0].displayEnd + 0.2
        #expect(project.activeLine(in: .upper, at: silentTime) == nil)
    }

    @Test func finishedLineHoldsUntilReplacedBySameLane() {
        var lines: [LyricLine] = []
        for i in 1...6 {
            let t = Double(i) * 3.0
            lines.append(LyricLine(order: i, lane: ScreenLane.lane(forOrder: i),
                                   displayText: "行\(i)", singStart: t, singEnd: t + 1.0))
        }
        DisplayScheduler.applyDisplayWindows(to: &lines)
        var project = KaraProject()
        project.lyricLines = lines

        let upper = lines.filter { $0.lane == .upper }.sorted { $0.order < $1.order }
        let first = upper[0]
        // 第 1 句唱完（singEnd）之后、被第 3 句替换之前，必须仍然可见
        let afterSing = first.singEnd + 0.2
        #expect(afterSing < upper[1].displayStart, "测试前提：第 3 句此时还没进入")
        #expect(project.activeLine(in: .upper, at: afterSing)?.order == 1,
                "唱完的句子不能立刻消失")
        // 到第 3 句进入后，才被替换
        #expect(project.activeLine(in: .upper, at: upper[1].displayStart + 0.05)?.order == 3)
    }

    // MARK: 验收 3：整句匀速扫色，不整句瞬间变色

    private func sweptLine() -> LyricLine {
        var line = LyricLine(order: 1, lane: .upper, displayText: "素晴らしき世界",
                             displayStart: 0, singStart: 1, singEnd: 3, displayEnd: 4)
        line.tokens = [
            LyricToken(surface: "素晴らしき", reading: "すばらしき", morae: [
                MoraTiming(mora: "す", start: 1.0, end: 1.2),
                MoraTiming(mora: "ば", start: 1.2, end: 1.4),
                MoraTiming(mora: "ら", start: 1.4, end: 1.6),
                MoraTiming(mora: "し", start: 1.6, end: 1.8),
                MoraTiming(mora: "き", start: 1.8, end: 2.0),
            ], sourceStart: 0, sourceLength: 5),
            LyricToken(surface: "世界", reading: "せかい", morae: [
                MoraTiming(mora: "せ", start: 2.0, end: 2.4),
                MoraTiming(mora: "か", start: 2.4, end: 2.7),
                MoraTiming(mora: "い", start: 2.7, end: 3.0),
            ], sourceStart: 5, sourceLength: 2),
        ]
        return line
    }

    private func sweptLayout(_ line: LyricLine) -> LineLayout {
        KaraokeLayout.layout(line: line, style: .default)
    }

    @Test func sweepAdvancesContinuouslyWithinAToken() throws {
        let line = sweptLine()
        let layout = sweptLayout(line)
        let world = line.tokens[1]
        let range = try #require(layout.tokenSweepFractions[world.id])
        let start = line.singStart + range.start * line.singDuration
        let end = line.singStart + range.end * line.singDuration

        // 在这个 token 的匀速窗口内部采样，进度必须严格递增且存在中间态
        var previous = -1.0
        var t = start + 0.02
        var intermediate = 0
        while t < end - 0.02 {
            let p = SweepProgress.forToken(world, in: line, layout: layout, at: t)
            #expect(p > previous, "t=\(t) 进度没有前进")
            if p > 0.01 && p < 0.99 { intermediate += 1 }
            previous = p
            t += 0.02
        }
        #expect(intermediate >= 5, "扫色中间态太少，说明接近瞬间变色")
    }

    @Test func sweepIsNotWholeLineInstantChange() throws {
        let line = sweptLine()
        let layout = sweptLayout(line)
        let first = line.tokens[0]
        let second = line.tokens[1]
        let range = try #require(layout.tokenSweepFractions[second.id])

        // 取「后一个词的匀速窗口中点」：此时前一个词应已唱完，后一个词处于中间态
        let mid = line.singStart + ((range.start + range.end) / 2) * line.singDuration
        let p1 = SweepProgress.forToken(first, in: line, layout: layout, at: mid)
        let p2 = SweepProgress.forToken(second, in: line, layout: layout, at: mid)
        #expect(p1 == 1.0, "前一个词此时应已唱完")
        #expect(p2 > 0 && p2 < 1, "后一个词此时必须处于扫色中间态，而不是 0 或 1")

        // 整句绝不能在 singStart 或句中就全亮
        for probe in [1.0, 1.5, 2.0, 2.5] {
            let all = SweepProgress.forLine(line, layout: layout, at: probe).values
            #expect(all.contains { $0 < 1 }, "t=\(probe) 时整句已经全亮 —— 那就是瞬间变色")
        }
        // 唱完之后才允许整句全亮
        let done = SweepProgress.forLine(line, layout: layout, at: line.singEnd).values
        #expect(done.allSatisfy { $0 == 1 })
    }

    @Test func unsungStaysDarkBeforeSingingAndAllLitAfter() {
        let line = sweptLine()
        let layout = sweptLayout(line)
        for token in line.tokens {
            #expect(SweepProgress.forToken(token, in: line, layout: layout, at: 0.5) == 0, "未唱必须是 0")
            #expect(SweepProgress.forToken(token, in: line, layout: layout, at: 3.5) == 1, "唱完必须全亮")
        }
    }

    @Test func sweepProgressIsMonotonicPerToken() {
        let line = sweptLine()
        let layout = sweptLayout(line)
        for token in line.tokens {
            var previous = -1.0
            var t = line.singStart
            while t <= line.singEnd + 0.5 {
                let p = SweepProgress.forToken(token, in: line, layout: layout, at: t)
                #expect(p >= previous - 1e-9, "进度回退")
                previous = p
                t += 0.02
            }
        }
    }

    // MARK: 验收 3（新增）：扫色边缘整句匀速，不受音拍长短影响

    @Test func sweepEdgeIsUniformAcrossLineIgnoringMoraLengths() {
        // 两个宽度接近的 token，但音拍时长一个很长一个很短。
        // 新规则下边缘只按整句时间匀速推进，中点必须正好落在行中心。
        var line = LyricLine(order: 1, lane: .upper, displayText: "ああ",
                             displayStart: 0, singStart: 1, singEnd: 3, displayEnd: 4)
        line.tokens = [
            LyricToken(surface: "あ", reading: nil, morae: [
                MoraTiming(mora: "あ", start: 1.0, end: 2.8),
            ], sourceStart: 0, sourceLength: 1),
            LyricToken(surface: "あ", reading: nil, morae: [
                MoraTiming(mora: "あ", start: 2.8, end: 3.0),
            ], sourceStart: 1, sourceLength: 1),
        ]
        let layout = KaraokeLayout.layout(line: line, style: .default)
        let mid = layout.sweepX(at: (line.singStart + line.singEnd) / 2, line: line)
        #expect(abs(mid) < max(1.0, layout.lineWidth * 0.02),
                "匀速扫色在中点应位于行中心，实际 \(mid)")
        #expect(abs(layout.sweepX(at: line.singStart, line: line) - (-layout.lineWidth / 2)) < 0.5,
                "入点必须精确落在行首")
        #expect(abs(layout.sweepX(at: line.singEnd, line: line) - layout.lineWidth / 2) < 0.5,
                "出点必须精确落在行尾")
    }

    // MARK: 验收 3/4：颜色与描边

    @Test func unsungIsWhiteAndSungIsBluePurple() throws {
        // 验收规则只约束原有的三套默认模版（白字 + 蓝紫扫色）。
        // ニコカラ 系列等新增模版故意使用别的配色（粉、金黄、深字白描边……），不受此规则约束。
        let originalPresets: [SubtitleStyle.Preset] = [.classicKaraoke, .vocaloidPurpleBlue, .minimalMV]
        for preset in originalPresets {
            let s = preset.style
            // 未唱：白色（三通道都接近 1）
            #expect(s.unsungColor.r > 0.9 && s.unsungColor.g > 0.9 && s.unsungColor.b > 0.9,
                    "预设「\(preset.displayName)」未唱色不是白色")
            // 已唱：蓝紫 —— 蓝通道最高，绿最低
            let sung = s.sungColor
            #expect(sung.b > sung.g, "已唱色应偏蓝紫（B > G）")
            #expect(sung.b >= 0.8, "已唱色蓝通道应足够高")
            #expect(sung.a > 0.9, "已唱色必须是实色")
        }
    }

    @Test func strokeIsBlackAndShadowIsDark() {
        let s = SubtitleStyle.default
        #expect(s.strokeColor.r < 0.10 && s.strokeColor.g < 0.10 && s.strokeColor.b < 0.15,
                "描边必须是黑色/近黑，实际 \(s.strokeColor.hexString)")
        #expect(s.strokeWidth >= 6, "描边要够粗才能在复杂背景上看清（实测 3 与 5 都偏细）")
        #expect(s.shadowOpacity > 0.3, "阴影不透明度太低")
        #expect(s.shadowBlur > 5, "阴影模糊太小，压不住复杂背景")
        let lum = 0.2126 * s.shadowColor.r + 0.7152 * s.shadowColor.g + 0.0722 * s.shadowColor.b
        #expect(lum < 0.25, "阴影必须是深色")
        #expect(s.fontWeight >= 600, "未唱为粗体")
    }

    // MARK: 验收 5：假名按词绑定，不平均铺开

    @Test func rubyIsBoundToWordWidthNotSpreadOverLine() throws {
        // 一句：一个很窄的汉字词 + 很长的一段假名
        let narrow = LyricToken(surface: "東", reading: "ひがし", morae: [
            MoraTiming(mora: "ひ", start: 0, end: 0.2),
            MoraTiming(mora: "が", start: 0.2, end: 0.4),
            MoraTiming(mora: "し", start: 0.4, end: 0.6),
        ], sourceStart: 0, sourceLength: 1)
        let longKana = LyricToken(surface: "のそらにひかる", reading: nil,
                                  sourceStart: 1, sourceLength: 6)
        let text = "東のそらにひかる"
        var line = LyricLine(order: 1, lane: .upper, displayText: text,
                             displayStart: 0, singStart: 0, singEnd: 2, displayEnd: 3)
        line.tokens = [narrow, longKana]

        let layout = KaraokeLayout.layout(line: line, style: .default)
        let ruby = try #require(layout.rubies.first, "窄汉字词必须有假名")
        let geo = try #require(layout.tokenGeometry[narrow.id])

        // 假名必须贴在窄词上：宽度接近词宽，而不是整行宽
        #expect(ruby.tokenWidth == geo.width)
        #expect(ruby.width < layout.lineWidth * 0.4,
                "假名被铺成了整行宽（\(Int(ruby.width)) / \(Int(layout.lineWidth))），违反「按词宽度绑定」")
        // 词在行的左侧，所以假名中心应明显偏左，而不是行中心
        #expect(ruby.centerX < -layout.lineWidth * 0.15,
                "假名中心 \(Int(ruby.centerX)) 太靠近行中心，说明按整句平均铺开了")

        // 纯假名 token 不产生假名
        #expect(!longKana.needsRuby)
        #expect(layout.rubies.count == 1, "只有含汉字的 token 才该有假名")
    }

    @Test func rubyCountEqualsKanjiTokenCount() {
        let project = KaraProject()
        var line = LyricLine(order: 1, lane: .upper, displayText: "素晴らしき世界に今日も乾杯",
                             displayStart: 0, singStart: 0, singEnd: 2, displayEnd: 3)
        line.tokens = JapaneseReadingService().tokens(for: line.displayText)
        let layout = KaraokeLayout.layout(line: line, style: project.style)

        let kanjiTokens = line.tokens.filter { JapaneseText.containsKanji($0.surface) }
        #expect(layout.rubies.count == kanjiTokens.count,
                "假名数量应等于含汉字 token 数：\(layout.rubies.count) vs \(kanjiTokens.count)")
        // 每条假名都必须落在它所属 token 的横向范围内（现在一条 token 可能有多段假名）
        for ruby in layout.rubies {
            if let geo = layout.tokenGeometry[ruby.tokenID] {
                let tokenMin = geo.centerX - geo.width / 2
                let tokenMax = geo.centerX + geo.width / 2
                #expect(ruby.centerX >= tokenMin - 0.5 && ruby.centerX <= tokenMax + 0.5,
                        "假名中心 \(ruby.centerX) 跑到 token 范围 [\(tokenMin), \(tokenMax)] 之外")
                #expect(ruby.tokenWidth <= geo.width + 0.5)
            }
        }
    }

    // MARK: 验收 6：App 只产出字幕层

    @Test func appNeverEmitsNonSubtitleArtwork() {
        // App 的输出只有两类：ASS 文本事件、以及工程内的字幕数据。
        // 这里断言导出的 ASS 里不包含任何图片/视频/绘制指令，
        // 也就是确认「源视频的标题、艺术字、演职员字样不是 App 生成内容」。
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 20, title: "t")
        var line = LyricLine(order: 1, lane: .upper, displayText: "テスト",
                             displayStart: 1, singStart: 2, singEnd: 3, displayEnd: 4)
        line.tokens = JapaneseReadingService().tokens(for: "テスト")
        project.lyricLines = [line]

        let ass = AssExporter.export(project: project)
        // ASS 里只有样式与对话事件；没有任何位图/绘图/外部资源引用
        for forbidden in ["\\p1", "\\p2", "picture", ".png", ".jpg", "\\clip(", "\\iclip("] {
            #expect(!ass.lowercased().contains(forbidden.lowercased()),
                    "导出里出现了非字幕内容：\(forbidden)")
        }
        #expect(ass.contains("[Events]"))
    }
}
