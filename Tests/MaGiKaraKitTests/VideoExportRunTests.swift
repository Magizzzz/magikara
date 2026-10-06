import Foundation
import AVFoundation
import Testing
@testable import MaGiKaraKit

/// 真正调用本机 ffmpeg 的导出测试；没有 ffmpeg 的机器上自动跳过。
@Suite struct VideoExportRunTests {

    private static var ffmpegAvailable: Bool { VideoExporter.ffmpegURL() != nil }

    private func makeSineWAV(in dir: URL, seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent("tone.wav")
        let process = Process()
        process.executableURL = try #require(VideoExporter.ffmpegURL())
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return url
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func progressFractionParsesFFmpegProgressLines() {
        #expect(VideoExporter.progressFraction(fromLine: "out_time_us=5000000", totalSeconds: 10) == 0.5)
        // 接近完成时封顶 0.99，把 1 留给真正完成
        #expect(VideoExporter.progressFraction(fromLine: "out_time_us=10000000", totalSeconds: 10) == 0.99)
        #expect(VideoExporter.progressFraction(fromLine: "frame=12", totalSeconds: 10) == nil)
        #expect(VideoExporter.progressFraction(fromLine: "out_time_us=N/A", totalSeconds: 10) == nil)
        #expect(VideoExporter.progressFraction(fromLine: "out_time_us=5000000", totalSeconds: 0) == nil)
    }

    @Test func outputCannotOverwriteSourceMedia() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("mv.mp4")
        try Data([1, 2, 3]).write(to: media)
        let project = KaraProject(mediaURL: media, duration: 5)
        #expect(throws: VideoExporter.ExportError.self) {
            try VideoExporter.export(project: project, settings: .default, to: media)
        }
        #expect(try Data(contentsOf: media) == Data([1, 2, 3]))
    }

    @Test(.enabled(if: VideoExportRunTests.ffmpegAvailable))
    func audioOnlyMediaExportsAVideoWithAudioAndReportsProgress() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeSineWAV(in: dir, seconds: 3)
        let project = KaraProject(mediaURL: wav, duration: 3)
        let output = dir.appendingPathComponent("out.mp4")

        let seen = ProgressRecorder()
        try VideoExporter.export(project: project,
                                 settings: VideoExportSettings(resolution: .source),
                                 to: output,
                                 progress: { seen.add($0) })

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(seen.values.last == 1)
        // 临时文件必须被清理
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".partial") }
        #expect(leftovers.isEmpty)

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 3) < 0.5)
    }

    @Test(.enabled(if: VideoExportRunTests.ffmpegAvailable))
    func mutedAudioOnlyMediaStillStopsAtAudioDurationAndHasNoAudioTrack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeSineWAV(in: dir, seconds: 2)
        var project = KaraProject(mediaURL: wav, duration: 2)
        project.trackStates.toggleMuted(.audio)
        let output = dir.appendingPathComponent("silent.mp4")

        try VideoExporter.export(project: project, settings: .default, to: output)

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2) < 0.5)
    }

    @Test(.enabled(if: VideoExportRunTests.ffmpegAvailable))
    func cancelledExportThrowsAndLeavesExistingFileUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeSineWAV(in: dir, seconds: 3)
        let project = KaraProject(mediaURL: wav, duration: 3)
        let output = dir.appendingPathComponent("keep.mp4")
        try Data("original".utf8).write(to: output)

        let cancellation = VideoExporter.Cancellation()
        cancellation.cancel()   // 启动前取消：进程一启动就会被终止
        #expect(throws: VideoExporter.ExportError.self) {
            try VideoExporter.export(project: project, settings: .default, to: output,
                                     cancellation: cancellation)
        }
        #expect(try Data(contentsOf: output) == Data("original".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".partial") }
        #expect(leftovers.isEmpty)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
