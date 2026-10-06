import Compression
import Foundation
import Testing
@testable import MaGiKaraKit

/// 本地人声分离后端。全部用例都不下载模型、不读网络：
/// 覆盖模型元数据、进度语义、分块/重叠相加/残差、STFT 往返、WAV 头与路径安全、
/// 以及安全解压（用测试内构造的最小 ZIP）。
@Suite struct VocalSeparationTests {

    // MARK: - 模型元数据

    @Test func modelInfoMatchesPinnedHFContract() {
        let info = VocalSeparationModelInfo.mdx23cInstVocHQ

        #expect(info.repository == "huggingsounds/nubeaudio-mdx")
        #expect(info.revision == "a133c157760773700ecbdaadcba755d7e94739c3")
        #expect(info.fileName == "mdx23c_instvoc_hq.mlpackage.zip")
        #expect(info.packageName == "mdx23c_instvoc_hq.mlpackage")
        #expect(info.expectedByteCount == 41_797_322)
        #expect(info.expectedSHA256 == "c1d4c475f1d43b64f9e48b8b8e5defe6f41ead6289d1feb9da6480c25246c674")
        #expect(info.expectedSHA256.count == 64)
        #expect(info.licenseName == "MIT")

        #expect(info.sampleRate == 44_100)
        #expect(info.nFFT == 8192)
        #expect(info.hopLength == 1024)
        #expect(info.dimF == 4096)
        #expect(info.chunkSampleCount == 261_120)
        #expect(info.frameCount == 256)
        #expect(info.inputName == "spectrogram")
        #expect(info.outputName == "stems")
        #expect(info.stemNames == ["vocals", "instrumental"])

        // 模型卡契约自洽：261120 / 1024 + 1 == 256
        #expect(info.chunkSampleCount / info.hopLength + 1 == info.frameCount)
        #expect(info.downloadURL.absoluteString
            == "https://huggingface.co/huggingsounds/nubeaudio-mdx/resolve/a133c157760773700ecbdaadcba755d7e94739c3/mdx23c_instvoc_hq.mlpackage.zip")
    }

    @Test func modelStatusProgressIsOrdered() {
        #expect(VocalSeparationModelStatus.notInstalled.progressValue == 0)
        let download = VocalSeparationModelStatus.downloading(progress: 0.5).progressValue
        let verifying = VocalSeparationModelStatus.verifying.progressValue
        let extracting = VocalSeparationModelStatus.extracting.progressValue
        let compiling = VocalSeparationModelStatus.compiling.progressValue
        #expect(download != nil && verifying != nil && extracting != nil && compiling != nil)
        #expect(download! < verifying!)
        #expect(verifying! < extracting!)
        #expect(extracting! < compiling!)
        #expect(VocalSeparationModelStatus.ready(compiledModelURL: URL(fileURLWithPath: "/tmp/x")).progressValue == 1)
        #expect(VocalSeparationModelStatus.ready(compiledModelURL: URL(fileURLWithPath: "/tmp/x")).isReady)
        #expect(VocalSeparationModelStatus.failed(message: "x").progressValue == nil)
    }

    // MARK: - 进度上报

    @Test func progressReporterIsMonotonicAndClamped() {
        var seen: [Double] = []
        var reporter = VocalSeparationProgressReporter { seen.append($0) }
        reporter.report(-1)      // → 0
        reporter.report(0.2)
        reporter.report(0.1)     // 后退，忽略
        reporter.report(0.5)
        reporter.report(2)       // → 1
        reporter.complete()      // 已是 1，忽略
        #expect(seen == [0, 0.2, 0.5, 1])
    }

    // MARK: - 分块

    @Test func chunkStartsCoverWholeSignalMonotonically() {
        let chunk = 261_120
        let hop = 130_560
        let total = 1_000_000
        let starts = VocalSeparationChunking.chunkStarts(sampleCount: total, chunk: chunk, hop: hop)

        #expect(starts.first == 0)
        #expect(starts.last == total - chunk)
        for start in starts {
            #expect(start >= 0)
            #expect(start + chunk <= total)
        }
        for (a, b) in zip(starts, starts.dropFirst()) {
            #expect(b > a)
        }

        var covered = [Bool](repeating: false, count: total)
        for start in starts {
            for i in 0..<chunk { covered[start + i] = true }
        }
        #expect(covered.allSatisfy { $0 }, "所有采样都必须至少被一个 chunk 覆盖")
    }

    @Test func chunkStartsHandlesExactMultipleAndShortInput() {
        let chunk = 261_120
        let hop = 130_560
        #expect(VocalSeparationChunking.chunkStarts(sampleCount: chunk, chunk: chunk, hop: hop) == [0])
        #expect(VocalSeparationChunking.chunkStarts(sampleCount: 100, chunk: chunk, hop: hop) == [0])
        #expect(VocalSeparationChunking.chunkStarts(sampleCount: 0, chunk: chunk, hop: hop).isEmpty)
        #expect(VocalSeparationChunking.chunkStarts(sampleCount: chunk * 2, chunk: chunk, hop: hop)
            == [0, hop, chunk])
    }

    @Test func hannWindowIsPeriodic() {
        let n = 16
        let w = VocalSeparationChunking.hannWindow(length: n)
        #expect(w.count == n)
        #expect(abs(w[0]) < 1e-6)
        #expect(abs(w[n / 2] - 1.0) < 1e-5)
        for i in 1..<n {
            #expect(abs(w[i] - w[n - i]) < 1e-6, "periodic Hann 应满足 w[i] == w[n-i]")
        }
    }

    // MARK: - 重叠相加 + 残差

    @Test func overlapAddNormalizesWindowWeighting() {
        let n = 1_000
        var accumulator = VocalOverlapAdd(sampleCount: n)
        let window = VocalSeparationChunking.hannWindow(length: n)
        let left = [Float](repeating: 0.4, count: n)
        let right = [Float](repeating: -0.6, count: n)

        accumulator.add([left, right], at: 0, validCount: n, window: window)
        let out = accumulator.normalizedVocal()

        // 常数信号乘以并除以同一个窗应完全还原（仅首个 w=0 的样本除外）
        #expect(abs(out[0][0]) < 1e-6)
        for i in 1..<n {
            #expect(abs(out[0][i] - 0.4) < 1e-4)
            #expect(abs(out[1][i] - (-0.6)) < 1e-4)
        }
    }

    @Test func peakLimiterKeepsEverySampleUnderCeilingAndLeavesQuietPartsAlone() {
        let sr = 44_100.0
        let n = 44_100
        // 前半秒安静（0.3），中间一个 1.35 的尖峰，后面再回到安静
        var l = (0..<n).map { Float(0.3 * sin(Double($0) * 0.05)) }
        var r = l
        l[22_050] = 1.35
        r[22_051] = -1.2
        let out = VocalPeakLimiter.limited([l, r], sampleRate: sr)
        let peak = out.flatMap { $0 }.map(abs).max() ?? 0
        #expect(peak <= VocalPeakLimiter.ceiling + 1e-6)
        // 离尖峰 0.4 秒之外的安静部分几乎不受影响
        #expect(abs(out[0][1000] - l[1000]) < 1e-4)
        #expect(abs(out[0][n - 10] - l[n - 10]) < 1e-3)
    }

    @Test func peakLimiterIsNoOpBelowCeiling() {
        let x: [[Float]] = [[0.5, -0.9, 0.2], [0.1, 0.3, -0.97]]
        #expect(VocalPeakLimiter.limited(x, sampleRate: 44_100) == x)
    }

    @Test func residualReconstructsMixExactly() {
        let mix: [[Float]] = [[0, 1, 2, 3], [0, -1, -2, -3]]
        let vocal: [[Float]] = [[0, 0.25, 0.5, 0.75], [0, -0.25, -0.5, -0.75]]
        let instrumental = VocalOverlapAdd.residual(mix: mix, vocal: vocal)

        #expect(instrumental.count == 2)
        for ch in 0..<2 {
            for i in 0..<4 {
                #expect(abs((vocal[ch][i] + instrumental[ch][i]) - mix[ch][i]) < 1e-6,
                        "vocal + instrumental 必须逐样本等于 input")
            }
        }
    }

    // MARK: - WAV

    @Test func wavHeaderHasIEEEFFloatStereoLayout() {
        let header = VocalWAVWriter.header(channelCount: 2, sampleRate: 44_100, frameCount: 1_000)
        #expect(header.count == 44)
        #expect(ascii(header, 0..<4) == "RIFF")
        #expect(ascii(header, 8..<12) == "WAVE")
        #expect(ascii(header, 12..<16) == "fmt ")
        #expect(ascii(header, 36..<40) == "data")
        #expect(leUInt32(header, 16) == 16)
        #expect(leUInt16(header, 20) == 3, "必须是 IEEE float（非 PCM 整数）")
        #expect(leUInt16(header, 22) == 2)
        #expect(leUInt32(header, 24) == 44_100)
        #expect(leUInt16(header, 34) == 32)
        #expect(leUInt32(header, 28) == 44_100 * 2 * 4, "byteRate 必须与采样率/位深一致")
        #expect(leUInt16(header, 32) == 2 * 4, "blockAlign 必须为 8 字节")
        let dataSize = leUInt32(header, 40)
        #expect(dataSize == 1_000 * 2 * 4)
        #expect(leUInt32(header, 4) == 36 + dataSize)
    }

    @Test func wavWriterEmitsAlignedInterleavedFloat32() throws {
        let channels: [[Float]] = [[0, 0.5, -0.5, 1.0], [0, -1.0, 0.25, -0.25]]
        let url = temporaryURL(extension: "wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try VocalWAVWriter.write(channels: channels, sampleRate: 44_100, to: url)
        let data = try Data(contentsOf: url)

        #expect(data.count == 44 + 4 * 2 * 4)
        #expect(leUInt32(data, 40) == 4 * 2 * 4)
        let bytes = [UInt8](data)
        for frame in 0..<4 {
            let base = 44 + frame * 8
            let l = readFloat(bytes, base)
            let r = readFloat(bytes, base + 4)
            #expect(abs(l - channels[0][frame]) < 1e-6)
            #expect(abs(r - channels[1][frame]) < 1e-6)
        }
    }

    // MARK: - 路径安全

    @Test func pathValidationRejectsOverwritesAndMissingDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-vs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let media = dir.appendingPathComponent("song.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: media)
        let vocal = dir.appendingPathComponent("vocal.wav")
        let instrumental = dir.appendingPathComponent("inst.wav")

        // 合法组合不应抛错
        try VocalSeparationPaths.validate(mediaURL: media, vocalURL: vocal, instrumentalURL: instrumental)

        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationPaths.validate(mediaURL: media, vocalURL: vocal, instrumentalURL: vocal)
        }
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationPaths.validate(mediaURL: media, vocalURL: media, instrumentalURL: instrumental)
        }
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationPaths.validate(mediaURL: media,
                                              vocalURL: dir.appendingPathComponent("missing/vocal.wav"),
                                              instrumentalURL: instrumental)
        }

        // 已存在文件必须保留原内容，不能因重复运行被静默覆盖。
        let existingVocal = Data("keep this output".utf8)
        try existingVocal.write(to: vocal)
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationPaths.validate(mediaURL: media,
                                              vocalURL: vocal,
                                              instrumentalURL: instrumental)
        }
        #expect(try Data(contentsOf: vocal) == existingVocal)
        try FileManager.default.removeItem(at: vocal)

        // 输出是目录 → 拒绝
        try FileManager.default.createDirectory(at: vocal, withIntermediateDirectories: true)
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationPaths.validate(mediaURL: media, vocalURL: vocal, instrumentalURL: instrumental)
        }
    }

    @Test func temporarySiblingStaysInOutputDirectoryAndIsHidden() {
        let output = URL(fileURLWithPath: "/tmp/out/song.vocal.wav")
        let temp = VocalSeparationPaths.temporarySibling(for: output)
        #expect(temp.deletingLastPathComponent().path == "/tmp/out")
        #expect(temp.lastPathComponent.hasSuffix(".magikara-partial"))
        #expect(temp.lastPathComponent.hasPrefix("."))
    }

    // MARK: - 摘要

    @Test func sha256MatchesKnownVector() throws {
        let url = temporaryURL(extension: "bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try VocalSeparationIntegrity.sha256Hex(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - 安全解压

    @Test func archivePathSanitizerRejectsTraversal() {
        #expect(VocalSeparationArchive.safeEntryPath("..") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("../evil") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("pkg/../../evil") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("/abs/path") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("pkg\\evil") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("") == nil)
        #expect(VocalSeparationArchive.safeEntryPath("pkg/./x") == nil)

        #expect(VocalSeparationArchive.safeEntryPath("pkg/Manifest.json") == "pkg/Manifest.json")
        #expect(VocalSeparationArchive.safeEntryPath("pkg/") == "pkg")
    }

    @Test func archiveExtractsExpectedPackageWithoutTouchingTraversal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("model.zip")
        let zip = makeStoredZip(entries: [
            ("pkg/", []),
            ("pkg/Manifest.json", Array("{\"ok\":true}".utf8)),
            ("pkg/Data/", []),
            ("pkg/Data/weight.bin", [1, 2, 3, 4, 5]),
        ])
        try zip.write(to: zipURL)

        let dest = dir.appendingPathComponent("extracted", isDirectory: true)
        let package = try VocalSeparationArchive.extractPackage(zipURL: zipURL,
                                                                into: dest,
                                                                expectedTopLevel: "pkg")
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("Manifest.json").path))
        let manifest = try String(contentsOf: package.appendingPathComponent("Manifest.json"), encoding: .utf8)
        #expect(manifest == "{\"ok\":true}")
        let weight = try Data(contentsOf: package.appendingPathComponent("Data/weight.bin"))
        #expect([UInt8](weight) == [1, 2, 3, 4, 5])
    }

    @Test func archiveRejectsTraversalAndUnexpectedTopLevel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-zip-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let traversalZip = dir.appendingPathComponent("traversal.zip")
        try makeStoredZip(entries: [
            ("pkg/", []),
            ("pkg/../evil.txt", [9, 9, 9]),
        ]).write(to: traversalZip)
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationArchive.extractPackage(zipURL: traversalZip,
                                                      into: dir.appendingPathComponent("a"),
                                                      expectedTopLevel: "pkg")
        }

        let wrongTopZip = dir.appendingPathComponent("wrongtop.zip")
        try makeStoredZip(entries: [("other/file.bin", [1])]).write(to: wrongTopZip)
        #expect(throws: VocalSeparationError.self) {
            try VocalSeparationArchive.extractPackage(zipURL: wrongTopZip,
                                                      into: dir.appendingPathComponent("b"),
                                                      expectedTopLevel: "pkg")
        }
    }

    @Test func archiveInflatesDeflatedEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-zip-deflate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 真实模型包正是用 deflate 存 weight.bin（~112 MB → ~41 MB），这里验证 inflate 路径。
        let payload = Array(String(repeating: "CoreML int8 weights / spectrogram ", count: 400).utf8)
        let compressed = try deflate(payload)
        #expect(compressed.count < payload.count, "测试负载应可被压缩")

        let zipURL = dir.appendingPathComponent("deflate.zip")
        try makeZip(entries: [
            ZIPSample(name: "pkg/Data/weight.bin", method: 8,
                      compressed: compressed, uncompressedSize: payload.count),
        ]).write(to: zipURL)

        let dest = dir.appendingPathComponent("out", isDirectory: true)
        let package = try VocalSeparationArchive.extractPackage(zipURL: zipURL,
                                                                into: dest,
                                                                expectedTopLevel: "pkg")
        let restored = try Data(contentsOf: package.appendingPathComponent("Data/weight.bin"))
        #expect([UInt8](restored) == payload)
    }

    // MARK: - STFT 往返

    @Test func stftRoundTripsSignalInInterior() throws {
        let n = 50_176
        var generator = SystemRandomNumberGenerator()
        let signal = (0..<n).map { _ in Float.random(in: -0.1...0.1, using: &generator) }

        let stft = try #require(VocalSeparationSTFT())
        let (spec, frames) = stft.forward([signal, signal])
        #expect(frames == 50)
        #expect(spec.count == 4 * 4096 * frames)

        let recon = stft.inverse(spec, frames: frames)
        // 只比较内部：dim_f 截断（丢弃 Nyquist）会限制边界保真度
        let interior = Array(recon[0][8192..<(n - 8192)])
        let reference = Array(signal[8192..<(n - 8192)])
        let snr = signalToNoise(interior, reference)
        #expect(snr > 30, "STFT → ISTFT 往返 SNR = \(snr) dB")
    }

    // MARK: - 工具

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("magikara-test-\(UUID().uuidString).\(ext)")
    }

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(bytes: data[range], encoding: .ascii) ?? ""
    }

    private func leUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let b = [UInt8](data)
        return UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
    }

    private func leUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data)
        return UInt32(b[offset])
            | (UInt32(b[offset + 1]) << 8)
            | (UInt32(b[offset + 2]) << 16)
            | (UInt32(b[offset + 3]) << 24)
    }

    private func readFloat(_ bytes: [UInt8], _ offset: Int) -> Float {
        let bits = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }

    private func signalToNoise(_ a: [Float], _ reference: [Float]) -> Double {
        var signal = 0.0
        var error = 0.0
        for i in 0..<min(a.count, reference.count) {
            let d = Double(a[i]) - Double(reference[i])
            error += d * d
            signal += Double(reference[i]) * Double(reference[i])
        }
        return 10 * log10(signal / max(error, 1e-12))
    }

    /// 构造一个只含 stored 条目、无压缩的最小 ZIP（不依赖外部工具）。
    private func makeStoredZip(entries: [(name: String, data: [UInt8])]) -> Data {
        makeZip(entries: entries.map {
            ZIPSample(name: $0.name, method: 0, compressed: $0.data, uncompressedSize: $0.data.count)
        })
    }

    private struct ZIPSample {
        let name: String
        let method: UInt16
        let compressed: [UInt8]
        let uncompressedSize: Int
    }

    private func makeZip(entries: [ZIPSample]) -> Data {
        var out = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(out.count)
            let nameBytes = Array(entry.name.utf8)
            out.appendLittleEndian(UInt32(0x04034b50))
            out.appendLittleEndian(UInt16(20))
            out.appendLittleEndian(UInt16(0))
            out.appendLittleEndian(entry.method)
            out.appendLittleEndian(UInt16(0))
            out.appendLittleEndian(UInt16(0))
            out.appendLittleEndian(UInt32(0))   // crc (未使用)
            out.appendLittleEndian(UInt32(entry.compressed.count))
            out.appendLittleEndian(UInt32(entry.uncompressedSize))
            out.appendLittleEndian(UInt16(nameBytes.count))
            out.appendLittleEndian(UInt16(0))
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: entry.compressed)
        }

        let centralOffset = out.count
        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            central.appendLittleEndian(UInt32(0x02014b50))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(entry.method)
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0))   // crc
            central.appendLittleEndian(UInt32(entry.compressed.count))
            central.appendLittleEndian(UInt32(entry.uncompressedSize))
            central.appendLittleEndian(UInt16(nameBytes.count))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0o100644 << 16))  // regular file
            central.appendLittleEndian(UInt32(offsets[index]))
            central.append(contentsOf: nameBytes)
        }

        let centralSize = central.count
        out.append(central)
        out.appendLittleEndian(UInt32(0x06054b50))
        out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt16(0))
        out.appendLittleEndian(UInt16(entries.count))
        out.appendLittleEndian(UInt16(entries.count))
        out.appendLittleEndian(UInt32(centralSize))
        out.appendLittleEndian(UInt32(centralOffset))
        out.appendLittleEndian(UInt16(0))
        return out
    }

    /// raw DEFLATE（与 ZIP 的 method 8 一致，也就是 Compression 的 COMPRESSION_ZLIB）。
    private func deflate(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: max(64, input.count + 64))
        let encoded = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard encoded > 0 else { throw VocalSeparationError.archiveCorrupt("测试用 deflate 失败") }
        return Array(output[0..<encoded])
    }

}
