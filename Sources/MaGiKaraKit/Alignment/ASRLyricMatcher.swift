import Foundation

/// 把用户歌词按顺序全局匹配到 ASR 时间片上的结果。
public struct LyricASRMatch: Sendable {
    public struct LineMatch: Sendable {
        public var lineIndex: Int
        /// 该行第一个/最后一个被 ASR 证据命中的时间
        public var start: Double?
        public var end: Double?
        /// 逐字命中 ASR 时间（nil = 该字没有证据）
        public var charTimes: [Double?]
        /// 逐字结束时间
        public var charEnds: [Double?]
        /// 完全命中的字符比例 0...1
        public var evidenceQuality: Double
        /// 是否拿到了直接证据（否则时间来自插值）
        public var hasDirectEvidence: Bool
        /// 该行落在哪个演唱区
        public var regionIndex: Int?
    }

    public var lines: [LineMatch]
    public var regionCount: Int
    public var asrCharCount: Int
    public var matchedCharCount: Int
    public var totalCost: Double
}

/// 顺序约束的全局匹配器：用户歌词 ↔ ASR 时间片。
///
/// 设计要点（每一条都是被真实素材逼出来的，见 TestAssets/ocr/FEASIBILITY.md）：
///
/// 1. **先按 ASR 时间空隙切「演唱区」**（gap > 2.5 秒）。
///    否则一行歌词会横跨大段间奏：实测第 21 行的前几个字被匹配到 73.8 秒、
///    后几个字匹配到 106 秒，句首误差 -31.7 秒。
///
/// 2. **两层 DP**：外层把一个**连续区间**的歌词行分配给一个演唱区
///    （允许一个区多行、也允许整区无歌词），内层在该区里做逐字顺序 DP。
///    重复副歌因此天然消歧：第二次副歌只能落到第二个演唱区，不靠均分。
///
/// 3. **替换只用于恢复顺序，不作为时间证据**。日语歌声 ASR 常把读音写错，
///    错配可以帮助 DP 保持文本顺序，但只有达到精确命中门槛的字符才能锚定时间。
///
/// 4. **证据质量门控**：一行里逐字完全命中的比例太低时，不承认直接证据，
///    改走插值。避免给出看似精确、实际是垃圾匹配的时间。
public enum ASRLyricMatcher {

    public struct Config: Sendable {
        /// 切演唱区的时间空隙阈值（秒）
        public var regionGap: Double = 2.5
        /// 整个演唱区没有对应歌词时的代价
        public var emptyRegionCost: Double = 8.0
        /// 歌词字没有对应 ASR（ASR 漏字）代价
        public var gapLyricCost: Double = 1.2
        /// ASR 字没有对应歌词（ASR 多字）代价
        public var gapASRCost: Double = 0.4
        /// 按被跳过的演唱时长额外加权
        public var skipTimeWeight: Double = 0.0
        /// 最低证据质量，低于此值视为无直接证据
        public var minEvidenceQuality: Double = 0.0
        /// 避免单个偶然同字把整行固定到错误时间；单字歌词仍只需命中一个字。
        public var minimumExactCharacters: Int = 2
        /// 只用于匹配的读音归一化；显示和导出仍保留原歌词表记。
        public var usePhoneticReadings: Bool = true

        public init() {}
        public static let `default` = Config()
    }

    public static func match(lyrics: [String],
                             transcript: ASRTranscript,
                             config: Config = .default) -> LyricASRMatch {

        // ---- 归一化 ----
        let readingService = JapaneseReadingService()
        func normalized(_ text: String) -> String {
            config.usePhoneticReadings
                ? JapaneseNormalizer.normalizeForAlignment(text, readingService: readingService)
                : JapaneseNormalizer.normalizeForMatching(text)
        }
        let lineChars = lyrics.map { Array(normalized($0)) }
        let asrTokenChars = transcript.tokens.map { Array(normalized($0.text)) }

        var asrChars: [Character] = []
        var asrOwner: [Int] = []
        var asrCharDuration: [Double] = []
        for (k, token) in transcript.tokens.enumerated() {
            let chars = asrTokenChars[k]
            guard !chars.isEmpty else { continue }
            let per = token.duration / Double(chars.count)
            for ch in chars {
                asrChars.append(ch)
                asrOwner.append(k)
                asrCharDuration.append(per)
            }
        }
        guard !asrChars.isEmpty else {
            return LyricASRMatch(lines: lyrics.indices.map {
                .init(lineIndex: $0, start: nil, end: nil,
                      charTimes: Array(repeating: nil, count: lineChars[$0].count),
                      charEnds: Array(repeating: nil, count: lineChars[$0].count),
                      evidenceQuality: 0, hasDirectEvidence: false, regionIndex: nil)
            }, regionCount: 0, asrCharCount: 0, matchedCharCount: 0, totalCost: 0)
        }

        // ---- 演唱区 ----
        var regions: [[Int]] = []
        var current: [Int] = []
        // 标点/空白 ASR 时间片没有可参与匹配的字符，不应单独切出一个空演唱区。
        let searchableTokenIndices = transcript.tokens.indices.filter {
            !asrTokenChars[$0].isEmpty
        }
        for k in searchableTokenIndices {
            let token = transcript.tokens[k]
            if let last = current.last,
               token.start - transcript.tokens[last].end > config.regionGap {
                regions.append(current)
                current = []
            }
            current.append(k)
        }
        if !current.isEmpty { regions.append(current) }

        // 每个演唱区在 asrChars 里的字符区间
        var regionCharRange: [(Int, Int)] = []
        var cursor = 0
        for region in regions {
            let count = region.reduce(0) {
                $0 + asrTokenChars[$1].count
            }
            regionCharRange.append((cursor, cursor + count))
            cursor += count
        }

        let n = lyrics.count
        let r = regions.count

        // ---- 外层 DP ----
        var blockCache: [Int: Double] = [:]
        func blockCost(_ i: Int, _ j: Int, _ region: Int) -> Double {
            let key = (i << 16) | (j << 8) | region
            if let cached = blockCache[key] { return cached }
            let (lo, hi) = regionCharRange[region]
            let text = lineChars[i..<j].flatMap { $0 }
            let cost = alignCost(text, Array(asrChars[lo..<hi]),
                                 durations: Array(asrCharDuration[lo..<hi]), config: config)
            blockCache[key] = cost
            return cost
        }

        let inf = Double.infinity
        var dp = [[Double]](repeating: [Double](repeating: inf, count: n + 1), count: r + 1)
        var back = [[(Int, Int, Int)]](repeating: [(Int, Int, Int)](repeating: (-1, -1, -1), count: n + 1), count: r + 1)
        dp[0][0] = 0
        for region in 0..<r {
            for i in 0...n where dp[region][i].isFinite {
                // 该区不使用
                if dp[region][i] + config.emptyRegionCost < dp[region + 1][i] {
                    dp[region + 1][i] = dp[region][i] + config.emptyRegionCost
                    back[region + 1][i] = (i, region, i)
                }
                // 该区覆盖 lines[i..<j]
                var j = i + 1
                while j <= n {
                    let cost = dp[region][i] + blockCost(i, j, region)
                    if cost < dp[region + 1][j] {
                        dp[region + 1][j] = cost
                        back[region + 1][j] = (i, region, j)
                    }
                    j += 1
                }
            }
        }
        // 末尾允许剩余行没有演唱区
        var bestCost = inf
        var bestEnd = n
        for i in 0...n {
            let cost = dp[r][i] + Double(n - i) * config.gapLyricCost * 6
            if cost < bestCost {
                bestCost = cost
                bestEnd = i
            }
        }

        // ---- 回溯行 → 演唱区 ----
        var assignment = [Int?](repeating: nil, count: n)
        var region = r
        var idx = bestEnd
        while region > 0 {
            let step = back[region][idx]
            guard step.0 >= 0 else { break }
            let (pi, pr, pj) = step
            if pj > pi {
                for k in pi..<pj { assignment[k] = pr }
            }
            idx = pi
            region = pr
        }

        // ---- 内层逐字对齐 ----
        var matches: [LyricASRMatch.LineMatch] = []
        var matchedChars = 0

        for li in 0..<n {
            let chars = lineChars[li]
            guard let regionIndex = assignment[li], regionIndex < regionCharRange.count else {
                matches.append(.init(lineIndex: li, start: nil, end: nil,
                                     charTimes: Array(repeating: nil, count: chars.count),
                                     charEnds: Array(repeating: nil, count: chars.count),
                                     evidenceQuality: 0, hasDirectEvidence: false, regionIndex: nil))
                continue
            }
            let (lo, hi) = regionCharRange[regionIndex]
            let group = (0..<n).filter { assignment[$0] == regionIndex }
            guard let gi = group.first, let gj = group.last else { continue }
            let groupText = lineChars[gi...gj].flatMap { $0 }
            let offset = lineChars[gi..<li].reduce(0) { $0 + $1.count }
            let (path, _) = alignPath(groupText, Array(asrChars[lo..<hi]),
                                      durations: Array(asrCharDuration[lo..<hi]), config: config)
            let mine = Array(path[offset..<min(path.count, offset + chars.count)])

            var charTimes: [Double?] = []
            var charEnds: [Double?] = []
            var exact = 0
            var ids: [Int] = []
            for (pos, m) in mine.enumerated() {
                guard let m else {
                    charTimes.append(nil); charEnds.append(nil); continue
                }
                let global = lo + m
                guard global < asrChars.count, pos < chars.count,
                      chars[pos] == asrChars[global] else {
                    charTimes.append(nil)
                    charEnds.append(nil)
                    continue
                }
                exact += 1
                let owner = asrOwner[global]
                charTimes.append(transcript.tokens[owner].start)
                charEnds.append(transcript.tokens[owner].end)
                ids.append(global)
            }
            while charTimes.count < chars.count { charTimes.append(nil); charEnds.append(nil) }

            let quality = chars.isEmpty ? 0 : Double(exact) / Double(chars.count)
            let requiredExactCharacters = min(max(1, config.minimumExactCharacters), chars.count)
            // 空行（歌词只有标点时 chars 为空）没有任何可用字，不能算有证据，否则下面取 ids[0] 会崩溃
            let hasEvidence = !ids.isEmpty
                && exact >= requiredExactCharacters
                && quality >= config.minEvidenceQuality
            matchedChars += ids.count
            matches.append(.init(lineIndex: li,
                                 start: hasEvidence ? transcript.tokens[asrOwner[ids[0]]].start : nil,
                                 end: hasEvidence ? transcript.tokens[asrOwner[ids[ids.count - 1]]].end : nil,
                                 charTimes: charTimes,
                                 charEnds: charEnds,
                                 evidenceQuality: quality,
                                 hasDirectEvidence: hasEvidence,
                                 regionIndex: regionIndex))
        }

        // ---- 无直接证据的行：在相邻有证据行之间按字数插值 ----
        let known = matches.indices.filter { matches[$0].start != nil }
        let speechStart = transcript.tokens.first?.start ?? 0
        let speechEnd = max(speechStart + 0.3,
                            transcript.tokens.last?.end ?? transcript.audioDuration)
        for li in 0..<n where matches[li].start == nil {
            let prev = known.last { $0 < li }
            let next = known.first { $0 > li }
            let loTime = prev.map { matches[$0].end ?? 0 } ?? speechStart
            let hiTime = next.map { matches[$0].start ?? (loTime + 5) }
                ?? max(speechEnd, loTime + 0.3)
            let span = max(0.1, hiTime - loTime)
            let from = (prev ?? -1) + 1
            let to = next ?? n
            let groupIdx = Array(from..<to)
            let totalChars = groupIdx.reduce(0) { $0 + lineChars[$1].count }
            var cursorTime = loTime
            for k in groupIdx where matches[k].start == nil {
                let share = span * Double(lineChars[k].count) / Double(max(1, totalChars))
                let s = cursorTime + share * 0.15
                let e = cursorTime + share * 0.85
                // 逐字时间也按比例铺开，保证行内扫色仍有顺序
                let count = max(1, lineChars[k].count)
                var times: [Double?] = []
                var ends: [Double?] = []
                for c in 0..<lineChars[k].count {
                    times.append(s + (e - s) * Double(c) / Double(count))
                    ends.append(s + (e - s) * Double(c + 1) / Double(count))
                }
                matches[k] = .init(lineIndex: k, start: s, end: e,
                                   charTimes: times, charEnds: ends,
                                   evidenceQuality: matches[k].evidenceQuality,
                                   hasDirectEvidence: false,
                                   regionIndex: matches[k].regionIndex)
                cursorTime += share
            }
        }

        return LyricASRMatch(lines: matches,
                             regionCount: r,
                             asrCharCount: asrChars.count,
                             matchedCharCount: matchedChars,
                             totalCost: bestCost)
    }

    // MARK: 逐字顺序 DP

    /// 只算代价（外层 DP 用，避免分配回溯矩阵）。
    static func alignCost(_ lyric: [Character], _ asr: [Character],
                          durations: [Double], config: Config) -> Double {
        let n = lyric.count, m = asr.count
        guard n > 0 else { return 0 }
        // 空 ASR 区间表示本句完全没有可匹配的语音字符；按漏词代价处理，不能构造 1...0。
        guard m > 0 else { return Double(n) * config.gapLyricCost }
        var prev = [Double](repeating: .infinity, count: m + 1)
        prev[0] = 0
        var cur = [Double](repeating: .infinity, count: m + 1)
        for i in 1...n {
            cur[0] = prev[0] + config.gapLyricCost
            let lc = lyric[i - 1]
            for j in 1...m {
                let sub = prev[j - 1] + JapaneseNormalizer.substitutionCost(lc, asr[j - 1])
                let del = prev[j] + config.gapLyricCost
                let ins = cur[j - 1] + config.gapASRCost + config.skipTimeWeight * durations[j - 1]
                cur[j] = min(sub, min(del, ins))
            }
            swap(&prev, &cur)
        }
        return prev[m]
    }

    /// 带回溯：返回每个歌词字命中的 ASR 下标。
    static func alignPath(_ lyric: [Character], _ asr: [Character],
                          durations: [Double], config: Config) -> ([Int?], Double) {
        let n = lyric.count, m = asr.count
        guard n > 0 else { return ([], 0) }
        guard m > 0 else { return (Array(repeating: nil, count: n), Double(n) * config.gapLyricCost) }

        let insCost: [Double] = (0..<m).map { config.gapASRCost + config.skipTimeWeight * durations[$0] }
        var rows = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        rows[0][0] = 0
        for j in 1...m { rows[0][j] = rows[0][j - 1] + insCost[j - 1] }
        for i in 1...n {
            rows[i][0] = rows[i - 1][0] + config.gapLyricCost
            let lc = lyric[i - 1]
            for j in 1...m {
                let sub = rows[i - 1][j - 1] + JapaneseNormalizer.substitutionCost(lc, asr[j - 1])
                let del = rows[i - 1][j] + config.gapLyricCost
                let ins = rows[i][j - 1] + insCost[j - 1]
                rows[i][j] = min(sub, min(del, ins))
            }
        }
        var path = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               rows[i][j] == rows[i - 1][j - 1]
                    + JapaneseNormalizer.substitutionCost(lyric[i - 1], asr[j - 1]) {
                path[i - 1] = j - 1
                i -= 1; j -= 1
            } else if i > 0, rows[i][j] == rows[i - 1][j] + config.gapLyricCost {
                i -= 1
            } else if j > 0, rows[i][j] == rows[i][j - 1] + insCost[j - 1] {
                j -= 1
            } else {
                break
            }
        }
        return (path, rows[n][m])
    }
}
