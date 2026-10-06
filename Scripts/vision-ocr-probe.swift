import Foundation
import AVFoundation
import Vision
import CoreImage

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: vision-ocr-probe <video>\n", stderr)
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVAsset(url: url)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let duration = try await asset.load(.duration)
let total = max(1, Int(CMTimeGetSeconds(duration) * 2.0))
let ciContext = CIContext()
for i in 0..<total {
    let seconds = Double(i) * 0.5
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLanguages = ["ja-JP", "zh-Hans"]
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let h = CGFloat(cgImage.height)
    let crop = cgImage.cropping(to: CGRect(x: 0, y: h * 0.55,
                                           width: CGFloat(cgImage.width),
                                           height: h * 0.45)) ?? cgImage
    let handler = VNImageRequestHandler(cgImage: crop, options: [:])
    try? handler.perform([request])
    let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let japanese = texts.filter { text in
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30ff).contains(Int(scalar.value))
        }
    }
    if !japanese.isEmpty {
        for text in japanese {
            print(String(format: "%.1f\t%@", seconds, text))
        }
    }
}
