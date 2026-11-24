import XCTest
@testable import KTubeCore

final class AnnotationTests: XCTestCase {
    static let sample = #"""
<?xml version="1.0" encoding="UTF-8" ?><document><annotations itct="x">
<annotation id="hl1" type="highlight" log_data="a=1&amp;b=2">
  <segment><movingRegion type="rect">
    <rectRegion x="10.0" y="20.0" w="30.0" h="10.0" t="0:01:00.5"/>
    <rectRegion x="10.0" y="20.0" w="30.0" h="10.0" t="1:30.0"/>
  </movingRegion></segment>
  <appearance bgColor="16777215" highlightWidth="3" borderAlpha="0.25"/>
  <action type="openUrl" trigger="click">
    <url target="current" value="https://www.youtube.com/watch?annotation_id=hl1&amp;feature=iv&amp;src_vid=abcdefghijk&amp;v=abcdefghijk#t=2m5s" link_class="1"/>
  </action>
</annotation>
<annotation id="tx1" type="text" style="highlightText" logable="false">
  <TEXT>Go to 2:05 &amp; more</TEXT>
  <segment spaceRelative="hl1"><movingRegion type="rect">
    <rectRegion x="1.0" y="-2.0" w="5" h="3" t="never"/>
    <rectRegion x="1.0" y="-2.0" w="5" h="3" t="never"/>
  </movingRegion></segment>
  <appearance bgAlpha="0" textSize="3.9" highlightFontColor="15921906"/>
</annotation>
<annotation id="p1" type="text" style="popup">
  <TEXT>Subscribe!
Thanks</TEXT>
  <segment><movingRegion type="rect">
    <rectRegion x="5" y="5" w="20" h="8" t="0:05.0"/>
    <rectRegion x="5" y="5" w="20" h="8" t="0:10.0"/>
  </movingRegion></segment>
  <appearance bgAlpha="0.6" bgColor="0" fgColor="16777215" textSize="3.9116"/>
  <action type="openUrl" trigger="click"><url value="https://www.youtube.com/watch?v=zzzzzzzzzzz&amp;feature=iv"/></action>
</annotation>
<annotation id="w1" type="text" style="speech">
  <TEXT>site</TEXT>
  <segment><movingRegion type="anchored">
    <anchoredRegion x="50" y="50" w="10" h="10" sx="40" sy="70" t="0:00:01"/>
    <anchoredRegion x="50" y="50" w="10" h="10" sx="40" sy="70" t="0:00:03"/>
  </movingRegion></segment>
  <action type="openUrl"><url value="http://example.org/page?x=1"/></action>
</annotation>
<annotation id="pz" type="pause"><segment><movingRegion type="rect"><rectRegion x="0" y="0" w="1" h="1" t="0:01"/></movingRegion></segment></annotation>
</annotations></document>
"""#

    func testParse() {
        let a = Annotations.parse(Self.sample, videoId: "abcdefghijk")
        XCTAssertEqual(a.map(\.id), ["hl1", "tx1", "p1", "w1"])
        XCTAssertEqual(a[0].kind, .highlight)
        XCTAssertEqual(a[0].start, 60.5)
        XCTAssertEqual(a[0].end, 90)
        XCTAssertEqual(a[0].action, .seek(125))
        XCTAssertEqual(a[1].rolloverOf, "hl1")
        XCTAssertEqual(a[1].x, 11)
        XCTAssertEqual(a[1].y, 18)
        XCTAssertEqual(a[1].text, "Go to 2:05 & more")
        XCTAssertEqual(a[1].fg, 15921906)
        XCTAssertFalse(a[1].visible(at: 70))
        XCTAssertEqual(a[2].text, "Subscribe!\nThanks")
        XCTAssertEqual(a[2].bg, 0)
        XCTAssertEqual(a[2].fg, 0xFFFFFF)
        XCTAssertEqual(a[2].bgAlpha, 0.6, accuracy: 1e-6)
        XCTAssertTrue(a[2].visible(at: 7) && !a[2].visible(at: 10) && !a[2].visible(at: 4))
        XCTAssertEqual(a[2].action, .youtube("https://www.youtube.com/watch?v=zzzzzzzzzzz&feature=iv"))
        XCTAssertEqual(a[3].style, "speech")
        XCTAssertEqual(a[3].bg, 0xFFFFFF)
        XCTAssertEqual(a[3].fg, 0)
        XCTAssertEqual(a[3].textSize, 3.15)
        XCTAssertEqual(a[3].action, .web("http://example.org/page?x=1"))
    }

    func testPathsAndTimes() {
        XCTAssertEqual(Annotations.url(for: "6Uwd5w1AwYU"), "\(Annotations.archive)/6/6Uw/6Uwd5w1AwYU.xml.gz")
        XCTAssertEqual(Annotations.url(for: "-abcdefghij"), "\(Annotations.archive)/-/ar-/-ab/-abcdefghij.xml.gz")
        XCTAssertEqual(Annotations.parseTime("0:48:00.9")!, 2880.9, accuracy: 1e-9)
        XCTAssertEqual(Annotations.parseTime("20:00.800")!, 1200.8, accuracy: 1e-9)
        XCTAssertNil(Annotations.parseTime("never"))
        XCTAssertEqual(Annotations.urlTime("https://x/watch?v=a#t=40m"), 2400)
    }
}
