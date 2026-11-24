import XCTest
@testable import KTubeCore

final class AccountTests: XCTestCase {
    func testTile() {
        let j = J.parse(Data("""
        {"tileRenderer":{"contentId":"abcdefghijk","contentType":"TILE_CONTENT_TYPE_VIDEO",
         "header":{"tileHeaderRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abcdefghijk/hq.jpg","width":480,"height":360}]},
           "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"text":{"simpleText":"12:05"},"style":"DEFAULT"}}]}},
         "metadata":{"tileMetadataRenderer":{"title":{"simpleText":"Видео"},"lines":[{"lineRenderer":{"items":[
           {"lineItemRenderer":{"text":{"runs":[{"text":"Канал","navigationEndpoint":{"browseEndpoint":{"browseId":"UCabcdefghijklmnopqrstuv"}}}]}}},
           {"lineItemRenderer":{"text":{"simpleText":"•"}}},
           {"lineItemRenderer":{"text":{"simpleText":"1,2 тыс. просмотров"}}},
           {"lineItemRenderer":{"text":{"simpleText":"3 дня назад"}}}]}}]}}}}
        """.utf8))
        let p = Parse.collectItems(j)
        XCTAssertEqual(p.items.count, 1)
        let v = p.items[0].video!
        XCTAssertEqual(v.id, "abcdefghijk")
        XCTAssertEqual(v.title, "Видео")
        XCTAssertEqual(v.channelName, "Канал")
        XCTAssertEqual(v.channelId, "UCabcdefghijklmnopqrstuv")
        XCTAssertEqual(v.durationSecs, 725)
        XCTAssertEqual(v.publishedText, "3 дня назад")
        XCTAssertEqual(v.viewsText, "1,2 тыс. просмотров")
    }

    func testChatParamsRoundTrip() {
        let p = Account.chatParams(channelId: "UCabc", videoId: "vid")
        let once = String(decoding: Data(base64Encoded: p)!, as: UTF8.self)
        let raw = Data(base64Encoded: URLCoding.decode(once))!
        XCTAssertEqual(Array(raw.suffix(4)), [0x10, 0x01, 0x18, 0x04])
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("UCabc"))
    }

    func testChannelIdFromParams() {
        let raw = Data([0x12, 0x18] + Array("UCabcdefghijklmnopqrstuv".utf8))
        XCTAssertEqual(Account.channelId(fromParams: raw.base64EncodedString()), "UCabcdefghijklmnopqrstuv")
    }
}
