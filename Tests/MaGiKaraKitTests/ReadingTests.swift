import Testing
import Foundation
@testable import MaGiKaraKit

/// 日语读音与音拍拆分（RD §6）
@Suite struct ReadingTests {

    // MARK: 字符判定

    @Test func kanjiDetection() {
        #expect(JapaneseText.containsKanji("世界"))
        #expect(JapaneseText.containsKanji("々"))     // 踊り字
        #expect(!JapaneseText.containsKanji("せかい"))
        #expect(!JapaneseText.containsKanji("コーヒー"))
        #expect(JapaneseText.containsKanji("Never give up そう信じて"))
    }

    @Test func katakanaToHiragana() {
        #expect(JapaneseText.katakanaToHiragana("カタカナ") == "かたかな")
        #expect(JapaneseText.katakanaToHiragana("ヴァイオリン") == "ゔぁいおりん")
        #expect(JapaneseText.katakanaToHiragana("ひらがな") == "ひらがな")
    }

    // MARK: 音拍拆分

    @Test func moraeBasic() {
        #expect(JapaneseText.morae(from: "せかい") == ["せ", "か", "い"])
    }

    @Test func moraeYouonIsOneBeat() {
        // 拗音与前一个假名合成一拍
        #expect(JapaneseText.morae(from: "きょう") == ["きょ", "う"])
        #expect(JapaneseText.morae(from: "しゃしん") == ["しゃ", "し", "ん"])
    }

    @Test func moraeSokuonAndHatsuon() {
        // 促音「っ」与撥音「ん」各自独立成拍
        #expect(JapaneseText.morae(from: "がっこう") == ["が", "っ", "こ", "う"])
        #expect(JapaneseText.morae(from: "しんぶん") == ["し", "ん", "ぶ", "ん"])
    }

    @Test func moraeLongVowelMergesIntoPrevious() {
        // 长音符并入前一拍
        #expect(JapaneseText.morae(from: "こーひー") == ["こー", "ひー"])
    }

    @Test func moraCount() {
        #expect(JapaneseText.moraCount(of: "きょう") == 2)
        #expect(JapaneseText.moraCount(of: "がっこう") == 4)
    }

    // MARK: 歌词分句

    @Test func splitLyricLinesByNewline() {
        let text = "一行目\n二行目\n\n三行目\n"
        #expect(JapaneseReadingService.splitLyricLines(from: text) == ["一行目", "二行目", "三行目"])
    }

    @Test func splitSingleParagraphByPunctuation() {
        let text = "最初の句。二番目の句！三番目の句？"
        #expect(JapaneseReadingService.splitLyricLines(from: text)
                == ["最初の句。", "二番目の句！", "三番目の句？"])
    }

    // MARK: 真实读音（macOS 自带日语分词 + Latin 转写）

    @Test func realReadingsForVerifiedWords() {
        // 这些读音已实测通过；若系统词典变化，这里会失败并暴露出来
        let service = JapaneseReadingService()
        #expect(service.reading(forWord: "世界") == "せかい")
        #expect(service.reading(forWord: "東京") == "とうきょう")
        #expect(service.reading(forWord: "運命") == "うんめい")
    }

    @Test func tokensForMixedLine() throws {
        let service = JapaneseReadingService()
        let tokens = service.tokens(for: "素晴らしき世界に今日も乾杯")
        #expect(!tokens.isEmpty)

        let world = try #require(tokens.first { $0.surface == "世界" }, "应当切出「世界」这个词")
        #expect(world.reading == "せかい")
        #expect(world.needsRuby)

        // 拼回原文必须完全一致（排版范围不能丢字）
        #expect(tokens.map(\.surface).joined() == "素晴らしき世界に今日も乾杯")
    }

    @Test func pureKanaLineHasNoRuby() {
        let service = JapaneseReadingService()
        let tokens = service.tokens(for: "そうですね")
        #expect(tokens.allSatisfy { !$0.needsRuby }, "纯假名不应生成假名附轨（RD §5.1）")
    }

    @Test func dictionaryOverrideWins() {
        let service = JapaneseReadingService()
        let tokens = service.tokens(for: "世界", dictionary: ["世界": "セカイ"])
        #expect(tokens.first?.reading == "せかい")   // 词典值会被规范化为平假名
    }

    @Test func alignmentUnitsCoverKanaAndKanji() {
        // 纯假名 token 也要参与对齐，否则整句音拍数会少算
        let kana = LyricToken(surface: "そう", reading: nil)
        #expect(JapaneseReadingService.alignmentUnits(for: kana) == ["そ", "う"])

        let kanji = LyricToken(surface: "世界", reading: "せかい")
        #expect(JapaneseReadingService.alignmentUnits(for: kanji) == ["せ", "か", "い"])
    }

    @Test func latinWordMapsEachCharacterOnceAndNormalizesApostrophes() {
        let never = LyricToken(surface: "Never", reading: nil)
        let here = LyricToken(surface: "here", reading: nil)
        let contraction = LyricToken(surface: "flower’s", reading: nil)
        #expect(JapaneseReadingService.alignmentUnits(for: never) == ["n", "e", "v", "e", "r"])
        #expect(JapaneseReadingService.alignmentUnits(for: here) == ["h", "e", "r", "e"])
        #expect(JapaneseReadingService.alignmentUnits(for: contraction) == ["f", "l", "o", "w", "e", "r", "'", "s"])
    }

    @Test func punctuationTakesNoBeat() {
        let punct = LyricToken(surface: "、", reading: nil)
        #expect(JapaneseReadingService.alignmentUnits(for: punct).isEmpty)
    }
}

/// 标点与符号不占音拍。回归：全角 `？` 曾被当成「拉丁字母」送进 Yohane，
/// 因无法转成拉丁音素而让整次对轨失败（默认路径会悄悄回退到精度更差的 ASR）。
@Suite struct AlignmentUnitsPunctuationTests {

    private func units(_ surface: String, reading: String? = nil) -> [String] {
        JapaneseReadingService.alignmentUnits(for: LyricToken(surface: surface, reading: reading))
    }

    @Test func punctuationTokensNeverOccupyMorae() {
        for mark in ["？", "！", "…", "、", "。", "「", "」", "『", "』", "〜", "・", "（", "）", "?", "!", "，", "．"] {
            // 标点 token 的「读音」往往就是它自己：必须在所有分支的出口被过滤掉
            #expect(units(mark, reading: mark).isEmpty, "「\(mark)」（读音同为自身）不应占音拍")
            #expect(units(mark).isEmpty, "「\(mark)」不应占音拍")
        }
    }

    @Test func singableTokensAreUnaffected() {
        #expect(units("花", reading: "はな") == ["は", "な"])
        #expect(units("そう") == ["そ", "う"])
        #expect(units("ありがとう") .count == 5)
        #expect(units("ー", reading: "ー") == ["ー"], "长音符是可唱的")
    }

    @Test func fullWidthLettersAndDigitsStillCountAsSingable() {
        // 全角字母数字规整成半角后是可唱的拉丁/数字；全角标点不是
        #expect(JapaneseReadingService.isSingableUnit("Ａ"))
        #expect(JapaneseReadingService.isSingableUnit("１"))
        #expect(!JapaneseReadingService.isSingableUnit("？"))
        #expect(!JapaneseReadingService.isSingableUnit("！"))
        #expect(!JapaneseReadingService.isSingableUnit("…"))
        #expect(!JapaneseReadingService.isSingableUnit(" "))
        #expect(JapaneseReadingService.isSingableUnit("'"), "英文缩写里的撇号是 Yohane 词表里的合法字符")
    }

    @Test func aLineWithPunctuationProducesOnlySingableUnits() {
        let service = JapaneseReadingService()
        for text in ["そう？ いいね！", "「あなた」を、愛して…", "ねぇ、どうして？"] {
            let tokens = service.tokens(for: text)
            let all = tokens.flatMap { JapaneseReadingService.alignmentUnits(for: $0) }
            #expect(!all.isEmpty)
            #expect(all.allSatisfy(JapaneseReadingService.isSingableUnit),
                    "整句里不应混进任何标点音拍：\(all)")
        }
    }
}
