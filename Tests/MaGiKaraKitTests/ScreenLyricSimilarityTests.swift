import Foundation
import Testing
@testable import MaGiKaraKit

/// 回归：画面歌词（OCR）匹配里，某一边是空字符串曾经会触发
/// "Range requires lowerBound <= upperBound" 直接崩溃整个 app（一键对轨时闪退）。
@Suite struct ScreenLyricSimilarityTests {
    private let aligner = ScreenLyricAligner()

    @Test func emptyAgainstNonEmptyDoesNotCrashAndScoresZero() {
        // OCR 这一帧没读到字，与期望歌词比较——必须是 0 分，而不是崩溃
        #expect(aligner.similarity("", "テスト") == 0)
        #expect(aligner.similarity("テスト", "") == 0)
    }

    @Test func bothEmptyIsIdentical() {
        #expect(aligner.similarity("", "") == 1)
    }

    @Test func identicalAndDifferentStringsStillScoreNormally() {
        #expect(aligner.similarity("abc", "abc") == 1)
        #expect(aligner.similarity("abc", "xyz") == 0)
        let partial = aligner.similarity("abcd", "abcx")
        #expect(partial > 0.7 && partial < 0.8, "一个字符不同：1 - 1/4 = 0.75，实际 \(partial)")
    }

    @Test func singleCharacterStringsWork() {
        #expect(aligner.similarity("a", "a") == 1)
        #expect(aligner.similarity("a", "b") == 0)
        #expect(aligner.similarity("a", "ab") == 0.5)
    }
}
