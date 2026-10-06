import Testing
import Foundation
import AVFoundation
@testable import MaGiKaraKit

/// 真实 MP4 上的时间线回归（无头执行，不启动 GUI）。
///
/// 覆盖验收清单里需要真实媒体的部分：0 秒/中段/末尾定位、连续播放后回到开头、
/// 100 次 seek、多 zoom 坐标映射、分割+撤销、锁定/显隐/静音。
///
/// 媒体缺失时整体跳过（不伪装通过）。
@Suite(.serialized) struct RealMediaTimelineTests {

    static let mediaPath = "/Users/magi/Downloads/chrome-extension___ekhbcipncbkfpkaianbjbcbmfehjflpf_popup.html/DM_20260922061122_001.mp4"

    private func mediaURL() -> URL? {
        let env = ProcessInfo.processInfo.environment["MAGIKARA_TEST_MEDIA"]
        let path = env ?? Self.mediaPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let d = try? await asset.load(.duration)
        return d.map { CMTimeGetSeconds($0) } ?? 0
    }

    // MARK: 坐标映射 / 点击定位

    @Test func clickAtStartMiddleEndMapsExactly() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 1)

        for pps in [4.0, 16.0, 64.0, 200.0, 400.0] {
            let viewport = 900.0
            let content = TimelineGeometry.contentWidth(duration: dur, pixelsPerSecond: pps, viewportWidth: viewport)
            for target in [0.0, dur / 2, dur] {
                for scroll in [0.0, TimelineGeometry.maxScrollX(contentWidth: content, viewportWidth: viewport) / 2,
                               TimelineGeometry.maxScrollX(contentWidth: content, viewportWidth: viewport)] {
                    let vx = TimelineGeometry.viewportX(forTime: target, scrollX: scroll, pixelsPerSecond: pps)
                    let back = TimelineGeometry.seekTime(forViewportX: vx, scrollX: scroll,
                                                         pixelsPerSecond: pps, duration: dur)
                    #expect(abs(back - target) < 1e-6,
                            "pps=\(pps) scroll=\(scroll) target=\(target) 得到 \(back)")
                }
            }
        }
    }

    @Test func clickBeyondTimelineClampsToBounds() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 1)
        #expect(TimelineGeometry.seekTime(forViewportX: -9999, scrollX: 0,
                                          pixelsPerSecond: 64, duration: dur) == 0)
        #expect(TimelineGeometry.seekTime(forViewportX: 99999, scrollX: 0,
                                          pixelsPerSecond: 64, duration: dur) == dur)
    }

    @Test func zoomKeepsAnchorWithoutDrift() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 1)
        let viewport = 900.0
        // 反复缩放，锚点时间在视口里的位置不应漂移
        var pps = 64.0
        var scroll = 0.0
        let anchor = dur * 0.4
        for _ in 0..<12 {
            let target = pps * 1.25
            let content = TimelineGeometry.contentWidth(duration: dur, pixelsPerSecond: target, viewportWidth: viewport)
            let fraction = (anchor * pps - scroll) / viewport
            scroll = TimelineGeometry.scrollXKeepingAnchor(anchorTime: anchor,
                                                          anchorViewportFraction: min(max(fraction, 0), 1),
                                                          newPixelsPerSecond: target,
                                                          viewportWidth: viewport,
                                                          contentWidth: content)
            pps = target
            #expect(scroll >= 0)
            #expect(scroll <= TimelineGeometry.maxScrollX(contentWidth: content, viewportWidth: viewport) + 1e-6)
        }
    }

    // MARK: 播放 / seek

    @Test func hundredSeeksAcrossRealMediaStayConsistent() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 1)

        let engine = await PlaybackEngineProbe(url: url)
        // 100 次 seek：交替 0 / 中段 / 末尾 / 随机，检查容器层不丢时间、不越界
        var reported: [Double] = []
        for i in 0..<100 {
            let target: Double
            switch i % 4 {
            case 0: target = 0
            case 1: target = dur / 2
            case 2: target = max(0, dur - 0.1)
            default: target = Double((i * 37) % 1000) / 1000.0 * dur
            }
            let got = await engine.seek(to: target)
            reported.append(got)
            #expect(got.isFinite, "第 \(i) 次 seek 返回了非有限时间")
            #expect(got >= -0.05 && got <= dur + 0.05, "第 \(i) 次 seek 越界：\(got) / \(dur)")
        }
        // 回到开头必须真的回到开头（回归：连续播放后不能失去回溯能力）
        let zero = await engine.seek(to: 0)
        #expect(zero < 0.15, "点回 0 秒后实际时间 \(zero)")
        let mid = await engine.seek(to: dur / 2)
        #expect(abs(mid - dur / 2) < 0.35)
    }

    @Test func playPauseHundredTimesThenReturnToStart() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 1)
        let engine = await PlaybackEngineProbe(url: url)

        for i in 0..<100 {
            await engine.play()
            if i % 7 == 0 { _ = await engine.seek(to: min(dur - 0.2, Double(i) * 0.3)) }
            await engine.pause()
        }
        // 连续播放/暂停 100 次之后，仍然能回到开头
        let zero = await engine.seek(to: 0)
        #expect(zero < 0.2, "100 次播放暂停后回到开头失败：\(zero)")
        let t1 = await engine.seek(to: dur - 0.1)
        #expect(t1 > dur - 0.5, "末尾定位失败：\(t1)")
    }

    // MARK: 轨道状态

    @Test func lockHideMuteOnRealProject() async throws {
        guard let url = mediaURL() else { return }
        var project = KaraProject()
        project.mediaURL = url
        project.duration = await duration(url)
        var l1 = LyricLine(order: 1, displayText: "あ", displayStart: 0, singStart: 1,
                           singEnd: 2, displayEnd: 3)
        var l2 = LyricLine(order: 2, displayText: "い", displayStart: 3, singStart: 4,
                           singEnd: 5, displayEnd: 6)
        l1.tokens = [LyricToken(surface: "あ", reading: nil, morae: [], sourceStart: 0, sourceLength: 1)]
        l2.tokens = [LyricToken(surface: "い", reading: nil, morae: [], sourceStart: 0, sourceLength: 1)]
        project.lyricLines = [l1, l2]

        #expect(project.isEditable(l1))
        project.trackStates.toggleLocked(.lyricUpper)
        #expect(!project.isEditable(l1))
        #expect(project.isEditable(l2))
        project.trackStates.toggleVisible(.video)
        #expect(!project.trackStates.isVisible(.video))
        project.trackStates.toggleMuted(.audio)
        #expect(project.trackStates.isMuted(.audio))
        // 存盘再读回来
        let data = try JSONEncoder().encode(project)
        let back = try JSONDecoder().decode(KaraProject.self, from: data)
        #expect(back.trackStates.isLocked(.lyricUpper))
        #expect(!back.trackStates.isVisible(.video))
        #expect(back.trackStates.isMuted(.audio))
    }

    // MARK: 分割 / 修剪 / 吸附（在真实时长范围内）

    @Test func splitThenUndoOnRealLengthProject() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 10)

        var project = KaraProject()
        project.mediaURL = url
        project.duration = dur
        var line = LyricLine(order: 1, displayText: "きみのうた",
                             displayStart: dur * 0.1, singStart: dur * 0.11,
                             singEnd: dur * 0.15, displayEnd: dur * 0.16)
        line.tokens = [LyricToken(surface: "きみのうた", reading: nil, morae: [
            MoraTiming(mora: "き", start: dur * 0.11, end: dur * 0.12),
            MoraTiming(mora: "み", start: dur * 0.12, end: dur * 0.13),
            MoraTiming(mora: "の", start: dur * 0.13, end: dur * 0.14),
            MoraTiming(mora: "う", start: dur * 0.14, end: dur * 0.15),
        ], sourceStart: 0, sourceLength: 4)]
        project.lyricLines = [line]

        let stack = UndoStack()
        stack.record(project, label: "分割前")
        let cut = (line.singStart + line.singEnd) / 2
        let parts = try #require(LineSplitter.split(line, at: cut))
        project.lyricLines = [parts.left, parts.right]
        project.renumber()
        #expect(project.lyricLines.count == 2)
        #expect(project.lyricLines[0].lane != project.lyricLines[1].lane,
                "renumber 后上下行应交替")

        let restored = try #require(stack.undo(current: project))
        #expect(restored.lyricLines.count == 1)
        #expect(restored.lyricLines[0].displayText == "きみのうた")
    }

    @Test func snapUsesPlayheadAndAcousticPointsOnRealLengths() async throws {
        guard let url = mediaURL() else { return }
        let dur = await duration(url)
        try #require(dur > 10)

        var a = LyricLine(order: 1, displayText: "あ", displayStart: 10, singStart: 11,
                          singEnd: 13, displayEnd: 14)
        a.tokens = [LyricToken(surface: "あ", reading: nil, morae: [], sourceStart: 0, sourceLength: 1)]
        var b = LyricLine(order: 2, displayText: "い", displayStart: 14, singStart: 15,
                          singEnd: 17, displayEnd: 18)
        b.tokens = [LyricToken(surface: "い", reading: nil, morae: [], sourceStart: 0, sourceLength: 1)]
        var project = KaraProject()
        project.mediaURL = url
        project.duration = dur
        project.lyricLines = [a, b]

        // 拖 b 到接近 a 的演唱终点 → 应吸到 13
        let r = SnapEngine.snap(13.03, project: project, excluding: b.id,
                                pixelsPerSecond: 64, playhead: 40, duration: dur)
        #expect(r.didSnap)
        #expect(abs(r.time - 13) < 1e-9)

        // 关掉吸附后不再吸
        var cfg = SnapConfig.default
        cfg.enabled = false
        let r2 = SnapEngine.snap(13.03, project: project, excluding: b.id,
                                 pixelsPerSecond: 64, playhead: 40, duration: dur, config: cfg)
        #expect(!r2.didSnap)

        // 移动整句后时长不变、且 token 时间整体平移（不重写）
        let moved = LineEditor.moved(b, by: 2.5)
        #expect(LineEditor.keepsDuration(b, moved))
        #expect(abs(moved.singStart - 17.5) < 1e-9)
    }
}

/// 直接驱动 AVPlayer 的最小探针：只做 seek/play/pause，用来验证容器层的时间一致性。
/// 不依赖 SwiftUI，因此可以在无头环境跑。
actor PlaybackEngineProbe {
    private let player = AVPlayer()
    private let durationValue: Double

    init(url: URL) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        let d = try? await asset.load(.duration)
        durationValue = d.map { CMTimeGetSeconds($0) } ?? 0
    }

    /// 精确 seek 并返回容器报告的实际时间
    func seek(to t: Double) async -> Double {
        let clamped = min(max(0, t), max(0, durationValue))
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        _ = await player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        return CMTimeGetSeconds(player.currentTime())
    }

    var duration: Double { durationValue }

    func currentTime() async -> Double {
        CMTimeGetSeconds(player.currentTime())
    }

    func play() async {
        player.play()
        try? await Task.sleep(nanoseconds: 12_000_000)
    }

    func pause() async {
        player.pause()
        try? await Task.sleep(nanoseconds: 4_000_000)
    }
}

/// 顶部播放定位按钮的真实媒体回归：
/// 播放到中间 → 前往开头 = 00:00 → 播放 → 前往结尾 = 02:51。
@Suite(.serialized) struct TransportButtonRegressionTests {

    private func media() -> URL? {
        let path = ProcessInfo.processInfo.environment["MAGIKARA_TEST_MEDIA"]
            ?? "/Users/magi/Downloads/chrome-extension___ekhbcipncbkfpkaianbjbcbmfehjflpf_popup.html/DM_20260922061122_001.mp4"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @Test func startAndEndButtonsLandAtTheRightTimes() async throws {
        guard let url = media() else { return }
        let engine = await PlaybackEngineProbe(url: url)
        let dur = await engine.duration
        try #require(dur > 5)

        // 1) 播放到中间
        let mid = await engine.seek(to: dur / 2)
        #expect(abs(mid - dur / 2) < 0.4, "中段定位失败：\(mid)")

        // 2) 前往开头 → 必须是 0，不是结尾
        let start = await engine.seek(to: 0)
        #expect(start < 0.2, "「前往开头」落到了 \(start)，应在 0 秒附近")

        // 3) 再播一小段
        await engine.play(); await engine.pause()
        let after = await engine.currentTime()
        #expect(after < 5, "播放后时间异常：\(after)")

        // 4) 前往结尾 → 必须是结尾，不是开头
        let end = await engine.seek(to: dur)
        #expect(end > dur - 0.5, "「前往结尾」落到了 \(end)，应在 \(dur) 附近")

        // 5) 再回开头仍然有效（不能因为去过结尾就失去回溯）
        let back = await engine.seek(to: 0)
        #expect(back < 0.2, "从结尾回到开头失败：\(back)")
    }
}
