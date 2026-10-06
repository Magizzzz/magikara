import Foundation

// MARK: - Float32 立体声 WAV 写出
//
// 手写 RIFF/WAVE 头而不走 AVAudioFile：输出必须与输入严格等长、采样率保真，
// 并且 header 可以在不碰 Core ML 的单元测试里逐字段核对。
//
// 只写 IEEE float（audioFormat = 3）32-bit，交错 L/R。

enum VocalWAVWriter {

    static let bitsPerSample = 32
    static let audioFormatIEEEFFloat: UInt16 = 3

    /// 构造 44 字节标准 WAV 头（不含采样数据）。
    static func header(channelCount: Int, sampleRate: Double, frameCount: Int) -> Data {
        let bits = bitsPerSample
        let blockAlign = channelCount * bits / 8
        let rate = Int(sampleRate.rounded())
        let byteRate = rate * blockAlign
        let dataSize = max(0, frameCount) * blockAlign

        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))                 // PCM fmt chunk size
        data.appendLittleEndian(audioFormatIEEEFFloat)      // 3 = IEEE float
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(rate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bits))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))
        return data
    }

    /// 交错写出 `channels`（必须恰好 2 条等长声道）。失败时删除本次半成品文件。
    static func write(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard channels.count == 2 else {
            throw VocalSeparationError.writeFailed("需要 2 条声道，实际 \(channels.count)")
        }
        let frameCount = channels[0].count
        guard channels[1].count == frameCount else {
            throw VocalSeparationError.writeFailed("左右声道长度不一致")
        }
        guard sampleRate > 0 else {
            throw VocalSeparationError.writeFailed("采样率必须为正")
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw VocalSeparationError.invalidOutputPath("拒绝覆盖已有文件：\(url.path)")
        }
        let head = header(channelCount: 2, sampleRate: sampleRate, frameCount: frameCount)
        guard fm.createFile(atPath: url.path, contents: head) else {
            throw VocalSeparationError.writeFailed("无法创建 \(url.path)")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw VocalSeparationError.writeFailed(error.localizedDescription)
        }

        do {
            _ = try handle.seekToEnd()
            let blockFrames = 1 << 16
            var buffer = [Float](repeating: 0, count: blockFrames * 2)
            var offset = 0
            while offset < frameCount {
                let n = min(blockFrames, frameCount - offset)
                for i in 0..<n {
                    buffer[2 * i] = channels[0][offset + i]
                    buffer[2 * i + 1] = channels[1][offset + i]
                }
                let byteCount = n * 2 * MemoryLayout<Float>.size
                let chunk = buffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: byteCount) }
                try handle.write(contentsOf: chunk)
                offset += n
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: url)
            throw VocalSeparationError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - 输出路径安全

enum VocalSeparationPaths {

    /// 在解码/推理之前校验三个路径，避免跑到一半才发现会互相覆盖。
    static func validate(mediaURL: URL, vocalURL: URL, instrumentalURL: URL) throws {
        let fm = FileManager.default

        guard mediaURL.isFileURL else {
            throw VocalSeparationError.invalidOutputPath("媒体必须是本地文件 URL")
        }
        var mediaIsDir: ObjCBool = false
        guard fm.fileExists(atPath: mediaURL.path, isDirectory: &mediaIsDir), !mediaIsDir.boolValue else {
            throw VocalSeparationError.mediaMissing(mediaURL)
        }
        let mediaPath = mediaURL.standardizedFileURL.path

        guard vocalURL.isFileURL, instrumentalURL.isFileURL else {
            throw VocalSeparationError.invalidOutputPath("输出必须是本地文件 URL")
        }
        let vocalPath = vocalURL.standardizedFileURL.path
        let instrumentalPath = instrumentalURL.standardizedFileURL.path

        if vocalPath == instrumentalPath {
            throw VocalSeparationError.invalidOutputPath("vocal 与 instrumental 不能是同一个文件")
        }
        if vocalPath == mediaPath || instrumentalPath == mediaPath {
            throw VocalSeparationError.invalidOutputPath("输出不能覆盖输入媒体")
        }

        for url in [vocalURL, instrumentalURL] {
            var outIsDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &outIsDir) {
                let reason = outIsDir.boolValue ? "输出路径是目录" : "拒绝覆盖已有文件"
                throw VocalSeparationError.invalidOutputPath("\(reason)：\(url.path)")
            }
            let parent = url.deletingLastPathComponent()
            var parentIsDir: ObjCBool = false
            guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
                throw VocalSeparationError.outputDirectoryMissing(parent)
            }
        }
    }

    /// 同目录下的隐藏临时文件；失败清理时只动它，绝不碰用户已有输出。
    static func temporarySibling(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = ".\(url.lastPathComponent).\(UUID().uuidString).magikara-partial"
        return dir.appendingPathComponent(name)
    }

    /// 只发布到不存在的目标；移动失败时保留目标文件，不做替换或破坏性回退。
    static func publish(_ temporaryURL: URL, to finalURL: URL) throws {
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
}

// MARK: - Data little-endian 辅助

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
