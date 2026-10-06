import Testing
import Foundation
@testable import MaGiKaraKit

/// 用真实 ASR 工程核对：时间线歌词块的逐字数据必须覆盖整句文字。
/// 时间线块内渲染依赖它 —— 少字会直接表现为「块里少几个假名」。
@Suite struct RealProjectCharTimingTests {

    private func loadRealProject() throws -> KaraProject? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/real-nanmonee-asr.magikara")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ProjectStore.load(from: url)
    }

    @Test func everyLineProducesOneTimedCharPerCharacter() throws {
        guard let project = try loadRealProject() else { return }   // 没跑过真实对轨时跳过
        var failures: [String] = []
        for line in project.sortedLines {
            let chars = LyricCharTiming.characters(of: line)
            if chars.count != line.displayText.count {
                failures.append("#\(line.order) 文字 \(line.displayText.count) 字 → 逐字 \(chars.count) 个  「\(line.displayText)」")
            }
        }
        #expect(failures.isEmpty, "以下句子的逐字数量与文字不符：\n\(failures.joined(separator: "\n"))")
    }

    @Test func everyCharHasATimeInsideItsSingInterval() throws {
        guard let project = try loadRealProject() else { return }
        for line in project.sortedLines {
            let chars = LyricCharTiming.characters(of: line)
            for c in chars {
                let s = try #require(c.start, "#\(line.order) 有字没有时间")
                let e = try #require(c.end)
                #expect(e > s)
                #expect(s >= line.singStart - 0.5, "#\(line.order) 字时间早于演唱区")
                #expect(e <= line.singEnd + 0.5, "#\(line.order) 字时间晚于演唱区")
            }
        }
    }

    @Test func everyCharacterIsPlacedInsideItsBlock() throws {
        guard let project = try loadRealProject() else { return }
        let pps = 64.0
        for line in project.sortedLines {
            let width = CGFloat(line.singEnd - line.singStart) * CGFloat(pps)
            let l = LyricBlockLayout.layout(line: line, pixelsPerSecond: pps,
                                            originTime: line.singStart, width: Double(width))
            if Double(width) < LyricBlockLayout.minimumUsableWidth {
                // 极窄块（演唱区间过短的插值句）：放不下字，只保留一个字作标记
                #expect(l.items.count <= 1,
                        "#\(line.order) 极窄块不应塞入 \(l.items.count) 个字")
                continue
            }
            #expect(l.items.count == line.displayText.count,
                    "#\(line.order) 块内应放 \(line.displayText.count) 个字，实际 \(l.items.count)")
            for item in l.items {
                #expect(item.x >= -0.5, "#\(line.order) 有字落在块外（x=\(item.x)）")
                #expect(item.x + l.fontSize <= Double(width) + 1.0,
                        "#\(line.order) 有字超出块右边界（x=\(item.x) 字号 \(l.fontSize) 块宽 \(width)）")
            }
            // 单调不减，保证画出来有顺序
            let xs = l.items.map(\.x)
            for (a, b) in zip(xs, xs.dropFirst()) {
                #expect(a <= b + 1e-6, "#\(line.order) 块内字序回退")
            }
        }
    }

    @Test func tokensCoverTheWholeDisplayText() throws {
        guard let project = try loadRealProject() else { return }
        for line in project.sortedLines {
            let joined = line.tokens.map(\.surface).joined()
            #expect(joined == line.displayText,
                    "#\(line.order) token 文字与 displayText 不一致：\(joined) vs \(line.displayText)")
        }
    }
}
