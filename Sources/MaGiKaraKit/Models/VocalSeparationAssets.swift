import Foundation

/// 已完成人声分离的本地双轨文件。媒体指纹用于阻止旧结果误套到新 MV。
public struct VocalSeparationAssets: Codable, Sendable, Equatable {
    public var vocalURL: URL
    public var instrumentalURL: URL
    public var sourceFingerprint: String
    public var modelID: String
    public var sampleRate: Double
    public var duration: Double
    public var separatedAt: Date

    public init(vocalURL: URL,
                instrumentalURL: URL,
                sourceFingerprint: String,
                modelID: String,
                sampleRate: Double,
                duration: Double,
                separatedAt: Date = Date()) {
        self.vocalURL = vocalURL
        self.instrumentalURL = instrumentalURL
        self.sourceFingerprint = sourceFingerprint
        self.modelID = modelID
        self.sampleRate = sampleRate
        self.duration = duration
        self.separatedAt = separatedAt
    }

    enum CodingKeys: String, CodingKey {
        case vocalURL, instrumentalURL, sourceFingerprint, modelID, sampleRate, duration, separatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vocalURL = Self.fileURL(try c.decode(String.self, forKey: .vocalURL))
        instrumentalURL = Self.fileURL(try c.decode(String.self, forKey: .instrumentalURL))
        sourceFingerprint = try c.decode(String.self, forKey: .sourceFingerprint)
        modelID = try c.decode(String.self, forKey: .modelID)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        duration = try c.decode(Double.self, forKey: .duration)
        separatedAt = try c.decodeIfPresent(Date.self, forKey: .separatedAt) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vocalURL.absoluteString, forKey: .vocalURL)
        try c.encode(instrumentalURL.absoluteString, forKey: .instrumentalURL)
        try c.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(duration, forKey: .duration)
        try c.encode(separatedAt, forKey: .separatedAt)
    }

    private static func fileURL(_ raw: String) -> URL {
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(fileURLWithPath: raw)
    }
}
