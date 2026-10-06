import SwiftUI
import AppKit
import MaGiKaraKit

/// 菜单只推荐当前机器确实安装的日文字体；系统字体分组保留完整本机字体族列表。
private enum JapaneseFontCatalog {
    private static let recommendations = [
        "Hiragino Sans",
        "Hiragino Maru Gothic ProN",
        "Hiragino Mincho ProN",
        "YuGothic",
        "YuMincho",
        "Source Han Sans JP",
        "Noto Sans JP",
        "Noto Serif JP",
        "BIZ UDGothic",
        "BIZ UDMincho",
        "Klee",
        "Tsukushi A Round Gothic",
        "Tsukushi B Round Gothic",
        "Toppan Bunkyu Gothic",
        "Toppan Bunkyu Mincho",
    ]

    static let systemFonts = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    static let recommendedFonts: [String] = recommendations.compactMap { recommended in
        systemFonts.first { $0.caseInsensitiveCompare(recommended) == .orderedSame }
    }
}

/// 右侧紧凑属性面板（RD §3）：只保留两个主 Tab —— `文本` 与 `字幕`。
///
/// - `文本`：统一样式层（字体、字号、字重、填充、描边、对齐、行距等）；
/// - `字幕`：当前选中 LyricLine 的实例层（文案、上下行、层级、时间、Ruby）。
///
/// 不再有「字幕模版」标题，也不新增第三个主 Tab。
struct InspectorPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if state.selectedCountdown != nil {
                        CountdownInspector()
                    } else {
                        switch state.inspectorTab {
                        case .text:
                            TextStyleInspector()
                        case .subtitle:
                            SubtitleInstanceInspector()
                        }
                    }
                }
                .padding(11)
            }
        }
        .background(.white.opacity(0.40))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(InspectorPrimaryTab.allCases) { tab in
                Button {
                    state.setInspectorTab(tab)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 10, weight: .medium))
                        Text(tab.title).font(.system(size: 11, weight: state.inspectorTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(state.inspectorTab == tab ? .white : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.inspectorTab == tab
                                  ? AnyShapeStyle(Theme.accentGradient)
                                  : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .text ? "统一调整所有字幕的视觉样式" : "编辑当前选中片段的文案、时间与假名")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

// MARK: - 文本 Tab：统一样式层

struct TextStyleInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let style = state.project.style
        let activeLane = state.selectedLine?.lane
        let activePosition = activeLane.map(style.position(for:)) ??
            (x: style.positionX, y: style.positionY)

        VStack(alignment: .leading, spacing: 11) {
            Text("样式统一作用于全部字幕，不影响文案、假名与时间。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // 字体
            InspectorFontMenuField(label: "字体", selection: style.fontName,
                                   recommendedFonts: JapaneseFontCatalog.recommendedFonts,
                                   systemFonts: JapaneseFontCatalog.systemFonts) { newValue in
                state.updateStyle { $0.fontName = newValue }
            }

            InspectorSliderField(label: "字号", value: style.fontSize, range: 24...140, format: "%.0f") { v in
                state.updateStyle { $0.fontSize = v }
            }

            InspectorMenuField(label: "字重", selection: Self.weightName(style.fontWeight),
                               options: Self.weightNames) { name in
                state.updateStyle { $0.fontWeight = Self.weightValue(name) }
            }

            InspectorLabeledField(label: "排版") {
                HStack(spacing: 3) {
                    ForEach(SubtitleLineLayout.allCases, id: \.self) { layout in
                        Button {
                            state.updateStyle { $0.setLineLayout(layout) }
                        } label: {
                            Text(layout.displayName)
                                .font(.system(size: 10))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(style.lineLayout == layout ? Theme.violet.opacity(0.18) : Theme.controlFill)
                                )
                                .foregroundStyle(style.lineLayout == layout ? Theme.violet : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(layout == .staggered
                              ? "上行靠左、下行靠右，两行错开（ニコカラ 常见排版）"
                              : "两行都\(layout.displayName)")
                    }
                }
            }
            if style.lineLayout != .center {
                InspectorSliderField(label: "左右边距", value: style.horizontalMargin, range: 0...400, format: "%.0f") { v in
                    state.updateStyle { $0.horizontalMargin = v }
                }
            }

            InspectorLabeledField(label: activeLane.map { "位置 · \($0.displayName)" } ?? "位置 · 双轨") {
                HStack(spacing: 5) {
                    InspectorNumberField(label: "X", value: activePosition.x) { v in
                        state.updateStyle { style in
                            if let activeLane {
                                var p = style.position(for: activeLane)
                                p.x = v
                                style.setPosition(p, for: activeLane)
                            } else {
                                style.setPositionForAllTracks(x: v)
                            }
                        }
                    }
                    InspectorNumberField(label: "Y", value: activePosition.y) { v in
                        state.updateStyle { style in
                            if let activeLane {
                                var p = style.position(for: activeLane)
                                p.y = v
                                style.setPosition(p, for: activeLane)
                            } else {
                                style.setPositionForAllTracks(y: v)
                            }
                        }
                    }
                }
            }

            // 一键把双行字幕块吸附到底部安全区（验收要求：字幕固定在底部安全区）
            Button {
                state.updateStyle {
                    let y = SubtitleStyle.bottomSafeAreaPositionY(fontSize: $0.fontSize,
                                                                   lineGap: $0.lineGap)
                    if let activeLane {
                        var p = $0.position(for: activeLane)
                        p.y = y
                        $0.setPosition(p, for: activeLane)
                    } else {
                        $0.setPositionForAllTracks(y: y)
                    }
                }
            } label: {
                Label("吸附到底部安全区", systemImage: "arrow.down.to.line")
                    .font(.system(size: 10.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Theme.violet)
            }
            .buttonStyle(.plain)

            InspectorSliderField(label: "两行间距", value: style.lineGap, range: 0...60, format: "%.0f") { v in
                state.updateStyle { $0.lineGap = v }
            }

            // 全局字幕轨道：一次应用到所有片段，不提供逐句动画配置。
            Divider().overlay(Theme.divider)
            Text("全局字幕轨道")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("统一控制所有歌词的入场与出场，默认硬切。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            InspectorMenuField(label: "入场效果", selection: style.entryEffect.displayName,
                               options: SubtitleTransitionEffect.allCases.map(\.displayName)) { name in
                if let effect = SubtitleTransitionEffect.allCases.first(where: { $0.displayName == name }) {
                    state.updateStyle { $0.entryEffect = effect }
                }
            }
            InspectorMenuField(label: "出场效果", selection: style.exitEffect.displayName,
                               options: SubtitleTransitionEffect.allCases.map(\.displayName)) { name in
                if let effect = SubtitleTransitionEffect.allCases.first(where: { $0.displayName == name }) {
                    state.updateStyle { $0.exitEffect = effect }
                }
            }
            Toggle("显示倒计时", isOn: Binding(
                get: { style.countdownEnabled },
                set: { v in state.updateStyle { $0.countdownEnabled = v } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .help("总开关：关掉后预览和导出都不显示任何倒计时")
            Text("倒计时在时间线「倒计时」轨道上：选中色块即可编辑时间、点数、大小、位置和走轨颜色。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.divider)
            Text("换行节奏")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            let policy = state.project.displayPolicy
            InspectorMenuField(label: "换行方式", selection: policy.mode.displayName,
                               options: DisplayMode.allCases.map(\.displayName)) { name in
                if let mode = DisplayMode.allCases.first(where: { $0.displayName == name }) {
                    state.updateDisplayPolicy { $0.mode = mode }
                }
            }
            InspectorSliderField(label: "提前量", value: policy.leadIn, range: 0...3, format: "%.1f") { v in
                state.updateDisplayPolicy { $0.leadIn = v }
            }
            if policy.mode == .pageFlip {
                InspectorSliderField(label: "下行延后", value: policy.lowerLineDelay, range: 0...1.5, format: "%.1f") { v in
                    state.updateDisplayPolicy { $0.lowerLineDelay = v }
                }
                InspectorSliderField(label: "页间空白", value: policy.pageGap, range: 0...1.5, format: "%.1f") { v in
                    state.updateDisplayPolicy { $0.pageGap = v }
                }
            }
            Text(policy.mode == .pageFlip
                 ? "翻页：上下两行成对出现、一页唱完整页换掉；下行比上行晚进场、晚退场，页与页之间留一小段空白。提前量 = 歌词比开唱早出现多久（单位：秒）。"
                 : "滚动：每一行等到同一行的下一句来了才被替换。提前量 = 歌词比开唱早出现多久（单位：秒）。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("整体走轨")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("提前") { state.shiftAllLines(by: -0.05) }
                    .help("全部歌词连同走轨一起提前 0.05 秒（可撤销）")
                Button("延后") { state.shiftAllLines(by: 0.05) }
                    .help("全部歌词连同走轨一起延后 0.05 秒（可撤销）")
            }
            .controlSize(.small)
            .font(.system(size: 10.5))
            .disabled(state.project.lyricLines.isEmpty)
            Text("觉得变色整体比唱的早或晚时用：每点一次，所有句子的出现、走轨、消失一起移动 0.05 秒，可撤销。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.divider)

            InspectorColorField(label: "未唱颜色", color: style.unsungColor) { c in
                state.updateStyle { $0.unsungColor = c }
            }
            InspectorColorField(label: "已唱颜色", color: style.sungColor) { c in
                state.updateStyle { $0.sungColor = c }
            }
            Toggle("已唱使用渐变", isOn: Binding(
                get: { style.sungGradientEnabled },
                set: { v in state.updateStyle { $0.sungGradientEnabled = v } }))
                .font(.system(size: 10.5))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if style.sungGradientEnabled {
                InspectorColorField(label: "渐变终点", color: style.sungGradientEndColor) { c in
                    state.updateStyle { $0.sungGradientEndColor = c }
                }
            }

            Divider().overlay(Theme.divider)

            InspectorColorField(label: "描边颜色", color: style.strokeColor) { c in
                state.updateStyle { $0.strokeColor = c }
            }
            InspectorSliderField(label: "描边宽度", value: style.strokeWidth, range: 0...12, format: "%.1f") { v in
                state.updateStyle { $0.strokeWidth = v }
            }

            InspectorColorField(label: "阴影颜色", color: style.shadowColor) { c in
                state.updateStyle { $0.shadowColor = c }
            }
            InspectorSliderField(label: "阴影模糊", value: style.shadowBlur, range: 0...60, format: "%.0f") { v in
                state.updateStyle { $0.shadowBlur = v }
            }
            InspectorSliderField(label: "不透明度", value: style.shadowOpacity, range: 0...1,
                                 format: "%.0f%%", scale: 100) { v in
                state.updateStyle { $0.shadowOpacity = v }
            }

            Divider().overlay(Theme.divider)

            InspectorFontMenuField(label: "假名字体", selection: style.rubyFontName,
                                   recommendedFonts: JapaneseFontCatalog.recommendedFonts,
                                   systemFonts: JapaneseFontCatalog.systemFonts) { newValue in
                state.updateStyle { $0.rubyFontName = newValue }
            }
            InspectorSliderField(label: "假名大小", value: style.rubySizeFactor * 100, range: 30...55, format: "%.0f") { v in
                state.updateStyle { $0.rubySizeFactor = v / 100 }
            }
            InspectorSliderField(label: "假名偏移", value: style.rubyVerticalOffset, range: -50...10, format: "%.0f") { v in
                state.updateStyle { $0.rubyVerticalOffset = v }
            }
        }
    }

    // 字重：用中文名显示，避免直接暴露 100–900 的数字
    static let weightNames = ["细", "常规", "中黑", "半粗", "粗体", "特粗"]
    private static let weightValues = [300, 400, 500, 600, 700, 800]

    static func weightName(_ value: Int) -> String {
        guard let idx = weightValues.firstIndex(of: value) else { return "粗体" }
        return weightNames[idx]
    }

    static func weightValue(_ name: String) -> Int {
        guard let idx = weightNames.firstIndex(of: name) else { return 700 }
        return weightValues[idx]
    }

    private func alignIcon(_ a: SubtitleAlignment) -> String {
        switch a {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }
}

// MARK: - 字幕 Tab：当前实例层

struct SubtitleInstanceInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let line = state.selectedLine {
            content(for: line)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.violet)
                Text(SubtitleEditorRouting.emptySelectionHint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("在时间线上单击任意歌词色块，右侧会自动切到本 Tab 并载入该行。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.controlFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func content(for line: LyricLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "text.cursor").font(.system(size: 10))
                Text("第 \(line.order) 句").font(.system(size: 11, weight: .semibold))
                if line.isManuallyAdjusted {
                    Label("已手动调整", systemImage: "hand.raised.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.violet)
                }
                Spacer(minLength: 0)
                Button("取消选择") { state.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.violet)
            }
            .foregroundStyle(Theme.textPrimary)

            // 文案
            InspectorLabeledField(label: "文案") {
                CommitTextField(text: line.displayText, placeholder: "输入这一行的歌词") { text in
                    state.setLineText(id: line.id, text: text)
                }
            }
            Text("单行歌词，不检测出显式换行时按当前预览规则处理。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)

            // 上下行
            InspectorLabeledField(label: "所属行") {
                HStack(spacing: 3) {
                    ForEach(ScreenLane.allCases, id: \.self) { lane in
                        Button {
                            state.setLineLane(id: line.id, lane: lane)
                        } label: {
                            Text(lane.displayName)
                                .font(.system(size: 10.5, weight: line.lane == lane ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(line.lane == lane ? Theme.violet.opacity(0.18) : Theme.controlFill)
                                )
                                .foregroundStyle(line.lane == lane ? Theme.violet : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if line.laneIsManual {
                Text("已手工指定轨道，重新排布不会改回自动交替。")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }

            // 层级
            InspectorLabeledField(label: "层级（同轨叠放顺序）") {
                HStack(spacing: 6) {
                    Button { state.setLineLayer(id: line.id, layer: line.layer - 1) } label: {
                        Image(systemName: "minus").font(.system(size: 9))
                            .frame(width: 20, height: 20)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    Text("\(line.layer)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .frame(width: 26)
                    Button { state.setLineLayer(id: line.id, layer: line.layer + 1) } label: {
                        Image(systemName: "plus").font(.system(size: 9))
                            .frame(width: 20, height: 20)
                            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }

            Divider().overlay(Theme.divider)
            Text("时间").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            // 色块可见开始/结束 = displayStart/displayEnd
            HStack(spacing: 5) {
                InspectorNumberField(label: "可见开始", value: line.displayStart, format: "%.2f") { v in
                    state.applyDisplayTimeEdit(lineID: line.id, start: v, end: nil)
                }
                InspectorNumberField(label: "可见结束", value: line.displayEnd, format: "%.2f") { v in
                    state.applyDisplayTimeEdit(lineID: line.id, start: nil, end: v)
                }
            }
            InspectorNumberField(label: "可见时长", value: line.displayDuration, format: "%.2f") { v in
                state.applyDisplayTimeEdit(lineID: line.id, start: nil, end: line.displayStart + max(LyricLine.minimumSingDuration, v))
            }
            Text("色块长度 = 可见开始 → 可见结束；结束必须大于开始，同轨不允许重叠。")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // singStart/singEnd 保留给卡拉OK扫色，作为高级字段，不合并两组时间。
            DisclosureGroup("高级 · 扫色时间") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        InspectorNumberField(label: "扫色开始", value: line.singStart, format: "%.2f") { v in
                            state.applySingTimeEdit(lineID: line.id, start: v, end: nil)
                        }
                        InspectorNumberField(label: "扫色结束", value: line.singEnd, format: "%.2f") { v in
                            state.applySingTimeEdit(lineID: line.id, start: nil, end: v)
                        }
                    }
                    InspectorNumberField(label: "扫色时长", value: line.singDuration, format: "%.2f") { v in
                        state.applySingTimeEdit(lineID: line.id, start: nil,
                                                end: line.singStart + max(LyricLine.minimumSingDuration, v))
                    }
                    Text("扫色时间只控制匀速变色；可见区始终包住扫色区。")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 10.5))
            .tint(Theme.violet)

            Divider().overlay(Theme.divider)
            rubySection(for: line)

            Divider().overlay(Theme.divider)
            HStack(spacing: 6) {
                Button {
                    state.duplicateLine(id: line.id)
                } label: {
                    Label("复制该句", systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button {
                    state.deleteLine(id: line.id)
                } label: {
                    Label("删除该句", systemImage: "trash")
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Theme.errorSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ruby 逐汉字段编辑

    @ViewBuilder
    private func rubySection(for line: LyricLine) -> some View {
        let slots = RubySlotBuilder.slots(for: line)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                Text("假名 / Ruby")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                if !slots.isEmpty {
                    Button("重置为自动") { state.resetRubyOverrides(lineID: line.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.violet)
                }
            }

            if slots.isEmpty {
                Text("本句没有需要注音的汉字（纯假名 / 拉丁不会生成 Ruby）。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if slots.contains(where: { $0.isUnconfirmed }) {
                    Label("自动对齐不可靠，已跳过猜测，请手动确认下方假名。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(slots) { slot in
                    rubyRow(slot, lineID: line.id)
                }
                Text("每个槽位对应一个汉字 / 熟字訓段；修改会立即写入并进入撤销栈。")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rubyRow(_ slot: RubyEditSlot, lineID: UUID) -> some View {
        HStack(spacing: 5) {
            Text(slot.characters)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 22)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))

            CommitTextField(text: slot.reading, placeholder: "假名") { reading in
                state.setRubyReading(lineID: lineID,
                                     tokenID: slot.tokenID,
                                     surfaceStart: slot.surfaceStart,
                                     surfaceLength: slot.surfaceLength,
                                     reading: reading)
            }

            if slot.reading.isEmpty {
                if slot.isOverride {
                    Button("恢复") {
                        state.restoreRubyBinding(lineID: lineID,
                                                 tokenID: slot.tokenID,
                                                 surfaceStart: slot.surfaceStart)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.violet)
                }
            } else {
                Button {
                    state.clearRubyBinding(lineID: lineID,
                                           tokenID: slot.tokenID,
                                           surfaceStart: slot.surfaceStart)
                } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("删除该汉字的假名绑定")
            }

            if slot.isUnconfirmed {
                Text("待确认")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

// MARK: - 共用控件

struct InspectorLabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            content
        }
    }
}

/// 统一样式的下拉选择。
/// 直接用 `Picker` 会渲染成对比度很低的样子（浅灰字几乎看不见），所以用 Menu 自己画。
struct InspectorMenuField: View {
    let label: String
    let selection: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { onSelect(option) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }
}

/// 字体专用分组菜单：推荐日文字体与完整本机字体列表作为两个同级入口。
struct InspectorFontMenuField: View {
    let label: String
    let selection: String
    let recommendedFonts: [String]
    let systemFonts: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Menu {
                Menu("推荐字体") {
                    ForEach(recommendedFonts, id: \.self, content: fontButton)
                }
                .disabled(recommendedFonts.isEmpty)

                Menu("系统字体") {
                    ForEach(systemFonts, id: \.self, content: fontButton)
                }
                .disabled(systemFonts.isEmpty)
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("推荐日文字体与本机已安装的系统字体")
        }
    }

    @ViewBuilder
    private func fontButton(_ family: String) -> some View {
        Button {
            onSelect(family)
        } label: {
            if family == selection {
                Label(family, systemImage: "checkmark")
            } else {
                Text(family)
            }
        }
    }
}

struct InspectorSliderField: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            KaraokeSlider(value: Binding(get: { value }, set: onChange), in: range)
                .frame(height: 16)
        }
    }
}

struct InspectorColorField: View {
    let label: String
    let color: RGBAColor
    let onChange: (RGBAColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { color.swiftUIColor },
                set: { newValue in
                    let ns = NSColor(newValue)
                    onChange(RGBAColor(nsColor: ns))
                }), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 42)
        }
    }
}

struct InspectorNumberField: View {
    let label: String
    let value: Double
    var format: String = "%.0f"
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            CommitNumberField(value: value, format: format, onCommit: onChange)
        }
    }
}

/// 文案输入：边输入边提交，切换片段 / Tab 前不会静默丢失。
struct CommitTextField: View {
    let text: String
    var placeholder: String = ""
    let onCommit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(text: String, placeholder: String = "", onCommit: @escaping (String) -> Void) {
        self.text = text
        self.placeholder = placeholder
        self.onCommit = onCommit
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
            .focused($focused)
            .onChange(of: draft) { _, newValue in
                if newValue != text { onCommit(newValue) }
            }
            .onChange(of: text) { _, newValue in
                if !focused, newValue != draft { draft = newValue }
            }
    }
}

/// 时间/数值输入：边输入边提交；非法输入在失焦时回退到最近的合法值。
struct CommitNumberField: View {
    let value: Double
    let format: String
    let onCommit: (Double) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: Double, format: String = "%.2f", onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.format = format
        self.onCommit = onCommit
        _draft = State(initialValue: String(format: format, value))
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 10.5).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .onChange(of: draft) { _, newValue in
                if let parsed = Double(newValue.trimmingCharacters(in: .whitespaces)), parsed.isFinite {
                    // 草稿被程序刷新成「当前值的四舍五入」时不要再提交回去：
                    // 否则拖动色块时，面板会把 19.5600001 悄悄改写成 19.56，并触发连锁修改。
                    guard String(format: format, parsed) != String(format: format, value) else { return }
                    onCommit(parsed)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { normalize() }
            }
            .onChange(of: value) { _, newValue in
                if !focused { draft = String(format: format, newValue) }
            }
            .onSubmit { normalize() }
    }

    private func normalize() {
        if let parsed = Double(draft.trimmingCharacters(in: .whitespaces)), parsed.isFinite {
            draft = String(format: format, parsed)
        } else {
            draft = String(format: format, value)
        }
    }
}


// MARK: - 倒计时编辑

/// 选中时间线「倒计时」轨道上的色块后显示：时间 + 样式（样式对所有倒计时共用）。
struct CountdownInspector: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let item = state.selectedCountdown {
            let style = state.project.style
            let cd = style.countdown
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                    Text("倒计时")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if item.isAuto {
                        Text("自动 · 跟随第一句")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.violet)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.violet.opacity(0.10), in: Capsule())
                            .help("开头的倒计时会自动贴合第一句歌词；你一改动它，就变成普通倒计时，不再被自动改回")
                    }
                    Spacer(minLength: 0)
                    Button("取消选择") { state.clearSelection() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.violet)
                }
                Text("色块存在的这段时间，画面上显示倒计时圆点；圆点画在下一句歌词将出现的位置。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.divider)
                Text("时间")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 5) {
                    InspectorNumberField(label: "开始", value: item.start, format: "%.2f") { v in
                        state.setCountdownTimes(id: item.id, start: v)
                    }
                    InspectorNumberField(label: "结束", value: item.end, format: "%.2f") { v in
                        state.setCountdownTimes(id: item.id, end: v)
                    }
                }
                InspectorNumberField(label: "时长", value: item.duration, format: "%.2f") { v in
                    state.setCountdownTimes(id: item.id,
                                            end: item.start + max(CountdownItem.minimumDuration, v))
                }

                Divider().overlay(Theme.divider)
                Text("样式（所有倒计时共用）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                InspectorMenuField(label: "表现方式", selection: cd.mode.displayName,
                                   options: CountdownMode.allCases.map(\.displayName)) { name in
                    if let mode = CountdownMode.allCases.first(where: { $0.displayName == name }) {
                        state.updateStyle { $0.countdown.mode = mode }
                    }
                }
                Text(cd.mode == .fill
                     ? "每个圆点依次被「走轨色」从左到右填满，整个色块走完时恰好全部填满。"
                     : "圆点逐个熄灭（3 → 2 → 1）。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                InspectorSliderField(label: "点数", value: Double(cd.dotCount),
                                     range: Double(CountdownStyle.dotCountRange.lowerBound)...Double(CountdownStyle.dotCountRange.upperBound),
                                     format: "%.0f") { v in
                    state.updateStyle { $0.countdown.dotCount = Int(v.rounded()) }
                }
                InspectorSliderField(label: "圆点大小", value: cd.sizeFactor, range: 0.1...0.6, format: "%.2f") { v in
                    state.updateStyle { $0.countdown.sizeFactor = v }
                }
                InspectorSliderField(label: "点间距", value: cd.spacingFactor, range: 0...0.8, format: "%.2f") { v in
                    state.updateStyle { $0.countdown.spacingFactor = v }
                }
                HStack(spacing: 5) {
                    InspectorNumberField(label: "偏移 X", value: cd.offsetX, format: "%.0f") { v in
                        state.updateStyle { $0.countdown.offsetX = v }
                    }
                    InspectorNumberField(label: "偏移 Y", value: cd.offsetY, format: "%.0f") { v in
                        state.updateStyle { $0.countdown.offsetY = v }
                    }
                }
                Text("偏移相对下一句歌词所在的位置（正数向右 / 向下）。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)

                Divider().overlay(Theme.divider)
                Text("颜色")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Toggle("未走轨色跟随歌词未唱色", isOn: Binding(
                    get: { cd.unsungColor == nil },
                    set: { follow in
                        state.updateStyle { $0.countdown.unsungColor = follow ? nil : style.unsungColor }
                    }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                if let color = cd.unsungColor {
                    InspectorColorField(label: "未走轨色", color: color) { c in
                        state.updateStyle { $0.countdown.unsungColor = c }
                    }
                }
                if cd.mode == .fill {
                    Toggle("走轨色跟随歌词已唱色", isOn: Binding(
                        get: { cd.sweepColor == nil },
                        set: { follow in
                            state.updateStyle { $0.countdown.sweepColor = follow ? nil : style.sungColor }
                        }))
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    if let color = cd.sweepColor {
                        InspectorColorField(label: "走轨色", color: color) { c in
                            state.updateStyle { $0.countdown.sweepColor = c }
                        }
                    }
                }

                Divider().overlay(Theme.divider)
                HStack(spacing: 8) {
                    Button("在播放头再加一个") { state.addCountdown(at: state.playhead) }
                    Button("删除此倒计时", role: .destructive) { state.deleteCountdown(id: item.id) }
                }
                .font(.system(size: 11))
                if !item.isAuto && !state.project.countdowns.contains(where: \.isAuto) {
                    Button("恢复开头自动倒计时") { state.restoreAutoOpeningCountdown() }
                        .font(.system(size: 11))
                        .help("重新生成跟随第一句歌词的开头倒计时")
                }
            }
        }
    }
}
