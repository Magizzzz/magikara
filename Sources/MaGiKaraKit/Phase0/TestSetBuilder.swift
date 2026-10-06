import Foundation

// MARK: - 测试集数据结构

/// 一个测试片段的真值。
///
/// **重要说明**：当前测试集是用 macOS `say`(Kyoko) 逐句合成的日语语音，
/// 按已知间隔拼接而成。真值由构造过程直接确定（逐句裁剪静音后的精确位置），
/// 因此可用于验证「句边界定位」这一环节。
///
/// 但它**不是歌手演唱**：没有伴奏、没有音乐性连音、没有颤音与气声。
/// 因此它只能作为 Phase 0 的可重复基线，**不能替代真实歌曲验证**。
public struct TestClipTruth: Codable, Sendable {
    public var id: String
    public var kind: String                 // "tts-baseline"
    public var note: String
    public var audioFile: String
    public var sampleRate: Double
    public var duration: Double
    public var voice: String
    public var rate: Double
    /// 是否含重复段落
    public var hasRepeat: Bool
    public var lines: [TruthLine]

    public struct TruthLine: Codable, Sendable {
        public var order: Int
        public var text: String
        /// 该句语音的精确起始时间（已裁掉首尾静音）
        public var start: Double
        public var end: Double
        /// 与上一句之间的间隔（秒）
        public var gapBefore: Double
        /// 该句之后是否有间奏
        public var interludeAfter: Double
    }
}

// MARK: - 生成器

/// 构建 Phase 0 本地测试集（RD §8.3）。
public enum TestSetBuilder {

    public struct Spec: Sendable {
        public var id: String
        public var voice: String
        public var rate: Double
        public var introSilence: Double
        public var gapBetweenLines: Double
        public var lines: [String]
        /// (在第几行之后, 间奏秒数)
        public var interludes: [Int: Double]
        public var hasRepeat: Bool
        /// 合成伴奏床的混入增益，0 表示无人声以外的伴奏
        public var backingLevel: Float

        public init(id: String,
                    voice: String = "Kyoko",
                    rate: Double = 180,
                    introSilence: Double = 1.5,
                    gapBetweenLines: Double = 0.35,
                    lines: [String],
                    interludes: [Int: Double] = [:],
                    hasRepeat: Bool = false,
                    backingLevel: Float = 0) {
            self.id = id
            self.voice = voice
            self.rate = rate
            self.introSilence = introSilence
            self.gapBetweenLines = gapBetweenLines
            self.lines = lines
            self.interludes = interludes
            self.hasRepeat = hasRepeat
            self.backingLevel = backingLevel
        }
    }

    public enum BuildError: LocalizedError {
        case sayFailed(String)
        case noSamples(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sayFailed(let m): return "say 合成失败：\(m)"
            case .noSamples(let m): return "合成结果没有可用音频：\(m)"
            case .writeFailed(let m): return "写入失败：\(m)"
            }
        }
    }

    /// RD §8.3 要求的覆盖面：常规、较快、重复副歌、软硬件混唱。
    /// 这里用 TTS 能覆盖的部分 + 明确的「未覆盖」说明。
    public static let defaultSpecs: [Spec] = [
        Spec(id: "tts-jpop-01",
             rate: 175,
             introSilence: 1.5,
             gapBetweenLines: 0.35,
             lines: [
                "素晴らしき世界に今日も乾杯",
                "どんな暗い夜でもきっとまた会える",
                "遠く離れていても君を想う",
                "夢の続きを歌い続けるよ",
                "風が運ぶ季節の匂い",
                "僕らの声は空を越えて",
                "何度でも立ち上がれるから",
                "光の中で君に会える",
             ],
             interludes: [4: 2.5]),

        Spec(id: "tts-fast-01",
             rate: 260,
             introSilence: 1.0,
             gapBetweenLines: 0.20,
             lines: [
                "走り出した世界の果てまで",
                "君の名前を何度も呼んだ",
                "時間が止まればいいのに",
                "教科書にない答えを探す",
                "Never give up そう信じて",
                "小さな声でも届くように",
                "運命なんて決められないよ",
                "東京の空はいつも広くて",
                "失敗しても笑い飛ばして",
                "最後のページを開こう",
             ],
             interludes: [5: 2.0]),

        // 重复副歌：结构与歌词重复，考验顺序约束是否会把第二次副歌错配到第一次
        Spec(id: "tts-repeat-01",
             rate: 180,
             introSilence: 1.0,
             gapBetweenLines: 0.30,
             lines: [
                "咲いた花のように笑って",
                "涙は星になるから",
                "明日へ続く道を歩こう",
                "君となら怖くない",
                "咲いた花のように笑って",
                "涙は星になるから",
                "明日へ続く道を歩こう",
                "君となら怖くない",
             ],
             interludes: [4: 3.0],
             hasRepeat: true),

        // 连续演唱：句间几乎无静音，考验在浊音内部切分句边界的能力
        Spec(id: "tts-continuous-01",
             rate: 200,
             introSilence: 0.8,
             gapBetweenLines: 0.10,
             lines: [
                "静かな朝に目を覚まして",
                "窓の外には青い空",
                "今日は何を話そうか",
                "君に会えるそれだけで",
                "一日中笑っていたい",
                "こんな気持ちは初めてで",
             ],
             interludes: [:]),

        // 伴奏密集：在人声上叠加本地合成的和弦垫音 + 贝斯 + 鼓，
        // 用来观察能量/谱通量对齐在有伴奏时的退化程度。
        Spec(id: "tts-with-backing-01",
             rate: 175,
             introSilence: 1.5,
             gapBetweenLines: 0.35,
             lines: [
                "素晴らしき世界に今日も乾杯",
                "どんな暗い夜でもきっとまた会える",
                "遠く離れていても君を想う",
                "夢の続きを歌い続けるよ",
                "風が運ぶ季節の匂い",
                "僕らの声は空を越えて",
                "何度でも立ち上がれるから",
                "光の中で君に会える",
             ],
             interludes: [4: 2.5],
             backingLevel: 0.55),
    ]

    /// 生成全部测试片段到 targetDirectory。返回每个片段的真值文件路径。
    public static func build(specs: [Spec] = defaultSpecs,
                             targetDirectory: URL,
                             progress: ((String) -> Void)? = nil) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let tmp = targetDirectory.appendingPathComponent(".tmp", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var outputs: [URL] = []
        for spec in specs {
            progress?("生成测试片段 \(spec.id) …")
            let url = try buildOne(spec: spec, targetDirectory: targetDirectory, tmp: tmp)
            outputs.append(url)
        }
        return outputs
    }

    static func buildOne(spec: Spec, targetDirectory: URL, tmp: URL) throws -> URL {
        let sr = AudioDecoder.defaultSampleRate
        let gapSamples = Int(spec.gapBetweenLines * sr)
        let introSamples = Int(spec.introSilence * sr)

        var buffer: [Float] = Array(repeating: 0, count: introSamples)
        var truthLines: [TestClipTruth.TruthLine] = []
        var cursor = Double(introSamples) / sr
        var interludeAfter: [Int: Double] = [:]

        for (index, text) in spec.lines.enumerated() {
            let order = index + 1
            let aiff = tmp.appendingPathComponent("\(spec.id)-\(order).aiff")
            try synthesize(text: text, voice: spec.voice, rate: spec.rate, to: aiff)

            let decoded: DecodedAudio
            do {
                decoded = try AudioDecoder.decodeSync(url: aiff, sampleRate: sr)
            } catch {
                throw BuildError.noSamples("\(spec.id) 第 \(order) 句：\(error.localizedDescription)")
            }
            guard !decoded.samples.isEmpty else {
                throw BuildError.noSamples("\(spec.id) 第 \(order) 句为空")
            }

            // 裁掉首尾静音，让真值对应真实语音起点
            let trimmed = trimSilence(decoded.samples, sampleRate: sr)
            guard !trimmed.isEmpty else {
                throw BuildError.noSamples("\(spec.id) 第 \(order) 句裁剪后为空")
            }

            let start = cursor
            buffer.append(contentsOf: trimmed)
            cursor += Double(trimmed.count) / sr
            let end = cursor

            let interlude = spec.interludes[order] ?? 0
            truthLines.append(.init(order: order,
                                    text: text,
                                    start: start,
                                    end: end,
                                    gapBefore: spec.gapBetweenLines,
                                    interludeAfter: interlude))

            if interlude > 0 {
                let n = Int(interlude * sr)
                buffer.append(contentsOf: [Float](repeating: 0, count: n))
                cursor += Double(n) / sr
                interludeAfter[order] = interlude
            } else if index < spec.lines.count - 1 {
                buffer.append(contentsOf: [Float](repeating: 0, count: gapSamples))
                cursor += Double(gapSamples) / sr
            }
        }

        // 尾部留 1 秒
        buffer.append(contentsOf: [Float](repeating: 0, count: Int(1.0 * sr)))

        // 可选：叠加合成伴奏床（真值不变，仍是逐句语音位置）
        if spec.backingLevel > 0 {
            let backing = BackingTrackSynth.generate(duration: Double(buffer.count) / sr, sampleRate: sr)
            buffer = BackingTrackSynth.mix(vocal: buffer, backing: backing, backingGain: spec.backingLevel)
        }

        let wavName = "\(spec.id).wav"
        let wavURL = targetDirectory.appendingPathComponent(wavName)
        do {
            try WAVWriter.write(samples: buffer, sampleRate: sr, to: wavURL)
        } catch {
            throw BuildError.writeFailed(error.localizedDescription)
        }

        let truth = TestClipTruth(
            id: spec.id,
            kind: "tts-baseline",
            note: "由 macOS say(\(spec.voice)) 逐句合成、裁除首尾静音后按已知间隔拼接；真值由构造确定。这是语音基线，不是歌手演唱，不能替代真实歌曲验证。",
            audioFile: wavName,
            sampleRate: sr,
            duration: Double(buffer.count) / sr,
            voice: spec.voice,
            rate: spec.rate,
            hasRepeat: spec.hasRepeat,
            lines: truthLines)

        let truthURL = targetDirectory.appendingPathComponent("\(spec.id).truth.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(truth).write(to: truthURL)
        return truthURL
    }

    static func synthesize(text: String, voice: String, rate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "-r", String(Int(rate)),
            "-o", url.path,
            text,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw BuildError.sayFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BuildError.sayFailed("退出码 \(process.terminationStatus) \(msg)")
        }
    }

    /// 用 -42 dBFS 阈值裁掉首尾静音，两端各留 15 ms 保护。
    public static func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let threshold: Float = 0.008
        var first = 0
        var last = samples.count - 1
        while first < samples.count && abs(samples[first]) < threshold { first += 1 }
        while last > first && abs(samples[last]) < threshold { last -= 1 }
        if first >= last { return [] }
        let guardSamples = Int(0.015 * sampleRate)
        let lo = max(0, first - guardSamples)
        let hi = min(samples.count, last + 1 + guardSamples)
        return Array(samples[lo..<hi])
    }
}

// MARK: - WAV 输出

public enum WAVWriter {
    public enum WriteError: LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let m) = self { return m }
            return nil
        }
    }

    /// 写 16-bit PCM 单声道 WAV。
    public static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)                      // PCM
        u16(channels)
        u32(Int(sampleRate))
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        u32(dataSize)

        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let clamped = max(-1, min(1, samples[i]))
            pcm[i] = Int16(clamped * 32767)
        }
        pcm.withUnsafeBufferPointer { bp in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(bp.baseAddress!).assumingMemoryBound(to: UInt8.self),
                                            count: bp.count * 2))
        }

        do {
            try data.write(to: url)
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
    }
}
