import Testing
import Foundation
@testable import MaGiKaraKit

/// ASS 导出与 Ruby 排版（RD §6.2 / §11.2）
@Suite struct ExportTests {

    private func projectWithLines() -> KaraProject {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
                                  duration: 30,
                                  title: "テスト")
        var upper = LyricLine(order: 1,
                              lane: .upper,
                              displayText: "素晴らしき世界に",
                              displayStart: 1.0,
                              singStart: 2.0,
                              singEnd: 4.0,
                              displayEnd: 6.0)
        upper.tokens = [
            LyricToken(surface: "素晴らしき", reading: "すばらしき", morae: [
                MoraTiming(mora: "す", start: 2.0, end: 2.2),
                MoraTiming(mora: "ば", start: 2.2, end: 2.4),
                MoraTiming(mora: "ら", start: 2.4, end: 2.6),
                MoraTiming(mora: "し", start: 2.6, end: 2.8),
                MoraTiming(mora: "き", start: 2.8, end: 3.0),
            ], sourceStart: 0, sourceLength: 5),
            LyricToken(surface: "世界", reading: "せかい", morae: [
                MoraTiming(mora: "せ", start: 3.0, end: 3.3),
                MoraTiming(mora: "か", start: 3.3, end: 3.6),
                MoraTiming(mora: "い", start: 3.6, end: 4.0),
            ], sourceStart: 5, sourceLength: 2),
            LyricToken(surface: "に", reading: nil, sourceStart: 7, sourceLength: 1),
        ]

        var lower = LyricLine(order: 2,
                              lane: .lower,
                              displayText: "今日も乾杯",
                              displayStart: 1.0,
                              singStart: 4.5,
                              singEnd: 7.0,
                              displayEnd: 9.0)
        lower.tokens = [
            LyricToken(surface: "今日", reading: "きょう", morae: [
                MoraTiming(mora: "きょ", start: 4.5, end: 5.0),
                MoraTiming(mora: "う", start: 5.0, end: 5.5),
            ], sourceStart: 0, sourceLength: 2),
            LyricToken(surface: "も", reading: nil, sourceStart: 2, sourceLength: 1),
            LyricToken(surface: "乾杯", reading: "かんぱい", morae: [
                MoraTiming(mora: "か", start: 5.5, end: 6.0),
                MoraTiming(mora: "ん", start: 6.0, end: 6.4),
                MoraTiming(mora: "ぱ", start: 6.4, end: 6.7),
                MoraTiming(mora: "い", start: 6.7, end: 7.0),
            ], sourceStart: 3, sourceLength: 2),
        ]

        project.lyricLines = [upper, lower]
        return project
    }

    private func dialogueLines(_ ass: String, layer: Int) -> [String] {
        ass.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("Dialogue: \(layer),") }
    }

    private func karaokeDurations(in text: String) -> [Int] {
        var result: [Int] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            guard let r = text.range(of: "\\kf", range: idx..<text.endIndex)
                    ?? text.range(of: "\\k", range: idx..<text.endIndex) else { break }
            let after = text[r.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let v = Int(digits) { result.append(v) }
            if after.startIndex >= text.endIndex { break }
            idx = after.startIndex
        }
        return result
    }

    // MARK: 时间与颜色格式

    @Test func assTimestampFormat() {
        #expect(AssExporter.timestamp(0) == "0:00:00.00")
        #expect(AssExporter.timestamp(1.5) == "0:00:01.50")
        #expect(AssExporter.timestamp(62.34) == "0:01:02.34")
        #expect(AssExporter.timestamp(3725.99) == "1:02:05.99")
    }

    @Test func assColorFormatIsAABBGGRR() {
        #expect(RGBAColor(1, 0, 0, 1).assColor == "&H000000FF")       // 纯红
        #expect(RGBAColor(1, 1, 1, 1).assColor == "&H00FFFFFF")       // 纯白
        #expect(RGBAColor(0, 0, 0, 0.5).assColor == "&H80000000")     // 半透明黑
    }

    // MARK: 结构

    @Test func exportContainsRequiredSections() {
        let ass = AssExporter.export(project: projectWithLines())

        #expect(ass.contains("[Script Info]"))
        #expect(ass.contains("ScriptType: v4.00+"))
        #expect(ass.contains("PlayResX: 1920"))
        #expect(ass.contains("[V4+ Styles]"))
        #expect(ass.contains("Style: Main,"))
        #expect(ass.contains("Style: Ruby,"))
        #expect(ass.contains("[Events]"))
        #expect(ass.contains("Dialogue: 0,"))
    }

    @Test func globalSubtitleTransitionDefaultsToHardCut() {
        let style = SubtitleStyle()
        #expect(style.entryEffect == .hardCut)
        #expect(style.exitEffect == .hardCut)
    }

    @Test func exportAppliesGlobalFadeOnlyAtTrackBoundaries() {
        var project = projectWithLines()
        project.style.entryEffect = .fade
        project.style.exitEffect = .fade
        let ass = AssExporter.export(project: project)

        // 等待区、唱后停留区和无等待/无停留的边界分别承载淡化，
        // 不应把 \fad 重复塞进每个逐字扫色块。
        #expect(ass.contains("\\fad(180,0)"))
        #expect(ass.contains("\\fad(0,180)"))
        #expect(!ass.contains("\\fad(180,180)\\kf"),
                "淡化不应附着到每个逐字 \\kf 块造成重复闪烁")
    }

    @Test func exportSplitsLeadInSingAndHoldOut() {
        let ass = AssExporter.export(project: projectWithLines())
        let mainEvents = dialogueLines(ass, layer: 0)
        // 每句最多 3 段：等待区 / 扫色 / 唱后停留。两句共 6 段。
        #expect(mainEvents.count == 6, "等待区与唱后停留必须是独立静态事件")

        // 第一句的等待区事件时间必须等于 displayStart → singStart
        #expect(ass.contains("Dialogue: 0,0:00:01.00,0:00:02.00,Main"), "等待区事件缺失或时间不对")
        // 唱后停留：singEnd → displayEnd
        #expect(ass.contains("Dialogue: 0,0:00:04.00,0:00:06.00,Main"), "唱后停留事件缺失或时间不对")
    }

    @Test func exportKaraokeTagsSumToSingDuration() throws {
        let ass = AssExporter.export(project: projectWithLines())
        #expect(ass.contains("\\kf") || ass.contains("\\k"), "必须输出卡拉 OK 扫色标签")

        // 第一句扫色事件的 \kf 时长之和应等于演唱时长 2.0 秒 = 200 厘秒
        let raw = try #require(ass.split(separator: "\n").first {
            $0.hasPrefix("Dialogue: 0,0:00:02.00,0:00:04.00,Main")
        }, "找不到扫色事件")
        let text = String(raw)

        let durations = karaokeDurations(in: text)
        // displayText「素晴らしき世界に」共 8 个字符；匀速扫色每个字符一个 \k 块（含无音拍的「に」）
        #expect(durations.count == 8, "实际 \(durations.count) 个扫色块")
        #expect(durations.reduce(0, +) == 200, "扫色时长之和应等于演唱时长，实际 \(durations.reduce(0, +))")
    }

    /// 取出 Dialogue 行 Text 字段里去掉 `{...}` 覆盖块之后的纯文字。
    /// 假名与主文字都被逐音拍 `\kf` 切成多段，所以必须这样还原才能比较文字内容。
    private func plainText(ofDialogue line: String) -> String {
        let text = line.components(separatedBy: ",,").last ?? line
        var result = ""
        var depth = 0
        for ch in text {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(ch) }
        }
        return result
    }

    @Test func exportEmitsRubyAsSeparatePositionedEvents() {
        let ass = AssExporter.export(project: projectWithLines())
        let rubyEvents = dialogueLines(ass, layer: 1)
        #expect(!rubyEvents.isEmpty, "假名必须以独立定位事件输出（RD §11.2）")
        // 4 个汉字词，每个词恰好一个扫色事件（另有等待区 / 唱后停留的静态事件）
        let sweepEvents = rubyEvents.filter { $0.contains("\\kf") }
        #expect(sweepEvents.count == 4, "实际 \(sweepEvents.count) 个扫色事件")
        #expect(rubyEvents.allSatisfy { $0.contains("\\an5\\pos(") }, "假名事件必须带独立定位")

        // 假名文字被逐字 \kf 切开，去掉覆盖块后应还原成完整读音
        let texts = rubyEvents.map { plainText(ofDialogue: $0) }
        #expect(texts.contains("すば"), "假名只应覆盖汉字「素晴」，实际：\(texts)")
        #expect(!texts.contains("すばらしき"), "送假名「らしき」不应重复注音")
        #expect(texts.contains("せかい"), "缺少「世界」的假名")
        #expect(texts.contains("きょう"), "缺少「今日」的假名")
        #expect(texts.contains("かんぱい"), "缺少「乾杯」的假名")
    }

    /// 回归：等待区事件曾把 `\alpha&H00&` 写到了 `{}` 外面，每一句歌词开头 0.5 秒都会
    /// 把这串乱码当成文字显示出来。任何事件去掉 `{...}` 覆盖块之后，都不应残留反斜杠命令。
    @Test func noEventLeaksOverrideTagsIntoVisibleText() {
        let ass = AssExporter.export(project: projectWithLines())
        let events = ass.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Dialogue:") }
        #expect(!events.isEmpty)
        for event in events {
            let visible = plainText(ofDialogue: event)
            #expect(!visible.contains("\\") && !visible.contains("&H"),
                    "可见文字里混进了覆盖标签：\(visible)")
        }
    }

    @Test func mainSweepEventTextMatchesDisplayText() throws {
        let ass = AssExporter.export(project: projectWithLines())
        let raw = try #require(ass.split(separator: "\n").first {
            $0.hasPrefix("Dialogue: 0,0:00:02.00,0:00:04.00,Main")
        })
        // 扫色事件被切成 8 个音拍段，拼起来必须还是原句，不能丢字或多字
        #expect(plainText(ofDialogue: String(raw)) == "素晴らしき世界に")
    }

    @Test func rubyEventsOnlyForKanjiTokens() {
        let ass = AssExporter.export(project: projectWithLines())
        let texts = dialogueLines(ass, layer: 1).map { plainText(ofDialogue: $0) }
        // 「に」「も」是纯假名，绝不能出现假名附轨（RD §5.1）
        #expect(!texts.contains("に"))
        #expect(!texts.contains("も"))
    }

    /// 把 ASS 时间戳 `H:MM:SS.cc` 还原成秒。
    private func seconds(fromASSTimestamp text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// 假名扫色必须与主词同步：主词边缘走过这段汉字所占宽度的那段时间，
    /// 就是该假名的扫色窗口，而不是按音拍节奏单独走轨。
    @Test func rubySweepWindowFollowsMainSweepPosition() throws {
        let project = projectWithLines()
        let line = try #require(project.lyricLines.first { $0.order == 1 })
        let layout = KaraokeLayout.layout(line: line, style: project.style)
        let ass = AssExporter.export(project: project)
        let sweepEvents = dialogueLines(ass, layer: 1).filter { $0.contains("\\kf") }

        for ruby in layout.rubies {
            let expectedStart = line.singStart + ruby.sweepStart * line.singDuration
            let expectedEnd = line.singStart + ruby.sweepEnd * line.singDuration
            let event = try #require(sweepEvents.first { plainText(ofDialogue: $0) == ruby.text },
                                     "找不到「\(ruby.text)」的扫色事件")
            let fields = event.split(separator: ",", maxSplits: 3).map(String.init)
            let start = try #require(seconds(fromASSTimestamp: fields[1]))
            let end = try #require(seconds(fromASSTimestamp: fields[2]))
            #expect(abs(start - expectedStart) <= 0.011,
                    "「\(ruby.text)」应在主词边缘到达 \(expectedStart) 秒时开始，实际 \(start)")
            #expect(abs(end - expectedEnd) <= 0.011,
                    "「\(ruby.text)」应在主词边缘离开 \(expectedEnd) 秒时结束，实际 \(end)")
        }
    }

    @Test func rubyStaysSungUntilDisplayEnds() throws {
        let ass = AssExporter.export(project: projectWithLines())
        // 第一句 displayEnd = 6.0：「世界」扫完后要以已唱色保持到 6.0，不能比主词先消失
        let held = dialogueLines(ass, layer: 1).filter {
            $0.contains(",0:00:06.00,Ruby") && plainText(ofDialogue: $0) == "せかい"
        }
        #expect(held.count == 1, "假名在唱后应保持已唱色直到整句显示结束")
    }

    @Test func rubySweepProgressIsProgressiveAndSharesTheLineSweep() throws {
        let project = projectWithLines()
        let line = try #require(project.lyricLines.first)
        let layout = KaraokeLayout.layout(line: line, style: project.style)
        let ruby = try #require(layout.rubies.first { $0.text == "せかい" })

        // 主词边缘还没到这段汉字：假名完全未唱
        #expect(layout.rubySweepProgress(ruby, sweepFraction: max(0, ruby.sweepStart - 0.01)) == 0)
        // 边缘在汉字中间：假名只扫了一部分（逐步扫色，不是整段一碰就变色）
        let mid = (ruby.sweepStart + ruby.sweepEnd) / 2
        let half = layout.rubySweepProgress(ruby, sweepFraction: mid)
        #expect(half > 0.4 && half < 0.6, "实际 \(half)")
        // 边缘离开这段汉字：假名完全已唱
        #expect(layout.rubySweepProgress(ruby, sweepFraction: min(1, ruby.sweepEnd + 0.01)) == 1)
    }

    /// 回归：布局缓存里的 singStart/singEnd 可能过期（重新对轨、拖动、修剪后）。
    /// 假名进度只取决于传入的整句进度，不能再读缓存里的旧时间。
    @Test func rubyProgressIgnoresStaleCachedLineTimes() throws {
        let project = projectWithLines()
        var line = try #require(project.lyricLines.first)
        let staleLayout = KaraokeLayout.layout(line: line, style: project.style)   // 按 2.0–4.0 缓存
        line.singStart = 10   // 之后歌词被整体移到 10–12 秒
        line.singEnd = 12
        let ruby = try #require(staleLayout.rubies.first { $0.text == "せかい" })

        // 实时进度（来自当前的 10–12 秒）在 10.2 秒仍应是未唱
        let live = (10.2 - line.singStart) / (line.singEnd - line.singStart)
        #expect(staleLayout.rubySweepProgress(ruby, sweepFraction: live) == 0)
        // 旧接口会拿缓存的 2–4 秒去算，在 10.2 秒时误判为「已唱完」——这正是假名提前变色的来源
        #expect(staleLayout.rubySweepProgress(ruby, at: 10.2) == 1)
    }

    @Test func shadowAlphaMatchesStyleOpacity() throws {
        // ASS 的 alpha 是反的（0x00 不透明、0xFF 全透明）。
        // shadowOpacity 0.7 对应的 alpha 字节应是 round((1-0.7)*255) = 0x4C。
        var project = projectWithLines()
        project.style.shadowColor = RGBAColor(0, 0, 0, 1)
        project.style.shadowOpacity = 0.7
        let ass = AssExporter.export(project: project)

        let styleLine = try #require(ass.split(separator: "\n").first { $0.hasPrefix("Style: Main,") })
        let fields = styleLine.split(separator: ",").map(String.init)
        // Format: Name, Fontname, Fontsize, Primary, Secondary, Outline, Back, ...
        let back = try #require(fields.count > 6 ? fields[6] : nil)
        // &HAABBGGRR —— 取 AA 字节，换算回不透明度应约等于 0.7
        let hex = back.replacingOccurrences(of: "&H", with: "")
        let alphaByte = try #require(Int(hex.prefix(2), radix: 16))
        let impliedOpacity = 1.0 - Double(alphaByte) / 255.0
        #expect(abs(impliedOpacity - 0.7) <= 0.01,
                "阴影不透明度应为 0.7，实际 \(impliedOpacity)（\(back)）")
    }

    @Test func swapKaraokeColorsOptionChangesOutput() {
        var project = projectWithLines()
        project.style.unsungColor = RGBAColor(1, 1, 1, 1)
        project.style.sungColor = RGBAColor(0, 0, 1, 1)

        var normal = AssExporter.Options()
        normal.swapKaraokeColors = false
        let a = AssExporter.export(project: project, options: normal)

        var swapped = AssExporter.Options()
        swapped.swapKaraokeColors = true
        let b = AssExporter.export(project: project, options: swapped)

        #expect(a != b, "交换开关必须改变输出")
    }

    @Test func singleEventFallbackPath() {
        var options = AssExporter.Options()
        options.splitPhases = false
        let ass = AssExporter.export(project: projectWithLines(), options: options)
        #expect(dialogueLines(ass, layer: 0).count == 2, "退化路径每句只有一个事件")
    }

    @Test func textWithBracesIsEscaped() {
        var project = projectWithLines()
        project.lyricLines[0].displayText = "{危险}的歌词"
        project.lyricLines[0].tokens = [
            LyricToken(surface: "{危险}的歌词", reading: nil, morae: [
                MoraTiming(mora: "き", start: 2.0, end: 2.5),
            ], sourceStart: 0, sourceLength: 7)
        ]
        let ass = AssExporter.export(project: project)
        #expect(ass.contains("\\{危险\\}"), "花括号必须转义，否则会被当成覆盖标签")
    }

    // MARK: Ruby 排版（Core Text）

    @Test func rubyIsCenteredOverItsKanjiToken() throws {
        let project = projectWithLines()
        let line = project.lyricLines[0]
        let layout = KaraokeLayout.layout(line: line, style: project.style)

        let ruby = try #require(layout.rubies.first { $0.text == "せかい" }, "缺少「世界」的假名排版")
        let token = try #require(line.tokens.first { $0.surface == "世界" })
        let geo = try #require(layout.tokenGeometry[token.id])

        // 假名中心必须与对应汉字词中心一致（RD §6.2）
        #expect(abs(ruby.centerX - geo.centerX) < 0.5)
    }

    @Test func wideRubyGetsLetterSpacingOrSmallerFont() throws {
        // 读音明显宽于汉字时，必须先加字距，必要时再轻微缩字号
        var style = SubtitleStyle.default
        style.fontSize = 60
        style.rubySizeFactor = 0.45
        let token = LyricToken(surface: "々", reading: "とてもながいよみかた", morae: [
            MoraTiming(mora: "と", start: 0, end: 0.2),
        ], sourceStart: 0, sourceLength: 1)
        let line = LyricLine(order: 1, displayText: "々", tokens: [token])

        let layout = KaraokeLayout.layout(line: line, style: style)
        let ruby = try #require(layout.rubies.first, "缺少 Ruby 排版")

        let baseRubySize = style.fontSize * style.rubySizeFactor
        #expect(ruby.letterSpacing > 0 || ruby.fontSize < baseRubySize,
                "过宽的读音必须加字距或缩字号")
        #expect(ruby.letterSpacing <= style.fontSize * 0.12 + 1e-6, "字距不应超过主字号的 12%")
    }

    @Test func moraBoxesCoverTheLineMonotonically() throws {
        let project = projectWithLines()
        let line = project.lyricLines[0]
        let layout = KaraokeLayout.layout(line: line, style: project.style)

        #expect(layout.moraBoxes.count == line.allMorae.count)
        for (a, b) in zip(layout.moraBoxes, layout.moraBoxes.dropFirst()) {
            #expect(a.start <= b.start, "音拍必须按时间排序")
            #expect(a.maxX <= b.minX + 1e-6, "音拍横向范围不能重叠")
        }
        let first = try #require(layout.moraBoxes.first)
        let last = try #require(layout.moraBoxes.last)
        #expect(first.minX <= -layout.lineWidth / 2 + 1e-6)
        #expect(last.maxX >= layout.lineWidth / 2 - 1e-6)
    }

    @Test func sweepXMovesLeftToRightAndClamps() {
        let project = projectWithLines()
        let line = project.lyricLines[0]
        let layout = KaraokeLayout.layout(line: line, style: project.style)

        let atStart = layout.sweepX(at: line.singStart, line: line)
        let mid = layout.sweepX(at: (line.singStart + line.singEnd) / 2, line: line)
        let atEnd = layout.sweepX(at: line.singEnd, line: line)

        #expect(atStart < mid)
        #expect(mid < atEnd)
        #expect(abs(atStart - (-layout.lineWidth / 2)) < 0.5)
        #expect(abs(atEnd - layout.lineWidth / 2) < 0.5)
        // 超出范围要夹住
        #expect(abs(layout.sweepX(at: -100, line: line) - (-layout.lineWidth / 2)) < 0.5)
        #expect(abs(layout.sweepX(at: 9999, line: line) - layout.lineWidth / 2) < 0.5)
    }

    @Test func tokenActiveStateForRubyHighlight() throws {
        let project = projectWithLines()
        let line = project.lyricLines[0]
        let layout = KaraokeLayout.layout(line: line, style: project.style)
        let world = try #require(line.tokens.first { $0.surface == "世界" })

        #expect(!layout.isTokenActive(tokenID: world.id, at: 2.5), "还没唱到「世界」")
        #expect(layout.isTokenActive(tokenID: world.id, at: 3.5), "正在唱「世界」")
        #expect(!layout.isTokenActive(tokenID: world.id, at: 4.5), "「世界」已唱完")
    }
}
