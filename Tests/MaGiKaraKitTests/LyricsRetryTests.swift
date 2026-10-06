import Foundation
import Testing
@testable import MaGiKaraKit

/// 按脚本依次返回结果或抛错的假传输层，用来测重试与回退。
private actor ScriptedTransport: LyricsSearchTransport {
    enum Step: Sendable {
        case respond(Int, String)
        case fail(URLError.Code)
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func response(for request: URLRequest) async throws -> LyricsHTTPResponse {
        requests.append(request)
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        switch step {
        case let .respond(status, body):
            return LyricsHTTPResponse(data: Data(body.utf8), statusCode: status)
        case let .fail(code):
            throw URLError(code)
        }
    }

    func requestCount() -> Int { requests.count }
    func queryNames(at index: Int) -> [String] {
        guard requests.indices.contains(index), let url = requests[index].url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [] }
        return items.map(\.name)
    }
}

private let oneRecord = """
[{"id":7,"trackName":"Title","artistName":"Artist","duration":200,"plainLyrics":"line one\\nline two"}]
"""

private func client(_ transport: ScriptedTransport) -> LRCLIBClient {
    // 重试等待全部设为 0，测试不用真的等
    LRCLIBClient(transport: transport, minRequestInterval: .zero, retryDelays: [.zero, .zero])
}

@Suite struct LyricsRetryTests {

    @Test func retriesTransientServerErrorsThenSucceeds() async throws {
        let transport = ScriptedTransport([.respond(503, "{}"), .respond(503, "{}"), .respond(200, oneRecord)])
        let found = try await client(transport).search(trackName: "Title", artistName: "")
        #expect(found.map(\.id) == [7])
        #expect(await transport.requestCount() == 3, "两次 503 后第三次成功")
    }

    @Test func givesUpAfterRetriesWithAFriendlyMessage() async throws {
        let transport = ScriptedTransport([.respond(503, "{}")])
        do {
            _ = try await client(transport).search(trackName: "Title", artistName: "")
            Issue.record("应该抛出服务器错误")
        } catch let error as LyricsLookupError {
            #expect(error == .server(statusCode: 503))
            let text = try #require(error.errorDescription)
            #expect(text.contains("暂时繁忙") && text.contains("不是你的操作问题"))
        }
        #expect(await transport.requestCount() == 3, "首次 + 2 次重试")
    }

    @Test func doesNotRetryClientErrorsOrRateLimits() async throws {
        let notFound = ScriptedTransport([.respond(404, "{}")])
        await #expect(throws: LyricsLookupError.server(statusCode: 404)) {
            _ = try await client(notFound).search(trackName: "Title", artistName: "")
        }
        #expect(await notFound.requestCount() == 1)

        let limited = ScriptedTransport([.respond(429, "{}")])
        await #expect(throws: LyricsLookupError.rateLimited(retryAfter: nil)) {
            _ = try await client(limited).search(trackName: "Title", artistName: "")
        }
        #expect(await limited.requestCount() == 1)
    }

    @Test func retriesTimeoutsThenSucceeds() async throws {
        let transport = ScriptedTransport([.fail(.timedOut), .respond(200, oneRecord)])
        let found = try await client(transport).search(trackName: "Title", artistName: "")
        #expect(found.count == 1)
        #expect(await transport.requestCount() == 2)
    }

    @Test func reportsUnreachableAfterRepeatedTimeouts() async throws {
        let transport = ScriptedTransport([.fail(.timedOut)])
        do {
            _ = try await client(transport).search(trackName: "Title", artistName: "")
            Issue.record("应该抛出无法连接")
        } catch let error as LyricsLookupError {
            #expect(error == .unreachable)
            #expect(try #require(error.errorDescription).contains("连不上歌词服务"))
        }
        #expect(await transport.requestCount() == 3)
    }

    @Test func doesNotRetryWhenOffline() async throws {
        let transport = ScriptedTransport([.fail(.notConnectedToInternet)])
        await #expect(throws: LyricsLookupError.unreachable) {
            _ = try await client(transport).search(trackName: "Title", artistName: "")
        }
        #expect(await transport.requestCount() == 1, "没联网重试没意义，应立即报错")
    }
}

@Suite struct LyricsArtistFallbackTests {

    @Test func dropsTheArtistWhenNothingMatchesAndFlagsTheResults() async throws {
        let transport = ScriptedTransport([.respond(200, "[]"), .respond(200, oneRecord)])
        let found = try await client(transport).search(trackName: "Title", artistName: "某歌手")

        #expect(found.map(\.id) == [7])
        #expect(found.allSatisfy { !$0.matchesRequestedArtist }, "界面据此提示用户核对歌手")
        #expect(await transport.requestCount() == 2)
        let first = await transport.queryNames(at: 0)
        let second = await transport.queryNames(at: 1)
        #expect(first.contains("artist_name"))
        #expect(second == ["track_name"], "第二次只按歌曲名搜索")
    }

    @Test func artistMatchedResultsAreNotFlagged() async throws {
        let transport = ScriptedTransport([.respond(200, oneRecord)])
        let found = try await client(transport).search(trackName: "Title", artistName: "Artist")
        #expect(found.first?.matchesRequestedArtist == true)
        #expect(await transport.requestCount() == 1, "有结果就不应该多发一次请求")
    }

    @Test func fallbackStaysEmptyWhenTitleAlsoMatchesNothing() async throws {
        let transport = ScriptedTransport([.respond(200, "[]")])
        let found = try await client(transport).search(trackName: "Title", artistName: "某歌手")
        #expect(found.isEmpty)
        #expect(await transport.requestCount() == 2)
    }

    @Test func rankingStillPrefersTheClosestDurationInFallback() async throws {
        let body = """
        [{"id":1,"trackName":"Title","artistName":"A","duration":120,"plainLyrics":"x"},
         {"id":2,"trackName":"Title","artistName":"B","duration":248,"plainLyrics":"y"}]
        """
        let transport = ScriptedTransport([.respond(200, "[]"), .respond(200, body)])
        let found = try await client(transport).search(trackName: "Title",
                                                       artistName: "某歌手",
                                                       mediaDurationSec: 248.3)
        #expect(found.map(\.id) == [2, 1])
    }
}
