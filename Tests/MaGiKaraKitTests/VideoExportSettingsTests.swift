import Testing
import Foundation
@testable import MaGiKaraKit

/// 视频导出设置的纯逻辑测试：分辨率 / 帧率是否真正接入 ffmpeg 参数，
/// 以及预估大小是否按时长与「视频码率 + 音频码率」计算。
@Suite struct VideoExportSettingsTests {

    @Test func defaultSettingsAreMediumSourceSource() {
        let settings = VideoExportSettings()
        #expect(settings.bitrate == .medium)
        #expect(settings.resolution == .source)
        #expect(settings.frameRate == .source)
        #expect(settings.audioQuality == .normal)
        #expect(VideoExportSettings.default == settings)
    }

    @Test func estimatedFileSizeUsesVideoPlusAudioBitrate() {
        let settings = VideoExportSettings(bitrate: .medium, audioQuality: .normal)
        // (8 Mbps + 192 kbps) * 60s / 8 = 61_440_000 bytes
        let bytes = settings.estimatedFileSize(duration: 60)
        #expect(abs(bytes - 61_440_000) < 1)
    }

    @Test func estimatedFileSizeGrowsWithQuality() {
        let low = VideoExportSettings(bitrate: .low).estimatedFileSize(duration: 30)
        let medium = VideoExportSettings(bitrate: .medium).estimatedFileSize(duration: 30)
        let high = VideoExportSettings(bitrate: .high).estimatedFileSize(duration: 30)
        #expect(low < medium)
        #expect(medium < high)
    }

    @Test func estimatedFileSizeGrowsWithAudioQuality() {
        let normal = VideoExportSettings(audioQuality: .normal).estimatedFileSize(duration: 30)
        let high = VideoExportSettings(audioQuality: .high).estimatedFileSize(duration: 30)
        #expect(normal < high)
    }

    @Test func estimatedFileSizeIsZeroForUnknownDuration() {
        #expect(VideoExportSettings().estimatedFileSize(duration: 0) == 0)
        #expect(VideoExportSettings().estimatedFileSize(duration: -5) == 0)
    }

    @Test func sourceResolutionAddsNoScaleFilter() {
        #expect(VideoExportResolution.source.scaleFilter == nil)
        #expect(VideoExportResolution.source.targetSize == nil)
    }

    @Test func nonSourceResolutionProducesExactCanvas() {
        #expect(VideoExportResolution.hd1080.scaleFilter?.contains("scale=1920:1080") == true)
        #expect(VideoExportResolution.uhd4K.scaleFilter?.contains("scale=3840:2160") == true)
        #expect(VideoExportResolution.uhd4K.scaleFilter?.contains("pad=3840:2160") == true)
    }

    @Test func sourceFrameRateAddsNoRateArgument() {
        #expect(VideoExportFrameRate.source.ffmpegValue == nil)
        let args = VideoExporter.encoderArguments(
            settings: VideoExportSettings(frameRate: .source))
        #expect(!args.contains("-r"))
    }

    @Test func explicitFrameRateBecomesFFmpegArgument() {
        for (rate, expected) in [(VideoExportFrameRate.fps25, "25"),
                                 (.fps30, "30"),
                                 (.fps60, "60")] {
            let args = VideoExporter.encoderArguments(
                settings: VideoExportSettings(frameRate: rate))
            guard let index = args.firstIndex(of: "-r") else {
                Issue.record("缺少 -r 参数：\(rate)")
                continue
            }
            #expect(args[index + 1] == expected)
        }
    }

    @Test func qualitySelectsVideoBitrateArgument() {
        let args = VideoExporter.encoderArguments(
            settings: VideoExportSettings(bitrate: .high, audioQuality: .high))
        guard let index = args.firstIndex(of: "-b:v") else {
            Issue.record("缺少 -b:v 参数")
            return
        }
        #expect(args[index + 1] == "14M")
        // 音频码率与预估使用同一常量
        let audioIndex = args.firstIndex(of: "-b:a")
        #expect(audioIndex != nil)
        if let audioIndex { #expect(args[audioIndex + 1] == VideoExportAudioQuality.high.audioBitrate) }
    }

    @Test func normalAudioQualityKeepsLegacyBitrate() {
        let args = VideoExporter.encoderArguments(
            settings: VideoExportSettings(audioQuality: .normal))
        guard let audioIndex = args.firstIndex(of: "-b:a") else {
            Issue.record("缺少 -b:a 参数")
            return
        }
        #expect(args[audioIndex + 1] == "192k")
        #expect(VideoExporter.audioBitrate == "192k")
    }

    @Test func separatedStemExportMixesAudioAndHonorsTrackMutes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-stem-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let media = root.appendingPathComponent("mv.mp4")
        let vocal = root.appendingPathComponent("vocal.wav")
        let instrumental = root.appendingPathComponent("instrumental.wav")
        try Data([0x01]).write(to: media)
        try Data([0x02]).write(to: vocal)
        try Data([0x03]).write(to: instrumental)

        var project = KaraProject(mediaURL: media, duration: 10)
        let fingerprint = try #require(project.mediaFingerprint())
        project.vocalSeparation = VocalSeparationAssets(
            vocalURL: vocal,
            instrumentalURL: instrumental,
            sourceFingerprint: fingerprint,
            modelID: "test",
            sampleRate: 44_100,
            duration: 10)

        let mixed = VideoExporter.audioMappingArguments(project: project)
        #expect(mixed.contains(where: { $0.contains("amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,\(VideoExporter.stemLimiter)[aout]") }))
        #expect(mixed.contains("[aout]"))

        project.trackStates.toggleMuted(.vocal)
        let instrumentalOnly = VideoExporter.audioMappingArguments(project: project)
        #expect(instrumentalOnly.contains("1:a:0?"))
        #expect(instrumentalOnly.contains(VideoExporter.stemLimiter), "单独导出伴奏也要限幅，防止削波")
        #expect(!instrumentalOnly.contains("-filter_complex"))

        project.trackStates.toggleMuted(.audio)
        let silent = VideoExporter.audioMappingArguments(project: project)
        #expect(silent.contains("-an"))
    }

    @Test func exportWithoutStemsHonorsOriginalAudioMute() {
        var project = KaraProject(mediaURL: URL(fileURLWithPath: "/tmp/mv.mp4"), duration: 10)

        let original = VideoExporter.audioMappingArguments(project: project)
        #expect(original == ["-map", "0:v:0?", "-map", "0:a?"])
        #expect(!VideoExporter.usesSeparatedAudio(project: project))

        // 无分轨时人声轨不存在，静音人声不应影响原音轨
        project.trackStates.toggleMuted(.vocal)
        #expect(VideoExporter.audioMappingArguments(project: project) == original)

        project.trackStates.toggleMuted(.audio)
        let silent = VideoExporter.audioMappingArguments(project: project)
        #expect(silent.contains("-an"))
        #expect(!silent.contains("0:a?"))
    }

    @Test func videoFilterScalesBeforeBurningSubtitles() {
        let source = VideoExporter.videoFilter(
            assPath: "karaoke.ass",
            settings: VideoExportSettings(resolution: .source))
        #expect(source == "ass=karaoke.ass")

        let scaled = VideoExporter.videoFilter(
            assPath: "karaoke.ass",
            settings: VideoExportSettings(resolution: .hd1080))
        // scale 必须在 ass 之前，字幕才会在目标分辨率下渲染
        let scaleRange = scaled.range(of: "scale=")
        let assRange = scaled.range(of: "ass=")
        #expect(scaleRange != nil && assRange != nil)
        if let scaleRange, let assRange {
            #expect(scaleRange.lowerBound < assRange.lowerBound)
        }
    }

    @Test func settingsCodableRoundTrip() throws {
        let original = VideoExportSettings(bitrate: .high,
                                           resolution: .uhd4K,
                                           frameRate: .fps60,
                                           audioQuality: .high)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoExportSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func settingsWithoutAudioQualityDecodeAsNormal() throws {
        let data = #"{"bitrate":"medium","resolution":"source","frameRate":"source"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(VideoExportSettings.self, from: data)
        #expect(decoded.audioQuality == .normal)
    }
}
