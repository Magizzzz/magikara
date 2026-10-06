import Compression
import Foundation

// MARK: - 安全解压
//
// 不调用 shell、不调用 `unzip`、也不依赖任何第三方库：直接解析 ZIP 的
// End-Of-Central-Directory / 中央目录 / 本地文件头。规则：
//   * 只接受存储在预期顶层 `.mlpackage` 目录之下的条目；
//   * 拒绝绝对路径、`..`/`.` 段、反斜杠、NUL、符号链接；
//   * 只支持 stored(0) 与 deflate(8)，其它方法直接报错；
//   * 支持条目数量少、单文件最大 ~112 MB 的模型包，拒绝 Zip64。
//
// 这样即使压缩包被替换/投毒，也不会写到目标目录之外，更不会「展开」出意外文件。

enum VocalSeparationArchive {

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let externalAttributes: UInt32

        var isDirectory: Bool { name.hasSuffix("/") }

        /// ZIP 的外部属性高 16 位是 Unix mode；0xA000 表示符号链接。
        var isSymlink: Bool { (externalAttributes >> 16) & 0xF000 == 0xA000 }
    }

    // MARK: 入口

    /// 解压 `zipURL` 到 `destination`，返回其中预期的 `.mlpackage` 目录 URL。
    static func extractPackage(zipURL: URL, into destination: URL, expectedTopLevel: String) throws -> URL {
        let raw: Data
        do {
            raw = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        } catch {
            throw VocalSeparationError.archiveCorrupt(error.localizedDescription)
        }
        let zip = [UInt8](raw)
        let entries = try centralDirectory(in: zip)
        guard !entries.isEmpty else { throw VocalSeparationError.archiveCorrupt("压缩包为空") }

        // 先整体校验路径，再落盘，避免解压到一半才发现恶意条目。
        for entry in entries {
            guard let safe = safeEntryPath(entry.name) else {
                throw VocalSeparationError.archiveUnsafeEntry(entry.name)
            }
            let components = safe.split(separator: "/").map(String.init)
            guard components.first == expectedTopLevel else {
                throw VocalSeparationError.archiveUnsafeEntry("\(entry.name)（不在 \(expectedTopLevel) 之下）")
            }
            if entry.isSymlink {
                throw VocalSeparationError.archiveUnsafeEntry("\(entry.name)（符号链接）")
            }
        }

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw VocalSeparationError.archiveCorrupt("无法创建解压目录：\(error.localizedDescription)")
        }

        for entry in entries {
            guard let safe = safeEntryPath(entry.name) else { continue }
            let outURL = destination.appendingPathComponent(safe)
            if entry.isDirectory {
                try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }
            do {
                try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let payload = try data(for: entry, in: zip)
                try Data(payload).write(to: outURL, options: .atomic)
            } catch let error as VocalSeparationError {
                throw error
            } catch {
                throw VocalSeparationError.archiveCorrupt("写入 \(safe) 失败：\(error.localizedDescription)")
            }
        }

        let packageURL = destination.appendingPathComponent(expectedTopLevel, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw VocalSeparationError.archiveMissingPackage(expectedTopLevel)
        }
        return packageURL
    }

    // MARK: 路径安全

    /// 把压缩包内路径规范化；任何越界/可疑写法返回 nil。
    static func safeEntryPath(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") || raw.hasPrefix("\\") { return nil }
        if raw.contains("\\") { return nil }
        if raw.unicodeScalars.contains(where: { $0.value == 0 }) { return nil }

        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components where component == ".." || component == "." {
            return nil
        }
        let meaningful = components.filter { !$0.isEmpty }
        guard !meaningful.isEmpty else { return nil }
        return meaningful.joined(separator: "/")
    }

    // MARK: 中央目录

    static func centralDirectory(in bytes: [UInt8]) throws -> [Entry] {
        let eocd = try findEndOfCentralDirectory(bytes)
        let count = Int(try u16(bytes, eocd + 10))
        let cdSize = Int(try u32(bytes, eocd + 12))
        let cdOffset = Int(try u32(bytes, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            throw VocalSeparationError.archiveUnsupported("不支持 Zip64")
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= bytes.count else {
            throw VocalSeparationError.archiveCorrupt("中央目录越界")
        }

        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard (try u32(bytes, p)) == 0x02014b50 else {
                throw VocalSeparationError.archiveCorrupt("中央目录签名错误")
            }
            let method = try u16(bytes, p + 10)
            let compressedSize = Int(try u32(bytes, p + 20))
            let uncompressedSize = Int(try u32(bytes, p + 24))
            let nameLength = Int(try u16(bytes, p + 28))
            let extraLength = Int(try u16(bytes, p + 30))
            let commentLength = Int(try u16(bytes, p + 32))
            let externalAttributes = try u32(bytes, p + 38)
            let localHeaderOffset = Int(try u32(bytes, p + 42))

            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                throw VocalSeparationError.archiveUnsupported("不支持 Zip64 条目")
            }
            guard p + 46 + nameLength <= bytes.count else {
                throw VocalSeparationError.archiveCorrupt("文件名越界")
            }
            let nameBytes = Array(bytes[(p + 46)..<(p + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw VocalSeparationError.archiveUnsafeEntry("非 UTF-8 文件名")
            }
            entries.append(Entry(name: name,
                                 method: method,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localHeaderOffset,
                                 externalAttributes: externalAttributes))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        let minOffset = max(0, bytes.count - (22 + 65_535))
        guard bytes.count >= 22 else { throw VocalSeparationError.archiveCorrupt("文件太短") }
        var i = bytes.count - 22
        while i >= minOffset {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        throw VocalSeparationError.archiveCorrupt("找不到 EOCD")
    }

    // MARK: 条目数据

    private static func data(for entry: Entry, in bytes: [UInt8]) throws -> [UInt8] {
        let p = entry.localHeaderOffset
        guard (try u32(bytes, p)) == 0x04034b50 else {
            throw VocalSeparationError.archiveCorrupt("本地文件头签名错误")
        }
        let nameLength = Int(try u16(bytes, p + 26))
        let extraLength = Int(try u16(bytes, p + 28))
        let dataStart = p + 30 + nameLength + extraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart >= 0, dataEnd <= bytes.count else {
            throw VocalSeparationError.archiveCorrupt("压缩数据越界")
        }
        let compressed = Array(bytes[dataStart..<dataEnd])

        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw VocalSeparationError.archiveCorrupt("stored 条目长度不符")
            }
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw VocalSeparationError.archiveUnsupported("不支持的压缩方法 \(entry.method)")
        }
    }

    private static func inflate(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard expectedSize >= 0 else {
            throw VocalSeparationError.archiveCorrupt("解压长度非法")
        }
        if expectedSize == 0 { return [] }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let decoded = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, expectedSize,
                                          source.baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == expectedSize else {
            throw VocalSeparationError.archiveCorrupt("inflate 输出 \(decoded) 字节，应为 \(expectedSize)")
        }
        return output
    }

    // MARK: little-endian

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw VocalSeparationError.archiveCorrupt("读取 UInt16 越界")
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw VocalSeparationError.archiveCorrupt("读取 UInt32 越界")
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
