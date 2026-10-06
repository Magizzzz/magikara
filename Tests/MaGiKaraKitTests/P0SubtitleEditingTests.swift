import Testing
import Foundation
@testable import MaGiKaraKit

// MARK: - Ruby：只给汉字注音 + 不可靠宁可不生成 + 逐段可逆覆盖

@Suite struct RubyBindingP0Tests {

    @Test func okuriganaExamplesNeverGetRuby() {
        let a = JapaneseReadingService.rubyRuns(surface: "勝ち筋", reading: "かちすじ")
        #expect(a.map(\.reading) == ["か", "すじ"])
        #expect(!a.contains { $0.reading == "ち" }, "送假名「ち」不能注音")

        let b = JapaneseReadingService.rubyRuns(surface: "素晴らしき", reading: "すばらしき")
        #expect(b.map(\.reading) == ["すば"])
        #expect(!b.contains { $0.reading.contains("らしき") })

        let c = JapaneseReadingService.rubyRuns(surface: "食べる", reading: "たべる")
        #expect(c.map(\.reading) == ["た"])
        #expect(!c.contains { $0.reading.contains("べる") })

        #expect(JapaneseReadingService.rubyRuns(surface: "そうですね", reading: "そうですね").isEmpty,
                "纯假名不生成 Ruby")
    }

    @Test func unreliableAlignmentIsNotGuessed() {
        // 表记「花が」读音「はな」缺「が」→ 不可靠，必须放弃而不是把「はな」盖到「花が」上
        let result = JapaneseReadingService.alignRuby(surface: "花が", reading: "はな")
        #expect(result.runs.isEmpty)
        #expect(result.needsConfirmation)

        let resolved = RubyBindingResolver.resolve(for: LyricToken(surface: "花が", reading: "はな"))
        #expect(resolved.bindings.isEmpty)
        #expect(resolved.needsConfirmation)
    }

    @Test func ambiguousReadingTailIsFlaggedWithoutCoveringKana() {
        // 表记「食べ」读音「たべる」多出「る」：给出可靠的 食=た，但标记待确认
        let result = JapaneseReadingService.alignRuby(surface: "食べ", reading: "たべる")
        #expect(result.runs.map(\.reading) == ["た"])
        #expect(result.needsConfirmation)
        #expect(!result.runs.contains { $0.reading.contains("べる") })
    }

    @Test func perKanjiOverrideWinsSuppressesAndRestores() {
        var token = LyricToken(surface: "勝ち筋", reading: "かちすじ")
        token.setRubyOverride(surfaceStart: 2, surfaceLength: 1, reading: "すぎ")

        var resolved = RubyBindingResolver.resolve(for: token)
        #expect(resolved.bindings.map(\.reading) == ["か", "すぎ"])
        #expect(resolved.bindings.first { $0.surfaceStart == 2 }?.isConfirmed == true)
        #expect(resolved.bindings.first { $0.surfaceStart == 0 }?.isConfirmed == false)

        // 显式删除「勝」的自动注音：保留槽位但不再显示
        token.setRubyOverride(surfaceStart: 0, surfaceLength: 1, reading: "")
        resolved = RubyBindingResolver.resolve(for: token)
        #expect(resolved.bindings.map(\.reading) == ["すぎ"])
        #expect(token.suppressedRubyStarts() == [0])

        // 恢复自动
        token.removeRubyOverride(surfaceStart: 0)
        token.removeRubyOverride(surfaceStart: 2)
        resolved = RubyBindingResolver.resolve(for: token)
        #expect(resolved.bindings.map(\.reading) == ["か", "すじ"])
        #expect(token.rubyOverrides == nil)
    }

    @Test func replacedKanjiDropsStaleOverride() {
        var token = LyricToken(surface: "食べる", reading: "たべる")
        token.setRubyOverride(surfaceStart: 0, surfaceLength: 1, reading: "た")
        #expect(token.sanitizedRubyOverrides().count == 1)

        // 替换第一个汉字：绑定必须失效，不能把旧读音留在新汉字上
        token.surface = "飲べる"
        #expect(token.sanitizedRubyOverrides().isEmpty)
        let resolved = RubyBindingResolver.resolve(for: token)
        #expect(resolved.bindings.allSatisfy { !$0.isConfirmed })
    }

    @Test func slotsKeepCompoundTogetherAndSplitPerKanji() {
        var compound = LyricLine(order: 1, lane: .upper, displayText: "素晴らしき")
        compound.tokens = [LyricToken(surface: "素晴らしき", reading: "すばらしき",
                                      sourceStart: 0, sourceLength: 5)]
        let compoundSlots = RubySlotBuilder.slots(for: compound)
        #expect(compoundSlots.count == 1)
        #expect(compoundSlots.first?.characters == "素晴")
        #expect(compoundSlots.first?.reading == "すば")

        var split = LyricLine(order: 2, lane: .lower, displayText: "勝ち筋")
        split.tokens = [LyricToken(surface: "勝ち筋", reading: "かちすじ",
                                   sourceStart: 0, sourceLength: 3)]
        let splitSlots = RubySlotBuilder.slots(for: split)
        #expect(splitSlots.map(\.characters) == ["勝", "筋"])
        #expect(splitSlots.map(\.reading) == ["か", "すじ"])
    }

    @Test func unreliableAlignmentStillOffersEditableEmptySlots() {
        var line = LyricLine(order: 1, lane: .upper, displayText: "花が")
        line.tokens = [LyricToken(surface: "花が", reading: "はな", sourceStart: 0, sourceLength: 2)]
        let slots = RubySlotBuilder.slots(for: line)
        #expect(slots.map(\.characters) == ["花"])
        #expect(slots.first?.reading == "")
        #expect(slots.first?.isUnconfirmed == true)
    }

    @Test func layoutSkipsUnreliableRubyAndFlagsIt() {
        var line = LyricLine(order: 1, lane: .upper, displayText: "花が")
        line.tokens = [LyricToken(surface: "花が", reading: "はな", sourceStart: 0, sourceLength: 2)]
        let layout = KaraokeLayout.layout(line: line, style: .default)
        #expect(layout.rubies.isEmpty, "不可靠时不能退化成整词读音覆盖混合 token")
        #expect(layout.rubyNeedsConfirmation)
    }

    @Test func rubyNeverWidensMainSentence() {
        func makeLine(_ token: LyricToken) -> LyricLine {
            var line = LyricLine(order: 1, lane: .upper, displayText: token.surface)
            line.tokens = [token]
            return line
        }
        let auto = LyricToken(surface: "世界", reading: "せかい")
        var overridden = auto
        overridden.setRubyOverride(surfaceStart: 0, surfaceLength: 2, reading: "せかい")

        let a = KaraokeLayout.layout(line: makeLine(auto), style: .default)
        let b = KaraokeLayout.layout(line: makeLine(overridden), style: .default)
        #expect(abs(a.lineWidth - b.lineWidth) < 1e-6, "Ruby 是独立浮层，不得撑宽主句")
        #expect(b.rubies.count == 1)
        #expect(b.rubies.first?.text == "せかい")
    }
}

// MARK: - 时间轴：无歌词文字 + 选中联动

@Suite struct TimelinePresentationP0Tests {

    @Test func timelineNeverShowsLyricText() {
        let line = LyricLine(order: 3, lane: .upper, displayText: "完整歌词句子",
                             displayStart: 0, singStart: 1, singEnd: 2, displayEnd: 3)
        let selected = TimelineSegment.presentation(for: line, selectedLineID: line.id)
        #expect(!selected.showsLyricText)
        #expect(selected.sequenceLabel == "3")
        #expect(selected.sequenceLabel != line.displayText)
        #expect(selected.isSelected)

        let unselected = TimelineSegment.presentation(for: line, selectedLineID: nil)
        #expect(!unselected.showsLyricText)
        #expect(!unselected.isSelected)

        let noSequence = TimelineSegment.presentation(for: line, selectedLineID: nil, showSequence: false)
        #expect(noSequence.sequenceLabel == nil)
    }

    @Test func timelineSelectionFollowsSelectedID() {
        let a = LyricLine(order: 1, lane: .upper, displayText: "a")
        let b = LyricLine(order: 2, lane: .lower, displayText: "b")
        #expect(TimelineSegment.presentation(for: a, selectedLineID: a.id).isSelected)
        #expect(!TimelineSegment.presentation(for: b, selectedLineID: a.id).isSelected)
        #expect(TimelineSegment.presentation(for: b, selectedLineID: a.id).lane == .lower)
    }
}

// MARK: - 双 Tab 路由 / 空状态

@Suite struct InspectorTabRoutingP0Tests {

    @Test func onlyTwoMainTabs() {
        #expect(InspectorPrimaryTab.allCases.map(\.title) == ["文本", "字幕"])
    }

    @Test func selectingLineActivatesSubtitleTab() {
        #expect(SubtitleEditorRouting.tab(afterSelectingLine: UUID(), from: .text) == .subtitle)
        #expect(SubtitleEditorRouting.tab(afterSelectingLine: UUID(), from: .subtitle) == .subtitle)
    }

    @Test func clearingSelectionKeepsTab() {
        #expect(SubtitleEditorRouting.tab(afterSelectionChangeTo: nil, from: .subtitle) == .subtitle)
        #expect(SubtitleEditorRouting.tab(afterSelectionChangeTo: nil, from: .text) == .text)
        #expect(SubtitleEditorRouting.tab(afterSelectionChangeTo: UUID(), from: .text) == .subtitle)
    }

    @Test func emptySelectionHintIsExact() {
        #expect(SubtitleEditorRouting.emptySelectionHint == "点击时间轴色块开始编辑")
    }
}

// MARK: - 上下行手工归属

@Suite struct ManualLaneP0Tests {

    @Test func manualLaneSurvivesRenumberAndDisplayScheduling() {
        var project = KaraProject()
        var first = LyricLine(order: 1, lane: .lower, displayText: "a",
                              singStart: 1, singEnd: 2)
        first.laneIsManual = true
        let second = LyricLine(order: 2, lane: .upper, displayText: "b",
                               singStart: 3, singEnd: 4)
        project.lyricLines = [first, second]

        project.renumber()
        #expect(project.lyricLines.first { $0.id == first.id }?.lane == .lower,
                "手工指定的轨道不能被 renumber 改回自动交替")

        DisplayScheduler.applyDisplayWindows(to: &project.lyricLines)
        #expect(project.lyricLines.first { $0.id == first.id }?.lane == .lower)
    }

    @Test func automaticLanesStillAlternate() {
        var lines = [
            LyricLine(order: 1, displayText: "a", singStart: 1, singEnd: 2),
            LyricLine(order: 2, displayText: "b", singStart: 3, singEnd: 4),
        ]
        DisplayScheduler.assignLanes(&lines)
        #expect(lines[0].lane == .upper)
        #expect(lines[1].lane == .lower)
    }
}

// MARK: - 四时间编辑：最小时长 / 夹紧 / 同轨重叠 / 不合并两组时间

@Suite struct LineTimeEditorP0Tests {

    @Test func enforcesEndGreaterThanStartAndMinimumDuration() {
        let r = LineTimeEditor.displayRange(desiredStart: 5, desiredEnd: 5,
                                            singStart: 5, singEnd: 5, duration: 30)
        #expect(r.displayEnd > r.displayStart)
        #expect(r.displayEnd - r.displayStart >= LineTimeEditor.minimumDuration - 1e-9)
        #expect(!r.rejected)
    }

    @Test func clampsToVideoBounds() {
        let r = LineTimeEditor.displayRange(desiredStart: -3, desiredEnd: 2,
                                            singStart: 0.5, singEnd: 1, duration: 10)
        #expect(r.displayStart >= 0)
        #expect(r.displayEnd <= 10)
        #expect(r.didClamp)
    }

    @Test func snapsSameLaneOverlapToNeighborBoundary() {
        let r = LineTimeEditor.displayRange(desiredStart: 4, desiredEnd: 9,
                                            singStart: 4, singEnd: 4.5,
                                            duration: 30,
                                            sameLaneNeighbors: [(start: 5, end: 8)],
                                            movingEdge: .end)
        #expect(r.didOverlap)
        #expect(!r.rejected)
        #expect(abs(r.displayEnd - 5) < 1e-9, "应吸附到相邻片段的起点")
    }

    @Test func rejectsUnavoidableSameLaneOverlap() {
        // 可见区必须包住扫色区 [6.5, 7]，而相邻片段正好压在 [5, 8)：无法通过吸附回避
        let r = LineTimeEditor.displayRange(desiredStart: 6, desiredEnd: 9,
                                            singStart: 6.5, singEnd: 7,
                                            duration: 30,
                                            sameLaneNeighbors: [(start: 5, end: 8)],
                                            movingEdge: .start)
        #expect(r.didOverlap)
        #expect(r.rejected, "无法回避的重叠必须阻止，而不是写出重叠数据")
    }

    @Test func singRangeKeepsDisplayContainingSing() {
        let r = LineTimeEditor.singRange(desiredStart: 2, desiredEnd: 3,
                                         displayStart: 2.5, displayEnd: 3.5,
                                         duration: 30)
        #expect(r.displayStart <= r.singStart + 1e-9)
        #expect(r.displayEnd >= r.singEnd - 1e-9)
        #expect(r.singEnd > r.singStart)
    }

    @Test func displayEditNeverMergesIntoSingTimes() {
        let r = LineTimeEditor.displayRange(desiredStart: 1, desiredEnd: 4,
                                            singStart: 2, singEnd: 3, duration: 30)
        #expect(r.displayStart == 1)
        #expect(r.displayEnd == 4)
        #expect(r.singStart == 2, "改可见时间不得合并/覆盖扫色时间")
        #expect(r.singEnd == 3)
    }
}

// MARK: - 样式改动不影响文案 / Ruby / 时间

@Suite struct StyleIsolationP0Tests {

    @Test func styleChangeDoesNotTouchContentRubyOrTiming() {
        var project = KaraProject()
        var line = LyricLine(order: 1, lane: .upper, displayText: "勝ち筋",
                             displayStart: 1, singStart: 2, singEnd: 3, displayEnd: 4)
        var token = LyricToken(surface: "勝ち筋", reading: "かちすじ",
                               sourceStart: 0, sourceLength: 3)
        token.setRubyOverride(surfaceStart: 2, surfaceLength: 1, reading: "すぎ")
        line.tokens = [token]
        project.lyricLines = [line]
        let before = project.lyricLines[0]

        project.style.fontSize = 99
        project.style.fontName = "Helvetica Neue"
        project.style.strokeWidth = 3
        project.style.alignment = .leading
        project.style.lineGap = 42

        #expect(project.lyricLines[0].displayText == before.displayText)
        #expect(project.lyricLines[0].tokens == before.tokens)
        #expect(project.lyricLines[0].displayStart == before.displayStart)
        #expect(project.lyricLines[0].singStart == before.singStart)
        #expect(project.lyricLines[0].singEnd == before.singEnd)
        #expect(project.lyricLines[0].displayEnd == before.displayEnd)
    }
}

// MARK: - 旧工程 Codable 兼容

@Suite struct RubyCodableCompatTests {

    @Test func oldTokenWithoutRubyOverridesDecodesAsNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","surface":"世界","reading":"せかい","morae":[],
         "sourceStart":0,"sourceLength":2}
        """
        let token = try JSONDecoder().decode(LyricToken.self, from: Data(json.utf8))
        #expect(token.rubyOverrides == nil)
        #expect(token.needsRuby)
        #expect(token.sanitizedRubyOverrides().isEmpty)
    }

    @Test func rubyOverridesRoundTripLosslessly() throws {
        var token = LyricToken(surface: "勝ち筋", reading: "かちすじ")
        token.setRubyOverride(surfaceStart: 0, surfaceLength: 1, reading: "かつ")
        token.setRubyOverride(surfaceStart: 2, surfaceLength: 1, reading: "")

        let data = try JSONEncoder().encode(token)
        let back = try JSONDecoder().decode(LyricToken.self, from: data)
        #expect(back.sanitizedRubyOverrides().count == 2)
        #expect(back.manualRubyOverrides().map(\.reading) == ["かつ"])
        #expect(back.suppressedRubyStarts() == [2])
    }

    @Test func oldLineWithoutLaneManualDecodesWithDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","order":1,"lane":"upper","displayText":"x",
         "displayStart":0,"singStart":0.5,"singEnd":1,"displayEnd":2,"tokens":[],
         "confidence":0.5,"needsReview":true}
        """
        let line = try JSONDecoder().decode(LyricLine.self, from: Data(json.utf8))
        #expect(!line.laneIsManual)
        #expect(line.layer == 0)
    }

    @Test func projectWithOverridesAndManualLaneRoundTrips() throws {
        var project = KaraProject()
        var line = LyricLine(order: 1, lane: .lower, laneIsManual: true, layer: 2,
                             displayText: "勝ち筋",
                             displayStart: 0, singStart: 1, singEnd: 2, displayEnd: 3)
        var token = LyricToken(surface: "勝ち筋", reading: "かちすじ",
                               sourceStart: 0, sourceLength: 3)
        token.setRubyOverride(surfaceStart: 2, surfaceLength: 1, reading: "すぎ")
        line.tokens = [token]
        project.lyricLines = [line]

        let data = try ProjectStore.encode(project)
        let back = try ProjectStore.decode(data)
        #expect(back.lyricLines[0].lane == .lower)
        #expect(back.lyricLines[0].laneIsManual)
        #expect(back.lyricLines[0].layer == 2)
        #expect(back.lyricLines[0].tokens[0].manualRubyOverrides().first?.reading == "すぎ")
    }
}
