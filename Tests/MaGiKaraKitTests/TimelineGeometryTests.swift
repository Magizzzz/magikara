import Testing
import Foundation
@testable import MaGiKaraKit

/// 时间线坐标映射的回归测试（本轮「点击定位 / 缩放后映射」修复）。
@Suite struct TimelineGeometryTests {

    @Test func contentXToTime() {
        #expect(TimelineGeometry.time(forContentX: 0, pixelsPerSecond: 64) == 0)
        #expect(TimelineGeometry.time(forContentX: 640, pixelsPerSecond: 64) == 10)
    }

    @Test func viewportXAccountsForScroll() {
        // 视口坐标要加上 scrollX 才是内容坐标
        #expect(TimelineGeometry.time(forViewportX: 0, scrollX: 0, pixelsPerSecond: 100) == 0)
        #expect(TimelineGeometry.time(forViewportX: 0, scrollX: 500, pixelsPerSecond: 100) == 5)
        #expect(TimelineGeometry.time(forViewportX: 200, scrollX: 500, pixelsPerSecond: 100) == 7)
    }

    @Test func roundTripViewportAndTime() {
        for pps in [8.0, 64.0, 240.0] {
            for scroll in [0.0, 137.5, 900.0] {
                for t in [0.0, 1.25, 42.0, 171.0] {
                    let x = TimelineGeometry.viewportX(forTime: t, scrollX: scroll, pixelsPerSecond: pps)
                    let back = TimelineGeometry.time(forViewportX: x, scrollX: scroll, pixelsPerSecond: pps)
                    #expect(abs(back - t) < 1e-6, "pps=\(pps) scroll=\(scroll) t=\(t)")
                }
            }
        }
    }

    @Test func seekTimeClampsToBounds() {
        let duration = 171.0
        // 左边界：点击在内容 0 之前 → 0
        #expect(TimelineGeometry.seekTime(forViewportX: -500, scrollX: 0,
                                          pixelsPerSecond: 64, duration: duration) == 0)
        // 右边界：超出总时长 → duration
        #expect(TimelineGeometry.seekTime(forViewportX: 99999, scrollX: 0,
                                          pixelsPerSecond: 64, duration: duration) == duration)
        // 播放后再点回 0 秒必须能回去（回归：不能因为播放过就失去回溯）
        #expect(TimelineGeometry.seekTime(forViewportX: 0, scrollX: 0,
                                          pixelsPerSecond: 64, duration: duration) == 0)
    }

    @Test func seekTimeWithZeroDurationIsNonNegative() {
        #expect(TimelineGeometry.seekTime(forViewportX: 100, scrollX: 0,
                                          pixelsPerSecond: 64, duration: 0) >= 0)
    }

    @Test func seekTimeIgnoresInvalidZoom() {
        // 缩放为 0 时不能产生 inf/nan
        let t = TimelineGeometry.seekTime(forViewportX: 100, scrollX: 0,
                                          pixelsPerSecond: 0, duration: 10)
        #expect(t.isFinite)
        #expect(t == 0)
    }

    @Test func contentWidthAndScrollClamp() {
        let w = TimelineGeometry.contentWidth(duration: 100, pixelsPerSecond: 64, viewportWidth: 800)
        #expect(w == 100 * 64 + 40)
        #expect(TimelineGeometry.maxScrollX(contentWidth: w, viewportWidth: 800) == w - 800)
        #expect(TimelineGeometry.clampScrollX(-50, contentWidth: w, viewportWidth: 800) == 0)
        #expect(TimelineGeometry.clampScrollX(1e9, contentWidth: w, viewportWidth: 800) == w - 800)
        // 内容比视口窄时不能滚动
        let small = TimelineGeometry.contentWidth(duration: 1, pixelsPerSecond: 4, viewportWidth: 800)
        #expect(small == 800)
        #expect(TimelineGeometry.clampScrollX(100, contentWidth: small, viewportWidth: 800) == 0)
    }

    @Test func zoomKeepsAnchorTimeAtSameViewportFraction() {
        // 缩放后，锚点时间在视口里的相对位置应保持不变
        let viewport = 800.0
        let anchorTime = 60.0
        let fraction = 0.5
        for newPPS in [16.0, 32.0, 128.0, 256.0] {
            let content = TimelineGeometry.contentWidth(duration: 171, pixelsPerSecond: newPPS,
                                                       viewportWidth: viewport)
            let sx = TimelineGeometry.scrollXKeepingAnchor(anchorTime: anchorTime,
                                                          anchorViewportFraction: fraction,
                                                          newPixelsPerSecond: newPPS,
                                                          viewportWidth: viewport,
                                                          contentWidth: content)
            let x = TimelineGeometry.viewportX(forTime: anchorTime, scrollX: sx, pixelsPerSecond: newPPS)
            // 被夹住时（靠近两端）允许偏差，否则应精确回到一半处
            if sx > 0, sx < TimelineGeometry.maxScrollX(contentWidth: content, viewportWidth: viewport) {
                #expect(abs(x - fraction * viewport) < 1e-6, "pps=\(newPPS) 锚点跑到了 \(x)")
            }
            #expect(sx >= 0)
        }
    }

    // MARK: leading inset 统一坐标约定（本轮「播放头/点击/滚动/缩放」修复）

    @Test func leadingInsetShiftsContentAndViewportConsistently() {
        let lead = 16.0
        let pps = 64.0
        // 时间 0 在内容坐标 lead 处（正文左边预留的安全起点）
        #expect(TimelineGeometry.contentX(forTime: 0, pixelsPerSecond: pps, leadingPadding: lead) == lead)
        // bodyX（各轨道手势的本地坐标）不受 inset 影响：0 = 时间 0
        #expect(TimelineGeometry.time(forBodyX: 0, pixelsPerSecond: pps) == 0)
        #expect(TimelineGeometry.time(forContentX: lead, pixelsPerSecond: pps, leadingPadding: lead) == 0)
        // 视口坐标 = 内容坐标 - scrollX
        #expect(TimelineGeometry.viewportX(forTime: 0, scrollX: 0,
                                           pixelsPerSecond: pps, leadingPadding: lead) == lead)
        #expect(TimelineGeometry.viewportX(forTime: 0, scrollX: lead,
                                           pixelsPerSecond: pps, leadingPadding: lead) == 0)
    }

    @Test func seekWithLeadingInsetRoundTrips() {
        let lead = 16.0
        for pps in [8.0, 64.0, 240.0] {
            for scroll in [0.0, 137.5, 900.0] {
                for t in [0.0, 1.25, 42.0, 171.0] {
                    let vx = TimelineGeometry.viewportX(forTime: t, scrollX: scroll,
                                                        pixelsPerSecond: pps, leadingPadding: lead)
                    let back = TimelineGeometry.seekTime(forViewportX: vx, scrollX: scroll,
                                                         pixelsPerSecond: pps, duration: 200,
                                                         leadingPadding: lead)
                    #expect(abs(back - t) < 1e-6, "lead=\(lead) pps=\(pps) scroll=\(scroll) t=\(t)")
                }
            }
        }
    }

    @Test func seekAtLeadingInsetHitsZero() {
        // 点击正好落在 leading inset 之后的 0:00 处，必须 seek 到 0，而不是一个 inset 对应的时间
        let lead = 16.0
        #expect(TimelineGeometry.seekTime(forViewportX: lead, scrollX: 0, pixelsPerSecond: 100,
                                          duration: 100, leadingPadding: lead) == 0)
        // 点在 inset 空白区更靠左也夹到 0
        #expect(TimelineGeometry.seekTime(forViewportX: 0, scrollX: 0, pixelsPerSecond: 100,
                                          duration: 100, leadingPadding: lead) == 0)
    }

    @Test func zoomAnchorIncludesLeadingInset() {
        // 播放头在 0:00、未滚动时缩放：锚点比例应包含 inset，
        // 否则 scrollX 会被算成 inset，时间线整体左移一次。
        let lead = 16.0
        let viewport = 800.0
        let newPPS = 128.0
        let content = TimelineGeometry.contentWidth(duration: 200, pixelsPerSecond: newPPS,
                                                    viewportWidth: viewport, leadingPadding: lead)
        let sx = TimelineGeometry.scrollXKeepingAnchor(anchorTime: 0,
                                                       anchorViewportFraction: lead / viewport,
                                                       newPixelsPerSecond: newPPS,
                                                       viewportWidth: viewport,
                                                       contentWidth: content,
                                                       leadingPadding: lead)
        #expect(sx == 0, "0:00 未滚动时缩放不应把时间线整体左移，实际 scroll=\(sx)")
    }
}

/// 播放时时间线自动跟随：拖动色块 / scrub 期间不能滚。
@Suite struct TimelineAutoFollowTests {
    private func follow(playing: Bool = true, interacting: Bool = false,
                        x: Double, scroll: Double = 0, width: Double = 1000) -> Bool {
        TimelineAutoFollow.shouldFollow(isPlaying: playing, isInteracting: interacting,
                                        viewportWidth: width, playheadContentX: x, scrollX: scroll)
    }

    @Test func followsOnlyWhenThePlayheadLeavesTheSafeMargin() {
        #expect(!follow(x: 500))                  // 在视口中间
        #expect(follow(x: 900))                   // 靠近右边缘（> 880）
        #expect(follow(x: 100))                   // 靠近左边缘（< 120）
        #expect(follow(x: 1500, scroll: 0))       // 已经跑出视口
        #expect(!follow(x: 1500, scroll: 1000))   // 视口已经滚过去了
    }

    @Test func neverFollowsWhileDraggingABlockOrScrubbing() {
        #expect(!follow(interacting: true, x: 900), "拖色块时播放头跑到边缘也不能滚")
        #expect(!follow(interacting: true, x: 5000))
    }

    @Test func neverFollowsWhenPausedOrWhenTheViewportIsNotMeasuredYet() {
        #expect(!follow(playing: false, x: 5000))
        #expect(!follow(x: 5000, width: 50))
    }
}
