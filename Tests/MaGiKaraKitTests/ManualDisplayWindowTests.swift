import Foundation
import Testing
@testable import MaGiKaraKit

/// 用户手动修剪的显示时间不能被自动算法覆盖。
@Suite struct ManualDisplayWindowTests {

    /// 同一行（上行）连续两句：第 1 句 10–14 秒，第 2 句 20–24 秒。
    /// 自动算法会让第 1 句一直保持到第 2 句出现（约 19.5 秒）。
    private func twoLinesInSameLane() -> [LyricLine] {
        var a = LyricLine(order: 1, lane: .upper, displayText: "A",
                          displayStart: 9.5, singStart: 10, singEnd: 14, displayEnd: 19.5)
        var b = LyricLine(order: 3, lane: .upper, displayText: "B",
                          displayStart: 19.5, singStart: 20, singEnd: 24, displayEnd: 25)
        a.laneIsManual = true
        b.laneIsManual = true
        return [a, b]
    }

    @Test func autoWindowHoldsLineUntilTheNextOneReplacesIt() {
        var lines = twoLinesInSameLane()
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let first = lines.first { $0.order == 1 }!
        #expect(first.displayEnd > 19, "自动规则：唱完后保持到同槽位下一句出现，实际 \(first.displayEnd)")
    }

    @Test func trimmedDisplayEndSurvivesRefresh() throws {
        var lines = twoLinesInSameLane()
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let index = try #require(lines.firstIndex { $0.order == 1 })

        // 用户把色块右边缘拖短到 16 秒
        let trimmed = try #require(LineEditor.trimmed(lines[index], edge: .displayEnd, to: 16))
        lines[index] = trimmed
        #expect(abs(lines[index].displayEnd - 16) < 1e-6)

        // 拖动结束后 App 会刷新显示窗口——用户手动的结果必须保留
        DisplayScheduler.applyDisplayWindows(to: &lines)
        #expect(abs(lines[index].displayEnd - 16) < 1e-6,
                "手动拖短后文字应在 16 秒消失，实际 \(lines[index].displayEnd)")
    }

    @Test func trimmedDisplayStartSurvivesRefresh() throws {
        var lines = twoLinesInSameLane()
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let index = try #require(lines.firstIndex { $0.order == 3 })

        // 用户把第 2 句的出现时间推迟到 19.8 秒（演唱 20 秒前仅保留 0.2 秒提前量）
        let trimmed = try #require(LineEditor.trimmed(lines[index], edge: .displayStart, to: 19.8))
        lines[index] = trimmed
        DisplayScheduler.applyDisplayWindows(to: &lines)
        #expect(abs(lines[index].displayStart - 19.8) < 1e-6,
                "手动修剪的出现时间不应被自动提前量覆盖，实际 \(lines[index].displayStart)")
    }

    @Test func movingASegmentKeepsItsManualWindowShape() throws {
        var lines = twoLinesInSameLane()
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let index = try #require(lines.firstIndex { $0.order == 1 })
        lines[index] = try #require(LineEditor.trimmed(lines[index], edge: .displayEnd, to: 16))
        let length = lines[index].displayEnd - lines[index].displayStart

        // 整体向后平移 1 秒：色块长度不变，仍保持用户设定的形状
        lines[index] = LineEditor.moved(lines[index], by: 1)
        DisplayScheduler.applyDisplayWindows(to: &lines)
        #expect(abs((lines[index].displayEnd - lines[index].displayStart) - length) < 1e-6)
    }

    @Test func trimmingSingEdgesStillFollowsAutoDisplayWindow() throws {
        var lines = twoLinesInSameLane()
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let index = try #require(lines.firstIndex { $0.order == 1 })

        // 只调整「演唱结束」：没有手动指定显示结束，所以仍按自动规则保持到下一句
        lines[index] = try #require(LineEditor.trimmed(lines[index], edge: .singEnd, to: 12))
        DisplayScheduler.applyDisplayWindows(to: &lines)
        #expect(lines[index].displayEnd > 19)
    }

    @Test func manualFlagsRoundTripAndDefaultToFalseForOldProjects() throws {
        var line = LyricLine(order: 1, displayText: "A", displayStart: 0, singStart: 1, singEnd: 2, displayEnd: 3)
        line.displayEndIsManual = true
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(LyricLine.self, from: data)
        #expect(decoded.displayEndIsManual)

        // 旧工程没有这两个字段：必须解码成 false
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "displayStartIsManual")
        json.removeValue(forKey: "displayEndIsManual")
        let old = try JSONDecoder().decode(LyricLine.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.displayStartIsManual && !old.displayEndIsManual)
    }
}

/// 走轨（扫色区间）的平移与「定住显示窗口」。
@Suite struct SweepEditingTests {

    private func block() -> LyricLine {
        var line = LyricLine(order: 1, lane: .upper, displayText: "A",
                             displayStart: 10, singStart: 11, singEnd: 13, displayEnd: 16)
        line.tokens = [LyricToken(surface: "A", reading: nil, morae: [
            MoraTiming(mora: "あ", start: 11, end: 12),
            MoraTiming(mora: "い", start: 12, end: 13),
        ], sourceStart: 0, sourceLength: 1)]
        return line
    }

    @Test func sweepMoveKeepsDurationAndShiftsMorae() {
        let moved = LineEditor.sweepMoved(block(), by: 1.5)
        #expect(abs(moved.singStart - 12.5) < 1e-9)
        #expect(abs(moved.singEnd - 14.5) < 1e-9)
        #expect(abs((moved.singEnd - moved.singStart) - 2) < 1e-9, "走轨时长（速度）不变")
        // 色块（画面歌词的存在时间）不动
        #expect(moved.displayStart == 10 && moved.displayEnd == 16)
        // 音拍跟着走轨平移
        let morae = moved.tokens[0].morae
        #expect(abs(morae[0].start - 12.5) < 1e-6 && abs(morae[1].end - 14.5) < 1e-6)
    }

    @Test func sweepCannotLeaveTheBlock() {
        let late = LineEditor.sweepMoved(block(), by: 100)
        #expect(abs(late.singEnd - 16) < 1e-9 && abs(late.singStart - 14) < 1e-9)
        let early = LineEditor.sweepMoved(block(), by: -100)
        #expect(abs(early.singStart - 10) < 1e-9 && abs(early.singEnd - 12) < 1e-9)
    }

    @Test func sweepMoveFreezesTheDisplayWindowAgainstAutoScheduling() {
        var lines = [block(),
                     LyricLine(order: 3, lane: .upper, displayText: "B",
                               displayStart: 19.5, singStart: 20, singEnd: 22, displayEnd: 23)]
        lines[1].laneIsManual = true
        lines[0].laneIsManual = true
        lines[0] = LineEditor.sweepMoved(lines[0], by: 1)
        DisplayScheduler.applyDisplayWindows(to: &lines)
        let first = lines.first { $0.order == 1 }!
        #expect(first.displayStart == 10 && first.displayEnd == 16,
                "色块到哪里画面歌词就到哪里，不被自动算法改动：\(first.displayStart)–\(first.displayEnd)")
    }

    @Test func freezingMarksBothEdgesManual() {
        let frozen = LineEditor.freezingDisplayWindow(block())
        #expect(frozen.displayStartIsManual && frozen.displayEndIsManual)
    }

    /// 画面上同一时刻显示哪句，与色块是否覆盖这一刻完全一致。
    @Test func previewVisibilityMatchesTheBlockExtent() {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 30)
        var line = block()
        line.displayEndIsManual = true
        line.displayEnd = 14   // 色块右边缘在 14 秒
        project.lyricLines = [line]
        #expect(project.previewLines(at: 13.9).upper != nil)
        #expect(project.previewLines(at: 14.1).upper == nil, "色块之外画面不应再有这句歌词")
    }
}
