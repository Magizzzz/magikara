import Foundation
import Testing
@testable import MaGiKaraKit

@Suite struct FallbackLyricAlignerTests {

    private struct StubAligner: LyricAligning {
        enum Behavior: Sendable { case succeed(Double), fail, cancel }
        let name: String
        let behavior: Behavior
        let method: AlignmentMethod
        var isProductionReady: Bool { true }

        func align(audioURL: URL,
                   lines: [LyricLineDraft],
                   progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
            switch behavior {
            case .succeed(let start):
                return lines.map {
                    AlignedLyricLine(id: $0.id, order: $0.order, singStart: start, singEnd: start + 1,
                                     confidence: 0.9, tokens: $0.tokens, method: method)
                }
            case .fail:
                struct Boom: Error {}
                throw Boom()
            case .cancel:
                throw CancellationError()
            }
        }
    }

    private let media = URL(fileURLWithPath: "/tmp/song.mp4")

    private func drafts() -> [LyricLineDraft] {
        [LyricLineDraft(id: UUID(), order: 0, text: "テスト", tokens: [])]
    }

    @Test func usesPrimaryWhenItSucceeds() async throws {
        let aligner = FallbackLyricAligner(
            primary: StubAligner(name: "primary", behavior: .succeed(10), method: .yohaneForcedAlign),
            fallback: StubAligner(name: "fallback", behavior: .succeed(99), method: .asrForcedAlign))
        let result = try await aligner.align(audioURL: media, lines: drafts(), progress: nil)
        #expect(result.first?.singStart == 10)
        #expect(result.first?.method == .yohaneForcedAlign)
    }

    @Test func fallsBackAndReportsWhenPrimaryFails() async throws {
        let aligner = FallbackLyricAligner(
            primary: StubAligner(name: "primary", behavior: .fail, method: .yohaneForcedAlign),
            fallback: StubAligner(name: "fallback", behavior: .succeed(99), method: .asrForcedAlign))
        let messages = MessageBox()
        let result = try await aligner.align(audioURL: media, lines: drafts(),
                                             progress: { messages.add($0.message) })
        #expect(result.first?.singStart == 99)
        #expect(result.first?.method == .asrForcedAlign)
        #expect(messages.values.contains { $0.contains("ASR") })
    }

    @Test func cancellationDoesNotTriggerFallback() async {
        let aligner = FallbackLyricAligner(
            primary: StubAligner(name: "primary", behavior: .cancel, method: .yohaneForcedAlign),
            fallback: StubAligner(name: "fallback", behavior: .succeed(99), method: .asrForcedAlign))
        await #expect(throws: CancellationError.self) {
            _ = try await aligner.align(audioURL: media, lines: drafts(), progress: nil)
        }
    }

    @Test func bothFailingSurfacesTheFallbackError() async {
        let aligner = FallbackLyricAligner(
            primary: StubAligner(name: "primary", behavior: .fail, method: .yohaneForcedAlign),
            fallback: StubAligner(name: "fallback", behavior: .fail, method: .asrForcedAlign))
        await #expect(throws: (any Error).self) {
            _ = try await aligner.align(audioURL: media, lines: drafts(), progress: nil)
        }
    }
}

private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ m: String) { lock.lock(); storage.append(m); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
