import Testing
@testable import MaGiKaraKit

/// 数据模型与四段时间约束（RD §4 / §5 / §14 验收清单）
@Suite struct LyricModelTests {

    @Test func laneAlternation() {
        #expect(ScreenLane.lane(forOrder: 1) == .upper)
        #expect(ScreenLane.lane(forOrder: 2) == .lower)
        #expect(ScreenLane.lane(forOrder: 3) == .upper)
        #expect(ScreenLane.lane(forOrder: 20) == .lower)
    }

    @Test func lineDefaultsToLaneFromOrder() {
        #expect(LyricLine(order: 5).lane == .upper)
        #expect(LyricLine(order: 6).lane == .lower)
    }

    @Test func fourTimeOrderIsEnforced() {
        // 故意给一个非法顺序：displayStart 晚于 singStart，displayEnd 早于 singEnd
        var line = LyricLine(order: 1,
                             displayStart: 5.0,
                             singStart: 3.0,
                             singEnd: 1.0,
                             displayEnd: 0.5)
        #expect(!line.hasValidTiming)
        line.enforceInvariants()
        #expect(line.hasValidTiming)
        #expect(line.displayStart <= line.singStart)
        #expect(line.singStart < line.singEnd)
        #expect(line.singEnd <= line.displayEnd)
    }

    @Test func zeroLengthSingRangeGetsMinimumDuration() {
        var line = LyricLine(order: 1, displayStart: 1, singStart: 2, singEnd: 2, displayEnd: 3)
        #expect(!line.hasValidTiming)
        line.enforceInvariants()
        #expect(line.hasValidTiming)
        #expect(line.singDuration >= LyricLine.minimumSingDuration - 1e-9)
    }

    @Test func shiftMovesAllFourTimesAndMorae() {
        var line = LyricLine(order: 1, displayStart: 1, singStart: 2, singEnd: 3, displayEnd: 4)
        let mora = MoraTiming(mora: "せ", start: 2.0, end: 2.5, confidence: 0.9)
        line.tokens = [LyricToken(surface: "世", reading: "せ", morae: [mora])]

        line.shift(by: 10)

        #expect(abs(line.displayStart - 11) < 1e-9)
        #expect(abs(line.singStart - 12) < 1e-9)
        #expect(abs(line.singEnd - 13) < 1e-9)
        #expect(abs(line.displayEnd - 14) < 1e-9)
        // 音拍必须同步平移（RD §9.3）
        #expect(abs(line.tokens[0].morae[0].start - 12.0) < 1e-9)
        #expect(abs(line.tokens[0].morae[0].end - 12.5) < 1e-9)
    }

    @Test func rescaleMoraeKeepsDurationClosure() {
        var line = LyricLine(order: 1, displayStart: 0, singStart: 2, singEnd: 4, displayEnd: 5)
        line.tokens = [LyricToken(surface: "世界", reading: "せかい", morae: [
            MoraTiming(mora: "せ", start: 2.0, end: 2.6),
            MoraTiming(mora: "か", start: 2.6, end: 3.2),
            MoraTiming(mora: "い", start: 3.2, end: 4.0),
        ])]

        let before = line.allMorae.reduce(0.0) { $0 + ($1.end - $1.start) }
        #expect(abs(before - line.singDuration) < 1e-6)

        line.rescaleMorae(from: 2.0...4.0, to: 5.0...9.0)
        let after = line.allMorae.reduce(0.0) { $0 + ($1.end - $1.start) }
        #expect(abs(after - 4.0) < 1e-6)
        #expect(abs(line.allMorae.first!.start - 5.0) < 1e-6)
        #expect(abs(line.allMorae.last!.end - 9.0) < 1e-6)
    }

    @Test func rubyOnlyForKanjiBearingTokens() {
        let kanji = LyricToken(surface: "世界", reading: "せかい", sourceStart: 0, sourceLength: 2)
        let kana = LyricToken(surface: "そう", reading: nil, sourceStart: 0, sourceLength: 2)
        let kanjiNoReading = LyricToken(surface: "世界", reading: nil, sourceStart: 0, sourceLength: 2)

        #expect(kanji.needsRuby)
        #expect(!kana.needsRuby)          // 纯假名不生成假名附轨（RD §5.1）
        #expect(!kanjiNoReading.needsRuby)
    }

    @Test func sweepProgressIsUniformAcrossLine() {
        // 本轮改为整句匀速：音拍之间的停顿不再让进度停住，
        // 进度只由 singStart/singEnd 决定。
        var line = LyricLine(order: 1, displayStart: -1, singStart: 0, singEnd: 4, displayEnd: 5)
        line.tokens = [LyricToken(surface: "あい", reading: nil, morae: [
            MoraTiming(mora: "あ", start: 0, end: 1),
            MoraTiming(mora: "い", start: 3, end: 4),   // 中间有停顿
        ])]

        #expect(abs(line.sweepProgress(at: -0.5) - 0) < 1e-9)
        #expect(abs(line.sweepProgress(at: 0.5) - 0.125) < 1e-6)
        #expect(abs(line.sweepProgress(at: 2.0) - 0.5) < 1e-6)
        #expect(abs(line.sweepProgress(at: 3.5) - 0.875) < 1e-6)
        #expect(abs(line.sweepProgress(at: 10) - 1) < 1e-9)
    }

    @Test func previewSlotReplacementRule() {
        // 唱完的句子不能立刻消失，要留到同槽位下下句出现（RD §4）
        var project = KaraProject()
        let l1 = LyricLine(order: 1, lane: .upper, displayStart: 0, singStart: 1, singEnd: 2, displayEnd: 5)
        let l2 = LyricLine(order: 2, lane: .lower, displayStart: 0, singStart: 1, singEnd: 2, displayEnd: 5)
        let l3 = LyricLine(order: 3, lane: .upper, displayStart: 5, singStart: 6, singEnd: 7, displayEnd: 10)
        let l4 = LyricLine(order: 4, lane: .lower, displayStart: 5, singStart: 6, singEnd: 7, displayEnd: 10)
        project.lyricLines = [l1, l2, l3, l4]

        // t=3：第 1、2 句都已唱完（singEnd=2），但仍停留在各自槽位上
        #expect(project.activeLine(in: .upper, at: 3)?.order == 1)
        #expect(project.activeLine(in: .lower, at: 3)?.order == 2)
        // 任意时刻上下两行同时可见，符合「当前句 + 下一句」
        #expect(project.previewLines(at: 3).upper != nil)
        #expect(project.previewLines(at: 3).lower != nil)

        // t=6：同槽位的下下句替换掉旧句
        #expect(project.activeLine(in: .upper, at: 6)?.order == 3)
        #expect(project.activeLine(in: .lower, at: 6)?.order == 4)
    }
}
