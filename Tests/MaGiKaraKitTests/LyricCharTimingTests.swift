import Testing
import Foundation
@testable import MaGiKaraKit

/// 句内逐字时间的回归测试（本轮「块内不按文字等距铺满」修复）。
@Suite struct LyricCharTimingTests {

    private func line(tokens: [LyricToken], text: String,
                      singStart: Double = 10, singEnd: Double = 14) -> LyricLine {
        var l = LyricLine(order: 1, lane: .upper, displayText: text,
                          displayStart: singStart - 1, singStart: singStart,
                          singEnd: singEnd, displayEnd: singEnd + 1)
        l.tokens = tokens
        return l
    }

    @Test func charactersUseTokenTimesNotEvenSpacing() {
        // 「世界」两字、三个音拍：0–1 / 1–2 / 2–4  →  世=[0,2) 界=[2,4)，时长并不相等
        let token = LyricToken(surface: "世界", reading: "せかい", morae: [
            MoraTiming(mora: "せ", start: 10.0, end: 11.0),
            MoraTiming(mora: "か", start: 11.0, end: 12.0),
            MoraTiming(mora: "い", start: 12.0, end: 14.0),
        ], sourceStart: 0, sourceLength: 2)
        let chars = LyricCharTiming.characters(of: line(tokens: [token], text: "世界"))

        #expect(chars.count == 2)
        #expect(chars.map(\.character) == ["世", "界"])
        #expect(chars.allSatisfy { $0.hasTokenEvidence })
        // 按「音拍下标比例」切给字：世 → 第 1 个音拍，界 → 第 2、3 个音拍
        #expect(chars[0].start == 10.0)
        #expect(chars[0].end == 11.0)
        #expect(chars[1].start == 11.0)
        #expect(chars[1].end == 14.0)
        let d0 = chars[0].end! - chars[0].start!
        let d1 = chars[1].end! - chars[1].start!
        #expect(abs(d0 - d1) > 0.5, "两字时长应当不同（不做等距铺满）")
    }

    @Test func singleCharacterTokenTakesWholeTokenSpan() {
        let token = LyricToken(surface: "東", reading: "ひがし", morae: [
            MoraTiming(mora: "ひ", start: 10.0, end: 10.5),
            MoraTiming(mora: "が", start: 10.5, end: 11.0),
            MoraTiming(mora: "し", start: 11.0, end: 12.0),
        ], sourceStart: 0, sourceLength: 1)
        let chars = LyricCharTiming.characters(of: line(tokens: [token], text: "東"))
        #expect(chars.count == 1)
        #expect(chars[0].start == 10.0)
        #expect(chars[0].end == 12.0)
    }

    @Test func tokenWithoutMoraeIsInterpolatedAndFlagged() {
        let timed = LyricToken(surface: "咲", reading: "さ", morae: [
            MoraTiming(mora: "さ", start: 10.0, end: 11.0),
        ], sourceStart: 0, sourceLength: 1)
        let untimed = LyricToken(surface: "いた", reading: nil, morae: [],
                                 sourceStart: 1, sourceLength: 3)
        let chars = LyricCharTiming.characters(of: line(tokens: [timed, untimed], text: "咲いた"))

        #expect(chars.count == 3, "「咲いた」是 3 个字")
        #expect(chars[0].hasTokenEvidence)          // 咲 有证据
        #expect(!chars[1].hasTokenEvidence)         // い 无证据
        #expect(!chars[2].hasTokenEvidence)         // た 无证据
        // 插值结果必须落在整行区间内且单调
        for c in chars {
            #expect(c.start != nil)
            #expect(c.start! >= 10.0 - 1e-9)
            #expect(c.end! <= 14.0 + 1e-9)
        }
    }

    @Test func lineWithoutAnyMoraeFallsBackButIsNotMarkedAsEvidence() {
        let token = LyricToken(surface: "あいうえお", reading: nil, morae: [],
                               sourceStart: 0, sourceLength: 5)
        let chars = LyricCharTiming.characters(of: line(tokens: [token], text: "あいうえお"))
        #expect(chars.count == 5)
        #expect(chars.allSatisfy { $0.start != nil })
        #expect(chars.allSatisfy { !$0.hasTokenEvidence }, "无音拍证据时不能标成有证据")
        // 退化铺开仍要覆盖整行并保持单调
        for (a, b) in zip(chars, chars.dropFirst()) {
            #expect(a.start! <= b.start!)
            #expect(a.end! <= b.start! + 1e-9)
        }
    }

    @Test func timesAreMonotonicAcrossTokens() {
        let t1 = LyricToken(surface: "僕ら", reading: "ぼくら", morae: [
            MoraTiming(mora: "ぼ", start: 10.0, end: 10.4),
            MoraTiming(mora: "く", start: 10.4, end: 10.8),
            MoraTiming(mora: "ら", start: 10.8, end: 11.2),
        ], sourceStart: 0, sourceLength: 2)
        let t2 = LyricToken(surface: "の歌", reading: "のうた", morae: [
            MoraTiming(mora: "の", start: 11.2, end: 11.6),
            MoraTiming(mora: "う", start: 11.6, end: 12.0),
            MoraTiming(mora: "た", start: 12.0, end: 12.4),
        ], sourceStart: 2, sourceLength: 2)
        let chars = LyricCharTiming.characters(of: line(tokens: [t1, t2], text: "僕らの歌"))
        #expect(chars.count == 4)
        for (a, b) in zip(chars, chars.dropFirst()) {
            #expect(a.start! <= b.start! + 1e-9)
        }
        #expect(chars.last!.end! <= 14.0 + 1e-9)
    }

    @Test func fullEvidenceFlag() {
        let timed = LyricToken(surface: "世界", reading: "せかい", morae: [
            MoraTiming(mora: "せ", start: 10.0, end: 10.5),
            MoraTiming(mora: "か", start: 10.5, end: 11.0),
            MoraTiming(mora: "い", start: 11.0, end: 11.5),
        ], sourceStart: 0, sourceLength: 2)
        #expect(LyricCharTiming.hasFullTokenEvidence(line(tokens: [timed], text: "世界")))

        let partial = LyricToken(surface: "世界に", reading: nil, morae: [], sourceStart: 0, sourceLength: 3)
        #expect(!LyricCharTiming.hasFullTokenEvidence(line(tokens: [timed, partial], text: "世界に")))
    }
}
