import XCTest
@testable import KTubeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plain URLSession: for the live checks in CI abroad (KTUBE_LIVE=1), not through the gateway.
struct DirectHTTP: HTTPClient {
    func send(_ r: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: URL(string: r.url)!)
        req.httpMethod = r.method
        req.httpBody = r.body
        req.timeoutInterval = r.timeout
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
            URLSession.shared.dataTask(with: req) { d, resp, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: (d ?? Data(), resp!)) }
            }.resume()
        }
        let h = resp as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in h.allHeaderFields { headers["\(k)"] = "\(v)" }
        return HTTPResponse(status: h.statusCode, headers: headers, body: data)
    }
}

final class LiveTests: XCTestCase {
    var live: Bool { ProcessInfo.processInfo.environment["KTUBE_LIVE"] == "1" }
    lazy var it = Innertube(http: DirectHTTP())

    func testSearchAndWatch() async throws {
        try XCTSkipUnless(live)
        let p = try await it.search("lofi hip hop")
        XCTAssertGreaterThan(p.videos.count, 5, "search")
        XCTAssertFalse(p.videos[0].title.isEmpty)
        XCTAssertFalse(p.videos[0].channelName.isEmpty)
        print("search:", p.videos.prefix(3).map { "\($0.title) | \($0.channelName) | \($0.viewsText ?? "-") | \($0.publishedText ?? "-") | \($0.durationText ?? "-")" })
        XCTAssertNotNil(p.continuation)
        let more = try await it.searchContinue(p.continuation!)
        XCTAssertGreaterThan(more.items.count, 0, "continuation")
        let w = try await it.watchNext("dQw4w9WgXcQ")
        XCTAssertFalse(w.title.isEmpty)
        XCTAssertFalse(w.channel.id.isEmpty)
        XCTAssertGreaterThan(w.related.count, 3, "related")
        print("watch:", w.title, w.channel.name, w.viewsText, w.dateText, w.likesText ?? "-", "related", w.related.count, "comments", w.commentsToken != nil)
        if let t = w.commentsToken {
            let c = try await it.comments(t)
            XCTAssertGreaterThan(c.comments.count, 0, "comments")
            print("comments:", c.countText ?? "-", c.comments.first?.author ?? "-")
        }
    }

    func testStreams() async throws {
        try XCTSkipUnless(live)
        let s = Streams(innertube: it)
        let info = try await s.resolve("dQw4w9WgXcQ")
        print("streams:", info.source, info.variants.map(\.label), info.audioTracks.map(\.name), "captions", info.captions.count)
        XCTAssertGreaterThan(info.variants.count, 2)
        XCTAssertNotNil(info.hlsURL)
    }

    func testFeeds() async throws {
        try XCTSkipUnless(live)
        let e = try await it.explorePage(Innertube.explore[0].1)
        print("explore:", e.videos.count)
        XCTAssertGreaterThan(e.videos.count, 3)
        let ch = try await it.channel("UCuAXFkgsw1L7xaCfnd5JJOw")
        print("channel:", ch.info.name, ch.tabs.map(\.title), ch.page.items.count)
        XCTAssertFalse(ch.info.name.isEmpty)
        if let vt = ch.tabs.first(where: { $0.title.lowercased().contains("видео") || $0.title.lowercased().contains("video") }) {
            let vids = try await it.channel("UCuAXFkgsw1L7xaCfnd5JJOw", tabParams: vt.params)
            XCTAssertGreaterThan(vids.page.videos.count, 3, "channel videos")
        }
        let pl = try await it.playlist("PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
        print("playlist:", pl.info.title, pl.videos.count)
        XCTAssertGreaterThan(pl.videos.count, 3)
        let sug = try await it.suggestions("котики")
        XCTAssertFalse(sug.isEmpty)
        let (shorts, _) = try await it.shortsFeed(token: nil, seed: nil)
        print("shorts:", shorts.count)
        let (_, rss) = try await Services(http: DirectHTTP()).channelRSS("UCuAXFkgsw1L7xaCfnd5JJOw")
        XCTAssertFalse(rss.isEmpty)
    }
}
