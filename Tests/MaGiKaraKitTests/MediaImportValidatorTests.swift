import Testing
import Foundation
@testable import MaGiKaraKit

/// 导入校验的回归测试（本轮「拖放导入」修复）。
@Suite struct MediaImportValidatorTests {

    private func makeTempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    @Test func acceptsSupportedMedia() throws {
        for name in ["a.mp4", "b.MOV", "c.m4v", "d.mp3", "e.wav", "f.m4a", "g.aiff"] {
            let url = try makeTempFile(name)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let d = MediaImportValidator.validate(url)
            #expect(d.isAccepted, "\(name) 应当被接受，实际：\(d)")
        }
    }

    @Test func kindIsVideoOrAudio() throws {
        let mp4 = try makeTempFile("v.mp4")
        defer { try? FileManager.default.removeItem(at: mp4.deletingLastPathComponent()) }
        let aiff = try makeTempFile("a.aiff")
        defer { try? FileManager.default.removeItem(at: aiff.deletingLastPathComponent()) }
        #expect(MediaImportValidator.validate(mp4) == .accept(kind: .video))
        #expect(MediaImportValidator.validate(aiff) == .accept(kind: .audio))
    }

    @Test func rejectsUnsupportedExtension() throws {
        let url = try makeTempFile("notes.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let d = MediaImportValidator.validate(url)
        #expect(!d.isAccepted)
        #expect(d.message?.contains("不支持") == true)
    }

    @Test func rejectsMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString).mp4")
        let d = MediaImportValidator.validate(url)
        #expect(!d.isAccepted)
        #expect(d.message?.contains("不存在") == true)
    }

    @Test func rejectsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = MediaImportValidator.validate(dir)
        #expect(!d.isAccepted)
        #expect(d.message?.contains("文件夹") == true)
    }

    @Test func rejectsNonFileURL() {
        let d = MediaImportValidator.validate(URL(string: "https://example.com/a.mp4")!)
        #expect(!d.isAccepted)
    }

    @Test func firstAcceptableSkipsBadEntriesAndReportsThem() throws {
        let good = try makeTempFile("song.mp3")
        defer { try? FileManager.default.removeItem(at: good.deletingLastPathComponent()) }
        let bad = try makeTempFile("cover.png")
        defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
        let missing = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).mp4")

        // 拖入多个文件时，应挑第一个可用的，并把其它被拒的原因收集起来
        let (accepted, rejections) = MediaImportValidator.firstAcceptable(from: [bad, missing, good])
        #expect(accepted?.kind == .audio)
        #expect(accepted?.url.lastPathComponent == "song.mp3")
        #expect(rejections.count == 2)
    }

    @Test func firstAcceptableWithAllInvalidReturnsNilAndReasons() throws {
        let bad = try makeTempFile("only.txt")
        defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
        let (accepted, rejections) = MediaImportValidator.firstAcceptable(from: [bad])
        #expect(accepted == nil)
        #expect(rejections.count == 1)
    }

    @Test func extensionSetsCoverRDRequirements() {
        // RD §2 明确要求 mp4 / mov / mp3 / wav
        for required in ["mp4", "mov", "mp3", "wav"] {
            #expect(MediaImportValidator.allExtensions.contains(required))
        }
    }
}
