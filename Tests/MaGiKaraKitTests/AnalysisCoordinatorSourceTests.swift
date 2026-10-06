import Testing
import Foundation
@testable import MaGiKaraKit

@Suite struct AnalysisCoordinatorSourceTests {
    @Test func oneClickAnalysisUsesOnlyCurrentSeparatedVocalStem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-source-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaURL = root.appendingPathComponent("source.mp4")
        let vocalURL = root.appendingPathComponent("vocal.wav")
        let instrumentalURL = root.appendingPathComponent("instrumental.wav")
        try Data([0x01, 0x02, 0x03]).write(to: mediaURL)
        try Data([0x11, 0x12, 0x13]).write(to: vocalURL)
        try Data([0x21, 0x22, 0x23]).write(to: instrumentalURL)

        var project = KaraProject(mediaURL: mediaURL,
                                  duration: 5,
                                  lyricLines: [LyricLine(order: 1, displayText: "あ")])
        project.vocalSeparation = VocalSeparationAssets(
            vocalURL: vocalURL,
            instrumentalURL: instrumentalURL,
            sourceFingerprint: project.mediaFingerprint()!,
            modelID: "test-model",
            sampleRate: 44_100,
            duration: 5)

        let capture = AlignmentSourceCapture()
        let aligner = CapturingSourceAwareAligner(capture: capture)
        _ = try await AnalysisCoordinator.analyze(project: project, aligner: aligner)
        var observed = await capture.values()

        #expect(observed.mediaURL == mediaURL)
        #expect(observed.recognitionAudioURL == vocalURL)

        // A stem from another source must never be silently applied to this media.
        project.vocalSeparation?.sourceFingerprint = "different-source"
        _ = try await AnalysisCoordinator.analyze(project: project, aligner: aligner)
        observed = await capture.values()
        #expect(observed.mediaURL == mediaURL)
        #expect(observed.recognitionAudioURL == mediaURL)
    }
}

private actor AlignmentSourceCapture {
    private(set) var mediaURL: URL?
    private(set) var recognitionAudioURL: URL?

    func set(mediaURL: URL, recognitionAudioURL: URL) {
        self.mediaURL = mediaURL
        self.recognitionAudioURL = recognitionAudioURL
    }

    func values() -> (mediaURL: URL?, recognitionAudioURL: URL?) {
        (mediaURL, recognitionAudioURL)
    }
}

private struct CapturingSourceAwareAligner: MediaAudioSourceAwareLyricAligning {
    let capture: AlignmentSourceCapture

    var name: String { "Source routing test" }
    var method: AlignmentMethod { .asrForcedAlign }
    var isProductionReady: Bool { true }

    func align(audioURL: URL,
               lines: [LyricLineDraft],
               progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        await capture.set(mediaURL: audioURL, recognitionAudioURL: audioURL)
        return aligned(lines)
    }

    func align(mediaURL: URL,
               recognitionAudioURL: URL,
               lines: [LyricLineDraft],
               progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        await capture.set(mediaURL: mediaURL, recognitionAudioURL: recognitionAudioURL)
        return aligned(lines)
    }

    private func aligned(_ lines: [LyricLineDraft]) -> [AlignedLyricLine] {
        lines.map {
            AlignedLyricLine(id: $0.id,
                             order: $0.order,
                             singStart: 0.1,
                             singEnd: 0.4,
                             confidence: 0.9,
                             tokens: $0.tokens,
                             method: .asrForcedAlign,
                             evidence: .asrTokens)
        }
    }
}
