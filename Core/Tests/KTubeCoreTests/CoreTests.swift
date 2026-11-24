import XCTest
@testable import KTubeCore

final class CoreTests: XCTestCase {
    func testDurationAndPlural() {
        XCTAssertEqual(Format.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(Format.parseDuration("4:05"), 245)
        XCTAssertNil(Format.parseDuration("live"))
        XCTAssertEqual(Format.duration(3723), "1:02:03")
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.plural(1, "a", "b", "c"), "a")
        XCTAssertEqual(Format.plural(3, "a", "b", "c"), "b")
        XCTAssertEqual(Format.plural(11, "a", "b", "c"), "c")
        XCTAssertEqual(Format.plural(22, "a", "b", "c"), "b")
        XCTAssertEqual(Format.compact(1234), "1,2 тыс.")
        XCTAssertEqual(Format.compact(3_400_000), "3,4 млн")
        XCTAssertEqual(Format.compact(999), "999")
    }

    func testRelativeTime() {
        XCTAssertEqual(Format.relativeSeconds("3 days ago"), 3 * 86400)
        XCTAssertEqual(Format.relativeSeconds("3 дня назад"), 3 * 86400)
        XCTAssertEqual(Format.relativeSeconds("Трансляция закончилась 2 недели назад"), 2 * 604800)
        XCTAssertEqual(Format.relativeSeconds("5 лет назад"), 5 * 31_536_000)
        XCTAssertEqual(Format.relativeSeconds("11 месяцев назад"), 11 * 2_592_000)
        XCTAssertNil(Format.relativeSeconds("1,2 млн просмотров"))
        XCTAssertEqual(Format.relative(from: 1000, now: 1000 + 2 * 3600), "2 часа назад")
        XCTAssertEqual(Format.relative(from: 1000, now: 1000 + 86400 * 5), "5 дней назад")
    }

    func testCounts() {
        XCTAssertEqual(Format.parseCount("1,2 тыс. просмотров"), 1200)
        XCTAssertEqual(Format.parseCount("3.4M views"), 3_400_000)
        XCTAssertEqual(Format.parseCount("12 345 просмотров"), 12345)
    }

    func testTimestamps() {
        let t = "Смотрите с 1:23 и до 01:02:03, а не 123"
        let found = Format.timestamps(in: t).map(\.seconds)
        XCTAssertEqual(found, [83, 3723])
    }

    func testSearchFilter() {
        var f = SearchFilter()
        XCTAssertNil(f.encode())
        f.sort = 2
        XCTAssertEqual(f.encode(), "CAI=")
        f = SearchFilter()
        f.kind = 1
        XCTAssertEqual(f.encode(), "EgIQAQ==")
    }

    func testParseURL() {
        XCTAssertEqual(Innertube.parseYouTubeURL("https://youtu.be/dQw4w9WgXcQ?t=42"), .video("dQw4w9WgXcQ", start: 42))
        XCTAssertEqual(Innertube.parseYouTubeURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1"), .video("dQw4w9WgXcQ", start: nil))
        XCTAssertEqual(Innertube.parseYouTubeURL("https://www.youtube.com/shorts/abcdefghijk"), .video("abcdefghijk", start: nil))
        XCTAssertEqual(Innertube.parseYouTubeURL("https://www.youtube.com/playlist?list=PLxyz"), .playlist("PLxyz"))
        XCTAssertEqual(Innertube.parseYouTubeURL("https://www.youtube.com/channel/UCabc/videos"), .channel("UCabc"))
        XCTAssertNil(Innertube.parseYouTubeURL("https://example.com"))
    }

    func testSuggestionsJSONP() {
        let t = #"window.google.ac.h(["lofi",[["lofi",0,[512]],["lofi girl",0,[512,433]]],{"k":1}])"#
        XCTAssertEqual(Innertube.parseSuggestionsJSONP(t), ["lofi", "lofi girl"])
    }

    func testLockupAndAds() {
        func lockup(_ id: String, _ title: String) -> [String: Any] {
            ["lockupViewModel": ["contentId": id, "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                                 "metadata": ["lockupMetadataViewModel": ["title": ["content": title],
                                    "metadata": ["contentMetadataViewModel": ["metadataRows": [
                                        ["metadataParts": [["text": ["content": "Канал"], "x": ["browseEndpoint": ["browseId": "UCchan"]]]]],
                                        ["metadataParts": [["text": ["content": "1,2 млн просмотров"]], ["text": ["content": "3 дня назад"]]]],
                                    ]]]]],
                                 "contentImage": ["thumbnailViewModel": ["image": ["sources": [["url": "https://i.ytimg.com/a.jpg", "width": 720, "height": 404]]],
                                                  "overlays": [["thumbnailBadgeViewModel": ["text": "12:34"]]]]]]]
        }
        var ad = lockup("adVid000001", "Buy")
        var lvm = ad["lockupViewModel"] as! [String: Any]
        lvm["rendererContext"] = ["loggingContext": ["adClientParams": ["x": 1]]]
        ad["lockupViewModel"] = lvm
        let feed: [String: Any] = ["contents": [
            ["richItemRenderer": ["content": lockup("realVid0001", "Видео")]],
            ["richItemRenderer": ["content": ["adSlotRenderer": ["x": lockup("adVid000002", "Ad")]]]],
            ["richItemRenderer": ["content": ad]],
            ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "NEXT"]]]],
        ]]
        let page = Parse.collectItems(J(feed))
        XCTAssertEqual(page.videos.map(\.id), ["realVid0001"])
        XCTAssertEqual(page.continuation, "NEXT")
        let v = page.videos[0]
        XCTAssertEqual(v.channelId, "UCchan")
        XCTAssertEqual(v.channelName, "Канал")
        XCTAssertEqual(v.viewsText, "1,2 млн просмотров")
        XCTAssertEqual(v.publishedText, "3 дня назад")
        XCTAssertEqual(v.durationSecs, 754)
        XCTAssertEqual(v.thumbnail, "https://i.ytimg.com/a.jpg")
    }

    func testVideoRenderer() {
        let r: [String: Any] = ["videoRenderer": [
            "videoId": "abcdefghijk", "title": ["runs": [["text": "Hello "], ["text": "world"]]],
            "ownerText": ["runs": [["text": "Chan", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCx"]]]]],
            "lengthText": ["simpleText": "1:00"], "viewCountText": ["simpleText": "10 views"],
        ]]
        let p = Parse.collectItems(J(r))
        XCTAssertEqual(p.videos.first?.title, "Hello world")
        XCTAssertEqual(p.videos.first?.channelId, "UCx")
        XCTAssertEqual(p.videos.first?.durationSecs, 60)
    }

    func testChaptersFromDescription() {
        let d = "Intro text\n0:00 Начало\n1:30 Середина\n10:05 - Конец"
        let c = Parse.chaptersFromDescription(d)
        XCTAssertEqual(c.map(\.start), [0, 90, 605])
        XCTAssertEqual(c.last?.title, "Конец")
        XCTAssertTrue(Parse.chaptersFromDescription("1:00 a\n2:00 b\n3:00 c").isEmpty)
    }

    func testAvatarLimit() {
        XCTAssertEqual(Parse.limitAvatar("https://yt3.ggpht.com/abc=s900-c-k-c0x00ffffff-no-rj"), "https://yt3.ggpht.com/abc=s240-c-k-c0x00ffffff-no-rj")
        XCTAssertEqual(Parse.limitAvatar("https://yt3.ggpht.com/abc=s88-c-k"), "https://yt3.ggpht.com/abc=s88-c-k")
    }

    func testSHA256() {
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Services.shaPrefix("dQw4w9WgXcQ").count, 4)
    }

    func testSegmentsAndBranding() {
        let j = J.parse(#"[{"videoID":"v1","segments":[{"segment":[10.5,20],"category":"sponsor","actionType":"skip","UUID":"u"}]},{"videoID":"v2","segments":[]}]"#)
        let s = Services.parseSegments(j, videoId: "v1")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].start, 10.5)
        let b = Services.parseBranding(J.parse(#"{"v1":{"titles":[{"title":"Better >title","original":false,"votes":1}],"thumbnails":[{"timestamp":12.5,"original":false}]}}"#), videoId: "v1")
        XCTAssertEqual(b?.title, "Better title")
        XCTAssertEqual(b?.thumbnailTime, 12.5)
    }

    func testRSS() {
        let xml = """
        <feed><title>Мой канал</title><entry><yt:videoId>abcdefghijk</yt:videoId><title>Видео &amp; звук</title>
        <link rel="alternate" href="https://www.youtube.com/shorts/abcdefghijk"/><published>2026-01-02T03:04:05+00:00</published>
        <media:statistics views="1500"/></entry></feed>
        """
        let (name, items) = Services.parseRSS(xml, channelId: "UC1")
        XCTAssertEqual(name, "Мой канал")
        XCTAssertEqual(items.first?.title, "Видео & звук")
        XCTAssertEqual(items.first?.isShort, true)
        XCTAssertNotNil(items.first?.publishedTs)
    }
}
