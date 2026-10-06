import Foundation
import AVFoundation
import Vision
import AppKit
import CoreGraphics

// lyric-ocr —— 从视频画面里 OCR 出日文歌词行。
//
// 用途：当素材是「画面里已经烧录了歌词」的成片时（例如ニコカラ、带硬字幕的 MV），
// 把真实出现的日文歌词提取出来，作为对轨实验的输入文本。
// 这是**识别**，不是编造；所有中间结果都会落盘，便于人工核对。
//
// 关键做法（都是实测调出来的）：
//   1. 只裁画面底部 28% 再 OCR。直接对全帧识别会把开头的假名漏掉
//      （实测「ありがとう…」被识别成「りがとう…」，置信度仅 0.50）；
//      裁剪后同帧置信度 1.00。
//   2. 识别语言同时给 ja-JP 与 zh-Hans，然后用「是否含假名」筛掉中文行。
//      本素材是中英日混排：中文行全汉字，日文行必含平假名/片假名。
//   3. 只在底部候选里取**最下面**的一行 —— 该素材日文行位于中文行下方。
//   4. 顶部的 UP 主水印（y≈0.9）天然被底部候选排除。
//
// 用法: lyric-ocr <视频路径> <输出json> [每秒采样帧数，默认2] [--full-frame]

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: lyric-ocr <视频路径> <输出json> [fps]")
    exit(1)
}
let videoPath = args[1]
let outPath = args[2]
let options = Array(args.dropFirst(3))
let fps = options.compactMap(Double.init).first ?? 2.0
let fullFrame = options.contains("--full-frame")

let url = URL(fileURLWithPath: videoPath)
guard FileManager.default.fileExists(atPath: url.path) else {
    print("视频不存在: \(videoPath)")
    exit(1)
}

let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
var duration: Double = 0
Task {
    duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
    sem.signal()
}
sem.wait()
guard duration > 0 else {
    print("无法读取时长")
    exit(1)
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

/// 是否含假名（平假名/片假名）。用来把日文行与中文行区分开。
func containsKana(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        if (0x3041...0x309F).contains(scalar.value) { return true }   // 平假名
        if (0x30A1...0x30FA).contains(scalar.value) { return true }   // 片假名
        if scalar.value == 0x30FC { return true }                     // 长音符
    }
    return false
}

struct Sample: Codable {
    var t: Double
    var text: String
    var confidence: Double
    var allLines: [String]
}

var samples: [Sample] = []
let step = 1.0 / fps
var t = 0.0
var processed = 0
var failed = 0

// 复用同一个 request，避免每帧重建
let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["ja-JP", "zh-Hans"]
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.minimumTextHeight = 0.01

while t < duration {
    defer { t += step }
    guard let cg = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600),
                                              actualTime: nil) else {
        failed += 1
        continue
    }
    // 默认裁底部 28%；可选全画面模式，适配歌词排在上半部/画面中央的 MV。
    let band: CGImage
    if fullFrame {
        band = cg
    } else {
        let cropY = Int(Double(cg.height) * 0.72)
        guard let crop = cg.cropping(to: CGRect(x: 0, y: cropY,
                                                width: cg.width, height: cg.height - cropY)) else {
            failed += 1
            continue
        }
        band = crop
    }
    let handler = VNImageRequestHandler(cgImage: band, options: [:])
    guard (try? handler.perform([request])) != nil else {
        failed += 1
        continue
    }
    processed += 1

    var candidates: [(text: String, conf: Double, y: Double)] = []
    for obs in (request.results ?? []) {
        guard let top = obs.topCandidates(1).first else { continue }
        let y = obs.boundingBox.origin.y
        // 默认只保留裁剪带底部候选；全画面模式保留各位置，再靠歌词相似度筛选。
        guard fullFrame || y < 0.35 else { continue }
        candidates.append((top.string, Double(top.confidence), y))
    }

    // 优先含假名的行（日文），否则取最下面一行
    let kanaLines = candidates.filter { containsKana($0.text) }
    let chosen = (kanaLines.isEmpty ? candidates : kanaLines)
        .min { $0.y < $1.y }

    samples.append(Sample(t: (t * 100).rounded() / 100,
                          text: chosen?.text ?? "",
                          confidence: chosen?.conf ?? 0,
                          allLines: candidates.sorted { $0.y < $1.y }.map(\.text)))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let payload: [String: Any] = [:]
_ = payload

struct Output: Codable {
    var video: String
    var duration: Double
    var fps: Double
    var framesProcessed: Int
    var framesFailed: Int
    var note: String
    var samples: [Sample]
}

let output = Output(video: url.lastPathComponent,
                    duration: duration,
                    fps: fps,
                    framesProcessed: processed,
                    framesFailed: failed,
    note: fullFrame
        ? "Vision OCR（ja-JP + zh-Hans），全画面搜索，只取含假名的日文行。空字符串表示该帧没有字幕。"
        : "Vision OCR（ja-JP + zh-Hans），裁底部 28%，只取含假名的日文行。空字符串表示该帧没有字幕。",
                    samples: samples)

do {
    try encoder.encode(output).write(to: URL(fileURLWithPath: outPath))
} catch {
    print("写文件失败: \(error.localizedDescription)")
    exit(1)
}

let nonEmpty = samples.filter { !$0.text.isEmpty }
let avgConf = nonEmpty.isEmpty ? 0 : nonEmpty.map(\.confidence).reduce(0, +) / Double(nonEmpty.count)
print("视频时长: \(String(format: "%.1f", duration)) 秒")
print("采样帧数: \(processed)（失败 \(failed)）")
print("有日文歌词的帧: \(nonEmpty.count) / \(processed)")
print(String(format: "平均置信度: %.3f", avgConf))
print("输出: \(outPath)")
