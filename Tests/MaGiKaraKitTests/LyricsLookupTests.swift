import Foundation
import Testing
@testable import MaGiKaraKit

private actor StubLyricsTransport: LyricsSearchTransport {
    private var responses: [LyricsHTTPResponse]
    private var requests: [URLRequest] = []

    init(statusCode: Int = 200, body: String, retryAfter: String? = nil) {
        responses = [LyricsHTTPResponse(data: Data(body.utf8),
                                        statusCode: statusCode,
                                        retryAfter: retryAfter)]
    }

    init(responses: [LyricsHTTPResponse]) {
        self.responses = responses
    }

    func response(for request: URLRequest) async throws -> LyricsHTTPResponse {
        requests.append(request)
        if responses.count > 1 { return responses.removeFirst() }
        return responses[0]
    }

    func capturedRequest() -> URLRequest? { requests.last }
    func capturedRequests() -> [URLRequest] { requests }
}

@Suite struct LyricsLookupTests {
    @Test func synchronizedLyricsLoseTimestampsButKeepRepeatedRows() throws {
        let lrc = """
        [ar:藤井風]
        [ti:花]
        [00:10.00][00:11.90]my flower's here
        [00:13.80]my flower's here
        [00:15.70]<00:15.80>咲いている
        """

        let parsed = try #require(LRCLyricsParser.text(synchronized: lrc, plain: nil))
        #expect(parsed.source == .synchronized)
        #expect(parsed.text == "my flower's here\nmy flower's here\nmy flower's here\n咲いている")
        #expect(!parsed.text.contains("00:"))

        let lines = AnalysisCoordinator.makeLines(from: parsed.text)
        #expect(lines.map(\.displayText) == ["my flower's here", "my flower's here",
                                             "my flower's here", "咲いている"])
        #expect(lines.allSatisfy { $0.singStart == 0 && $0.singEnd == 0 })
    }

    @Test func plainLyricsPreserveEveryRepeatedOutroLine() throws {
        let outro = String(repeating: "my flower's here\n", count: 16)
        let parsed = try #require(LRCLyricsParser.text(synchronized: nil, plain: outro))
        let lines = AnalysisCoordinator.makeLines(from: parsed.text)

        #expect(parsed.source == .plain)
        #expect(lines.count == 16)
        #expect(lines.allSatisfy { $0.displayText == "my flower's here" })
        #expect(lines.map(\.order) == Array(1...16))
    }

    @Test func synchronizedLyricsExpandMultipleTimestampTagsOnOneRow() throws {
        let text = try #require(LRCLyricsParser.text(fromSynchronized: "[00:10.00][00:12.50]花"))
        #expect(text == "花\n花")
    }

    @Test func lookupUsesEncodedQueryAndRanksByMediaDuration() async throws {
        let body = """
        [
          {"id":1,"trackName":"花","artistName":"藤井風","duration":220,"plainLyrics":"wrong duration"},
          {"id":2,"trackName":"花","artistName":"藤井風","duration":248,"syncedLyrics":"[00:01.00]my flower's here\\n[00:02.00]my flower's here"}
        ]
        """
        let transport = StubLyricsTransport(body: body)
        let client = LRCLIBClient(transport: transport,
                                  baseURL: URL(string: "https://lyrics.test")!,
                                  userAgent: "MaGiKara-tests",
                                  minRequestInterval: .zero)
        let candidates = try await client.search(trackName: "花 + flower",
                                                 artistName: "藤井風",
                                                 mediaDurationSec: 248.3)

        #expect(candidates.map(\.id) == [2, 1])
        #expect(candidates[0].lyricsText == "my flower's here\nmy flower's here")
        #expect(candidates[0].textSource == .synchronized)
        let request = try #require(await transport.capturedRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "track_name" })?.value == "花 + flower")
        #expect(components.queryItems?.first(where: { $0.name == "artist_name" })?.value == "藤井風")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MaGiKara-tests")
    }

    @Test func lookupReportsRateLimitClearly() async throws {
        let transport = StubLyricsTransport(statusCode: 429, body: "{}", retryAfter: "3")
        let client = LRCLIBClient(transport: transport, minRequestInterval: .zero)

        do {
            _ = try await client.search(trackName: "花", artistName: "")
            Issue.record("Expected a rate-limit error")
        } catch let error as LyricsLookupError {
            #expect(error == .rateLimited(retryAfter: "3"))
            #expect(error.localizedDescription.contains("3 秒"))
        }
    }

    @Test func artistlessFilenameSearchUsesAllFields() async throws {
        let transport = StubLyricsTransport(body: "[]")
        let client = LRCLIBClient(transport: transport, minRequestInterval: .zero)
        _ = try await client.search(trackName: "花", artistName: "")
        let request = try #require(await transport.capturedRequest())
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "花")
        #expect(components.queryItems?.allSatisfy { $0.name != "track_name" } == true)
    }

    @Test func filenameSearchFallsBackToTitleTokenAndRanksByDuration() async throws {
        let fallbackBody = """
        [{"id":42,"trackName":"花","artistName":"Fujii Kaze (藤井風)","duration":247,"plainLyrics":"line\\nline"}]
        """
        let transport = StubLyricsTransport(responses: [
            LyricsHTTPResponse(data: Data("[]".utf8), statusCode: 200),
            LyricsHTTPResponse(data: Data(fallbackBody.utf8), statusCode: 200),
        ])
        let client = LRCLIBClient(transport: transport, minRequestInterval: .zero)
        let candidates = try await client.search(trackName: "藤井风 花",
                                                 artistName: "",
                                                 mediaDurationSec: 248.3)

        #expect(candidates.first?.id == 42)
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        let firstURL = try #require(requests.first?.url)
        let firstQuery = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
        #expect(firstQuery.queryItems?.first(where: { $0.name == "q" })?.value == "藤井风 花")
        let secondURL = try #require(requests.last?.url)
        let secondQuery = try #require(URLComponents(url: secondURL, resolvingAgainstBaseURL: false))
        #expect(secondQuery.queryItems?.first(where: { $0.name == "track_name" })?.value == "花")
    }
}
