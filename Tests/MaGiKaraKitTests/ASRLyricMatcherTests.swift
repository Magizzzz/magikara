import Testing
import Foundation
@testable import MaGiKaraKit

@Suite struct ASRLyricMatcherTests {
    @Test func punctuationOnlyLyricLineDoesNotCrash() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "punctuation-line",
            audioDuration: 6,
            elapsedSeconds: 0,
            tokens: [
                ASRToken(text: "あい", start: 1, end: 1.6),
                ASRToken(text: "うえ", start: 3, end: 3.6),
            ])

        let result = ASRLyricMatcher.match(lyrics: ["あい", "？！", "うえ"], transcript: transcript)

        #expect(result.lines.count == 3)
        #expect(!result.lines[1].hasDirectEvidence)
        #expect(result.lines[0].hasDirectEvidence)
        #expect(result.lines[2].hasDirectEvidence)
    }

    @Test func punctuationOnlyASRTokenDoesNotCreateEmptyRegionOrCrash() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "punctuation-gap",
            audioDuration: 12,
            elapsedSeconds: 0,
            tokens: [
                ASRToken(text: "あ", start: 1, end: 1.3),
                ASRToken(text: "。", start: 8, end: 8.2),
            ])

        let result = ASRLyricMatcher.match(lyrics: ["あ", "い"], transcript: transcript)

        #expect(result.regionCount == 1)
        #expect(result.lines.count == 2)
        #expect(result.lines[0].hasDirectEvidence)
        #expect(!result.lines[1].hasDirectEvidence)
    }

    @Test func localRealignerMapsCharacterIndicesBackToOwningTokens() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "multi-character-tokens",
            audioDuration: 3,
            elapsedSeconds: 0,
            tokens: [
                ASRToken(text: "あいう", start: 0, end: 0.8),
                ASRToken(text: "えお", start: 1, end: 1.6),
            ])
        let lyrics = ["あいう", "かきく"]
        let match = ASRLyricMatcher.match(lyrics: lyrics, transcript: transcript)

        let refined = LocalRealigner.refine(lyrics: lyrics,
                                            transcript: transcript,
                                            match: match)

        #expect(refined.starts.count == lyrics.count)
        #expect(refined.ends.count == lyrics.count)
        #expect(refined.changes.contains { $0.lineIndex == 1 })
    }

    @Test func unrelatedASRCharactersDoNotBecomeTimingEvidence() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "unrelated-characters",
            audioDuration: 2,
            elapsedSeconds: 0,
            tokens: [ASRToken(text: "かきく", start: 0.5, end: 1.5)])
        let result = ASRLyricMatcher.match(lyrics: ["あいう"], transcript: transcript)

        #expect(!result.lines[0].hasDirectEvidence)
        #expect(result.lines[0].evidenceQuality == 0)
    }

    @Test func singleAccidentalCharacterDoesNotAnchorLongLyricLine() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "one-character-hit",
            audioDuration: 3,
            elapsedSeconds: 0,
            tokens: [ASRToken(text: "あ", start: 1, end: 1.2)])

        let result = ASRLyricMatcher.match(lyrics: ["あいうえお"], transcript: transcript)

        #expect(result.lines[0].evidenceQuality == 0.2)
        #expect(!result.lines[0].hasDirectEvidence)
    }

    @Test func phoneticReadingsMatchKanjiLyricsToKanaASR() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "kanji-to-kana-reading",
            audioDuration: 8,
            elapsedSeconds: 0,
            tokens: [ASRToken(text: "きょう", start: 4.2, end: 4.9)])

        let phonetic = ASRLyricMatcher.match(lyrics: ["今日"], transcript: transcript)
        var surfaceConfig = ASRLyricMatcher.Config()
        surfaceConfig.usePhoneticReadings = false
        let surfaceOnly = ASRLyricMatcher.match(lyrics: ["今日"], transcript: transcript,
                                                config: surfaceConfig)

        #expect(phonetic.lines[0].hasDirectEvidence)
        #expect(phonetic.lines[0].evidenceQuality == 1)
        #expect(abs((phonetic.lines[0].start ?? 0) - 4.2) < 0.001)
        #expect(!surfaceOnly.lines[0].hasDirectEvidence)
    }

    @Test func defaultMatcherUsesKanaReadingsButDoesNotRewriteDisplayedLyrics() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "kanji-to-kana-default",
            audioDuration: 8,
            elapsedSeconds: 0,
            tokens: [ASRToken(text: "きょう", start: 4.2, end: 4.9)])

        let result = ASRLyricMatcher.match(lyrics: ["今日"], transcript: transcript)

        #expect(ASRLyricMatcher.Config().usePhoneticReadings)
        #expect(result.lines[0].hasDirectEvidence)
        #expect(result.lines[0].evidenceQuality == 1)
    }

    @Test func chronologicalGuardRejectsBackwardAndOutOfBoundsAnchors() {
        func line(_ index: Int, _ start: Double, _ end: Double) -> LyricASRMatch.LineMatch {
            .init(lineIndex: index,
                  start: start,
                  end: end,
                  charTimes: [start],
                  charEnds: [end],
                  evidenceQuality: 1,
                  hasDirectEvidence: true,
                  regionIndex: 0)
        }
        let original = LyricASRMatch(lines: [
            line(0, 1, 2),
            line(1, 8, 9),
            line(2, 3, 4),
            line(3, 10, 100),
        ], regionCount: 1, asrCharCount: 4, matchedCharCount: 4, totalCost: 0)

        let repaired = LocalRealigner.enforceChronologicalOrder(
            lyrics: ["花", "歌", "葉", "空"],
            match: original,
            audioDuration: 12)

        #expect(repaired.rejectedDirectCount == 2)
        #expect(repaired.match.lines[0].hasDirectEvidence)
        #expect(repaired.match.lines[1].hasDirectEvidence)
        #expect(!repaired.match.lines[2].hasDirectEvidence)
        #expect(!repaired.match.lines[3].hasDirectEvidence)
        #expect((repaired.match.lines[2].start ?? 0) >= (repaired.match.lines[1].start ?? 0))
        #expect((repaired.match.lines[3].start ?? 0) > (repaired.match.lines[2].start ?? 0))
        #expect((repaired.match.lines[3].end ?? .infinity) <= 12)
        #expect(repaired.match.matchedCharCount == 2)
    }

    @Test func interpolationReferenceExcludesTheAnchorBeingChecked() {
        let starts: [Double?] = [1.0, 50.0, 5.0]
        let ends: [Double?] = [1.5, 50.5, 5.5]

        let reference = LocalRealigner.interpolationReference(
            lyrics: ["あ", "い", "う"],
            starts: starts,
            ends: ends,
            reliableAnchors: [true, true, true])

        #expect(abs(reference[1] - 2.025) < 0.001)
        #expect(abs(reference[1] - starts[1]!) > 40)
    }

    @Test func interpolationReferenceUsesRemainingSpeechForUnanchoredTail() {
        let reference = LocalRealigner.interpolationReference(
            lyrics: ["あ", "い", "う", "え"],
            starts: [10.0, 13.0, 14.0, 15.0],
            ends: [12.0, 13.5, 14.5, 15.5],
            reliableAnchors: [true, false, false, false],
            startBoundary: 5,
            endBoundary: 40)

        #expect(abs(reference[3] - 32.067) < 0.01)
    }

    @Test func failedLocalRetryFallsBackToNeighborAnchorsForStructuralOutlier() {
        let lyrics = ["ああ", "かき", "うう"]
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "structural-outlier",
            audioDuration: 7,
            elapsedSeconds: 0,
            tokens: [
                ASRToken(text: "ああ", start: 1.0, end: 1.5),
                ASRToken(text: "ええ", start: 3.0, end: 3.5),
                ASRToken(text: "うう", start: 5.0, end: 5.5),
            ])
        let match = LyricASRMatch(
            lines: [
                .init(lineIndex: 0, start: 1.0, end: 1.5,
                      charTimes: [1.0, 1.2], charEnds: [1.2, 1.5],
                      evidenceQuality: 1, hasDirectEvidence: true, regionIndex: 0),
                .init(lineIndex: 1, start: 50.0, end: 50.5,
                      charTimes: [50.0, 50.2], charEnds: [50.2, 50.5],
                      evidenceQuality: 1, hasDirectEvidence: true, regionIndex: 0),
                .init(lineIndex: 2, start: 5.0, end: 5.5,
                      charTimes: [5.0, 5.2], charEnds: [5.2, 5.5],
                      evidenceQuality: 1, hasDirectEvidence: true, regionIndex: 0),
            ],
            regionCount: 1,
            asrCharCount: 6,
            matchedCharCount: 6,
            totalCost: 0)

        let refined = LocalRealigner.refine(lyrics: lyrics, transcript: transcript, match: match)

        #expect(abs((refined.starts[1] ?? 0) - 2.025) < 0.01)
        #expect(refined.evidence[1] == .interpolated)
        #expect(refined.changes.contains { $0.lineIndex == 1 && $0.kind.contains("仍无证据") })
    }

    @Test func unmatchedTailLyricsSpreadAcrossRemainingSpeechInsteadOfFiveSeconds() {
        let transcript = ASRTranscript(
            engine: "test",
            locale: "ja-JP",
            mediaName: "unmatched-tail",
            audioDuration: 40,
            elapsedSeconds: 0,
            tokens: [
                ASRToken(text: "ああ", start: 10, end: 11),
                ASRToken(text: "ひひ", start: 35, end: 36),
            ])

        let result = ASRLyricMatcher.match(
            lyrics: ["ああ", "かき", "くけ", "こさ"], transcript: transcript)

        #expect(result.lines.count == 4)
        #expect(!result.lines[1].hasDirectEvidence)
        #expect(!result.lines[2].hasDirectEvidence)
        #expect(!result.lines[3].hasDirectEvidence)
        #expect((result.lines[3].start ?? 0) > 25)
    }

}
