import Foundation
import Testing
@testable import MaGiKaraKit

/// 上下行各自的水平对齐（错开排版：上行靠左、下行靠右）。
/// 回归：样式里的「左对齐 / 居中 / 右对齐」曾经只是个摆设，预览和导出都只用「行中心 + 偏移」。
@Suite struct SubtitleAlignmentTests {

    private func style(upper: SubtitleAlignment, lower: SubtitleAlignment,
                       margin: Double = 140, upperX: Double = 0, lowerX: Double = 0) -> SubtitleStyle {
        var s = SubtitleStyle()
        s.upperAlignment = upper
        s.lowerAlignment = lower
        s.horizontalMargin = margin
        s.upperPositionX = upperX
        s.lowerPositionX = lowerX
        return s
    }

    @Test func centerUsesTheLaneOffsetOnly() {
        let s = style(upper: .center, lower: .center, upperX: 30, lowerX: -20)
        #expect(s.lineCenterX(for: .upper, lineWidth: 400) == 30)
        #expect(s.lineCenterX(for: .lower, lineWidth: 900) == -20)
    }

    @Test func leadingPutsTheLeftEdgeAtTheMargin() {
        let s = style(upper: .leading, lower: .leading)
        let center = s.lineCenterX(for: .upper, lineWidth: 400)
        #expect(abs((960 + center - 400 / 2) - 140) < 1e-9, "行的左边缘应距画面左边缘 140，实际中心偏移 \(center)")
    }

    @Test func trailingPutsTheRightEdgeAtTheMargin() {
        let s = style(upper: .trailing, lower: .trailing)
        let center = s.lineCenterX(for: .lower, lineWidth: 400)
        #expect(abs((960 + center + 400 / 2) - (1920 - 140)) < 1e-9)
    }

    @Test func staggeredLanesAreIndependentAndMirrorEachOther() {
        let s = style(upper: .leading, lower: .trailing)
        #expect(s.lineCenterX(for: .upper, lineWidth: 400) == -620)
        #expect(s.lineCenterX(for: .lower, lineWidth: 400) == 620)
    }

    @Test func laneOffsetFineTunesAlignedLines() {
        let s = style(upper: .leading, lower: .trailing, upperX: 25, lowerX: -15)
        #expect(s.lineCenterX(for: .upper, lineWidth: 400) == -620 + 25)
        #expect(s.lineCenterX(for: .lower, lineWidth: 400) == 620 - 15)
    }

    @Test func aLineWiderThanTheSafeAreaFallsBackToCenter() {
        let s = style(upper: .leading, lower: .trailing, upperX: 10, lowerX: -10)
        #expect(s.lineCenterX(for: .upper, lineWidth: 1700) == 10, "1700 ≥ 1920 - 2×140，不能被推出画面")
        #expect(s.lineCenterX(for: .lower, lineWidth: 1700) == -10)
    }

    @Test func oldProjectsKeepTheirUnifiedAlignmentOnBothLanes() throws {
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SubtitleStyle())) as? [String: Any])
        json.removeValue(forKey: "upperAlignment")
        json.removeValue(forKey: "lowerAlignment")
        json.removeValue(forKey: "horizontalMargin")
        json["alignment"] = "trailing"
        let old = try JSONDecoder().decode(SubtitleStyle.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        #expect(old.upperAlignment == .trailing && old.lowerAlignment == .trailing)
        #expect(old.horizontalMargin == 140)
        // 默认样式仍然居中：升级不改变任何已有画面
        #expect(SubtitleStyle().upperAlignment == .center && SubtitleStyle().lowerAlignment == .center)
    }

    @Test func assPlacesEachLineByItsLaneAlignment() throws {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 30)
        project.style.upperAlignment = .leading
        project.style.lowerAlignment = .trailing
        project.lyricLines = [
            LyricLine(order: 1, lane: .upper, displayText: "あいうえお", displayStart: 1,
                      singStart: 2, singEnd: 4, displayEnd: 6),
            LyricLine(order: 2, lane: .lower, displayText: "かきくけこさし", displayStart: 3,
                      singStart: 4, singEnd: 6, displayEnd: 8),
        ]
        for index in project.lyricLines.indices {
            project.lyricLines[index].tokens = JapaneseReadingService().tokens(for: project.lyricLines[index].displayText)
        }
        let ass = AssExporter.export(project: project)
        func mainX(startingAt time: String) -> Double? {
            guard let line = ass.split(separator: "\n").first(where: { $0.hasPrefix("Dialogue: 0,\(time),") && $0.contains(",Main,") }),
                  let r = line.range(of: "\\pos("),
                  let end = line[r.upperBound...].firstIndex(of: ",") else { return nil }
            return Double(line[r.upperBound..<end])
        }
        let font = KaraokeLayout.mainFont(style: project.style)
        let upperWidth = KaraokeLayout.width(of: "あいうえお", font: font)
        let lowerWidth = KaraokeLayout.width(of: "かきくけこさし", font: font)
        let upperX = try #require(mainX(startingAt: "0:00:01.00"))
        let lowerX = try #require(mainX(startingAt: "0:00:03.00"))
        #expect(abs((upperX - upperWidth / 2) - 140) < 0.1, "上行的左边缘应贴着左边距 140，实际 \(upperX - upperWidth / 2)")
        #expect(abs((lowerX + lowerWidth / 2) - (1920 - 140)) < 0.1, "下行的右边缘应贴着右边距，实际 \(lowerX + lowerWidth / 2)")
    }
}
