import Foundation

public struct LyricsHTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var retryAfter: String?

    public init(data: Data, statusCode: Int, retryAfter: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

public protocol LyricsSearchTransport: Sendable {
    func response(for request: URLRequest) async throws -> LyricsHTTPResponse
}

private final class URLSessionLyricsTransport: LyricsSearchTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func response(for request: URLRequest) async throws -> LyricsHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return LyricsHTTPResponse(data: data, statusCode: -1)
        }
        return LyricsHTTPResponse(data: data,
                                  statusCode: http.statusCode,
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }
}

public enum LyricsLookupError: Error, LocalizedError, Equatable {
    case invalidTrackName
    case rateLimited(retryAfter: String?)
    case server(statusCode: Int)
    /// 网络超时、断开或连不上歌词服务（已自动重试仍失败）。
    case unreachable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidTrackName:
            return "请先输入歌曲名"
        case let .rateLimited(retryAfter):
            if let retryAfter, !retryAfter.isEmpty {
                return "歌词服务请求过于频繁，请稍后再试（\(retryAfter) 秒）"
            }
            return "歌词服务请求过于频繁，请稍后再试"
        case let .server(statusCode):
            if (500...599).contains(statusCode) {
                return "歌词服务暂时繁忙（HTTP \(statusCode)），不是你的操作问题。已自动重试仍未成功，请稍后再点“搜索”。"
            }
            return "歌词服务返回了意外的状态（HTTP \(statusCode)）"
        case .unreachable:
            return "连不上歌词服务（网络超时或断开）。请检查网络后再点“搜索”。"
        case .invalidResponse:
            return "歌词服务返回的数据无法读取"
        }
    }
}

/// LRCLIB search is used only to source ordered lyric text; local audio owns all alignment timing.
public actor LRCLIBClient {
    private struct Record: Decodable {
        var id: Int
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private let transport: any LyricsSearchTransport
    private let baseURL: URL
    private let userAgent: String
    private let minRequestInterval: Duration
    /// 遇到 5xx 或瞬时网络错误时的重试等待时间；数组长度就是最多重试次数。
    /// LRCLIB 是免费的社区服务，偶尔会在繁忙时返回 503，稍等再试通常就好了。
    private let retryDelays: [Duration]
    private let clock = ContinuousClock()
    private var lastRequestAt: ContinuousClock.Instant?

    public init(baseURL: URL = URL(string: "https://lrclib.net")!,
                userAgent: String = "MaGiKara/0.1.0 (com.magi.magikara)",
                minRequestInterval: Duration = .seconds(1),
                retryDelays: [Duration] = LRCLIBClient.defaultRetryDelays) {
        self.transport = URLSessionLyricsTransport()
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.minRequestInterval = minRequestInterval
        self.retryDelays = retryDelays
    }

    public init(transport: any LyricsSearchTransport,
                baseURL: URL = URL(string: "https://lrclib.net")!,
                userAgent: String = "MaGiKara/0.1.0 (com.magi.magikara)",
                minRequestInterval: Duration = .seconds(1),
                retryDelays: [Duration] = LRCLIBClient.defaultRetryDelays) {
        self.transport = transport
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.minRequestInterval = minRequestInterval
        self.retryDelays = retryDelays
    }

    public static let defaultRetryDelays: [Duration] = [.milliseconds(1500), .seconds(3)]

    public func search(trackName: String,
                       artistName: String,
                       mediaDurationSec: Double? = nil) async throws -> [LyricsCandidate] {
        let track = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else { throw LyricsLookupError.invalidTrackName }
        var queryItems: [URLQueryItem]
        if artist.isEmpty {
            // A filename often contains "artist title" as one string. Search all
            // fields in that case so the artist prefix does not hide the track.
            queryItems = [URLQueryItem(name: "q", value: track)]
        } else {
            queryItems = [URLQueryItem(name: "track_name", value: track),
                          URLQueryItem(name: "artist_name", value: artist)]
        }
        var records = try await searchRecords(queryItems: queryItems)

        // LRCLIB 里歌手名多为英文写法（例如 Fujii Kaze），填中文/日文名往往一条都搜不到。
        // 带歌手名没结果时，去掉歌手名只按歌曲名再搜一次；按素材时长排序能把最可能的版本排前面，
        // 同时把结果标记为「未按歌手匹配」，让界面提示用户核对。
        var artistFallbackUsed = false
        if records.isEmpty, !artist.isEmpty {
            records = try await searchRecords(queryItems: [URLQueryItem(name: "track_name", value: track)])
            artistFallbackUsed = !records.isEmpty
        }

        // If a filename such as "藤井风 花" is not indexed as one phrase, try
        // its final whitespace-delimited token as the track title. Duration
        // ranking then helps disambiguate common short titles like 花.
        if records.isEmpty, artist.isEmpty {
            let words = track.split(whereSeparator: \.isWhitespace)
            if words.count > 1, let titleToken = words.last {
                records = try await searchRecords(queryItems: [
                    URLQueryItem(name: "track_name", value: String(titleToken))
                ])
            }
        }

        let candidates = records.compactMap { record -> LyricsCandidate? in
            guard record.instrumental != true else { return nil }
            guard let parsed = LRCLyricsParser.text(synchronized: record.syncedLyrics,
                                                    plain: record.plainLyrics) else { return nil }
            let durationDelta: Double? = if let mediaDurationSec, let sourceDuration = record.duration {
                abs(sourceDuration - mediaDurationSec)
            } else {
                nil
            }
            return LyricsCandidate(id: record.id,
                                   trackName: record.trackName ?? "未知曲名",
                                   artistName: record.artistName ?? "未知艺术家",
                                   albumName: record.albumName,
                                   durationSec: record.duration,
                                   durationDeltaSec: durationDelta,
                                   lyricsText: parsed.text,
                                   textSource: parsed.source,
                                   matchesRequestedArtist: !artistFallbackUsed)
        }

        return candidates.sorted { lhs, rhs in
            switch (lhs.durationDeltaSec, rhs.durationDeltaSec) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.trackName.localizedCaseInsensitiveCompare(rhs.trackName) == .orderedAscending
            }
        }
    }

    private func searchRecords(queryItems: [URLQueryItem]) async throws -> [Record] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LyricsLookupError.invalidResponse }

        var attempt = 0
        while true {
            try await waitForRateLimit()

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let response: LyricsHTTPResponse
            do {
                response = try await transport.response(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if Self.isTransient(error), attempt < retryDelays.count {
                    try await Task.sleep(for: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw LyricsLookupError.unreachable
            }

            if response.statusCode == 429 {
                // 限流不自动重试：Retry-After 往往比我们愿意等的更久，直接告诉用户。
                throw LyricsLookupError.rateLimited(retryAfter: response.retryAfter)
            }
            if (500...599).contains(response.statusCode) {
                if attempt < retryDelays.count {
                    try await Task.sleep(for: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw LyricsLookupError.server(statusCode: response.statusCode)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw LyricsLookupError.server(statusCode: response.statusCode)
            }
            guard let records = try? JSONDecoder().decode([Record].self, from: response.data) else {
                throw LyricsLookupError.invalidResponse
            }
            return records
        }
    }

    /// 值得重试的瞬时网络错误（超时、连接中断、暂时连不上）；没联网之类的重试也没用，直接报错。
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private func waitForRateLimit() async throws {
        if let lastRequestAt {
            let elapsed = lastRequestAt.duration(to: clock.now)
            if elapsed < minRequestInterval {
                try await Task.sleep(for: minRequestInterval - elapsed)
            }
        }
        lastRequestAt = clock.now
    }
}
