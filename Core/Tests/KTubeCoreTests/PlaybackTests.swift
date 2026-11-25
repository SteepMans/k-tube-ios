import XCTest
@testable import KTubeCore

final class PlaybackTests: XCTestCase {
    let master = """
    #EXTM3U
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:URI="https://manifest.googlevideo.com/a/en.m3u8",TYPE=AUDIO,GROUP-ID="234",LANGUAGE="en",NAME="English original",DEFAULT=YES,AUTOSELECT=YES
    #EXT-X-MEDIA:URI="https://manifest.googlevideo.com/a/ru.m3u8",TYPE=AUDIO,GROUP-ID="234",LANGUAGE="ru",NAME="Русский",DEFAULT=NO,AUTOSELECT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30,AUDIO="234"
    https://manifest.googlevideo.com/v/720.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60,AUDIO="234"
    https://manifest.googlevideo.com/v/1080.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="vp09.00.40.08",RESOLUTION=1920x1080,FRAME-RATE=60,AUDIO="234"
    https://manifest.googlevideo.com/v/1080vp9.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=30,AUDIO="234"
    rel/360.m3u8
    """

    func testMaster() {
        let (v, a) = HLS.parseMaster(master)
        XCTAssertEqual(v.map(\.label), ["1080p60", "720p", "360p"])
        XCTAssertEqual(a.map(\.name), ["English original", "Русский"])
        XCTAssertTrue(a[0].isOriginal)
        XCTAssertEqual(HLS.attr(#"#EXT-X-MEDIA:URI="x,y",TYPE=AUDIO,NAME="N""#, "TYPE"), "AUDIO")
        XCTAssertEqual(HLS.attr(#"#EXT-X-MEDIA:URI="x,y",TYPE=AUDIO,NAME="N""#, "URI"), "x,y")
    }

    func testRewrite() {
        let out = HLS.rewrite(master, base: "https://manifest.googlevideo.com/master.m3u8", keep: { $0.qualityClass == 720 }, audio: "Русский") { "L(\($0))" }
        XCTAssertTrue(out.contains("L(https://manifest.googlevideo.com/v/720.m3u8)"))
        XCTAssertFalse(out.contains("1080"))
        XCTAssertFalse(out.contains("360"))
        XCTAssertTrue(out.contains(#"URI="L(https://manifest.googlevideo.com/a/ru.m3u8)""#))
        XCTAssertTrue(out.contains(#"NAME="Русский",DEFAULT=YES"#))
        XCTAssertTrue(out.contains(#"NAME="English original",DEFAULT=NO"#))
        let all = HLS.rewrite(master, base: "https://manifest.googlevideo.com/x/master.m3u8") { "L(\($0))" }
        XCTAssertTrue(all.contains("L(https://manifest.googlevideo.com/x/rel/360.m3u8)"))
        XCTAssertFalse(all.contains("vp9"))
        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:5.0,\nhttps://rr1.googlevideo.com/seg/1\n#EXT-X-ENDLIST"
        let m = HLS.rewrite(media, base: "https://rr1.googlevideo.com/pl/index.m3u8") { "L(\($0))" }
        XCTAssertTrue(m.contains(#"URI="L(https://rr1.googlevideo.com/pl/init.mp4)""#))
        XCTAssertTrue(m.contains("L(https://rr1.googlevideo.com/seg/1)"))
    }

    /// YouTube's fragment URLs carry `/playlist/index.m3u8/` in the path: the kind comes from the playlist, not the URL.
    func testRewriteKinds() {
        var kinds: [String: HLS.URIKind] = [:]
        let withIFrames = master + "\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,CODECS=\"vp09.00.40.08\",URI=\"https://manifest.googlevideo.com/i/1080.m3u8\""
        let out = HLS.rewrite(withIFrames, base: "https://manifest.googlevideo.com/x/master.m3u8") { u, k in kinds[u] = k; return "L" }
        XCTAssertFalse(out.contains("I-FRAME"))
        XCTAssertEqual(kinds["https://manifest.googlevideo.com/v/720.m3u8"], .video)
        XCTAssertEqual(kinds["https://manifest.googlevideo.com/a/ru.m3u8"], .rendition)
        XCTAssertNil(kinds["https://manifest.googlevideo.com/i/1080.m3u8"])
        let seg = "https://rr3.googlevideo.com/videoplayback/id/1/itag/229/playlist_type/DVR/playlist/index.m3u8/sq/0/file/seg.ts"
        let media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:5.0,\n\(seg)\n#EXT-X-ENDLIST"
        _ = HLS.rewrite(media, base: "https://manifest.googlevideo.com/v/229/playlist/index.m3u8") { u, k in kinds[u] = k; return "L" }
        XCTAssertEqual(kinds[seg], .segment)
        XCTAssertTrue(HLS.looksLikePlaylist(Data("\u{FEFF}\n#EXTM3U\n".utf8)))
        XCTAssertFalse(HLS.looksLikePlaylist(Data([0x47, 0x40, 0x00, 0x30])))
        XCTAssertFalse(HLS.looksLikePlaylist(Data("<!DOCTYPE html>".utf8)))
    }

    func testPickQuality() {
        let (v, _) = HLS.parseMaster(master)
        XCTAssertEqual(AppSettings.pick(v, preferred: 1080)?.label, "1080p60")
        XCTAssertEqual(AppSettings.pick(v, preferred: 480)?.label, "360p")
        XCTAssertEqual(AppSettings.pick(v, preferred: 144)?.label, "360p")
        XCTAssertNil(AppSettings.pick(v, preferred: 0))
    }

    func testStoryboard() {
        let sb = Streams.parseStoryboard("https://i.ytimg.com/sb/x/storyboard3_L$L/$N.jpg?sqp=a|48#27#100#10#10#0#default#rs$A|80#45#200#10#10#2000#M$M#rs$B")
        XCTAssertEqual(sb?.width, 80)
        XCTAssertEqual(sb?.urlTemplate, "https://i.ytimg.com/sb/x/storyboard3_L1/M$M.jpg?sqp=a&sigh=rs$B")
        let f = sb?.frame(at: 230)
        XCTAssertEqual(f?.url, "https://i.ytimg.com/sb/x/storyboard3_L1/M1.jpg?sqp=a&sigh=rs$B")
        XCTAssertEqual(f?.col, 5)
    }

    func testVTT() {
        let vtt = "WEBVTT\nKind: captions\n\n00:00:01.000 --> 00:00:03.500 align:start\nПривет <c>мир</c>\n\n00:00:03.500 --> 00:00:03.510\nПривет мир\n\n00:00:04.000 --> 00:00:06.000\nВторая\nстрока\n"
        let cues = WebVTT.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(WebVTT.text(at: 2, in: cues), "Привет мир")
        XCTAssertNil(WebVTT.text(at: 3.8, in: cues))
        XCTAssertEqual(WebVTT.text(at: 5, in: cues), "Вторая\nстрока")
    }

    func testGateway() {
        let t = "tc_" + String(repeating: "a", count: 43)
        XCTAssertTrue(Gateway.validToken(t))
        XCTAssertFalse(Gateway.validToken("tc_short"))
        XCTAssertEqual(Gateway.parseInput(t).token, t)
        let p = Gateway.parseInput("ktube://gateway?url=https%3A%2F%2Fgw.example&token=\(t)")
        XCTAssertEqual(p.url, "https://gw.example")
        XCTAssertEqual(p.token, t)
        XCTAssertEqual(Gateway.normalize("wss://GW.example/v1/stream"), "https://gw.example")
        XCTAssertNil(Gateway.normalize("http://gw.example"))
        XCTAssertEqual(Gateway.route("rr1---sn-abc.googlevideo.com"), .gateway)
        XCTAssertEqual(Gateway.route("www.youtube.com"), .gateway)
        XCTAssertEqual(Gateway.route("sponsor.ajay.app"), .gateway)
        XCTAssertEqual(Gateway.route("evilyoutube.com"), .refuse)
        XCTAssertEqual(Gateway.route("googlevideo.com"), .refuse)
        XCTAssertTrue(Gateway.splitHostPort("WWW.YouTube.com.:443", defaultPort: 80)! == ("www.youtube.com", 443))
        let req = String(decoding: Gateway.proxyRequest(gatewayHost: "gw.example", token: "tc_x", client: "streamtube-ios/0.1.0", target: "i.ytimg.com", port: 443), as: UTF8.self)
        XCTAssertTrue(req.hasPrefix("GET /v1/proxy HTTP/1.1\r\n"))
        XCTAssertTrue(req.contains("X-Proxy-Target: i.ytimg.com:443\r\n"))
        XCTAssertTrue(req.hasSuffix("\r\n\r\n"))
        if case .failure(let r) = Gateway.parseAnswer(head: "HTTP/1.1 503 Service Unavailable\r\nX-Proxy-Error: no_leg\r\n\r\n", body: "", target: "x") {
            XCTAssertTrue(r.important)
            XCTAssertTrue(r.text.contains("недоступны"))
        } else { XCTFail() }
        if case .failure = Gateway.parseAnswer(head: "HTTP/1.1 101 Switching Protocols\r\n\r\n", body: "", target: "x") { XCTFail() }
        XCTAssertEqual(Gateway.clientHeader(version: "0.1.0"), "streamtube-ios/0.1.0")
    }

    func testLibrary() {
        var lib = Library()
        let v = VideoItem(id: "abcdefghijk", title: "A", channelName: "C", channelId: "UC1")
        lib.recordWatch(v, position: 100, duration: 1000, at: 10)
        lib.recordWatch(VideoItem(id: "b"), position: 0, duration: 0, at: 20)
        lib.recordWatch(VideoItem(id: "abcdefghijk"), position: 200, duration: 1000, at: 30)
        XCTAssertEqual(lib.history.map(\.video.id), ["abcdefghijk", "b"])
        XCTAssertEqual(lib.history[0].video.title, "A")
        XCTAssertEqual(lib.resumePosition("abcdefghijk"), 200)
        lib.updatePosition("abcdefghijk", position: 995, duration: 1000)
        XCTAssertNil(lib.resumePosition("abcdefghijk"))
        XCTAssertTrue(lib.watchedIds.contains("abcdefghijk"))
        XCTAssertTrue(lib.isWatched("abcdefghijk"))
        lib.setWatched(v, false)
        XCTAssertFalse(lib.isWatched("abcdefghijk"))
        XCTAssertEqual(lib.entry("abcdefghijk")?.progress, 0)
        lib.setWatched(v, true)
        XCTAssertEqual(lib.entry("abcdefghijk")?.progress, 1)
        var fresh = VideoItem(id: "c")
        fresh.durationSecs = 300
        lib.setWatched(fresh, true, at: 40)
        XCTAssertEqual(lib.history.first?.video.id, "c")
        XCTAssertTrue(lib.isWatched("c"))
        XCTAssertNil(lib.resumePosition("c"))
        lib.setWatched(VideoItem(id: "d"), true, at: 50)
        XCTAssertTrue(lib.isWatched("d"))
        lib.setWatched(VideoItem(id: "e"), false)
        XCTAssertNil(lib.entry("e"))
        lib.removeHistory("c")
        lib.removeHistory("d")
        lib.toggleWatchLater(v)
        XCTAssertTrue(lib.isInWatchLater(v.id))
        lib.watched(v.id)
        XCTAssertFalse(lib.isInWatchLater(v.id))
        let p = lib.createPlaylist("Мой")
        lib.add(v, toPlaylist: p.id)
        lib.add(v, toPlaylist: p.id)
        XCTAssertEqual(lib.playlists[0].videos.count, 1)
        lib.recordSearch("кот")
        lib.recordSearch("пёс")
        lib.recordSearch("КОТ")
        XCTAssertEqual(lib.searchHistory, ["КОТ", "пёс"])
        XCTAssertEqual(lib.merge(subscriptions: [ChannelItem(id: "UC1"), ChannelItem(id: "UC1"), ChannelItem(id: "UC2")]), 2)
        let data = try! JSONEncoder().encode(lib)
        XCTAssertEqual(try! JSONDecoder().decode(Library.self, from: data), lib)
        XCTAssertEqual(try! JSONDecoder().decode(Library.self, from: Data("{}".utf8)), Library())
    }

    func testSettingsTolerant() {
        let s = try! JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"light","sbActions":{"sponsor":"ask"},"unknown":1}"#.utf8))
        XCTAssertEqual(s.theme, .light)
        XCTAssertEqual(s.sbActions["sponsor"], .ask)
        XCTAssertEqual(s.sbActions["selfpromo"], .skip)
        XCTAssertTrue(s.sbCategories.contains("sponsor"))
        XCTAssertFalse(s.sbCategories.contains("filler"))
        var f = AppSettings()
        f.hideShorts = true
        f.blockedKeywords = ["спойлер"]
        f.blockedChannels = ["UCbad": "Bad"]
        var short = VideoItem(id: "s1"); short.isShort = true
        let items: [VideoItem] = [short, VideoItem(id: "a", title: "Без СПОЙЛЕРОВ"), VideoItem(id: "b", channelId: "UCbad"), VideoItem(id: "c", title: "ok")]
        XCTAssertEqual(f.filter(items).map(\.id), ["c"])
    }

    func testImport() throws {
        let opml = #"<opml><body><outline text="subs"><outline text="A &amp; B" title="A &amp; B" type="rss" xmlUrl="https://www.youtube.com/feeds/videos.xml?channel_id=UCaaaaaaaaaaaaaaaaaaaaaa"/></outline></body></opml>"#
        let r1 = try ImportExport.parse(Data(opml.utf8))
        XCTAssertEqual(r1.subscriptions.map(\.name), ["A & B"])
        let np = #"{"app_version":"0.27","subscriptions":[{"service_id":0,"url":"https://www.youtube.com/channel/UCbbbbbbbbbbbbbbbbbbbbbb","name":"B"},{"service_id":1,"url":"x","name":"SC"}]}"#
        XCTAssertEqual(try ImportExport.parse(Data(np.utf8)).subscriptions.map(\.id), ["UCbbbbbbbbbbbbbbbbbbbbbb"])
        let csv = "Channel Id,Channel Url,Channel Title\nUCcccccccccccccccccccccc,http://www.youtube.com/channel/UCcccccccccccccccccccccc,\"Name, with comma\"\n"
        XCTAssertEqual(try ImportExport.parse(Data(csv.utf8), fileName: "subscriptions.csv").subscriptions.first?.name, "Name, with comma")
        let takeout = #"[{"header":"YouTube","title":"Watched Cool video","titleUrl":"https://www.youtube.com/watch?v=abcdefghijk","subtitles":[{"name":"Chan","url":"https://www.youtube.com/channel/UCdddddddddddddddddddddd"}],"time":"2026-01-02T03:04:05.123Z"}]"#
        let h = try ImportExport.parse(Data(takeout.utf8)).history
        XCTAssertEqual(h.first?.video.title, "Cool video")
        XCTAssertEqual(h.first?.video.channelId, "UCdddddddddddddddddddddd")
        XCTAssertGreaterThan(h.first?.watchedAt ?? 0, 0)
        var lib = Library()
        lib.toggleSubscription(ChannelItem(id: "UCeeeeeeeeeeeeeeeeeeeeee", name: "Один"))
        let back = try ImportExport.parse(ImportExport.exportBackup(library: lib, settings: AppSettings()))
        XCTAssertEqual(back.library, lib)
        let again = try ImportExport.parse(ImportExport.exportOPML(lib.subscriptions))
        XCTAssertEqual(again.subscriptions.first?.id, "UCeeeeeeeeeeeeeeeeeeeeee")
        XCTAssertEqual(try ImportExport.parse(ImportExport.exportNewPipe(lib.subscriptions)).subscriptions.first?.name, "Один")
        XCTAssertEqual(try ImportExport.parse(ImportExport.exportCSV(lib.subscriptions), fileName: "s.csv").subscriptions.first?.name, "Один")
    }

    func testInterleave() {
        let a = [VideoItem(id: "1"), VideoItem(id: "2"), VideoItem(id: "3")]
        let b = [VideoItem(id: "2"), VideoItem(id: "4")]
        XCTAssertEqual(Recommend.interleave([a, b], exclude: ["3"]).map(\.id), ["1", "2", "4"])
    }
}
