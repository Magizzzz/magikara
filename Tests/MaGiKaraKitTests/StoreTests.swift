import Testing
import Foundation
@testable import MaGiKaraKit

/// 工程文件读写、版本迁移、撤销栈（RD §11.1 / §14）
@Suite struct StoreTests {

    private func sampleProject() -> KaraProject {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
                                  duration: 42.5,
                                  title: "青い約束")
        var line = LyricLine(order: 1,
                             lane: .upper,
                             displayText: "素晴らしき世界に今日も乾杯",
                             displayStart: 1.0,
                             singStart: 2.2,
                             singEnd: 5.4,
                             displayEnd: 6.6,
                             tokens: [
                                LyricToken(surface: "世界", reading: "せかい", morae: [
                                    MoraTiming(mora: "せ", start: 2.6, end: 3.0, confidence: 0.91),
                                    MoraTiming(mora: "か", start: 3.0, end: 3.4, confidence: 0.88),
                                    MoraTiming(mora: "い", start: 3.4, end: 3.9, confidence: 0.86),
                                ], sourceStart: 4, sourceLength: 2),
                             ],
                             confidence: 0.9,
                             needsReview: false,
                             reviewReasons: [])
        line.styleOverride = SubtitleStyleOverride(fontSize: 80)
        project.lyricLines = [line]
        project.style.fontSize = 66
        project.style.sungColor = RGBAColor(0.5, 0.4, 0.9, 1)
        project.dictionary = ["世界": "せかい"]
        project.analysis = AnalysisSummary(alignerName: "test", elapsedSeconds: 0.5,
                                           totalLines: 1, lowConfidenceCount: 0)
        project.lyricsSource = LyricsSourceInfo(recordID: 42,
                                                trackName: "花",
                                                artistName: "藤井風",
                                                albumName: "LOVE ALL SERVE ALL",
                                                sourceDurationSec: 248.3,
                                                textSource: .synchronized,
                                                importedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return project
    }

    @Test func roundTripPreservesEverything() throws {
        let original = sampleProject()
        let data = try ProjectStore.encode(original)
        let restored = try ProjectStore.decode(data)

        #expect(restored.version == KaraProject.currentVersion)
        #expect(restored.title == original.title)
        #expect(abs(restored.duration - original.duration) < 1e-9)
        #expect(restored.mediaURL == original.mediaURL)
        #expect(restored.lyricLines.count == 1)
        #expect(abs(restored.style.fontSize - 66) < 1e-9)
        #expect(restored.dictionary["世界"] == "せかい")

        let line = try #require(restored.lyricLines.first)
        #expect(line.displayText == "素晴らしき世界に今日も乾杯")
        #expect(abs(line.displayStart - 1.0) < 1e-9)
        #expect(abs(line.singEnd - 5.4) < 1e-9)
        #expect(abs(line.displayEnd - 6.6) < 1e-9)
        #expect(line.tokens.count == 1)
        #expect(line.tokens[0].reading == "せかい")
        #expect(line.tokens[0].morae.count == 3)
        #expect(abs(line.tokens[0].morae[1].start - 3.0) < 1e-9)
        #expect(line.styleOverride?.fontSize == 80)
        #expect(restored.analysis?.alignerName == "test")
        #expect(restored.lyricsSource?.recordID == 42)
        #expect(restored.lyricsSource?.textSource == .synchronized)
    }

    @Test func saveAndLoadFromDisk() throws {
        let project = sampleProject()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-test-\(UUID().uuidString).magikara")
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try ProjectStore.load(from: url)
        #expect(loaded.title == "青い約束")
        #expect(loaded.lyricLines.first?.tokens.first?.morae.count == 3)
    }

    @Test func decodingOldProjectWithoutNewFieldsStillWorks() throws {
        // 模拟旧版本工程：缺少 reviewReasons / styleOverride / displayPolicy / analysis
        let json = """
        {
          "version": 1,
          "mediaURL": "file:///tmp/old.mp3",
          "duration": 10.0,
          "title": "旧工程",
          "lyricLines": [
            {
              "id": "\(UUID().uuidString)",
              "order": 1,
              "lane": "upper",
              "displayText": "テスト",
              "displayStart": 0.5,
              "singStart": 1.0,
              "singEnd": 2.0,
              "displayEnd": 3.0,
              "tokens": [],
              "confidence": 0.7,
              "needsReview": true
            }
          ],
          "style": { "fontSize": 60 }
        }
        """
        let project = try ProjectStore.decode(Data(json.utf8))
        #expect(project.title == "旧工程")
        #expect(project.lyricLines.count == 1)
        // 样式缺失字段要用默认值补齐
        #expect(abs(project.style.fontSize - 60) < 1e-9)
        #expect(project.style.fontWeight == SubtitleStyle.default.fontWeight)
        #expect(project.lyricLines[0].reviewReasons.isEmpty)
        #expect(project.displayPolicy.leadIn == DisplayPolicy.default.leadIn)
        #expect(project.analysis == nil)
        #expect(project.lyricsSource == nil)
    }

    @Test func decodingRepairsInvalidTiming() throws {
        let json = """
        {
          "version": 1,
          "mediaURL": "file:///tmp/x.mp3",
          "duration": 10,
          "title": "坏时间",
          "lyricLines": [
            {
              "id": "\(UUID().uuidString)",
              "order": 1,
              "lane": "upper",
              "displayText": "x",
              "displayStart": 5.0,
              "singStart": 2.0,
              "singEnd": 1.0,
              "displayEnd": 0.5,
              "tokens": [],
              "confidence": 0.5,
              "needsReview": true
            }
          ],
          "style": {}
        }
        """
        let project = try ProjectStore.decode(Data(json.utf8))
        #expect(project.lyricLines[0].hasValidTiming, "解码时应修复非法的四段时间顺序")
    }

    // MARK: 撤销 / 重做

    @Test func undoRedoRestoresSnapshots() throws {
        let stack = UndoStack()
        var project = sampleProject()
        let originalTitle = project.title

        stack.record(project, label: "改名")
        project.title = "改了名字"

        #expect(stack.canUndo)
        let undone = try #require(stack.undo(current: project))
        #expect(undone.title == originalTitle)
        #expect(stack.canRedo)

        let redone = try #require(stack.redo(current: undone))
        #expect(redone.title == "改了名字")
    }

    @Test func undoRecordsClearRedoStack() {
        let stack = UndoStack()
        var project = sampleProject()
        stack.record(project, label: "a")
        project.title = "b"
        _ = stack.undo(current: project)
        #expect(stack.canRedo)

        stack.record(project, label: "c")
        #expect(!stack.canRedo, "新的编辑必须清空重做栈")
    }

    @Test func undoStackRespectsLimit() {
        let stack = UndoStack(limit: 3)
        var project = sampleProject()
        for i in 0..<10 {
            stack.record(project, label: "\(i)")
            project.title = "t\(i)"
        }
        #expect(stack.undoCount == 3)
    }

    // MARK: 媒体

    @Test func hasMediaDetection() {
        #expect(!KaraProject().hasMedia, "默认工程不应被认为已导入媒体")
        let p = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/does-not-exist.mp3"))
        #expect(p.hasMedia)
        #expect(!p.mediaExists)
    }

    @Test func missingMediaDoesNotBreakProject() throws {
        var p = sampleProject()
        p.mediaURL = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString).mp4")
        #expect(!p.mediaExists)
        // 仍然可以正常序列化
        let data = try ProjectStore.encode(p)
        #expect(!data.isEmpty)
    }

    // MARK: 自动保存

    @Test func autosaveDebouncesAndWrites() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-autosave-\(UUID().uuidString).magikara")
        defer { try? FileManager.default.removeItem(at: url) }

        let project = sampleProject()
        let saver = Autosaver(delay: 0.2)
        saver.schedule(url: url, provider: { project })

        // 防抖期内多次调度只应落盘一次
        saver.schedule(url: url, provider: { project })
        saver.schedule(url: url, provider: { project })

        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(FileManager.default.fileExists(atPath: url.path), "防抖结束后应写入文件")
        #expect(saver.lastError == nil)

        let loaded = try ProjectStore.load(from: url)
        #expect(loaded.title == "青い約束")
    }
}
