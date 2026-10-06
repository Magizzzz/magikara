import CoreML
import Foundation

// MARK: - Core ML 包装
//
// 模型只做 mask/复数谱预测，STFT/ISTFT 在 Swift 侧完成。
// 契约（模型卡）：
//   input  `spectrogram` MLMultiArray<Float32> [1, 4, 4096, T]
//         4 = 2 声道 × [real, imag]，4096 = dim_f（丢弃 Nyquist），T = 时间帧
//   output `stems`       MLMultiArray<Float32> [1, 2, 4, 4096, T]
//         outer 2 = [Vocals, Instrumental]，内层与输入同布局
//
// 这里刻意不吞任何 Core ML 错误：拿不到输出、形状不符、推理抛错都向上抛，
// 绝不用静音 stem 伪装成功。
public final class VocalSeparationCoreMLModel: @unchecked Sendable {

    /// 推理设备。命令行测试可改成 `.cpuOnly`（Float32）对比半精度带来的音质差异。
    nonisolated(unsafe) public static var computeUnits: MLComputeUnits = .all

    static let specChannels = 4
    static let stemCount = 2

    let dimF: Int
    let frames: Int
    let info: VocalSeparationModelInfo

    private let model: MLModel

    init(compiledModelURL: URL, info: VocalSeparationModelInfo = .mdx23cInstVocHQ) throws {
        self.info = info
        self.dimF = info.dimF
        self.frames = info.frameCount
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VocalSeparationCoreMLModel.computeUnits
        do {
            self.model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        } catch {
            throw VocalSeparationError.modelCompileFailed(error.localizedDescription)
        }
    }

    /// `spectrogram` 为 `[4, dimF, frames]`（row-major），返回 `[2*4*dimF*frames]`。
    func predict(_ spectrogram: [Float]) throws -> [Float] {
        let inCount = Self.specChannels * dimF * frames
        guard spectrogram.count == inCount else {
            throw VocalSeparationError.modelOutputUnexpected(
                "输入频谱长度应为 \(inCount)，实际 \(spectrogram.count)")
        }

        let shape: [NSNumber] = [
            1,
            NSNumber(value: Self.specChannels),
            NSNumber(value: dimF),
            NSNumber(value: frames),
        ]
        let input: MLMultiArray
        do {
            input = try MLMultiArray(shape: shape, dataType: .float32)
        } catch {
            throw VocalSeparationError.modelPredictionFailed("无法分配输入 MLMultiArray：\(error.localizedDescription)")
        }
        let ip = input.dataPointer.assumingMemoryBound(to: Float.self)
        spectrogram.withUnsafeBufferPointer { ip.update(from: $0.baseAddress!, count: inCount) }

        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [info.inputName: input])
        } catch {
            throw VocalSeparationError.modelPredictionFailed("无法构造输入特征：\(error.localizedDescription)")
        }

        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            throw VocalSeparationError.modelPredictionFailed(error.localizedDescription)
        }

        guard let stems = result.featureValue(for: info.outputName)?.multiArrayValue else {
            let names = result.featureNames.sorted().joined(separator: ", ")
            throw VocalSeparationError.modelOutputUnexpected("输出里没有 `\(info.outputName)`（实际特征：\(names)）")
        }

        let outCount = Self.stemCount * Self.specChannels * dimF * frames
        guard stems.count == outCount else {
            throw VocalSeparationError.modelOutputUnexpected("输出元素数应为 \(outCount)，实际 \(stems.count)")
        }
        return try Self.floats(from: stems)
    }

    /// 把 MLMultiArray 拷成 `[Float]`，兼容 float16 / float32 / double 输出。
    private static func floats(from array: MLMultiArray) throws -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float16:
            let p = array.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<count).map { Float(p[$0]) }
        case .float32:
            let p = array.dataPointer.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: p, count: count))
        case .double:
            let p = array.dataPointer.assumingMemoryBound(to: Double.self)
            return (0..<count).map { Float(p[$0]) }
        default:
            throw VocalSeparationError.modelOutputUnexpected("不支持的输出数据类型 \(array.dataType.rawValue)")
        }
    }
}
