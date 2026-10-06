import Testing
import Foundation
@testable import MaGiKaraKit

/// 走轨整体偏晚的修正：Yohane 起音补偿 + 全部歌词整体平移。
@Suite struct OnsetShiftTests {
    private func token(_ s: String, _ times: [(Double, Double)]) -> LyricToken {
        var t = LyricToken(surface: s, reading: s)
        t.morae = times.map { MoraTiming(mora: "あ", start: $0.0, end: $0.1) }
        return t
    }

    @Test func yohaneCompensationMovesSweepEarlier() {
        let line = AlignedLyricLine(id: UUID(), order: 1, singStart: 10, singEnd: 11,
                                    confidence: 0.5,
                                    tokens: [token("はな", [(10, 10.5), (10.5, 11)])])
        let c = LocalYohaneForcedAligner.compensateOnsetDelay(line)
        let d = LocalYohaneForcedAligner.onsetDelayCompensation
        #expect(abs(c.singStart - (10 - d)) < 1e-9)
        #expect(abs(c.singEnd - (11 - d)) < 1e-9)
        #expect(abs(c.tokens[0].morae[0].start - (10 - d)) < 1e-9)
        #expect(abs(c.tokens[0].morae[1].end - (11 - d)) < 1e-9)
    }

    @Test func yohaneCompensationNeverGoesBelowZero() {
        let line = AlignedLyricLine(id: UUID(), order: 1, singStart: 0.05, singEnd: 1,
                                    confidence: 0.5, tokens: [token("は", [(0.05, 1)])])
        let c = LocalYohaneForcedAligner.compensateOnsetDelay(line)
        #expect(c.singStart == 0)
        #expect(c.tokens[0].morae[0].start == 0)
    }

    @Test func shiftAllLinesMovesEverythingAndClampsAtZero() {
        let a = LyricLine(order: 1, lane: .upper, displayText: "はな",
                          displayStart: 0.1, singStart: 1, singEnd: 2, displayEnd: 2.5,
                          tokens: [token("はな", [(1, 1.5), (1.5, 2)])])
        let b = LyricLine(order: 2, lane: .lower, displayText: "そら",
                          displayStart: 2, singStart: 3, singEnd: 4, displayEnd: 4.5,
                          tokens: [token("そら", [(3, 3.5), (3.5, 4)])])
        var project = KaraProject(duration: 10, title: "t", lyricLines: [a, b])

        #expect(abs(project.shiftAllLines(by: 0.05) - 0.05) < 1e-9)
        #expect(abs(project.lyricLines[1].singStart - 3.05) < 1e-9)
        #expect(abs(project.lyricLines[1].tokens[0].morae[0].start - 3.05) < 1e-9)

        // 最早显示起点是 0.15，只能再提前 0.15
        let applied = project.shiftAllLines(by: -1)
        #expect(abs(applied + 0.15) < 1e-9)
        #expect(abs(project.lyricLines[0].displayStart) < 1e-9)
        #expect(abs(project.lyricLines[0].tokens[0].morae[0].start - 0.9) < 1e-9)
        #expect(project.shiftAllLines(by: -0.05) == 0)
    }
}
