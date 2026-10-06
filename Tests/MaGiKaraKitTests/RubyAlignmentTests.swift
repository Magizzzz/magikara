import Testing
import Foundation
@testable import MaGiKaraKit

/// Ruby 只给汉字注音（不重复注音假名）+ 主句排版稳定 + 匀速导出（本轮修复）。
@Suite struct RubyAlignmentTests {

    // MARK: Ruby 对齐：只给汉字注音

    @Test func rubyRunsSkipOkurigana() {
        // 「勝ち筋」读「かちすじ」→ か 属于勝、すじ 属于筋；「ち」本身是假名，不注音
        let runs = JapaneseReadingService.rubyRuns(surface: "勝ち筋", reading: "かちすじ")
        #expect(runs.count == 2)
        #expect(runs[0].surfaceStart == 0 && runs[0].surfaceLength == 1)
        #expect(runs[0].reading == "か")
        #expect(runs[1].surfaceStart == 2 && runs[1].surfaceLength == 1)
        #expect(runs[1].reading == "すじ")
        #expect(!runs.contains { $0.reading == "ち" }, "假名「ち」不应被注音")
    }

    @Test func rubyRunsKeepKanjiCompoundTogetherOverOkurigana() {
        // 「素晴らしき」→「素晴」是一段连续汉字，注「すば」；送假名「らしき」不注音
        let runs = JapaneseReadingService.rubyRuns(surface: "素晴らしき", reading: "すばらしき")
        #expect(runs.count == 1)
        #expect(runs[0].surfaceStart == 0 && runs[0].surfaceLength == 2)
        #expect(runs[0].reading == "すば")
        #expect(!runs.contains { $0.reading.contains("ら") })
    }

    @Test func rubyRunsAllKanjiIsSingleRun() {
        let runs = JapaneseReadingService.rubyRuns(surface: "世界", reading: "せかい")
        #expect(runs.count == 1)
        #expect(runs[0].reading == "せかい")
        #expect(runs[0].readingStart == 0)
    }

    @Test func rubyRunsPureKanaOrNoReadingIsEmpty() {
        #expect(JapaneseReadingService.rubyRuns(surface: "そうですね", reading: "そうですね").isEmpty)
        #expect(JapaneseReadingService.rubyRuns(surface: "世界", reading: "").isEmpty)
    }

    @Test func mixedKanjiKanaTokenProducesRubyOnlyOverKanji() {
        var line = LyricLine(order: 1, lane: .upper, displayText: "勝ち筋",
                             displayStart: 0, singStart: 0, singEnd: 2, displayEnd: 3)
        line.tokens = [LyricToken(surface: "勝ち筋", reading: "かちすじ", morae: [
            MoraTiming(mora: "か", start: 0.0, end: 0.4),
            MoraTiming(mora: "ち", start: 0.4, end: 0.8),
            MoraTiming(mora: "す", start: 0.8, end: 1.2),
            MoraTiming(mora: "じ", start: 1.2, end: 2.0),
        ], sourceStart: 0, sourceLength: 3)]

        let layout = KaraokeLayout.layout(line: line, style: .default)
        #expect(layout.rubies.count == 2)
        #expect(layout.rubies.map(\.text) == ["か", "すじ"])
        #expect(!layout.rubies.contains { $0.text == "ち" }, "假名「ち」被重复注音了")

        // か 压在「勝」上、すじ 压在「筋」上 → 中心必须从左到右
        if layout.rubies.count == 2 {
            #expect(layout.rubies[0].centerX < layout.rubies[1].centerX)
        }

        // 时间窗：か = 第一个音拍，すじ = 后两个音拍
        #expect(layout.rubies[0].start == 0.0)
        #expect(layout.rubies[0].end == 0.4)
        #expect(layout.rubies[1].start == 0.8)
        #expect(layout.rubies[1].end == 2.0)
    }

    // MARK: 主句排版稳定：不因假名或未对齐 token 变形

    @Test func mainLayoutIsStableRegardlessOfRuby() throws {
        let kanji = LyricToken(surface: "世界", reading: "せかい", morae: [
            MoraTiming(mora: "せ", start: 0, end: 0.6),
            MoraTiming(mora: "か", start: 0.6, end: 1.2),
            MoraTiming(mora: "い", start: 1.2, end: 2.0),
        ], sourceStart: 0, sourceLength: 2)
        // 无读音、无音拍的助词：必须照样参与主句排版与扫色
        let particle = LyricToken(surface: "に", reading: nil, morae: [],
                                  sourceStart: 2, sourceLength: 1)
        var line = LyricLine(order: 1, lane: .upper, displayText: "世界に",
                             displayStart: 0, singStart: 0, singEnd: 2, displayEnd: 3)
        line.tokens = [kanji, particle]

        let layout = KaraokeLayout.layout(line: line, style: .default)
        let world = try #require(layout.tokenGeometry[kanji.id])
        let ni = try #require(layout.tokenGeometry[particle.id])
        #expect(world.centerX < ni.centerX, "token 必须按原文顺序排布")

        // 整行宽度 = 完整 displayText 的宽度（没有被 ruby 撑宽或截断）
        let expected = KaraokeLayout.width(of: "世界に", font: KaraokeLayout.mainFont(style: .default))
        #expect(abs(layout.lineWidth - expected) < 0.5)

        // token 横向比例按顺序覆盖整行，且不重叠
        let f0 = try #require(layout.tokenSweepFractions[kanji.id])
        let f1 = try #require(layout.tokenSweepFractions[particle.id])
        #expect(f0.start == 0)
        #expect(f0.end <= f1.start + 1e-6)
        #expect(abs(f1.end - 1) < 1e-6)

        // 没有音拍的 token 也必须有完整扫色比例（否则扫色会提前停住）
        #expect(f1.end > f1.start)
    }

    // MARK: 导出：逐字符按渲染宽度分配时间（匀速）

    private func durations(in body: String) -> [Int] {
        var result: [Int] = []
        var idx = body.startIndex
        while idx < body.endIndex {
            guard let r = body.range(of: "\\k", range: idx..<body.endIndex) else { break }
            let after = body[r.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let v = Int(digits) { result.append(v) }
            idx = after.startIndex
        }
        return result
    }

    @Test func uniformBodySumsToTotal() {
        let font = KaraokeLayout.mainFont(style: .default)
        let body = AssExporter.uniformBody(text: "素晴らしき世界に", font: font, tag: .k, total: 2.0)
        let ds = durations(in: body)
        #expect(ds.count == 8, "每个字符一个 \\k 块，实际 \(ds.count)")
        #expect(ds.reduce(0, +) == 200, "\\k 之和必须精确等于总时长")
    }

    @Test func uniformBodyWeightsByRenderedWidth() {
        let font = KaraokeLayout.mainFont(style: .default)
        // 「i」很窄、「あ」接近全角 → i 分到的时间必须明显更少
        let body = AssExporter.uniformBody(text: "あi", font: font, tag: .k, total: 2.0)
        let ds = durations(in: body)
        #expect(ds.count == 2)
        #expect(ds.reduce(0, +) == 200)
        #expect(ds[1] < ds[0], "窄字符应分到更少时间：\(ds)")
    }
}
