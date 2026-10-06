import Testing
import Foundation
@testable import MaGiKaraKit

@Suite struct LyricTextExporterTests {
    private func project() -> KaraProject {
        let first = LyricLine(order: 1, lane: .upper, displayText: "なんもねえ",
                               displayStart: 0.4, singStart: 1.25, singEnd: 3.5, displayEnd: 4.2)
        let second = LyricLine(order: 2, lane: .lower, displayText: "また会える",
                                displayStart: 3.6, singStart: 4.0, singEnd: 5.125, displayEnd: 5.8)
        return KaraProject(duration: 10, title: "test", lyricLines: [first, second])
    }

    @Test func lrcUsesSingStartAndKeepsJapaneseText() {
        let output = LyricTextExporter.lrc(project: project())
        #expect(output.contains("[00:01.25]なんもねえ"))
        #expect(output.contains("[00:04.00]また会える"))
    }

    @Test func srtUsesDisplayWindowAndMilliseconds() {
        let output = LyricTextExporter.srt(project: project())
        #expect(output.contains("00:00:00,400 --> 00:00:04,200"))
        #expect(output.contains("00:00:03,600 --> 00:00:05,800"))
        #expect(output.contains("また会える"))
    }
}
