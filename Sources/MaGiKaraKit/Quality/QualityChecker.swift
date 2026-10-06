import Foundation

/// 成品检查（RD §8.2 第 8 步 / §2 成败标准）。
/// 检测漏句、串句、重叠、过短、异常长音、整体偏移和逐渐漂移。
public enum QualityChecker {

    public struct Report: Sendable {
        public var overlapCount: Int = 0
        public var suspiciousGapCount: Int = 0
        public var tooShortCount: Int = 0
        public var tooLongCount: Int = 0
        /// 整曲整体偏移估计（秒）
        public var globalOffset: Double = 0
        /// 逐渐漂移斜率（秒 / 秒）
        public var driftSlope: Double = 0
        public var notes: [String] = []
    }

    /// 阈值
    static let overlapTolerance = 0.05
    static let suspiciousGap = 8.0
    static let minSingDuration = 0.30
    static let maxSingDuration = 15.0
    static let offsetWarn = 0.20
    static let driftWarn = 0.03

    /// 给每句补充 reasons，并在严重问题上压低置信度。
    public static func annotate(results: [AlignedLyricLine],
                                features: AudioFeatures?,
                                audioDuration: Double) -> [AlignedLyricLine] {
        guard !results.isEmpty else { return results }
        var lines = results.sorted { $0.order < $1.order }
        var report = Report()

        // 1. 顺序、重叠、间隔
        for i in lines.indices {
            if i > 0 {
                let prev = lines[i - 1]
                let cur = lines[i]
                if cur.singStart < prev.singEnd - overlapTolerance {
                    report.overlapCount += 1
                    lines[i].reasons.append("与上一句时间重叠，可能出现串句或倒序")
                    lines[i].confidence = min(lines[i].confidence, 0.55)
                } else {
                    let gap = cur.singStart - prev.singEnd
                    if gap > suspiciousGap {
                        report.suspiciousGapCount += 1
                        lines[i].reasons.append(String(format: "与上一句间隔 %.1f 秒，可能有漏句", gap))
                        lines[i].confidence = min(lines[i].confidence, 0.70)
                    }
                }
            }

            let dur = lines[i].singEnd - lines[i].singStart
            if dur < minSingDuration {
                report.tooShortCount += 1
                lines[i].reasons.append("演唱时间过短，可能只匹配到部分歌词")
                lines[i].confidence = min(lines[i].confidence, 0.55)
            } else if dur > maxSingDuration {
                report.tooLongCount += 1
                lines[i].reasons.append("演唱时间异常长，可能吞掉了间奏或相邻句")
                lines[i].confidence = min(lines[i].confidence, 0.60)
            }
        }

        // 2. 未被任何歌词覆盖的人声 → 大概率漏句
        //
        // 这一条是被测试逼出来的：只给 6 句而音频唱了 8 句时，
        // 粗对齐会「免费跳过」多出来的段落，每句自身仍然贴合得很好，
        // 于是逐句置信度全部很高、漏句完全不被发现。
        // 因此必须显式检查句与句之间残留的人声。
        if let features, features.frameCount > 1 {
            let hop = features.hopSeconds

            func uncoveredVoiced(from t0: Double, to t1: Double) -> Double {
                guard t1 > t0 else { return 0 }
                let a = max(0, min(features.frameCount, Int(t0 / hop)))
                let b = max(a, min(features.frameCount, Int(t1 / hop)))
                guard b > a else { return 0 }
                // 用连续似然：密集伴奏下二值浊音会几乎恒为真，导致到处误报漏句
                return features.meanVoiceScore(from: a, to: b) * Double(b - a) * hop
            }

            let minUncovered = 1.2      // 秒：超过这个长度的人声没有被任何歌词覆盖
            let introUncovered = 2.0

            for i in lines.indices {
                let from = i == 0 ? 0 : lines[i - 1].singEnd
                let to = lines[i].singStart
                let missing = uncoveredVoiced(from: from, to: to)
                guard missing > (i == 0 ? introUncovered : minUncovered) else { continue }

                if i == 0 {
                    lines[0].reasons.append(String(format: "开头有约 %.1f 秒人声未被歌词覆盖，可能漏了第一句", missing))
                    lines[0].confidence = min(lines[0].confidence, 0.70)
                } else {
                    lines[i - 1].reasons.append(String(format: "之后有约 %.1f 秒人声未被任何歌词覆盖，可能漏句", missing))
                    lines[i - 1].confidence = min(lines[i - 1].confidence, 0.60)
                    lines[i].reasons.append(String(format: "之前有约 %.1f 秒人声未被歌词覆盖，上一句可能被吞并", missing))
                    lines[i].confidence = min(lines[i].confidence, 0.75)
                }
            }

            // 结尾残留人声
            if let last = lines.last {
                let tail = uncoveredVoiced(from: last.singEnd, to: features.duration)
                if tail > introUncovered {
                    lines[lines.count - 1].reasons.append(String(format: "结尾有约 %.1f 秒人声未被歌词覆盖，可能漏了最后一句", tail))
                    lines[lines.count - 1].confidence = min(lines[lines.count - 1].confidence, 0.70)
                }
            }
        }

        // 3. 整体偏移与逐渐漂移（用起音点做参考）
        var offsets: [(time: Double, offset: Double)] = []
        if let features, !features.onsets.isEmpty {
            for line in lines {
                guard let nearest = features.onsets.min(by: { abs($0 - line.singStart) < abs($1 - line.singStart) })
                else { continue }
                let off = nearest - line.singStart
                if abs(off) < 0.5 {
                    offsets.append((line.singStart, off))
                }
            }
        }

        if offsets.count >= 4 {
            let sortedOffsets = offsets.map(\.offset).sorted()
            let median = sortedOffsets[sortedOffsets.count / 2]
            report.globalOffset = median

            // 最小二乘斜率
            let n = Double(offsets.count)
            let meanT = offsets.reduce(0) { $0 + $1.time } / n
            let meanO = offsets.reduce(0) { $0 + $1.offset } / n
            var num = 0.0
            var den = 0.0
            for o in offsets {
                num += (o.time - meanT) * (o.offset - meanO)
                den += (o.time - meanT) * (o.time - meanT)
            }
            let slope = den > 1e-6 ? num / den : 0
            report.driftSlope = slope

            if abs(median) > offsetWarn {
                report.notes.append(String(format: "整曲可能存在 %.2f 秒的整体偏移", median))
            }
            if abs(slope) > driftWarn {
                report.notes.append(String(format: "检测到逐渐漂移，斜率 %.3f 秒/秒", slope))
            }
        }

        if report.overlapCount > 0 {
            report.notes.append("\(report.overlapCount) 句存在时间重叠")
        }
        if report.suspiciousGapCount > 0 {
            report.notes.append("\(report.suspiciousGapCount) 处句间隔异常，疑似漏句")
        }
        if report.tooShortCount > 0 {
            report.notes.append("\(report.tooShortCount) 句演唱时间过短")
        }
        if report.tooLongCount > 0 {
            report.notes.append("\(report.tooLongCount) 句演唱时间异常长")
        }

        // 去重原因
        for i in lines.indices {
            if ConfidenceLevel.from(lines[i].confidence) != .normal && lines[i].reasons.isEmpty {
                lines[i].reasons.append("对齐置信度偏低，建议试听确认")
            }
            var seen = Set<String>()
            lines[i].reasons = lines[i].reasons.filter { seen.insert($0).inserted }
            lines[i].confidence = max(0, min(1, lines[i].confidence))
        }
        return lines
    }

    /// 汇总报告，供 Phase 0 指标输出使用。
    public static func summarize(results: [AlignedLyricLine]) -> Report {
        var report = Report()
        guard !results.isEmpty else { return report }
        let lines = results.sorted { $0.order < $1.order }
        for i in lines.indices {
            if i > 0, lines[i].singStart < lines[i - 1].singEnd - overlapTolerance {
                report.overlapCount += 1
            }
            let dur = lines[i].singEnd - lines[i].singStart
            if dur < minSingDuration { report.tooShortCount += 1 }
            if dur > maxSingDuration { report.tooLongCount += 1 }
        }
        return report
    }
}

/// 只用于 UI 单元测试与无模型开发环境（RD §8.4）。
///
/// 明确标记为非产品路径：`isProductionReady == false`，
/// 结果置信度强制不超过 0.5，并附带「Mock」原因，避免被误当成真实对轨结论。
public struct MockLyricAligner: LyricAligning {
    public var startTime: Double
    public var secondsPerMora: Double

    public init(startTime: Double = 0.5, secondsPerMora: Double = 0.22) {
        self.startTime = startTime
        self.secondsPerMora = secondsPerMora
    }

    public var name: String { "MockLyricAligner（仅 UI 测试）" }
    public var isProductionReady: Bool { false }
    public var method: AlignmentMethod { .mock }

    public func align(audioURL: URL,
                      lines: [LyricLineDraft],
                      progress: AlignProgressHandler?) async throws -> [AlignedLyricLine] {
        let duration = await AudioDecoder.duration(of: audioURL)
        progress?(AlignProgress(fraction: 0.5, message: "Mock 对齐中…"))
        var t = startTime
        var out: [AlignedLyricLine] = []
        for draft in lines {
            var tokens = draft.tokens
            var cursor = t
            for ti in tokens.indices {
                let units = JapaneseReadingService.alignmentUnits(for: tokens[ti])
                var morae: [MoraTiming] = []
                for u in units {
                    morae.append(MoraTiming(mora: u, start: cursor, end: cursor + secondsPerMora, confidence: 0.5))
                    cursor += secondsPerMora
                }
                tokens[ti].morae = morae
            }
            let singEnd = max(cursor, t + 0.2)
            out.append(AlignedLyricLine(id: draft.id,
                                        order: draft.order,
                                        singStart: t,
                                        singEnd: singEnd,
                                        confidence: 0.5,
                                        tokens: tokens,
                                        reasons: ["MockLyricAligner 结果，仅用于 UI 测试，不代表真实对轨"],
                                        method: .mock,
                                        evidence: .durationPrior))
            t = singEnd + 0.35
            if duration > 0, t > duration { t = duration }
        }
        progress?(AlignProgress(fraction: 1.0, message: "完成"))
        return out
    }
}
