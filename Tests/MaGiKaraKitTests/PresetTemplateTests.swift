import Foundation
import Testing
@testable import MaGiKaraKit

/// 歌词模版：每套都是「样式 + 换行节奏」。
@Suite struct PresetTemplateTests {

    private let all = SubtitleStyle.Preset.allCases

    @Test func thereAreEnoughTemplatesWithUniqueNames() {
        #expect(all.count >= 11)
        #expect(Set(all.map(\.displayName)).count == all.count)
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(all.allSatisfy { !$0.summary.isEmpty })
    }

    @Test func everyTemplateHasASaneStyle() {
        for preset in all {
            let s = preset.style
            #expect(s.fontSize >= 40 && s.fontSize <= 100, "\(preset.displayName) 字号 \(s.fontSize)")
            #expect(s.strokeWidth >= 3, "\(preset.displayName) 描边太细")
            #expect(s.unsungColor != s.sungColor, "\(preset.displayName) 未唱色与已唱色相同，看不出扫色")
            #expect(s.rubySizeFactor > 0.3 && s.rubySizeFactor < 0.5)
        }
    }

    /// 回归：旧模版的行距只有 14，假名会压到上一行（导出里实测看到过）。
    /// 现在行距必须放得下假名：行距 ≥ 假名高度 + 描边。
    @Test func lineGapLeavesRoomForRubyAboveTheLowerLine() {
        for preset in all {
            let s = preset.style
            let rubyHeight = s.fontSize * s.rubySizeFactor
            #expect(s.lineGap >= rubyHeight + s.strokeWidth,
                    "\(preset.displayName)：行距 \(s.lineGap) 放不下假名（\(rubyHeight) + 描边 \(s.strokeWidth)）")
        }
    }

    @Test func bothLinesStayInsideTheCanvasSafeArea() {
        for preset in all {
            let s = preset.style
            let half = (s.fontSize + s.lineGap) / 2
            let center = 540 + s.positionY
            let lowerBottom = center + half + s.fontSize / 2
            let upperTop = center - half - s.fontSize / 2 - s.fontSize * s.rubySizeFactor
            #expect(lowerBottom <= 1080 * (1 - 0.04), "\(preset.displayName) 下行贴到画面底边：\(lowerBottom)")
            #expect(upperTop >= 1080 * 0.45, "\(preset.displayName) 上行（含假名）跑到画面上半部：\(upperTop)")
        }
    }

    @Test func nicokaraTemplatesArePageFlipWithTheMeasuredRhythm() {
        let nicokara: [SubtitleStyle.Preset] = [.nicokaraBlue, .nicokaraPink, .nicokaraGold]
        for preset in nicokara {
            let p = preset.displayPolicy
            #expect(p.mode == .pageFlip)
            #expect(p.leadIn == 1.5, "提前量约 1.5 秒")
            #expect((0.6...1.0).contains(p.lowerLineDelay), "下行比上行晚 0.6–1.0 秒")
            #expect((0.3...0.6).contains(p.pageGap), "页间空白约 0.4 秒")
            #expect(preset.style.lineLayout == .staggered, "第二行错开排版：上行靠左、下行靠右")
        }
    }

    @Test func originalTemplatesKeepRollingAndMinimalStaysCentered() {
        #expect(SubtitleStyle.Preset.classicKaraoke.displayPolicy == DisplayPolicy())
        #expect(SubtitleStyle.Preset.vocaloidPurpleBlue.displayPolicy.mode == .rolling)
        #expect(SubtitleStyle.Preset.minimalMV.style.lineLayout == .center)
        // 其余模版默认都是上行靠左、下行靠右
        for preset in all where preset != .minimalMV {
            #expect(preset.style.lineLayout == .staggered, "\(preset.displayName)")
        }
    }

    @Test func staggeredLinesDoNotCollideWithEachOther() {
        // 错开：上行从左边距开始、下行在右边距结束；两行水平上不重叠才有意义（长度合理时）
        for preset in all where preset.style.lineLayout == .staggered {
            let s = preset.style
            let font = KaraokeLayout.mainFont(style: s)
            let w = KaraokeLayout.width(of: "あいうえおかきくけこ", font: font)
            let upperRight = s.lineCenterX(for: .upper, lineWidth: w) + w / 2
            let lowerLeft = s.lineCenterX(for: .lower, lineWidth: w) - w / 2
            #expect(upperRight < 960 + 960 - 2 * s.horizontalMargin)
            #expect(lowerLeft > -960 + s.horizontalMargin - 1e-6)
        }
    }

    @Test func styleSwitchesBetweenLineLayouts() {
        var s = SubtitleStyle()
        for layout in SubtitleLineLayout.allCases {
            s.setLineLayout(layout)
            #expect(s.lineLayout == layout)
        }
        s.upperAlignment = .trailing; s.lowerAlignment = .leading
        #expect(s.lineLayout == nil, "两行是别的组合时没有对应的整体版式")
    }
}

/// 新项目默认错开排版；旧工程保持原样。
@Suite struct DefaultStyleLayoutTests {
    @Test func newProjectsUseTheStaggeredDefaultLayout() {
        let style = KaraProject().style
        #expect(style.lineLayout == .staggered, "新项目：上行靠左、下行靠右")
        #expect(style == SubtitleStyle.Preset.classicKaraoke.style)
        #expect(style.lineGap >= style.fontSize * style.rubySizeFactor + style.strokeWidth)
    }

    @Test func projectsWithoutAStyleKeepTheLegacyCenteredLook() throws {
        var json = try #require(JSONSerialization.jsonObject(
            with: ProjectStore.encode(KaraProject())) as? [String: Any])
        json.removeValue(forKey: "style")
        let old = try ProjectStore.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.style == SubtitleStyle.legacyDefault)
        #expect(old.style.lineLayout == .center)
    }

    @Test func partialOldStylesAreNotRewrittenByTheNewDefault() throws {
        // 旧工程的样式只存了几个字段：缺失的部分必须取旧默认（居中、行距 14），而不是新默认
        let old = try JSONDecoder().decode(SubtitleStyle.self,
                                           from: Data(#"{"fontSize": 60}"#.utf8))
        #expect(old.fontSize == 60)
        #expect(old.lineLayout == .center)
        #expect(old.lineGap == 14)
    }
}
