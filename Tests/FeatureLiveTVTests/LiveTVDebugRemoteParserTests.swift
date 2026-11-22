#if DEBUG
import XCTest
@testable import FeatureLiveTV

final class LiveTVDebugRemoteParserTests: XCTestCase {
    private func parse(_ string: String) -> LiveTVDebugRemoteParseResult? {
        LiveTVDebugRemoteParser.parse(URL(string: string)!)
    }

    func testParsesEveryArgumentFreeCommand() {
        let expected: [(String, LiveTVDebugRemoteCommand)] = [
            ("open", .open), ("guide", .guide), ("quickmenu", .quickMenu), ("context", .context),
            ("panel", .panel), ("back", .back), ("stop", .stop)
        ]
        for (path, command) in expected {
            XCTAssertEqual(parse("plozz-debug://livetv/\(path)"), .command(command), path)
        }
    }

    func testTuneAndFocusCarryNameAndOptionalGroup() {
        XCTAssertEqual(parse("plozz-debug://livetv/tune?name=CTV"), .command(.tune(name: "CTV", group: nil)))
        XCTAssertEqual(
            parse("plozz-debug://livetv/tune?name=CTV&group=CA"), .command(.tune(name: "CTV", group: "CA")))
        XCTAssertEqual(parse("plozz-debug://livetv/focus?name=CBC&group=CA"), .command(.focus(name: "CBC", group: "CA")))
    }

    func testPercentEncodingIsDecodedAndPlusStaysLiteral() {
        XCTAssertEqual(
            parse("plozz-debug://livetv/tune?name=CA%3A%20TSN%201%20%26%20More&group=Sports%20%7C%20CA"),
            .command(.tune(name: "CA: TSN 1 & More", group: "Sports | CA")))
        XCTAssertEqual(parse("plozz-debug://livetv/tune?name=A+B"), .command(.tune(name: "A+B", group: nil)))
    }

    func testOtherSchemesAndHostsAreNotOurs() {
        XCTAssertNil(parse("plozz://livetv/open"))
        XCTAssertNil(parse("https://livetv/open"))
        XCTAssertNil(parse("plozz-debug://shots/open"))
    }

    func testUnknownOrMissingCommandIsRejected() {
        XCTAssertEqual(parse("plozz-debug://livetv/nope"), .rejected(command: "nope", reason: "unknown-command"))
        XCTAssertEqual(parse("plozz-debug://livetv"), .rejected(command: "", reason: "missing-command"))
        XCTAssertEqual(parse("plozz-debug://livetv/open/extra"), .rejected(command: "open", reason: "unknown-command"))
    }

    func testMissingEmptyOrDuplicatedNameIsRejected() {
        XCTAssertEqual(parse("plozz-debug://livetv/tune"), .rejected(command: "tune", reason: "missing-name"))
        XCTAssertEqual(parse("plozz-debug://livetv/tune?name="), .rejected(command: "tune", reason: "missing-name"))
        XCTAssertEqual(parse("plozz-debug://livetv/tune?group=CA"), .rejected(command: "tune", reason: "missing-name"))
        XCTAssertEqual(parse("plozz-debug://livetv/focus?name=A&name=B"), .rejected(command: "focus", reason: "duplicate-name"))
        XCTAssertEqual(parse("plozz-debug://livetv/tune?name=A&group="), .rejected(command: "tune", reason: "empty-group"))
        XCTAssertEqual(
            parse("plozz-debug://livetv/tune?name=A&group=1&group=2"), .rejected(command: "tune", reason: "duplicate-group"))
    }

    func testResolveIsExactAndByNameAndGroupNeverNumber() {
        let channels = [
            LiveTVDebugRemoteChannelKey(id: "1", name: "CBC", groups: ["CA News"]),
            LiveTVDebugRemoteChannelKey(id: "2", name: "CBC", groups: ["CA Sports"]),
            LiveTVDebugRemoteChannelKey(id: "3", name: "CTV", groups: ["CA News"]),
            LiveTVDebugRemoteChannelKey(id: "4", name: "CTV Two", groups: ["CA News"])
        ]
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "CTV", group: nil, in: channels), .match(id: "3"))
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "CBC", group: "CA Sports", in: channels), .match(id: "2"))
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "CBC", group: nil, in: channels), .ambiguous)
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "ctv", group: nil, in: channels), .missing)
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "CT", group: nil, in: channels), .missing)
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "CTV", group: "CA Sports", in: channels), .missing)
        XCTAssertEqual(LiveTVDebugRemoteParser.resolve(name: "3", group: nil, in: channels), .missing)
    }
}
#endif
