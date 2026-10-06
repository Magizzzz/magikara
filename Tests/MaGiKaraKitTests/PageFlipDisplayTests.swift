import Foundation
import Testing
@testable import MaGiKaraKit

/// 翻页式换行（ニコカラ 风格）：上下两行成对出现 / 消失，下行延后，页间留空白。
@Suite struct PageFlipDisplayTests {

    private let policy = DisplayPolicy(leadIn: 1.5, lastHoldOut: 1.2, adaptToGap: true,
                                       mode: .pageFlip, lowerLineDelay: 0.8,
                                       pageGap: 0.4, pageHoldOut: 0.5)

    private func lines(_ sing: [(Double, Double)]) -> [LyricLine] {
        sing.enumerated().map { index, t in
            LyricLine(order: index + 1, displayText: "L\(index + 1)",
                      displayStart: 0, singStart: t.0, singEnd: t.1, displayEnd: 0)
        }
    }

    private func applied(_ sing: [(Double, Double)], policy: DisplayPolicy? = nil) -> [LyricLine] {
        var l = lines(sing)
        DisplayScheduler.applyDisplayWindows(to: &l, policy: policy ?? self.policy)
        return l.sorted { $0.order < $1.order }
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    /// 三页（间隔宽松）：1+2、3+4、5+6
    private let relaxed: [(Double, Double)] = [(10, 13), (13.5, 16), (20, 23), (23.5, 26), (40, 43), (43.5, 46)]

    @Test func upperLineEntersLeadInBeforeSingingAndLowerLineEntersLater() {
        let r = applied(relaxed)
        #expect(close(r[0].displayStart, 8.5), "第一页：开唱前 1.5 秒进场，实际 \(r[0].displayStart)")
        #expect(close(r[1].displayStart, 9.3), "下行比上行晚 0.8 秒，实际 \(r[1].displayStart)")
        // 第三页（前面是很长的空档）：同样是开唱前 1.5 秒
        #expect(close(r[4].displayStart, 38.5) && close(r[5].displayStart, 39.3))
    }

    @Test func pairLeavesTogetherWithTheLowerLineLater() {
        let r = applied(relaxed)
        // 第一页唱完在 16；下一页 20 开唱，最晚能留到 17.2（唱完 + lastHoldOut）
        #expect(close(r[0].displayEnd, 17.2), "上行消失，实际 \(r[0].displayEnd)")
        #expect(close(r[1].displayEnd, 18.0), "下行晚 0.8 秒消失（出场与入场对称），实际 \(r[1].displayEnd)")
        #expect(close(r[5].displayEnd, 46 + 1.2 + 0.8), "最后一页：唱完 + lastHoldOut，下行再晚 0.8")
    }

    @Test func nextPageEntersAfterAGapOrAtItsLeadInWhicheverIsLater() {
        // 紧凑歌词：页间只隔 3 秒。下一页想提前 1.5 秒进场，但要等上一页消失 + 0.4 秒空白
        let r = applied([(10, 13), (13.2, 16), (18.5, 21), (21.2, 24)])
        let firstPageEnd = r[0].displayEnd
        #expect(r[2].displayStart >= firstPageEnd + 0.4 - 1e-9,
                "下一页至少在上一页消失 0.4 秒后才出现：\(firstPageEnd) → \(r[2].displayStart)")
        #expect(r[2].displayStart <= r[2].singStart, "不能晚于开唱")
    }

    @Test func continuousSingingFlipsExactlyWhenThePageIsSungWithoutOverlap() {
        // 一页唱完马上接下一页（间隔 0）：上一页恰好在唱完时消失，下一页恰好在这时进场
        let r = applied([(10, 13), (13, 16), (16, 19), (19, 22)])
        #expect(close(r[0].displayEnd, 16), "唱完即换页：\(r[0].displayEnd)")
        #expect(close(r[2].displayStart, 16), "下一页紧接着进场：\(r[2].displayStart)")
        #expect(r[2].displayStart >= r[0].displayEnd - 1e-9, "同一行（上行）不重叠")
        #expect(r[3].displayStart >= r[1].displayEnd - 1e-9 - 0.0, "下行也不重叠：\(r[1].displayEnd) vs \(r[3].displayStart)")
    }

    @Test func everyLineKeepsTheCoreInvariants() {
        for sing in [relaxed, [(10, 13), (13, 16), (16, 19), (19, 22)], [(5, 8), (9, 12), (30, 34)]] {
            for line in applied(sing) {
                #expect(line.displayStart <= line.singStart + 1e-9, "显示起点不能晚于开唱")
                #expect(line.displayEnd >= line.singEnd - 1e-9, "显示终点不能早于唱完")
                #expect(line.displayStart >= 0)
            }
        }
    }

    @Test func oddNumberOfLinesLeavesTheLastOneAsASingleLinePage() {
        let r = applied([(10, 13), (13.5, 16), (20, 23)])
        #expect(close(r[2].displayStart, 18.5), "单行页：只有上行规则，不加下行延后")
        #expect(close(r[2].displayEnd, 23 + 1.2))
    }

    @Test func userEditedDisplayEdgesSurviveARefresh() {
        var l = lines(relaxed)
        DisplayScheduler.applyDisplayWindows(to: &l, policy: policy)
        l[0].displayEnd = 15; l[0].displayEndIsManual = true     // 用户把上行拖短
        l[1].displayStart = 9.9; l[1].displayStartIsManual = true
        DisplayScheduler.applyDisplayWindows(to: &l, policy: policy)
        let r = l.sorted { $0.order < $1.order }
        #expect(close(r[0].displayEnd, 15))
        #expect(close(r[1].displayStart, 9.9))
    }

    @Test func rollingModeIsUnchangedByDefault() {
        let rolling = applied(relaxed, policy: .default)
        #expect(DisplayPolicy.default.mode == .rolling)
        // 滚动模式：下行的出现时间不会被 pageFlip 的延后规则影响
        var again = lines(relaxed)
        DisplayScheduler.applyDisplayWindows(to: &again, policy: .default)
        let sorted = again.sorted { $0.order < $1.order }
        #expect(zip(rolling, sorted).allSatisfy { close($0.displayStart, $1.displayStart) && close($0.displayEnd, $1.displayEnd) })
    }

    @Test func policyDecodesFromOldProjectsWithoutNewFields() throws {
        let old = #"{"leadIn":0.5,"lastHoldOut":1.2,"adaptToGap":true}"#
        let p = try JSONDecoder().decode(DisplayPolicy.self, from: Data(old.utf8))
        #expect(p.mode == .rolling && p.lowerLineDelay == 0 && p.pageGap == 0.4 && p.pageHoldOut == 0.5)
        let back = try JSONDecoder().decode(DisplayPolicy.self, from: JSONEncoder().encode(policy))
        #expect(back == policy)
    }
}
