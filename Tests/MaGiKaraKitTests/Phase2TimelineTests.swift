import Testing
import Foundation
@testable import MaGiKaraKit

private func makeLine(order: Int = 1,
                      text: String = "なんもねえ",
                      displayStart: Double = 9.0,
                      singStart: Double = 10.0,
                      singEnd: Double = 12.0,
                      displayEnd: Double = 13.0,
                      morae: [(String, Double, Double)] = []) -> LyricLine {
    var tokens: [LyricToken] = []
    if !morae.isEmpty {
        tokens = [LyricToken(surface: text, reading: nil,
                             morae: morae.map { MoraTiming(mora: $0.0, start: $0.1, end: $0.2) },
                             sourceStart: 0, sourceLength: text.count)]
    } else {
        tokens = [LyricToken(surface: text, reading: nil, morae: [],
                             sourceStart: 0, sourceLength: text.count)]
    }
    return LyricLine(order: order, displayText: text,
                     displayStart: displayStart, singStart: singStart,
                     singEnd: singEnd, displayEnd: displayEnd, tokens: tokens)
}

private func makeProject(lines: [LyricLine], duration: Double = 60) -> KaraProject {
    var p = KaraProject()
    p.duration = duration
    p.lyricLines = lines
    return p
}

@Suite struct SnapEngineTests {

    @Test func snapsToPlayheadWithinThreshold() {
        let project = makeProject(lines: [makeLine(order: 1)])
        let r = SnapEngine.snap(10.03, project: project, excluding: nil,
                                pixelsPerSecond: 100, playhead: 10.0, duration: 60)
        #expect(r.didSnap)
        #expect(r.target == .playhead)
        #expect(abs(r.time - 10.0) < 1e-9)
    }

    @Test func doesNotSnapOutsideThreshold() {
        let project = makeProject(lines: [makeLine(order: 1)])
        // 阈值 = 8px / 100pps = 0.08s；0.5s 远在阈值外
        let r = SnapEngine.snap(10.5, project: project, excluding: nil,
                                pixelsPerSecond: 100, playhead: 10.0, duration: 60)
        #expect(!r.didSnap)
        #expect(abs(r.time - 10.5) < 1e-9)
    }

    @Test func thresholdIsZoomIndependent() {
        // 同一个「像素距离」在不同缩放下应给出同样的判定
        let project = makeProject(lines: [makeLine(order: 1)])
        let atLowZoom = SnapEngine.snap(10.5, project: project, excluding: nil,
                                        pixelsPerSecond: 10, playhead: 10.0, duration: 60)
        // 10pps 时阈值 0.8s，10.5 应该吸附
        #expect(atLowZoom.didSnap)
        let atHighZoom = SnapEngine.snap(10.5, project: project, excluding: nil,
                                         pixelsPerSecond: 400, playhead: 10.0, duration: 60)
        // 400pps 时阈值 0.02s，不该吸附
        #expect(!atHighZoom.didSnap)
    }

    @Test func toggleOffDisablesSnapping() {
        var cfg = SnapConfig.default
        cfg.enabled = false
        let project = makeProject(lines: [makeLine(order: 1)])
        let r = SnapEngine.snap(10.01, project: project, excluding: nil,
                                pixelsPerSecond: 100, playhead: 10.0, duration: 60, config: cfg)
        #expect(!r.didSnap)
    }

    @Test func optionTemporarilyDisablesSnapping() {
        let project = makeProject(lines: [makeLine(order: 1)])
        let r = SnapEngine.snap(10.01, project: project, excluding: nil,
                                pixelsPerSecond: 100, playhead: 10.0, duration: 60,
                                temporarilyDisabled: true)
        #expect(!r.didSnap)
    }

    @Test func snapsToAdjacentAcousticPoints() {
        let a = makeLine(order: 1, displayStart: 9, singStart: 10, singEnd: 12, displayEnd: 13)
        let b = makeLine(order: 2, displayStart: 13, singStart: 14, singEnd: 16, displayEnd: 17)
        let project = makeProject(lines: [a, b])
        // 拖 b 时应该能吸到 a 的演唱终点 12
        let r = SnapEngine.snap(12.02, project: project, excluding: b.id,
                                pixelsPerSecond: 100, playhead: 40, duration: 60)
        #expect(r.didSnap)
        #expect(r.target == .acousticOffset)
        #expect(abs(r.time - 12) < 1e-9)
    }

    @Test func snapsToTimelineStartAndAudioEnd() {
        let project = makeProject(lines: [makeLine(order: 1)], duration: 60)
        let start = SnapEngine.snap(0.02, project: project, excluding: nil,
                                    pixelsPerSecond: 100, playhead: 30, duration: 60)
        #expect(start.target == .timelineStart)
        let end = SnapEngine.snap(59.99, project: project, excluding: nil,
                                  pixelsPerSecond: 100, playhead: 30, duration: 60)
        #expect(end.target == .audioBoundary)
    }

    @Test func snappingNeverMutatesAsrTokenTimes() {
        // 关键约束：吸附只决定落点，不得改写 ASR 的 token/mora 时间
        let morae = [("な", 10.0, 10.3), ("ん", 10.3, 10.6), ("も", 10.6, 11.0)]
        let line = makeLine(order: 1, morae: morae)
        let project = makeProject(lines: [line])
        let before = line.tokens.flatMap { $0.morae.map { ($0.mora, $0.start, $0.end) } }

        _ = SnapEngine.snap(10.01, project: project, excluding: nil,
                            pixelsPerSecond: 100, playhead: 10.0, duration: 60)

        let after = project.lyricLines[0].tokens.flatMap { $0.morae.map { ($0.mora, $0.start, $0.end) } }
        #expect(before.count == after.count)
        for (b, a) in zip(before, after) {
            #expect(b.0 == a.0)
            #expect(abs(b.1 - a.1) < 1e-12, "吸附不应改动 token 时间")
            #expect(abs(b.2 - a.2) < 1e-12)
        }
    }

    @Test func zeroZoomDoesNotCrash() {
        let project = makeProject(lines: [makeLine(order: 1)])
        let r = SnapEngine.snap(10.0, project: project, excluding: nil,
                                pixelsPerSecond: 0, playhead: 10, duration: 60)
        #expect(r.time.isFinite)
        #expect(!r.didSnap)
    }
}

@Suite struct LineSplitterTests {

    private func splittableLine() -> LyricLine {
        // 4 个字、4 个音拍，均匀落在 10–14
        makeLine(order: 1, text: "きみのうた",
                 displayStart: 9, singStart: 10, singEnd: 14, displayEnd: 15,
                 morae: [("き", 10.0, 11.0), ("み", 11.0, 12.0),
                         ("の", 12.0, 13.0), ("う", 13.0, 14.0)])
    }

    @Test func rejectsSplitOutsideSingInterval() {
        let line = splittableLine()
        #expect(LineSplitter.split(line, at: 5.0) == nil)
        #expect(LineSplitter.split(line, at: 20.0) == nil)
    }

    @Test func rejectsSplitTooCloseToEdges() {
        let line = splittableLine()
        #expect(LineSplitter.split(line, at: 10.01) == nil)
        #expect(LineSplitter.split(line, at: 13.99) == nil)
    }

    @Test func splitsInTheMiddle() throws {
        let line = splittableLine()
        let result = try #require(LineSplitter.split(line, at: 12.0))
        #expect(result.left.singEnd == 12.0)
        #expect(result.right.singStart == 12.0)
        #expect(result.left.id == line.id, "左段保留原 id")
        #expect(result.right.id != line.id, "右段必须换新 id")
    }

    @Test func splitPreservesTextWithoutLossOrDuplication() throws {
        let line = splittableLine()
        let result = try #require(LineSplitter.split(line, at: 12.0))
        #expect(result.left.displayText + result.right.displayText == line.displayText)
        #expect(!result.left.displayText.isEmpty)
        #expect(!result.right.displayText.isEmpty)
    }

    @Test func splitUnionEqualsOriginalInterval() throws {
        let line = splittableLine()
        let result = try #require(LineSplitter.split(line, at: 12.0))
        #expect(result.left.singStart == line.singStart)
        #expect(result.right.singEnd == line.singEnd)
        #expect(result.left.singEnd == result.right.singStart)
        // 显示区覆盖原区间
        #expect(result.left.displayStart <= line.displayStart + 1e-9)
        #expect(result.right.displayEnd >= line.singEnd)
    }

    @Test func splitDoesNotDuplicateOrDropMorae() throws {
        let line = splittableLine()
        let result = try #require(LineSplitter.split(line, at: 12.0))
        let left = result.left.tokens.flatMap(\.morae)
        let right = result.right.tokens.flatMap(\.morae)
        #expect(left.count + right.count >= 4, "音拍不应少于原来的 4 个")
        // 左段音拍不越过分割点，右段不早于分割点
        for m in left { #expect(m.end <= 12.0 + 1e-6) }
        for m in right { #expect(m.start >= 12.0 - 1e-6) }
    }

    @Test func splitAtTokenBoundaryGivesWholeTokens() throws {
        let line = splittableLine()
        // 正好在 11.0（第一个音拍结束）分割
        let result = try #require(LineSplitter.split(line, at: 11.0))
        #expect(result.left.displayText == "き")
        #expect(result.right.displayText == "みのうた")
    }

    @Test func splitSnapsCutToNearestMoraBoundaryWithoutDuplicatingCharacters() throws {
        // 在音拍中间切
        // 回归：早期实现会把被切开的音拍同时算进两侧，得到「きみの」+「のうた」这种重复文本
        let line = splittableLine()
        // 探测点会吸附到内部边界（11/12/13），因此都能切
        for probe in [11.5, 11.6, 12.4, 12.9] {
            let result = try #require(LineSplitter.split(line, at: probe), "在 \(probe) 处应当能分割")
            #expect(result.left.displayText + result.right.displayText == line.displayText,
                    "分割不得重复或丢字（probe=\(probe)）")
            #expect(result.left.singEnd == result.right.singStart)
            // 切割点必须落在音拍边界上
            #expect([10.0, 11.0, 12.0, 13.0, 14.0].contains(result.left.singEnd),
                    "切割点 \(result.left.singEnd) 不在音拍边界上")
        }
    }

    @Test func splitRejectedWhenSnappingCollapsesCutToAnEdge() {
        // 10.4 吸附到起点 10，等于没切 → 拒绝
        #expect(LineSplitter.split(splittableLine(), at: 10.4) == nil)
        // 13.9 吸附到终点 14 → 同样拒绝
        #expect(LineSplitter.split(splittableLine(), at: 13.9) == nil)
    }

    @Test func splitRejectsWhenSnappedCutWouldMakeASegmentTooShort() {
        // 只有一个 10–14 的音拍：两个边界是 10 与 14，吸附后必然有一段过短 → 拒绝
        let line = makeLine(order: 1, text: "あ",
                            displayStart: 9, singStart: 10, singEnd: 14, displayEnd: 15,
                            morae: [("あ", 10.0, 14.0)])
        #expect(LineSplitter.split(line, at: 12.0) == nil)
    }

    @Test func splitWithoutSnappingCanRejectMidMoraCut() {
        var cfg = LineSplitter.Config.default
        cfg.snapToMoraBoundary = false
        // 关闭吸附后，切在音拍中间会导致文字无法干净划分 → 拒绝
        #expect(LineSplitter.split(splittableLine(), at: 11.5, config: cfg) == nil)
    }

    @Test func splitBoundarySnapKeepsMoraePartitioned() throws {
        let line = splittableLine()
        let result = try #require(LineSplitter.split(line, at: 12.4))
        let left = result.left.tokens.flatMap(\.morae)
        let right = result.right.tokens.flatMap(\.morae)
        #expect(left.count + right.count == 4, "四个音拍应被完整分到两侧，不增不减")
        for m in left { #expect(m.end <= result.left.singEnd + 1e-9) }
        for m in right { #expect(m.start >= result.right.singStart - 1e-9) }
    }

    @Test func canSplitMatchesSplit() {
        let line = splittableLine()
        #expect(LineSplitter.canSplit(line, at: 12.0))
        #expect(!LineSplitter.canSplit(line, at: 100.0))
    }
}

@Suite struct LineTrimTests {

    private func line() -> LyricLine {
        makeLine(order: 1, displayStart: 9, singStart: 10, singEnd: 12, displayEnd: 13)
    }

    @Test func trimSingEndWithinBounds() throws {
        let out = try #require(LineEditor.trimmed(line(), edge: .singEnd, to: 11.5))
        #expect(out.singEnd == 11.5)
        #expect(out.singStart == 10)
    }

    @Test func trimSingEndRejectedWhenCrossingStart() {
        // 越过起点、或导致过短，都应拒绝
        #expect(LineEditor.trimmed(line(), edge: .singEnd, to: 9.5) == nil)
        #expect(LineEditor.trimmed(line(), edge: .singEnd, to: 10.01) == nil)
    }

    @Test func trimSingStartRejectedWhenCrossingEnd() {
        #expect(LineEditor.trimmed(line(), edge: .singStart, to: 12.5) == nil)
        #expect(LineEditor.trimmed(line(), edge: .singStart, to: 11.99) == nil)
    }

    @Test func trimDisplayEdgesRespectSingInterval() throws {
        let out = try #require(LineEditor.trimmed(line(), edge: .displayEnd, to: 14))
        #expect(out.displayEnd == 14)
        #expect(out.singEnd == 12, "拉长显示结束不应改动走轨")
        // 不能切到只剩不到最短时长的走轨（走轨 10…12，起点 10）
        #expect(LineEditor.trimmed(line(), edge: .displayEnd, to: 10.02) == nil)
        #expect(LineEditor.trimmed(line(), edge: .displayStart, to: 11.99) == nil)
    }

    /// 色块 = 画面歌词的存在时间：外边缘往里拖进走轨时，走轨同步缩短，而不是拒绝。
    @Test func trimmingDisplayEdgesIntoTheSweepShortensTheSweep() throws {
        let end = try #require(LineEditor.trimmed(line(), edge: .displayEnd, to: 11.0))
        #expect(end.displayEnd == 11.0)
        #expect(end.singEnd == 11.0, "歌词在 11 秒消失，扫色也不能超过它")
        #expect(end.singStart == 10)

        let start = try #require(LineEditor.trimmed(line(), edge: .displayStart, to: 10.5))
        #expect(start.displayStart == 10.5)
        #expect(start.singStart == 10.5)
        #expect(start.singEnd == 12)
    }

    @Test func trimSingStartPullsDisplayStartAlong() throws {
        let out = try #require(LineEditor.trimmed(line(), edge: .singStart, to: 10.5))
        #expect(out.singStart == 10.5)
        #expect(out.displayStart <= out.singStart)
    }

    @Test func moveKeepsDuration() {
        let original = line()
        let moved = LineEditor.moved(original, by: 3.0)
        #expect(LineEditor.keepsDuration(original, moved))
        #expect(abs(moved.singStart - 13.0) < 1e-9)
        #expect(abs(moved.displayEnd - 16.0) < 1e-9)
    }

    @Test func moveClampsAtBoundsWithoutChangingDuration() {
        let original = line()
        // 往左推到越界
        let moved = LineEditor.moved(original, by: -100, bounds: 0...60)
        #expect(moved.displayStart >= 0)
        #expect(LineEditor.keepsDuration(original, moved), "越界停住也必须保持时长")
    }

    @Test func moveClampsAtRightBound() {
        let original = line()
        let moved = LineEditor.moved(original, by: 1000, bounds: 0...60)
        #expect(moved.displayEnd <= 60 + 1e-9)
        #expect(LineEditor.keepsDuration(original, moved))
    }

    @Test func trimThenRetimeRemapsMorae() {
        var l = makeLine(order: 1, text: "よんもじ", displayStart: 9, singStart: 10,
                         singEnd: 14, displayEnd: 15,
                         morae: [("よ", 10, 11), ("ん", 11, 12), ("も", 12, 13), ("じ", 13, 14)])
        let old = l.singStart...l.singEnd
        l.singEnd = 12
        let out = LineEditor.retimed(l, from: old)
        let morae = out.tokens.flatMap(\.morae)
        #expect(!morae.isEmpty)
        // 重映射后必须落在新的演唱区间内
        for m in morae {
            #expect(m.start >= out.singStart - 1e-6)
            #expect(m.end <= out.singEnd + 1e-6)
        }
    }
}

@Suite struct TrackStateTests {

    @Test func defaultsAreVisibleUnlockedUnmuted() {
        let store = TrackStateStore()
        #expect(store.isVisible(.lyricUpper))
        #expect(!store.isLocked(.lyricUpper))
        #expect(!store.isMuted(.lyricUpper))
    }

    @Test func togglesAreIndependent() {
        var store = TrackStateStore()
        store.toggleLocked(.lyricUpper)
        #expect(store.isLocked(.lyricUpper))
        #expect(store.isVisible(.lyricUpper), "锁定不应影响显隐")
        #expect(!store.isMuted(.lyricUpper), "锁定不应影响静音")
        store.toggleMuted(.audio)
        #expect(store.isMuted(.audio))
        #expect(!store.isLocked(.audio))
    }

    @Test func lockedTrackBlocksEditingOfItsLines() {
        var store = TrackStateStore()
        let upper = makeLine(order: 1)          // order 1 → 上行
        let lower = makeLine(order: 2)          // order 2 → 下行
        var project = makeProject(lines: [upper, lower])
        project.trackStates = store
        #expect(project.isEditable(upper))
        #expect(project.isEditable(lower))

        store.toggleLocked(.lyricUpper)
        project.trackStates = store
        #expect(!project.isEditable(upper), "锁定上行后上行句子不可编辑")
        #expect(project.isEditable(lower), "锁定上行不应影响下行")
    }

    @Test func trackStatesSurviveEncodeDecode() throws {
        var project = makeProject(lines: [makeLine(order: 1)])
        project.trackStates.toggleLocked(.lyricUpper)
        project.trackStates.toggleMuted(.audio)
        project.trackStates.toggleMuted(.vocal)
        project.trackStates[.video].isVisible = false

        let data = try JSONEncoder().encode(project)
        let back = try JSONDecoder().decode(KaraProject.self, from: data)
        #expect(back.trackStates.isLocked(.lyricUpper))
        #expect(back.trackStates.isMuted(.audio))
        #expect(back.trackStates.isMuted(.vocal))
        #expect(!back.trackStates.isVisible(.video))
    }

    @Test func separatedStemReferencesSurviveProjectRoundTrip() throws {
        var project = makeProject(lines: [])
        project.vocalSeparation = VocalSeparationAssets(
            vocalURL: URL(fileURLWithPath: "/tmp/stems/vocal.wav"),
            instrumentalURL: URL(fileURLWithPath: "/tmp/stems/instrumental.wav"),
            sourceFingerprint: "mv.mp4|1234|42.00",
            modelID: "mdx23c-inst-voc-hq-int8",
            sampleRate: 44_100,
            duration: 42)

        let data = try ProjectStore.encode(project)
        let restored = try ProjectStore.decode(data)
        let stems = try #require(restored.vocalSeparation)
        #expect(stems.vocalURL.path == "/tmp/stems/vocal.wav")
        #expect(stems.instrumentalURL.path == "/tmp/stems/instrumental.wav")
        #expect(stems.sourceFingerprint == "mv.mp4|1234|42.00")
        #expect(stems.sampleRate == 44_100)
    }

    @Test func oldProjectWithoutTrackStatesStillDecodes() throws {
        // 旧工程没有 trackStates 字段，必须能打开且用默认值
        let json = """
        {"version":1,"mediaURL":"/tmp/a.mp4","duration":10,"title":"t","lyricLines":[],
         "dictionary":{}}
        """
        let p = try JSONDecoder().decode(KaraProject.self, from: Data(json.utf8))
        #expect(!p.trackStates.isLocked(.lyricUpper))
    }
}

@Suite struct UndoRedoTests {

    @Test func undoRedoRestoresExactSequence() {
        let stack = UndoStack()
        var project = makeProject(lines: [makeLine(order: 1)])
        // UndoStack 的用法与 `AppState.beginEdit` 一致：**在每次编辑之前**记录当前状态
        let v0 = project
        stack.record(project, label: "初始")        // 编辑 1 之前

        project.lyricLines[0].singStart = 11
        let v1 = project
        stack.record(project, label: "移动")        // 编辑 2 之前

        project.lyricLines[0].singEnd = 13
        let v2 = project

        #expect(stack.canUndo)
        let back1 = stack.undo(current: project)                  // v2 → v1
        #expect(back1?.lyricLines[0].singStart == v1.lyricLines[0].singStart)
        #expect(back1?.lyricLines[0].singEnd == v1.lyricLines[0].singEnd)
        let back0 = stack.undo(current: back1 ?? project)          // v1 → v0
        #expect(back0?.lyricLines[0].singStart == v0.lyricLines[0].singStart)
        #expect(back0?.lyricLines[0].singEnd == v0.lyricLines[0].singEnd)
        #expect(!stack.canUndo)

        #expect(stack.canRedo)
        let fwd1 = stack.redo(current: back0 ?? project)           // v0 → v1
        #expect(fwd1?.lyricLines[0].singStart == v1.lyricLines[0].singStart)
        let fwd2 = stack.redo(current: fwd1 ?? project)            // v1 → v2
        #expect(fwd2?.lyricLines[0].singEnd == v2.lyricLines[0].singEnd)
        #expect(!stack.canRedo)
    }

    @Test func undoAfterSplitRestoresSingleLine() throws {
        let stack = UndoStack()
        let line = makeLine(order: 1, text: "きみのうた",
                            displayStart: 9, singStart: 10, singEnd: 14, displayEnd: 15,
                            morae: [("き", 10, 11), ("み", 11, 12), ("の", 12, 13), ("う", 13, 14)])
        var project = makeProject(lines: [line])
        stack.record(project, label: "分割前")

        let parts = try #require(LineSplitter.split(line, at: 12.0))
        project.lyricLines = [parts.left, parts.right]
        project.renumber()
        #expect(project.lyricLines.count == 2)

        let restored = stack.undo(current: project)
        #expect(restored?.lyricLines.count == 1)
        #expect(restored?.lyricLines[0].displayText == "きみのうた")
        #expect(restored?.lyricLines[0].singStart == 10)
        #expect(restored?.lyricLines[0].singEnd == 14)
    }

    @Test func undoOnEmptyStackReturnsNil() {
        let stack = UndoStack()
        #expect(stack.undo(current: KaraProject()) == nil)
        #expect(!stack.canUndo)
    }
}

@Suite struct ManualAdjustmentTests {

    private func aligned(for line: LyricLine, start: Double, end: Double) -> AlignedLyricLine {
        AlignedLyricLine(id: line.id, order: line.order, singStart: start, singEnd: end,
                         confidence: 0.9, tokens: line.tokens, reasons: [],
                         method: .asrForcedAlign, evidence: .asrTokens)
    }

    @Test func mergeKeepsManuallyAdjustedTimes() {
        var line = makeLine(order: 1, singStart: 10, singEnd: 12)
        line.markManuallyAdjusted("拖动移动")
        let project = makeProject(lines: [line])

        // 自动对轨给出完全不同的时间
        let merged = AnalysisCoordinator.merge(aligned: [aligned(for: line, start: 30, end: 33)],
                                              into: project)
        #expect(merged.lyricLines[0].singStart == 10, "手动调整过的时间不能被覆盖")
        #expect(merged.lyricLines[0].singEnd == 12)
        #expect(merged.lyricLines[0].isManuallyAdjusted)
        #expect(merged.lyricLines[0].reviewReasons.contains { $0.contains("手动调整") })
    }

    @Test func mergeAppliesAlignmentToUntouchedLines() {
        let line = makeLine(order: 1, singStart: 10, singEnd: 12)
        let project = makeProject(lines: [line])
        let merged = AnalysisCoordinator.merge(aligned: [aligned(for: line, start: 30, end: 33)],
                                              into: project)
        #expect(merged.lyricLines[0].singStart == 30)
        #expect(merged.lyricLines[0].singEnd == 33)
        #expect(!merged.lyricLines[0].isManuallyAdjusted)
    }

    @Test func mergeMaterializesRepeatedTailAsSeparateReviewableTimelineRows() {
        let intro = makeLine(order: 1, text: "夜が明ける")
        let tail = makeLine(order: 2, text: "花")
        var firstTokens = tail.tokens
        firstTokens[0].morae = [MoraTiming(mora: "は", start: 8.0, end: 8.3),
                                MoraTiming(mora: "な", start: 8.3, end: 8.6)]
        var repeatedToken = tail.tokens[0]
        repeatedToken.id = UUID()
        repeatedToken.morae = [MoraTiming(mora: "は", start: 9.0, end: 9.3),
                               MoraTiming(mora: "な", start: 9.3, end: 9.6)]
        let repeated = AlignedLyricLine(id: UUID(), sourceLineID: tail.id, order: 3,
                                        singStart: 9.0, singEnd: 9.6, confidence: 0.72,
                                        tokens: [repeatedToken],
                                        reasons: ["尾句重复次数仍需校准"],
                                        method: .yohaneForcedAlign, evidence: .ctcForcedAlignment)
        let baseTail = AlignedLyricLine(id: tail.id, order: 2,
                                        singStart: 8.0, singEnd: 8.6, confidence: 0.72,
                                        tokens: firstTokens, reasons: ["尾句重复次数仍需校准"],
                                        method: .yohaneForcedAlign, evidence: .ctcForcedAlignment)
        let merged = AnalysisCoordinator.merge(
            aligned: [aligned(for: intro, start: 2, end: 3), baseTail, repeated],
            into: makeProject(lines: [intro, tail]))

        #expect(merged.lyricLines.count == 3)
        #expect(merged.lyricLines.map(\.order) == [1, 2, 3])
        #expect(merged.lyricLines[2].displayText == tail.displayText)
        #expect(merged.lyricLines[2].singStart == 9.0)
        #expect(merged.lyricLines[2].singEnd == 9.6)
        #expect(merged.lyricLines[2].lane == .upper)
        #expect(merged.lyricLines[2].needsReview)
        #expect(merged.lyricLines[2].reviewReasons.contains { $0.contains("仍需校准") })
        #expect(Set(merged.lyricLines.map(\.id)).count == 3)
        #expect(Set(merged.lyricLines.flatMap(\.tokens).map(\.id)).count == 3)
    }

    @Test func manualFlagSurvivesEncodeDecode() throws {
        var line = makeLine(order: 1)
        line.markManuallyAdjusted("修剪右缘")
        let project = makeProject(lines: [line])
        let data = try JSONEncoder().encode(project)
        let back = try JSONDecoder().decode(KaraProject.self, from: data)
        #expect(back.lyricLines[0].isManuallyAdjusted)
        #expect(back.lyricLines[0].manualAdjustmentNote == "修剪右缘")
    }
}

@Suite struct TimelineKeyCommandTests {

    @Test func spaceTogglesPlayback() {
        let c = TimelineKeyMapper.command(characters: " ", keyCode: 49,
                                          command: false, shift: false, option: false, control: false)
        #expect(c == .togglePlay)
    }

    @Test func arrowsStep() {
        #expect(TimelineKeyMapper.command(characters: nil, keyCode: 123, command: false,
                                          shift: false, option: false, control: false) == .stepBackward)
        #expect(TimelineKeyMapper.command(characters: nil, keyCode: 124, command: false,
                                          shift: false, option: false, control: false) == .stepForward)
        // Shift 走大步长
        #expect(TimelineKeyMapper.command(characters: nil, keyCode: 124, command: false,
                                          shift: true, option: false, control: false) == .stepForwardLarge)
    }

    @Test func commandBSplits() {
        let c = TimelineKeyMapper.command(characters: "b", keyCode: 11,
                                          command: true, shift: false, option: false, control: false)
        #expect(c == .splitAtPlayhead)
    }

    @Test func commandZUndoRedo() {
        #expect(TimelineKeyMapper.command(characters: "z", keyCode: 6, command: true,
                                          shift: false, option: false, control: false) == .undo)
        #expect(TimelineKeyMapper.command(characters: "z", keyCode: 6, command: true,
                                          shift: true, option: false, control: false) == .redo)
    }

    @Test func escapeCancels() {
        #expect(TimelineKeyMapper.command(characters: "\u{1B}", keyCode: 53, command: false,
                                          shift: false, option: false, control: false) == .cancel)
    }

    @Test func optionModifiedKeysAreNotTimelineShortcuts() {
        // Option 用于临时关闭吸附，不应被当成时间线快捷键
        #expect(TimelineKeyMapper.command(characters: "b", keyCode: 11, command: false,
                                          shift: false, option: true, control: false) == nil)
    }

    @Test func textEditingDoesNotStealShortcuts() {
        // 文本框聚焦时，空格/方向键/删除都必须让位，否则打不了字
        for c in [TimelineKeyCommand.togglePlay, .stepBackward, .stepForward,
                  .splitAtPlayhead, .deleteSelection, .cancel] {
            #expect(TimelineKeyMapper.shouldIgnore(c, isTextEditing: true), "\(c) 不该在文本框里抢键")
        }
        // 撤销/重做例外
        #expect(!TimelineKeyMapper.shouldIgnore(.undo, isTextEditing: true))
        #expect(!TimelineKeyMapper.shouldIgnore(.redo, isTextEditing: true))
    }

    @Test func frameStepIsOneFrame() {
        #expect(abs(TimelineKeyMapper.frameStep - 1.0 / 30.0) < 1e-12)
    }
}

/// 正常 NLE 的手势分工：块主体=移动、左右边缘=修剪、空白=scrub、滚轮=平移。
@Suite struct LyricBlockHitTestTests {

    // 块：displayStart 0，宽 200；演唱区 20…180
    private func zone(_ x: Double, selected: Bool = false) -> LyricBlockZone {
        LyricBlockHitTest.zone(localX: x, displayWidth: 200, singOffset: 20,
                               singWidth: 160, isSelected: selected)
    }

    @Test func blockBodyMeansMove() {
        #expect(zone(100) == .move)
        #expect(zone(60) == .move)
        #expect(zone(150) == .move)
    }

    @Test func leftAndRightEdgesMeanTrim() {
        #expect(zone(0) == .displayStart)
        #expect(zone(3) == .displayStart)
        #expect(zone(200) == .displayEnd)
        #expect(zone(197) == .displayEnd)
    }

    @Test func innerSingEdgesOnlyWhenSelected() {
        // 未选中：内部边缘不暴露，落在主体上（避免误触）
        #expect(zone(20, selected: false) == .move)
        #expect(zone(180, selected: false) == .move)
        // 选中：内部边缘可拖，且优先于外框
        #expect(zone(20, selected: true) == .singStart)
        #expect(zone(180, selected: true) == .singEnd)
    }

    @Test func trimZonesAreNotMove() {
        #expect(zone(0).isTrim)
        #expect(zone(200).isTrim)
        #expect(!zone(100).isTrim)
        #expect(!LyricBlockZone.sweepMove.isTrim)
    }

    /// 选中后，块底部的走轨条中间 = 在块内平移走轨；上半部分和未选中时仍是整块移动。
    @Test func sweepStripMiddleMeansSweepMoveOnlyWhenSelected() {
        let height = 28.0
        func zoneAt(_ x: Double, _ y: Double, selected: Bool) -> LyricBlockZone {
            LyricBlockHitTest.zone(localX: x, displayWidth: 200, singOffset: 20, singWidth: 160,
                                   isSelected: selected, localY: y, blockHeight: height)
        }
        #expect(zoneAt(100, height - 4, selected: true) == .sweepMove)
        #expect(zoneAt(100, 6, selected: true) == .move, "走轨条以上仍是整块移动")
        #expect(zoneAt(100, height - 4, selected: false) == .move, "未选中不暴露走轨条")
        // 走轨条两端仍是调范围；块外边缘仍是显示起止
        #expect(zoneAt(20, height - 4, selected: true) == .singStart)
        #expect(zoneAt(180, height - 4, selected: true) == .singEnd)
        #expect(zoneAt(0, height - 4, selected: true) == .displayStart)
        // 走轨条左侧的等待区（x 在走轨之前）不属于走轨条
        #expect(zoneAt(10, height - 4, selected: true) == .move)
    }

    @Test func toleranceIsApplied() {
        // 7 点已经超出 6 点容差 → 主体
        #expect(zone(7) == .move)
        #expect(zone(6) == .displayStart)
    }

    @Test func worksAtAnyZoomBecauseAllInputsAreViewLocal() {
        // 同样的相对几何在不同缩放下（宽度不同）判定一致
        for width in [40.0, 200.0, 1200.0] {
            let body = LyricBlockHitTest.zone(localX: width / 2, displayWidth: width,
                                              singOffset: width * 0.1, singWidth: width * 0.8,
                                              isSelected: false)
            #expect(body == .move)
            let left = LyricBlockHitTest.zone(localX: 0, displayWidth: width,
                                              singOffset: width * 0.1, singWidth: width * 0.8,
                                              isSelected: false)
            #expect(left == .displayStart)
        }
    }
}

@Suite struct TimelineScrollMapperTests {

    @Test func plainWheelPans() {
        let r = TimelineScrollMapper.map(deltaX: 30, deltaY: 0, shift: false,
                                         command: false, precise: true)
        #expect(r.panPixels == 30)
        #expect(r.zoomDelta == nil)
    }

    @Test func shiftWheelAlwaysPans() {
        // 只有纵向 delta 时，Shift+滚轮也要变成横向平移
        let r = TimelineScrollMapper.map(deltaX: 0, deltaY: 40, shift: true,
                                         command: false, precise: true)
        #expect(r.panPixels == 40)
        #expect(r.zoomDelta == nil)
    }

    @Test func verticalWheelAlsoPans() {
        let r = TimelineScrollMapper.map(deltaX: 0, deltaY: 25, shift: false,
                                         command: false, precise: true)
        #expect(r.panPixels == 25)
    }

    @Test func commandWheelZoomsInsteadOfPanning() {
        let r = TimelineScrollMapper.map(deltaX: 30, deltaY: 12, shift: false,
                                         command: true, precise: true)
        #expect(r.zoomDelta == 12)
        #expect(r.panPixels == 0)
    }

    @Test func mouseWheelIsAmplifiedRelativeToTrackpad() {
        let trackpad = TimelineScrollMapper.map(deltaX: 3, deltaY: 0, shift: false,
                                                command: false, precise: true)
        let mouse = TimelineScrollMapper.map(deltaX: 3, deltaY: 0, shift: false,
                                             command: false, precise: false)
        #expect(mouse.panPixels > trackpad.panPixels)
    }

    @Test func tinyDeltaIsIgnored() {
        let r = TimelineScrollMapper.map(deltaX: 0.001, deltaY: 0, shift: false,
                                         command: false, precise: true)
        #expect(r.panPixels == 0)
        #expect(r.zoomDelta == nil)
    }
}
