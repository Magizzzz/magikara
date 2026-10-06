import Testing
import Foundation
@testable import MaGiKaraKit

/// 倒计时：时间线「倒计时」轨道上的色块。预览与导出共用 `KaraokeCountdown` 的全部计算。
@Suite struct KaraokeCountdownTests {

    private func project(firstDisplayStart: Double = 10, lane: ScreenLane = .upper) -> KaraProject {
        var p = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 60)
        p.lyricLines = [LyricLine(order: 1, lane: lane, displayText: "A",
                                  displayStart: firstDisplayStart,
                                  singStart: firstDisplayStart + 0.5,
                                  singEnd: firstDisplayStart + 3,
                                  displayEnd: firstDisplayStart + 4)]
        return p
    }

    // MARK: 自动倒计时

    @Test func autoItemEndsWhenTheFirstLineAppears() throws {
        let item = try #require(KaraokeCountdown.autoItem(for: project(firstDisplayStart: 10)))
        #expect(item.start == 7 && item.end == 10 && item.isAuto)
    }

    @Test func autoItemIsClippedAtZeroAndSkippedWhenThereIsNoRoom() throws {
        let near = try #require(KaraokeCountdown.autoItem(for: project(firstDisplayStart: 1.2)))
        #expect(near.start == 0 && abs(near.end - 1.2) < 1e-9)
        #expect(KaraokeCountdown.autoItem(for: project(firstDisplayStart: 0)) == nil, "第一句从 0 秒开始，没有空间")
        #expect(KaraokeCountdown.autoItem(for: project(firstDisplayStart: 0.1)) == nil, "不足最短时长也不放")
        #expect(KaraokeCountdown.autoItem(for: KaraProject()) == nil, "没有歌词不放")
    }

    @Test func syncCreatesTheOpeningCountdownOnceAndFollowsTheFirstLine() throws {
        var p = project(firstDisplayStart: 10)
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1)
        let id = p.countdowns[0].id

        // 第一句往后挪：自动倒计时跟着走，而不是再多出一个
        p.lyricLines[0].displayStart = 20
        p.lyricLines[0].singStart = 20.5
        p.lyricLines[0].singEnd = 23
        p.lyricLines[0].displayEnd = 24
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1 && p.countdowns[0].id == id)
        #expect(p.countdowns[0].start == 17 && p.countdowns[0].end == 20)
    }

    @Test func syncNeverTouchesUserEditedCountdownsAndNeverBringsBackADeletedOne() {
        var p = project(firstDisplayStart: 10)
        p.syncOpeningCountdown()
        // 用户手动改过：不再是自动的，也不会再补一个
        p.countdowns[0].isAuto = false
        p.countdowns[0].start = 5
        p.countdownAutoDismissed = true
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1 && p.countdowns[0].start == 5)

        // 用户删除：不会被自动补回
        p.countdowns.removeAll()
        p.syncOpeningCountdown()
        #expect(p.countdowns.isEmpty)
    }

    /// 回归：拖动期间每一帧传入的都是「拖动开始时的快照」（那时是自动的）。
    /// 曾经第二帧起把它改回了自动，拖好的位置下次同步就被覆盖。
    @Test func draggingKeepsTheCountdownManualEvenWhenEveryFrameCarriesTheStaleAutoSnapshot() throws {
        var p = project(firstDisplayStart: 10)
        p.syncOpeningCountdown()
        let snapshot = try #require(p.countdowns.first)
        #expect(snapshot.isAuto)

        for step in 1...5 {
            var frame = snapshot                       // 每一帧都从旧快照出发
            frame.start = snapshot.start + Double(step) * 0.2
            frame.end = snapshot.end + Double(step) * 0.2
            p.replaceCountdown(frame)
        }
        let moved = try #require(p.countdowns.first)
        #expect(!moved.isAuto, "拖动结束后必须是手动的，不能被快照改回自动")
        #expect(p.countdownAutoDismissed)
        #expect(abs(moved.start - 8.0) < 1e-9 && abs(moved.end - 11.0) < 1e-9)

        // 之后第一句有任何变化触发同步，拖好的位置都不能被改回
        p.lyricLines[0].displayStart = 12
        p.lyricLines[0].singStart = 12.5
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1 && abs(p.countdowns[0].start - 8.0) < 1e-9)
    }

    @Test func replaceKeepsTheMinimumDurationAndNeverGoesBelowZero() throws {
        var p = project(firstDisplayStart: 10)
        p.syncOpeningCountdown()
        var item = try #require(p.countdowns.first)
        item.start = -5
        item.end = -4.9
        p.replaceCountdown(item)
        let fixed = try #require(p.countdowns.first)
        #expect(fixed.start == 0)
        #expect(fixed.duration >= CountdownItem.minimumDuration - 1e-9)
    }

    @Test func syncRemovesTheAutoCountdownWhenTheFirstLineMovesToTheStart() {
        var p = project(firstDisplayStart: 10)
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1)
        p.lyricLines[0].displayStart = 0
        p.lyricLines[0].singStart = 0.5
        p.syncOpeningCountdown()
        #expect(p.countdowns.isEmpty)
        // 第一句重新挪开后又会出现
        p.lyricLines[0].displayStart = 8
        p.lyricLines[0].singStart = 8.5
        p.syncOpeningCountdown()
        #expect(p.countdowns.count == 1)
    }

    // MARK: 状态计算

    @Test func activeItemFollowsTheBlockAndTheGlobalSwitch() {
        var p = project()
        p.countdowns = [CountdownItem(start: 7, end: 10)]
        #expect(KaraokeCountdown.activeItem(in: p, at: 6.99) == nil)
        #expect(KaraokeCountdown.activeItem(in: p, at: 7.0) != nil)
        #expect(KaraokeCountdown.activeItem(in: p, at: 9.99) != nil)
        #expect(KaraokeCountdown.activeItem(in: p, at: 10.0) == nil)
        p.style.countdownEnabled = false
        #expect(KaraokeCountdown.activeItem(in: p, at: 8) == nil)
    }

    @Test func fillProgressSweepsEachDotInItsOwnSlice() {
        let item = CountdownItem(start: 0, end: 3)
        // 3 个点，每个占 1 秒
        func p(_ dot: Int, _ t: Double) -> Double {
            KaraokeCountdown.fillProgress(dot: dot, dotCount: 3, item: item, at: t)
        }
        #expect(p(0, 0.5) == 0.5 && p(1, 0.5) == 0 && p(2, 0.5) == 0)
        #expect(p(0, 1.0) == 1 && p(1, 1.5) == 0.5 && p(2, 1.5) == 0)
        #expect(p(2, 2.5) == 0.5)
        #expect(p(0, 3) == 1 && p(1, 3) == 1 && p(2, 3) == 1, "色块走完时全部填满")
        #expect(p(0, -1) == 0)
    }

    @Test func fillProgressWorksForAnyDotCountAndDuration() {
        let item = CountdownItem(start: 10, end: 14)
        // 4 个点 × 1 秒；第 3 个点（下标 2）在 12–13 秒填满
        #expect(KaraokeCountdown.fillProgress(dot: 2, dotCount: 4, item: item, at: 12.5) == 0.5)
        #expect(KaraokeCountdown.fillProgress(dot: 3, dotCount: 4, item: item, at: 12.9) == 0)
    }

    @Test func dwindleKeepsAtLeastOneDotUntilTheEnd() {
        let item = CountdownItem(start: 0, end: 3)
        func lit(_ t: Double) -> Int { KaraokeCountdown.litDots(dotCount: 3, item: item, at: t) }
        #expect(lit(0.1) == 3 && lit(1.1) == 2 && lit(2.1) == 1 && lit(2.99) == 1)
        let segments = KaraokeCountdown.dwindleSegments(dotCount: 3, item: item)
        #expect(segments == [.init(start: 0, end: 1, dots: 3),
                             .init(start: 1, end: 2, dots: 2),
                             .init(start: 2, end: 3, dots: 1)])
    }

    // MARK: 位置

    @Test func countdownIsDrawnInTheLaneOfTheNextLine() {
        var p = project(firstDisplayStart: 10, lane: .lower)
        p.lyricLines.append(LyricLine(order: 2, lane: .upper, displayText: "B",
                                      displayStart: 30, singStart: 30.5, singEnd: 33, displayEnd: 34))
        let opening = CountdownItem(start: 7, end: 10)
        let interlude = CountdownItem(start: 27, end: 30)
        #expect(KaraokeCountdown.lane(for: opening, in: p) == .lower)
        #expect(KaraokeCountdown.lane(for: interlude, in: p) == .upper, "间奏后的倒计时画在下一句所在的行")
        #expect(KaraokeCountdown.lane(for: CountdownItem(start: 50, end: 55), in: p) == .lower, "没有下一句时退回第一句")
    }

    // MARK: 数据与兼容

    @Test func itemKeepsAMinimumDuration() {
        let item = CountdownItem(start: 5, end: 5.01)
        #expect(item.duration >= CountdownItem.minimumDuration - 1e-9)
    }

    @Test func styleDefaultsAndResolvedColorsFollowTheLyricColors() {
        var style = SubtitleStyle()
        #expect(style.countdownEnabled)
        #expect(style.countdown.mode == .fill && style.countdown.dotCount == 3)
        #expect(style.countdownUnsungColor == style.unsungColor)
        #expect(style.countdownSweepColor == style.sungColor)
        // 单独设置后不再跟随歌词
        let custom = RGBAColor(1, 0.2, 0.2, 1)
        style.countdown.sweepColor = custom
        #expect(style.countdownSweepColor == custom)
    }

    @Test func dotCountIsClampedToTheSupportedRange() {
        #expect(CountdownStyle(dotCount: 0).dotCount == 1)
        #expect(CountdownStyle(dotCount: 99).dotCount == 6)
    }

    @Test func oldProjectsWithoutCountdownFieldsStillDecode() throws {
        var p = project()
        p.syncOpeningCountdown()
        let data = try ProjectStore.encode(p)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "countdowns")
        json.removeValue(forKey: "countdownAutoDismissed")
        var style = try #require(json["style"] as? [String: Any])
        style.removeValue(forKey: "countdown")
        style.removeValue(forKey: "countdownEnabled")
        json["style"] = style
        let old = try ProjectStore.decode(JSONSerialization.data(withJSONObject: json))
        // 旧工程的预览里本来就隐含开头倒计时：载入时变成时间线上的显式色块
        #expect(old.countdowns.count == 1 && old.countdowns[0].isAuto && !old.countdownAutoDismissed)
        #expect(old.countdowns[0].end == p.lyricLines[0].displayStart)
        #expect(old.style.countdownEnabled && old.style.countdown == CountdownStyle())
    }

    @Test func aDeletedOpeningCountdownIsNotBroughtBackOnLoad() throws {
        var p = project()
        p.syncOpeningCountdown()
        p.countdowns.removeAll()
        p.countdownAutoDismissed = true
        let back = try ProjectStore.decode(ProjectStore.encode(p))
        #expect(back.countdowns.isEmpty, "用户删掉的倒计时，下次打开不能被悄悄补回")
    }

    @Test func countdownsSurviveSaveAndLoad() throws {
        var p = project()
        p.syncOpeningCountdown()
        p.style.countdown.mode = .dwindle
        p.style.countdown.dotCount = 4
        p.style.countdown.sweepColor = RGBAColor(0.1, 0.9, 0.3, 1)
        let back = try ProjectStore.decode(ProjectStore.encode(p))
        #expect(back.countdowns == p.countdowns)
        #expect(back.style.countdown == p.style.countdown)
    }
}

/// 倒计时的导出（ASS）。
@Suite struct KaraokeCountdownExportTests {

    private func project(items: [CountdownItem] = [CountdownItem(start: 7, end: 10)],
                         mode: CountdownMode = .fill,
                         dots: Int = 3) -> KaraProject {
        var p = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 60)
        p.lyricLines = [LyricLine(order: 1, lane: .upper, displayText: "A",
                                  displayStart: 10, singStart: 10.5, singEnd: 13, displayEnd: 14)]
        p.countdowns = items
        p.style.setLineLayout(.center)      // 这组测试检查「居中」时的几何；靠左 / 靠右见下面的专门测试
        p.style.countdown.mode = mode
        p.style.countdown.dotCount = dots
        return p
    }

    private func events(_ ass: String) -> [String] {
        ass.split(separator: "\n").map(String.init).filter { $0.contains(",Countdown,,") }
    }

    /// 事件里「纯等待」的空 `{\k数字}` 音节（不含带文字的 `{\kf数字}`）。
    private func waits(_ event: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"\{\\k(\d+)\}"#)
        let range = NSRange(event.startIndex..., in: event)
        return regex.matches(in: event, range: range).compactMap { m in
            Range(m.range(at: 1), in: event).flatMap { Int(event[$0]) }
        }
    }

    private func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    @Test func fillModeDrawsOneKaraokeSweptDotEventPerDot() {
        let list = events(AssExporter.export(project: project()))
        #expect(list.count == 3)
        let layer = AssExporter.countdownLayer
        #expect(list.allSatisfy { $0.hasPrefix("Dialogue: \(layer),0:00:07.00,0:00:10.00,Countdown") })
        // 圆点是文字「●」，导出不含绘图命令
        #expect(list.allSatisfy { $0.hasSuffix("●") && !$0.contains("\\p1") })
        // 每个点自己的 \kf 时长 = 总时长 / 3 = 100 厘秒；第 2、3 个点前面用空 \k 等待
        #expect(list.allSatisfy { $0.contains("\\kf100}") })
        #expect(waits(list[0]) == [] && waits(list[1]) == [100] && waits(list[2]) == [200])
        // 走轨色是 \1c，未走轨色是 \2c（ASS 标准：\2c → \1c）
        let style = SubtitleStyle()
        #expect(list.allSatisfy {
            $0.contains("\\1c\(style.sungColor.assColor)") && $0.contains("\\2c\(style.unsungColor.assColor)")
        })
    }

    @Test func fillModeUsesTheCustomSweepAndBaseColors() {
        var p = project()
        p.style.countdown.sweepColor = RGBAColor(1, 0, 0, 1)
        p.style.countdown.unsungColor = RGBAColor(0, 0, 1, 1)
        let list = events(AssExporter.export(project: p))
        #expect(list.allSatisfy { $0.contains("\\1c&H000000FF") && $0.contains("\\2c&H00FF0000") })
    }

    @Test func dotCountAndLayoutAreCenteredAndEvenlySpaced() {
        let list = events(AssExporter.export(project: project(dots: 4)))
        #expect(list.count == 4)
        let xs = list.compactMap { event -> Double? in
            guard let r = event.range(of: "\\pos("),
                  let end = event[r.upperBound...].firstIndex(of: ",") else { return nil }
            return Double(event[r.upperBound..<end])
        }.sorted()
        #expect(xs.count == 4)
        let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 0.01 })
        #expect(abs((xs.first! + xs.last!) / 2 - 960) < 0.01, "整体以画面水平中心为中点")
    }

    /// 圆点整体和歌词一样按所在行的对齐方式放置：上行靠左、下行靠右时，圆点也贴着左 / 右边距。
    @Test func dotsFollowTheLaneAlignmentOfTheNextLine() throws {
        func dotXs(firstLane: ScreenLane) throws -> [Double] {
            var p = project()
            p.style.setLineLayout(.staggered)
            p.lyricLines[0].lane = firstLane
            p.lyricLines[0].laneIsManual = true
            return try events(AssExporter.export(project: p)).map { event in
                let r = try #require(event.range(of: "\\pos("))
                let end = try #require(event[r.upperBound...].firstIndex(of: ","))
                return try #require(Double(event[r.upperBound..<end]))
            }.sorted()
        }
        let style = project().style
        let d = KaraokeCountdown.dotDiameter(style: style)

        let upper = try dotXs(firstLane: .upper)        // 上行靠左
        #expect(abs((upper.first! - d / 2) - 140) < 0.1, "最左的点贴着左边距，实际左缘 \(upper.first! - d / 2)")

        let lower = try dotXs(firstLane: .lower)        // 下行靠右
        #expect(abs((lower.last! + d / 2) - (1920 - 140)) < 0.1, "最右的点贴着右边距，实际右缘 \(lower.last! + d / 2)")
    }

    @Test func positionOffsetIsApplied() {
        var p = project()
        let base = events(AssExporter.export(project: p))
        p.style.countdown.offsetX = 100
        p.style.countdown.offsetY = -40
        let moved = events(AssExporter.export(project: p))
        func pos(_ e: String) -> (Double, Double)? {
            guard let r = e.range(of: "\\pos("), let end = e[r.upperBound...].firstIndex(of: ")") else { return nil }
            let v = e[r.upperBound..<end].split(separator: ",").compactMap { Double($0) }
            return v.count == 2 ? (v[0], v[1]) : nil
        }
        let a = pos(base[0])!, b = pos(moved[0])!
        #expect(abs((b.0 - a.0) - 100) < 0.01 && abs((b.1 - a.1) + 40) < 0.01)
    }

    @Test func dwindleModeDrawsAllDotsPerSegmentWithTheRestFaded() {
        let list = events(AssExporter.export(project: project(mode: .dwindle)))
        #expect(list.count == 9, "3 段 × 3 个点")
        let layer = AssExporter.countdownLayer
        let last = list.filter { $0.hasPrefix("Dialogue: \(layer),0:00:09.00,0:00:10.00,Countdown") }
        #expect(last.count == 3 && last.filter { $0.contains("\\1a&H") }.count == 2)
        #expect(list.allSatisfy { !$0.contains("\\kf") })
    }

    @Test func everyCountdownBlockOnTheTrackIsExportedAtItsOwnTime() {
        let list = events(AssExporter.export(project: project(items: [
            CountdownItem(start: 7, end: 10),
            CountdownItem(start: 20, end: 24),
        ])))
        #expect(list.count == 6)
        #expect(list.contains { $0.hasPrefix("Dialogue: \(AssExporter.countdownLayer),0:00:20.00,0:00:24.00,") })
        // 倒计时块的结束不能晚于其后没有歌词的事实无关，但必须是合法区间
        let ends = list.compactMap { e -> Double? in
            seconds(e.split(separator: ",", maxSplits: 3).map(String.init)[2])
        }
        #expect(ends.count == 6)
    }

    @Test func disabledSwitchOrEmptyTrackMeansNothingIsExported() {
        var p = project()
        p.style.countdownEnabled = false
        #expect(events(AssExporter.export(project: p)).isEmpty)
        #expect(events(AssExporter.export(project: project(items: []))).isEmpty)
    }

    @Test func exportNeverContainsDrawingCommands() {
        let ass = AssExporter.export(project: project())
        #expect(!ass.contains("\\p1"))
    }
}
