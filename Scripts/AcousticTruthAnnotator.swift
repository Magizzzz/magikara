import Foundation
import SwiftUI
import AVFoundation
import CryptoKit
import Combine
import AppKit
import UniformTypeIdentifiers

// AcousticTruthAnnotator —— 离线「声学真值」盲标器（audio-only blind listen）。
//
// 目的：让真人只听声音，为每一行歌词标出真实的 acousticOnset / acousticOffset，
// 产出可作为校准基准的 human-acoustic-truth JSON。
//
// 硬性约束（务必保持）：
//   1. 音频-only：界面只有播放/时间码/歌词行，**绝不创建 AVPlayerLayer / VideoPlayer**，
//      因此不会渲染任何视频画面；AVPlayer 仅用于本地音频播放。
//   2. 盲标：不读取任何模型生成的对轨时间，不调用 OCR，不调用任何模型，不访问网络。
//   3. 不自动填充：没有任何人工输入的行，acousticOnset / acousticOffset 一律写 null。
//      工具不做插值、不做推荐、不显示任何自动对轨结果。
//   4. 可复现：对完整媒体文件计算 SHA-256，作为版本指纹（不是视觉分析）。
//   5. 安全落盘：先写同目录临时文件，再原子替换目标文件；保存前重新校验媒体 / 歌词 / 作者。
//
// 用法（GUI）：
//   AcousticTruthAnnotator [--media <媒体>] [--lyrics <lyrics.txt>] [--out <out.json>] [--annotator <名字>]
//   也可以不带参数启动，在界面里填写。
//
// 诊断用法（仅供构建验证，不是产品路径；不进行任何人声听音，写出全 null 行）：
//   AcousticTruthAnnotator --selftest --media <媒体> --lyrics <lyrics.txt> --out <out.json> --annotator <名字>

// MARK: - 命令行参数

struct CLIOptions {
    var media: String?
    var lyrics: String?
    var out: String?
    var annotator: String?
    var selfTest = false

    static func parse(_ args: [String]) -> CLIOptions {
        var options = CLIOptions()
        var positional: [String] = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--media":
                if index + 1 < args.count { options.media = args[index + 1]; index += 1 }
            case "--lyrics":
                if index + 1 < args.count { options.lyrics = args[index + 1]; index += 1 }
            case "--out":
                if index + 1 < args.count { options.out = args[index + 1]; index += 1 }
            case "--annotator":
                if index + 1 < args.count { options.annotator = args[index + 1]; index += 1 }
            case "--selftest":
                options.selfTest = true
            default:
                positional.append(arg)
            }
            index += 1
        }
        if positional.count >= 1, options.media == nil { options.media = positional[0] }
        if positional.count >= 2, options.lyrics == nil { options.lyrics = positional[1] }
        if positional.count >= 3, options.out == nil { options.out = positional[2] }
        if positional.count >= 4, options.annotator == nil { options.annotator = positional[3] }
        return options
    }
}

// MARK: - 错误

enum AnnotatorError: LocalizedError {
    case missingInput(String)
    case fileNotFound(String)
    case notAFile(String)
    case unreadable(String)
    case noAudioTrack(String)
    case unknownDuration(String)
    case mediaChanged(String)
    case lyricsChanged
    case outputDirectoryMissing(String)
    case writeFailed(String, String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInput(let what):
            return "缺少必填项：\(what)。"
        case .fileNotFound(let path):
            return "文件不存在：\(path)"
        case .notAFile(let path):
            return "路径不是文件：\(path)"
        case .unreadable(let path):
            return "无法读取或解析文件：\(path)"
        case .noAudioTrack(let name):
            return "所选媒体不包含音频轨道：\(name)。\n盲标需要可播放的音频；纯视频或损坏的文件无法用于本工具。请改用带音轨的媒体。"
        case .unknownDuration(let name):
            return "无法读取媒体时长（音频轨可能损坏）：\(name)"
        case .mediaChanged(let name):
            return "媒体文件在载入后被改动或替换：\(name)。\n为保证真值与媒体版本一一对应，请重新载入后再保存。"
        case .lyricsChanged:
            return "歌词文件在载入后被改动。请重新载入后再保存，避免标记行与文本错位。"
        case .outputDirectoryMissing(let path):
            return "输出目录不存在：\(path)。请先创建目录或改用已存在的路径。"
        case .writeFailed(let path, let reason):
            return "写入输出文件失败：\(path)\n\(reason)"
        case .encodingFailed(let reason):
            return "生成 JSON 失败：\(reason)"
        }
    }
}

// MARK: - 数据模型

struct MediaInfo: Codable, Equatable {
    var filename: String
    var path: String
    var bytes: Int64
    var durationSec: Double
    var sha256: String
}

/// 内存里的歌词行。acousticOnset / acousticOffset 仅来自人工标记，未标记为 nil。
struct TruthLine: Identifiable, Equatable {
    let order: Int
    let text: String
    var acousticOnset: Double?
    var acousticOffset: Double?
    var notes: String
    var id: Int { order }
}

/// 输出记录。用显式 encode 保证未标记时间为 JSON null，而不是被省略。
struct TruthLineRecord: Encodable {
    let order: Int
    let text: String
    let acousticOnset: Double?
    let acousticOffset: Double?
    let notes: String

    enum CodingKeys: String, CodingKey {
        case order, text, acousticOnset, acousticOffset, notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(text, forKey: .text)
        try container.encode(acousticOnset, forKey: .acousticOnset)
        try container.encode(acousticOffset, forKey: .acousticOffset)
        try container.encode(notes, forKey: .notes)
    }
}

/// 最终写出的 human-acoustic-truth 文档。
struct TruthDocument: Encodable {
    let kind: String
    let schemaVersion: Int
    let annotator: String
    let annotatedAt: String
    let method: String
    let blindToModelOutput: Bool
    let media: MediaInfo
    let lines: [TruthLineRecord]
}

struct SaveRequest {
    var mediaPath: String
    var lyricsPath: String
    var outPath: String
    var annotator: String
    var lines: [TruthLine]
    var expectedMedia: MediaInfo?
    var expectedLyrics: [String]?
}

// MARK: - 时间格式

func formatTimecode(_ seconds: Double) -> String {
    let value = max(0, seconds)
    let totalMillis = Int((value * 1000).rounded())
    let minutes = totalMillis / 60_000
    let secs = (totalMillis % 60_000) / 1000
    let millis = totalMillis % 1000
    return String(format: "%02d:%02d.%03d", minutes, secs, millis)
}

func roundMillis(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
}

func deltaLabel(_ delta: Double) -> String {
    delta < 0 ? String(format: "%.2f", delta) : String(format: "+%.2f", delta)
}

extension ISO8601DateFormatter {
    static func truthTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - 真值 I/O 与校验（GUI 与诊断模式共用，保证行为一致）

enum TruthIO {
    static let documentKind = "human-acoustic-truth"
    static let schemaVersion = 1
    static let method = "audio-only-blind-listen"

    /// 纯文本歌词解析：逐行 trim，丢弃空行，保持原始顺序；不解析任何时间戳/LRC。
    /// 该文件是人工提供的文本，不是模型输出。
    static func parseLyrics(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            line = line.replacingOccurrences(of: "\u{FEFF}", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            result.append(line)
        }
        return result
    }

    static func readLyrics(_ path: String) throws -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnnotatorError.missingInput("歌词文件路径") }
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AnnotatorError.fileNotFound(trimmed)
        }
        if isDirectory.boolValue { throw AnnotatorError.notAFile(trimmed) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnnotatorError.unreadable(trimmed)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .shiftJIS) else {
            throw AnnotatorError.unreadable(trimmed)
        }
        let lines = parseLyrics(text)
        guard !lines.isEmpty else { throw AnnotatorError.missingInput("歌词内容（文件为空或不含有效行）") }
        return lines
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw AnnotatorError.unreadable(url.path)
        }
        guard let number = attributes[.size] as? NSNumber else {
            throw AnnotatorError.unreadable(url.path)
        }
        return number.int64Value
    }

    /// 对完整媒体文件流式计算 SHA-256（作为版本指纹，不做任何视觉分析）。
    static func sha256File(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AnnotatorError.unreadable(url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw AnnotatorError.unreadable(url.path)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 媒体校验 + 指纹：确认存在、是文件、含音频轨、时长有效，并计算 bytes / durationSec / sha256。
    static func probeMedia(_ path: String) async throws -> MediaInfo {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnnotatorError.missingInput("媒体文件路径") }
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AnnotatorError.fileNotFound(trimmed)
        }
        if isDirectory.boolValue { throw AnnotatorError.notAFile(trimmed) }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AnnotatorError.unreadable(trimmed)
        }
        guard !audioTracks.isEmpty else { throw AnnotatorError.noAudioTrack(url.lastPathComponent) }

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw AnnotatorError.unreadable(trimmed)
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw AnnotatorError.unknownDuration(url.lastPathComponent)
        }

        let bytes = try fileSize(url)
        let hash = try await Task.detached(priority: .userInitiated) {
            try TruthIO.sha256File(url)
        }.value

        return MediaInfo(filename: url.lastPathComponent,
                         path: url.standardizedFileURL.path,
                         bytes: bytes,
                         durationSec: seconds,
                         sha256: hash)
    }

    static func makeDocument(annotator: String, media: MediaInfo, lines: [TruthLine]) throws -> TruthDocument {
        let author = annotator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw AnnotatorError.missingInput("标注者（annotator）") }
        let records = lines.map {
            TruthLineRecord(order: $0.order,
                            text: $0.text,
                            acousticOnset: $0.acousticOnset,
                            acousticOffset: $0.acousticOffset,
                            notes: $0.notes)
        }
        return TruthDocument(kind: documentKind,
                             schemaVersion: schemaVersion,
                             annotator: author,
                             annotatedAt: ISO8601DateFormatter.truthTimestamp(),
                             method: method,
                             blindToModelOutput: true,
                             media: media,
                             lines: records)
    }

    /// 先写同目录临时文件，再原子替换目标。目标已存在用 replaceItemAt，不存在用 moveItem。
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AnnotatorError.outputDirectoryMissing(directory.path)
        }
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw AnnotatorError.writeFailed(url.path, error.localizedDescription)
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw AnnotatorError.writeFailed(url.path, error.localizedDescription)
        }
    }

    /// 保存前完整校验：作者必填、媒体必须仍是同一版本且含音频轨、歌词逐行一致、行序一致。
    /// 然后构造文档并原子落盘。
    @discardableResult
    static func performSave(_ request: SaveRequest) async throws -> MediaInfo {
        let author = request.annotator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw AnnotatorError.missingInput("标注者（annotator）") }

        let outPath = request.outPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outPath.isEmpty else { throw AnnotatorError.missingInput("输出 JSON 路径") }

        // 媒体：重新探测（会再次检查音频轨），并与载入时指纹比对。
        let media = try await probeMedia(request.mediaPath)
        if let expected = request.expectedMedia {
            if media.path != expected.path
                || media.bytes != expected.bytes
                || media.sha256 != expected.sha256 {
                throw AnnotatorError.mediaChanged(media.filename)
            }
        }

        // 歌词：重新解析并与载入时文本逐行比对。
        let lyrics = try readLyrics(request.lyricsPath)
        if let expected = request.expectedLyrics, expected != lyrics {
            throw AnnotatorError.lyricsChanged
        }
        guard request.lines.count == lyrics.count else { throw AnnotatorError.lyricsChanged }
        for (index, line) in request.lines.enumerated() {
            if line.order != index + 1 || line.text != lyrics[index] {
                throw AnnotatorError.lyricsChanged
            }
        }

        let document = try makeDocument(annotator: author, media: media, lines: request.lines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw AnnotatorError.encodingFailed(error.localizedDescription)
        }
        try atomicWrite(data, to: URL(fileURLWithPath: outPath))
        return media
    }
}

// MARK: - 构建验证用诊断模式（不参与产品盲标流程）

enum SelfTest {
    private final class ResultBox: @unchecked Sendable {
        var code: Int32 = 1
    }

    /// 该模式只用于验证「媒体/歌词/作者校验 + 全 null 行 + 原子写盘」是否正常，
    /// 不做任何听音，也不代表真值。通过 exit 直接结束进程，不启动界面。
    static func run(_ options: CLIOptions) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            box.code = await runAsync(options)
            semaphore.signal()
        }
        semaphore.wait()
        exit(box.code)
    }

    private static func runAsync(_ options: CLIOptions) async -> Int32 {
        do {
            guard let media = options.media, !media.isEmpty else {
                throw AnnotatorError.missingInput("媒体文件路径")
            }
            guard let lyrics = options.lyrics, !lyrics.isEmpty else {
                throw AnnotatorError.missingInput("歌词文件路径")
            }
            guard let out = options.out, !out.isEmpty else {
                throw AnnotatorError.missingInput("输出 JSON 路径")
            }
            let author = (options.annotator ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !author.isEmpty else { throw AnnotatorError.missingInput("标注者（annotator）") }

            let info = try await TruthIO.probeMedia(media)
            let parsed = try TruthIO.readLyrics(lyrics)
            // 诊断模式：不进行任何人工标记，全部保持 null。
            let lines = parsed.enumerated().map {
                TruthLine(order: $0.offset + 1, text: $0.element, acousticOnset: nil, acousticOffset: nil, notes: "")
            }
            _ = try await TruthIO.performSave(SaveRequest(mediaPath: media,
                                                          lyricsPath: lyrics,
                                                          outPath: out,
                                                          annotator: author,
                                                          lines: lines,
                                                          expectedMedia: info,
                                                          expectedLyrics: parsed))
            let message = "selftest: OK 媒体=\(info.filename) bytes=\(info.bytes) duration=\(String(format: "%.3f", info.durationSec)) sha256=\(info.sha256) 行数=\(lines.count)\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            return 0
        } catch {
            let message = "selftest: FAILED: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        }
    }
}

// MARK: - 视图模型

@MainActor
final class AnnotatorModel: ObservableObject {
    @Published var mediaPath: String
    @Published var lyricsPath: String
    @Published var outPath: String
    @Published var annotator: String

    @Published private(set) var lines: [TruthLine] = []
    @Published var selectedLineID: Int?
    @Published private(set) var isLoaded = false
    @Published private(set) var mediaInfo: MediaInfo?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBusy = false
    @Published var statusMessage = "填写媒体、歌词与输出路径后，点击「载入」。"
    @Published var errorMessage: String?
    @Published var scrubTarget: Double = 0

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedLyrics: [String] = []
    private var scrubbing = false

    init(options: CLIOptions) {
        mediaPath = options.media ?? ""
        lyricsPath = options.lyrics ?? ""
        outPath = options.out ?? ""
        annotator = options.annotator ?? ""
        player.actionAtItemEnd = .pause
    }

    var selectedIndex: Int? {
        guard let id = selectedLineID,
              let index = lines.firstIndex(where: { $0.order == id }) else { return nil }
        return index
    }

    var selectedLine: TruthLine? {
        selectedIndex.map { lines[$0] }
    }

    // MARK: 载入

    /// 命令行预填了媒体与歌词时自动载入一次，方便 `--run` 直接进入标注。
    func autoLoadIfConfigured() {
        guard !isLoaded, !isBusy else { return }
        let media = mediaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let lyrics = lyricsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !media.isEmpty, !lyrics.isEmpty else { return }
        load()
    }

    func load() {
        errorMessage = nil
        let media = mediaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let lyrics = lyricsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !media.isEmpty else { present(AnnotatorError.missingInput("媒体文件路径")); return }
        guard !lyrics.isEmpty else { present(AnnotatorError.missingInput("歌词文件路径")); return }

        isBusy = true
        statusMessage = "正在校验媒体、读取歌词并计算 SHA-256…"
        Task {
            do {
                let parsed = try TruthIO.readLyrics(lyrics)
                let info = try await TruthIO.probeMedia(media)

                player.pause()
                player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: info.path)))
                stopObserving()

                durationSeconds = info.durationSec
                currentTime = 0
                scrubTarget = 0
                isPlaying = false
                mediaInfo = info
                loadedLyrics = parsed
                // 所有行初始都无人工标记，保持 null。
                lines = parsed.enumerated().map {
                    TruthLine(order: $0.offset + 1, text: $0.element, acousticOnset: nil, acousticOffset: nil, notes: "")
                }
                selectedLineID = lines.first?.order
                isLoaded = true
                installTimeObserver()
                statusMessage = "已载入 \(info.filename)：\(String(format: "%.2f", info.durationSec)) 秒 / \(parsed.count) 行。SHA-256 \(info.sha256.prefix(12))…（音频-only，未渲染画面）"
            } catch {
                isLoaded = false
                mediaInfo = nil
                loadedLyrics = []
                player.replaceCurrentItem(with: nil)
                stopObserving()
                present(error)
            }
            isBusy = false
        }
    }

    // MARK: 播放控制

    func togglePlay() {
        guard isLoaded else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if durationSeconds > 0, currentTime >= durationSeconds - 0.05 {
                seek(to: 0, precise: true)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double, precise: Bool) {
        guard isLoaded else { return }
        let upper = max(0, durationSeconds)
        let clamped = min(max(0, seconds), upper)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
        currentTime = clamped
        scrubTarget = clamped
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta, precise: true)
    }

    func setScrubbing(_ value: Bool) {
        scrubbing = value
        if !value { scrubTarget = currentTime }
    }

    func seekToScrubTarget() {
        seek(to: scrubTarget, precise: false)
    }

    // MARK: 行选择

    func select(order: Int) {
        selectedLineID = order
        statusMessage = "已选择第 \(order) 行。"
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < lines.count else { return }
        select(order: lines[index + 1].order)
    }

    func selectPrevious() {
        guard let index = selectedIndex, index - 1 >= 0 else { return }
        select(order: lines[index - 1].order)
    }

    // MARK: 人工标记与微调

    func markOnset() {
        guard let index = selectedIndex else { return }
        lines[index].acousticOnset = roundMillis(currentTime)
        statusMessage = "第 \(lines[index].order) 行：acousticOnset = \(formatTimecode(currentTime))"
    }

    func markOffset() {
        guard let index = selectedIndex else { return }
        lines[index].acousticOffset = roundMillis(currentTime)
        statusMessage = "第 \(lines[index].order) 行：acousticOffset = \(formatTimecode(currentTime))"
    }

    func clearOnset() {
        guard let index = selectedIndex else { return }
        lines[index].acousticOnset = nil
        statusMessage = "第 \(lines[index].order) 行：已清除 acousticOnset（保存为 null）。"
    }

    func clearOffset() {
        guard let index = selectedIndex else { return }
        lines[index].acousticOffset = nil
        statusMessage = "第 \(lines[index].order) 行：已清除 acousticOffset（保存为 null）。"
    }

    func setOnset(_ value: Double?) {
        guard let index = selectedIndex else { return }
        lines[index].acousticOnset = value.map(clampTime)
    }

    func setOffset(_ value: Double?) {
        guard let index = selectedIndex else { return }
        lines[index].acousticOffset = value.map(clampTime)
    }

    func setNotes(_ value: String) {
        guard let index = selectedIndex else { return }
        lines[index].notes = value
    }

    func nudgeOnset(by delta: Double) {
        guard let index = selectedIndex, let base = lines[index].acousticOnset else { return }
        lines[index].acousticOnset = clampTime(base + delta)
    }

    func nudgeOffset(by delta: Double) {
        guard let index = selectedIndex, let base = lines[index].acousticOffset else { return }
        lines[index].acousticOffset = clampTime(base + delta)
    }

    func seekToOnset() {
        guard let line = selectedLine, let onset = line.acousticOnset else { return }
        seek(to: onset, precise: true)
    }

    func seekToOffset() {
        guard let line = selectedLine, let offset = line.acousticOffset else { return }
        seek(to: offset, precise: true)
    }

    private func clampTime(_ value: Double) -> Double {
        let upper = durationSeconds > 0 ? durationSeconds : value
        return roundMillis(min(max(0, value), upper))
    }

    // MARK: 保存

    func save() {
        errorMessage = nil
        let out = outPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { present(AnnotatorError.missingInput("输出 JSON 路径")); return }
        guard isLoaded, let info = mediaInfo else {
            present(AnnotatorError.missingInput("已载入的媒体与歌词（请先点击「载入」）"))
            return
        }
        let author = annotator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { present(AnnotatorError.missingInput("标注者（annotator）")); return }

        isBusy = true
        statusMessage = "正在重新校验媒体 / 歌词 / 作者并原子写入…"
        let request = SaveRequest(mediaPath: mediaPath,
                                  lyricsPath: lyricsPath,
                                  outPath: out,
                                  annotator: author,
                                  lines: lines,
                                  expectedMedia: info,
                                  expectedLyrics: loadedLyrics)
        Task {
            do {
                let media = try await TruthIO.performSave(request)
                let marked = lines.filter { $0.acousticOnset != nil || $0.acousticOffset != nil }.count
                statusMessage = "已保存 \(lines.count) 行（其中 \(marked) 行有人工标记），媒体 SHA-256 \(media.sha256.prefix(12))… → \(out)"
            } catch {
                present(error)
            }
            isBusy = false
        }
    }

    // MARK: 时间观察

    private func installTimeObserver() {
        stopObserving()
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                    if !self.scrubbing { self.scrubTarget = self.currentTime }
                }
                self.isPlaying = (self.player.timeControlStatus == .playing)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: player.currentItem,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
    }

    private func stopObserving() {
        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }
        if let token = endObserver {
            NotificationCenter.default.removeObserver(token)
            endObserver = nil
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "操作失败，请查看错误提示。"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AcousticTruthAnnotatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AnnotatorModel

    init() {
        let options = CLIOptions.parse(CommandLine.arguments)
        if options.selfTest {
            SelfTest.run(options) // 直接 exit，不进入界面
        }
        _model = StateObject(wrappedValue: AnnotatorModel(options: options))
    }

    var body: some Scene {
        WindowGroup("离线声学真值盲标器") {
            ContentView(model: model)
                .onAppear { model.autoLoadIfConfigured() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var model: AnnotatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            inputSection
            Divider()
            if model.isLoaded {
                playerSection
                Divider()
                HStack(alignment: .top, spacing: 14) {
                    lyricListSection
                    lineEditorSection
                }
                .frame(maxHeight: .infinity)
            } else {
                emptyState
                Spacer(minLength: 0)
            }
            Divider()
            statusBar
        }
        .padding(16)
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 680, idealHeight: 820)
        .alert("出错了", isPresented: alertBinding) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("离线声学真值盲标器").font(.title2).bold()
            Text("音频-only 盲听：只播放声音，不渲染任何视频画面；不读取模型对轨结果，不显示自动推荐。所有 acousticOnset / acousticOffset 均来自人工听音标记。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow(title: "媒体", text: $model.mediaPath,
                    placeholder: "音频或含音频的媒体文件路径（必填）",
                    pick: pickMedia)
            pathRow(title: "歌词", text: $model.lyricsPath,
                    placeholder: "lyrics.txt 纯文本，每行一句（必填）",
                    pick: pickLyrics)
            pathRow(title: "输出", text: $model.outPath,
                    placeholder: "输出 human-acoustic-truth JSON 路径（必填）",
                    pick: pickOutput)
            HStack(spacing: 8) {
                Text("标注者").frame(width: 52, alignment: .leading)
                TextField("必填：姓名 / 代号", text: $model.annotator)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button(model.isLoaded ? "重新载入" : "载入") { model.load() }
                    .disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text("禁止网络与模型调用 · 不显示视频画面 · 不显示自动对轨结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathRow(title: String,
                         text: Binding<String>,
                         placeholder: String,
                         pick: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            Button("选择…", action: pick)
        }
    }

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.togglePlay()
                } label: {
                    Label(model.isPlaying ? "暂停" : "播放",
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                Divider().frame(height: 18)
                Button("−1s") { model.skip(by: -1) }
                Button("−0.1s") { model.skip(by: -0.1) }
                Button("+0.1s") { model.skip(by: 0.1) }
                Button("+1s") { model.skip(by: 1) }
                Divider().frame(height: 18)
                Button("上一行") { model.selectPrevious() }
                Button("下一行") { model.selectNext() }
                Spacer()
                Text("\(formatTimecode(model.currentTime)) / \(formatTimecode(model.durationSeconds))")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Slider(value: $model.scrubTarget,
                   in: 0...max(model.durationSeconds, 0.001),
                   onEditingChanged: { editing in
                       model.setScrubbing(editing)
                       if !editing { model.seekToScrubTarget() }
                   })
        }
    }

    private var lyricListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("歌词行（\(model.lines.count)）").font(.headline)
            List {
                ForEach(model.lines) { line in
                    lyricRow(line)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(order: line.order) }
                        .listRowBackground(model.selectedLineID == line.order
                                           ? Color.accentColor.opacity(0.18)
                                           : Color.clear)
                }
            }
            .border(Color.secondary.opacity(0.25))
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func lyricRow(_ line: TruthLine) -> some View {
        HStack(spacing: 8) {
            Text("\(line.order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if line.acousticOnset != nil || line.acousticOffset != nil {
                Text(markSummary(line))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func markSummary(_ line: TruthLine) -> String {
        let onset = line.acousticOnset.map(formatTimecode) ?? "—"
        let offset = line.acousticOffset.map(formatTimecode) ?? "—"
        return "\(onset)→\(offset)"
    }

    private var lineEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前行标记").font(.headline)
            if let line = model.selectedLine {
                Text(line.text)
                    .font(.title3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("标记起点 @ 当前时间") { model.markOnset() }
                    Button("标记终点 @ 当前时间") { model.markOffset() }
                }
                HStack(spacing: 8) {
                    Button("清除起点") { model.clearOnset() }.disabled(line.acousticOnset == nil)
                    Button("清除终点") { model.clearOffset() }.disabled(line.acousticOffset == nil)
                    Spacer()
                    Button("跳到起点") { model.seekToOnset() }.disabled(line.acousticOnset == nil)
                    Button("跳到终点") { model.seekToOffset() }.disabled(line.acousticOffset == nil)
                }

                TimeField(label: "起点", value: onsetBinding)
                nudgeRow(label: "微调起点", enabled: line.acousticOnset != nil) { model.nudgeOnset(by: $0) }

                TimeField(label: "终点", value: offsetBinding)
                nudgeRow(label: "微调终点", enabled: line.acousticOffset != nil) { model.nudgeOffset(by: $0) }

                VStack(alignment: .leading, spacing: 4) {
                    Text("备注").font(.caption).foregroundStyle(.secondary)
                    TextField("可选备注", text: notesBinding).textFieldStyle(.roundedBorder)
                }

                Text("未人工标记的行保存为 null；工具不做自动填充、不插值、不显示任何对轨推荐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("保存 JSON") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.isBusy || model.annotator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.annotator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("请先填写标注者").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            } else {
                Text("请选择一行歌词。").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nudgeRow(label: String, enabled: Bool, action: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            ForEach([-1.0, -0.1, -0.01, 0.01, 0.1, 1.0], id: \.self) { delta in
                Button(deltaLabel(delta)) { action(delta) }
                    .disabled(!enabled)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("尚未载入").font(.headline)
            Text("填写媒体、歌词与输出路径，并填写标注者后点击「载入」。载入后界面只提供音频播放、时间码和歌词行，不会出现任何视频画面或自动对轨结果。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var statusBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: 绑定与文件选择

    private var onsetBinding: Binding<Double?> {
        Binding(get: { model.selectedLine?.acousticOnset },
                set: { model.setOnset($0) })
    }

    private var offsetBinding: Binding<Double?> {
        Binding(get: { model.selectedLine?.acousticOffset },
                set: { model.setOffset($0) })
    }

    private var notesBinding: Binding<String> {
        Binding(get: { model.selectedLine?.notes ?? "" },
                set: { model.setNotes($0) })
    }

    private func pickMedia() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择音频或含音频的媒体文件（仅播放声音并计算 SHA-256，不渲染任何画面）"
        if panel.runModal() == .OK, let url = panel.url {
            model.mediaPath = url.path
        }
    }

    private func pickLyrics() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = "选择纯文本歌词文件（每行一句）"
        if panel.runModal() == .OK, let url = panel.url {
            model.lyricsPath = url.path
        }
    }

    private func pickOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "acoustic-truth.json"
        panel.allowedContentTypes = [.json]
        panel.message = "选择 human-acoustic-truth JSON 的输出位置"
        if panel.runModal() == .OK, let url = panel.url {
            model.outPath = url.path
        }
    }
}

// MARK: - 可编辑时间字段

struct TimeField: View {
    let label: String
    @Binding var value: Double?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 64, alignment: .leading)
            TextField("未标记（null）", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, newValue in if !focused { text = Self.format(newValue) } }
            Text(value == nil ? "未标记" : formatTimecode(value!))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
            return
        }
        if let parsed = Double(trimmed) {
            value = roundMillis(max(0, parsed))
        } else {
            text = Self.format(value)
        }
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.3f", value)
    }
}
