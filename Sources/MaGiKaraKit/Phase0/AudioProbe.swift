import Foundation

/// 对真实媒体跑一遍生产用的音频分析链路，并报告可核对的事实。
///
/// 用途：在还没有歌词（因而无法做强制对齐）的情况下，
/// 先验证「解码 → 逐帧特征 → 浊音/起音」这一段在真实歌曲上不会失真或失效。
public struct AudioProbeReport: Codable, Sendable {

    public struct Island: Codable, Sendable {
        public var start: Double
        public var end: Double
        public var duration: Double
    }

    public var file: String
    public var duration: Double
    public var sampleRate: Double
    public var frameCount: Int

    /// 解码后的电平情况
    public var peakLevel: Double
    public var rmsDBFS: Double
    public var nearSilentRatio: Double
    public var nearClippedRatio: Double

    /// VAD 结果
    public var voicedRatio: Double
    public var noiseFloorDB: Double
    public var peakDB: Double
    /// 能量动态范围（95% 分位 − 15% 分位，dB）。越小说明压缩越重。
    public var dynamicRangeDB: Double
    /// 该素材是否不适合纯能量法
    public var isHeavilyCompressed: Bool
    /// 人声似然的 15% / 50% / 95% 分位
    public var likelihoodP15: Double
    public var likelihoodP50: Double
    public var likelihoodP95: Double

    /// 人声段（已合并短空隙）
    public var islands: [Island]
    public var gapCount: Int
    public var medianGap: Double
    public var longestGap: Double

    /// 起音点
    public var onsetCount: Int
    public var medianOnsetSpacing: Double
    public var onsetsPerSecond: Double

    public var notes: [String]
}

public enum AudioProbe {

    /// 合并间隔小于该值的人声段
    public static let gapMergeSeconds = 0.25
    /// 短于该值的人声段视为噪声丢弃
    public static let minIslandSeconds = 0.20

    public static func run(url: URL, sampleRate: Double = AudioDecoder.defaultSampleRate) throws -> AudioProbeReport {
        let decoded = try AudioDecoder.decode(url: url, sampleRate: sampleRate, peakBuckets: 2000)
        let features = AudioFeatureExtractor.extract(from: decoded)

        // ---- 解码电平 ----
        var peak: Float = 0
        var sumSquares: Double = 0
        var nearSilent = 0
        var nearClipped = 0
        for s in decoded.samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSquares += Double(s) * Double(s)
            if a < 0.001 { nearSilent += 1 }
            if a > 0.985 { nearClipped += 1 }
        }
        let rms = decoded.samples.isEmpty ? 0 : (sumSquares / Double(decoded.samples.count)).squareRoot()
        let rmsDB = 20 * log10(max(rms, 1e-7))

        // ---- 噪声底与峰值 ----
        let sortedDB = features.energyDB.sorted()
        let noiseFloor = sortedDB.isEmpty ? -120 : Double(sortedDB[Int(Double(sortedDB.count - 1) * 0.15)])
        let peakDB = sortedDB.isEmpty ? -120 : Double(sortedDB[Int(Double(sortedDB.count - 1) * 0.95)])
        let voicedFrames = features.voiced.reduce(0) { $0 + ($1 ? 1 : 0) }
        let voicedRatio = features.frameCount > 0 ? Double(voicedFrames) / Double(features.frameCount) : 0

        let sortedLikelihood = features.voiceLikelihood.sorted()
        func pct(_ p: Double) -> Double {
            guard !sortedLikelihood.isEmpty else { return 0 }
            return Double(sortedLikelihood[Int(Double(sortedLikelihood.count - 1) * p)])
        }

        // ---- 人声段 ----
        var islands: [AudioProbeReport.Island] = []
        var runStart: Int? = nil
        let hop = features.hopSeconds
        var gaps: [Double] = []

        var i = 0
        while i <= features.frameCount {
            let isVoiced = i < features.frameCount ? features.voiced[i] : false
            if isVoiced {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                let start = Double(s) * hop
                let end = Double(i) * hop
                if end - start >= minIslandSeconds {
                    if let last = islands.last {
                        let gap = start - last.end
                        if gap < gapMergeSeconds {
                            // 合并
                            islands[islands.count - 1].end = end
                            islands[islands.count - 1].duration = end - islands[islands.count - 1].start
                            runStart = nil
                            i += 1
                            continue
                        } else {
                            gaps.append(gap)
                        }
                    }
                    islands.append(.init(start: start, end: end, duration: end - start))
                }
                runStart = nil
            }
            i += 1
        }

        // ---- 起音点 ----
        var spacing: [Double] = []
        for (a, b) in zip(features.onsets, features.onsets.dropFirst()) {
            spacing.append(b - a)
        }
        let medianSpacing = spacing.isEmpty ? 0 : spacing.sorted()[spacing.count / 2]

        var notes: [String] = []
        if voicedRatio < 0.15 {
            notes.append("浊音比例很低（\(String(format: "%.1f%%", voicedRatio * 100))）：可能是纯伴奏或人声被压得很低")
        }
        if nearClipped > decoded.samples.count / 1000 {
            notes.append("约 \(String(format: "%.2f%%", Double(nearClipped) / Double(decoded.samples.count) * 100)) 的采样接近满刻度，可能有削顶")
        }
        if islands.isEmpty {
            notes.append("没有检测到任何连续人声段")
        }
        if features.isHeavilyCompressed {
            notes.append(String(format: "能量动态范围只有 %.1f dB（压缩/限幅很重）：能量类阈值几乎不可用，已改为相对分位数 + 谱平坦度似然", features.dynamicRangeDB))
        }

        return AudioProbeReport(
            file: url.lastPathComponent,
            duration: decoded.duration,
            sampleRate: decoded.sampleRate,
            frameCount: features.frameCount,
            peakLevel: Double(peak),
            rmsDBFS: rmsDB,
            nearSilentRatio: decoded.samples.isEmpty ? 0 : Double(nearSilent) / Double(decoded.samples.count),
            nearClippedRatio: decoded.samples.isEmpty ? 0 : Double(nearClipped) / Double(decoded.samples.count),
            voicedRatio: voicedRatio,
            noiseFloorDB: noiseFloor,
            peakDB: peakDB,
            dynamicRangeDB: features.dynamicRangeDB,
            isHeavilyCompressed: features.isHeavilyCompressed,
            likelihoodP15: pct(0.15),
            likelihoodP50: pct(0.50),
            likelihoodP95: pct(0.95),
            islands: islands,
            gapCount: gaps.count,
            medianGap: gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2],
            longestGap: gaps.max() ?? 0,
            onsetCount: features.onsets.count,
            medianOnsetSpacing: medianSpacing,
            onsetsPerSecond: decoded.duration > 0 ? Double(features.onsets.count) / decoded.duration : 0,
            notes: notes)
    }

    public static func renderText(_ r: AudioProbeReport) -> String {
        var out = ""
        out += "文件:        \(r.file)\n"
        out += String(format: "时长:        %.2f 秒\n", r.duration)
        out += "解码采样率:  \(Int(r.sampleRate)) Hz   帧数: \(r.frameCount)\n"
        out += String(format: "峰值电平:    %.3f (%.1f dBFS)\n", r.peakLevel, 20 * log10(max(r.peakLevel, 1e-7)))
        out += String(format: "整体 RMS:    %.1f dBFS\n", r.rmsDBFS)
        out += String(format: "近似静音:    %.1f%%   近削顶: %.3f%%\n", r.nearSilentRatio * 100, r.nearClippedRatio * 100)
        out += "\n── 浊音检测（VAD）──\n"
        out += String(format: "噪声底:      %.1f dB   95%% 分位: %.1f dB\n", r.noiseFloorDB, r.peakDB)
        out += String(format: "动态范围:    %.1f dB%@\n", r.dynamicRangeDB,
                      r.isHeavilyCompressed ? "  ⚠️ 压缩很重，能量法信息有限" : "")
        out += String(format: "人声似然:    P15 %.2f  P50 %.2f  P95 %.2f\n", r.likelihoodP15, r.likelihoodP50, r.likelihoodP95)
        out += String(format: "浊音比例:    %.1f%%\n", r.voicedRatio * 100)
        out += "人声段数:    \(r.islands.count)\n"
        out += "段间空隙:    \(r.gapCount) 处，中央值 \(String(format: "%.2f", r.medianGap)) 秒，最长 \(String(format: "%.2f", r.longestGap)) 秒\n"
        out += "\n── 起音检测 ──\n"
        out += "起音点数:    \(r.onsetCount)（\(String(format: "%.1f", r.onsetsPerSecond)) 个/秒）\n"
        out += String(format: "起音间隔:    中央值 %.3f 秒\n", r.medianOnsetSpacing)

        if !r.islands.isEmpty {
            out += "\n── 人声段列表 ──\n"
            for (i, island) in r.islands.enumerated() {
                out += String(format: "  #%2d  %7.2f → %7.2f   (%.2f 秒)\n",
                              i + 1, island.start, island.end, island.duration)
            }
        }
        if !r.notes.isEmpty {
            out += "\n── 提示 ──\n"
            for n in r.notes { out += "  · \(n)\n" }
        }
        return out
    }
}
