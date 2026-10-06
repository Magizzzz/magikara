import Testing
import Foundation
@testable import MaGiKaraKit

@Suite struct TimelineSnapperTests {
    // 100 px/s：8 px 阈值 = 0.08 秒
    let pps = 100.0

    @Test func singleEdgeSnapsWithinThreshold() {
        let r = TimelineSnapper.snap(time: 5.05, candidates: [5.0, 6.0], pixelsPerSecond: pps)
        #expect(r.time == 5.0)
        #expect(r.target == 5.0)
    }

    @Test func outsideThresholdDoesNotSnap() {
        let r = TimelineSnapper.snap(time: 5.2, candidates: [5.0], pixelsPerSecond: pps)
        #expect(r.time == 5.2)
        #expect(r.target == nil)
    }

    @Test func thresholdScalesWithZoom() {
        // 缩小到 20 px/s 时 8 px = 0.4 秒，0.2 秒的距离就能吸住
        let r = TimelineSnapper.snap(time: 5.2, candidates: [5.0], pixelsPerSecond: 20)
        #expect(r.target == 5.0)
    }

    @Test func movingBlockSnapsWhicheverEdgeIsClosest() {
        // 块 [2, 4]，原始位移 +0.97：右边缘到 4.97，离 5.0 最近，整体位移修正为 +1.0
        let r = TimelineSnapper.snap(edges: [2, 4], delta: 0.97, candidates: [3.05, 5.0], pixelsPerSecond: pps)
        #expect(abs(r.delta - 1.0) < 1e-9)
        #expect(r.target == 5.0)
    }

    @Test func picksNearestCandidate() {
        let r = TimelineSnapper.snap(time: 5.03, candidates: [4.98, 5.04], pixelsPerSecond: pps)
        #expect(r.target == 5.04)
    }

    @Test func candidatesExcludeDraggedItems() {
        let a = LyricLine(order: 1, lane: .upper, displayText: "あ",
                          displayStart: 1, singStart: 1.5, singEnd: 2, displayEnd: 2.5)
        let b = LyricLine(order: 2, lane: .lower, displayText: "い",
                          displayStart: 3, singStart: 3.5, singEnd: 4, displayEnd: 4.5)
        var project = KaraProject(duration: 10, title: "t", lyricLines: [a, b])
        project.countdowns = [CountdownItem(start: 0.2, end: 1.0)]
        let c = TimelineSnapper.candidates(project: project, excludingLine: a.id, playhead: 7)
        #expect(!c.contains(1.5))
        #expect(c.contains(3.5))
        #expect(c.contains(7))
        #expect(c.contains(0.2) && c.contains(1.0))
        #expect(c.contains(0))
    }

    @Test func nKeyTogglesSnappingButNotWhileTyping() {
        let cmd = TimelineKeyMapper.command(characters: "n", keyCode: 45,
                                            command: false, shift: false, option: false, control: false)
        #expect(cmd == .toggleSnapping)
        #expect(TimelineKeyMapper.shouldIgnore(.toggleSnapping, isTextEditing: true))
        #expect(TimelineKeyMapper.command(characters: "n", keyCode: 45,
                                          command: true, shift: false, option: false, control: false) == nil)
    }
}
