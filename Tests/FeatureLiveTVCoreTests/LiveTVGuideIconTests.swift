#if DEBUG
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideIconTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    // MARK: Parser

    func testChannelIconIsReadByTheSavedAndIndexedReaders() throws {
        let xml = Data("""
        <tv>
          <channel id="a"><display-name>A</display-name><icon src="https://img.example/a.png"/></channel>
          <channel id="b"><display-name>B</display-name></channel>
        </tv>
        """.utf8)
        for guide in [
            try LiveTVXMLTVParser().parseXML(data: xml, channels: [], now: now),
            try LiveTVXMLTVParser().parseIndexed(data: xml, channels: [], now: now, sink: { _ in })
        ] {
            XCTAssertEqual(guide.guideIcons, ["a": try XCTUnwrap(URL(string: "https://img.example/a.png"))])
            XCTAssertEqual(guide.guideChannelCount, 2)
        }
    }

    func testInvalidChannelIconsAreRejectedAndALaterValidIconIsUsed() throws {
        let tooLong = "https://img.example/" + String(repeating: "x", count: 4_080)
        let xml = Data("""
        <tv>
          <channel id="scheme"><icon src="ftp://img.example/a.png"/><icon src="file:///a.png"/></channel>
          <channel id="user"><icon src="https://user:pass@img.example/a.png"/></channel>
          <channel id="password"><icon src="https://:pass@img.example/a.png"/></channel>
          <channel id="long"><icon src="\(tooLong)"/></channel>
          <channel id="empty"><icon src=""/><icon/></channel>
          <channel id="later"><icon src="javascript:alert(1)"/><icon src="http://img.example/later.png"/></channel>
        </tv>
        """.utf8)
        XCTAssertGreaterThan(tooLong.count, 4_096)
        let guide = try LiveTVXMLTVParser().parseXML(data: xml, channels: [], now: now)
        XCTAssertEqual(guide.guideIcons, ["later": try XCTUnwrap(URL(string: "http://img.example/later.png"))])
        XCTAssertEqual(guide.guideChannelCount, 6)
    }

    func testFirstValidIconWinsAcrossMultipleIconsAndRepeatedDeclarations() throws {
        let xml = Data("""
        <tv>
          <channel id="a"><icon src="https://img.example/first.png"/><icon src="https://img.example/second.png"/></channel>
          <channel id="a"><display-name>A again</display-name><icon src="https://img.example/third.png"/></channel>
          <channel id="b"><display-name>B</display-name></channel>
          <channel id="b"><icon src="https://img.example/b.png"/></channel>
        </tv>
        """.utf8)
        let guide = try LiveTVXMLTVParser().parseXML(data: xml, channels: [], now: now)
        XCTAssertEqual(guide.guideIcons["a"]?.absoluteString, "https://img.example/first.png")
        XCTAssertEqual(guide.guideIcons["b"]?.absoluteString, "https://img.example/b.png")
        XCTAssertEqual(guide.guideChannels["a"], ["A again"])
    }

    func testProgrammeIconStillFeedsProgrammeArtworkNotTheChannelIcon() throws {
        let xml = Data("""
        <tv>
          <channel id="g"><display-name>G</display-name><icon src="https://img.example/channel.png"/></channel>
          <programme channel="g" start="20260101000000 +0000" stop="20260101010000 +0000">
            <title>Show</title><icon src="https://img.example/show.png"/>
          </programme>
        </tv>
        """.utf8)
        let guide = try LiveTVXMLTVParser().parseXML(
            data: xml, channels: [channel(id: "app", guideID: "g")], now: now
        )
        XCTAssertEqual(guide.programs.first?.details?.artworkURL?.absoluteString, "https://img.example/show.png")
        XCTAssertEqual(guide.guideIcons["g"]?.absoluteString, "https://img.example/channel.png")
    }

    func testProgrammeOnlyIconsNeverBecomeChannelIcons() throws {
        let xml = Data("""
        <tv><programme channel="g" start="20260101000000 +0000" stop="20260101010000 +0000">
        <title>Show</title><icon src="https://img.example/show.png"/></programme></tv>
        """.utf8)
        let guide = try LiveTVXMLTVParser().parseXML(data: xml, channels: [], now: now)
        XCTAssertTrue(guide.guideIcons.isEmpty)
    }

    func testIconBytesCountTowardTheRetainedTextLimit() throws {
        let address = "https://img.example/" + String(repeating: "i", count: 4_000)
        let count = LiveTVXMLTVParser.maximumRetainedTextBytes / address.utf8.count + 2
        var xml = "<tv>"
        for index in 0..<count { xml += "<channel id=\"c\(index)\"><icon src=\"\(address)\"/></channel>" }
        xml += "</tv>"
        XCTAssertLessThan(count, LiveTVXMLTVParser.maximumGuideChannels)
        XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        // The same channels without icons stay well inside the limit.
        let plain = "<tv>" + (0..<count).map { "<channel id=\"c\($0)\"/>" }.joined() + "</tv>"
        XCTAssertEqual(
            try LiveTVXMLTVParser().parseXML(data: Data(plain.utf8), channels: [], now: now).guideChannelCount, count
        )
    }

    // MARK: Cache

    func testGuideIconsSurviveCacheRoundTripAndReopen() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/icons.xml"))
        let xml = Data("""
        <tv><channel id="g1"><display-name>One</display-name><icon src="https://img.example/one.png"/></channel></tv>
        """.utf8)
        let imported = try await fixture.cache.importGuide(
            data: xml, sourceID: "guide", channels: [channel(id: "app", guideID: "g1")],
            provider: nil, now: now, sourceURL: guideURL
        )
        XCTAssertEqual(imported.guideIcons["g1"]?.absoluteString, "https://img.example/one.png")
        let reopened = fixture.reopen()
        let restored = try await reopened.guide(sourceID: "guide", sourceURL: guideURL)
        XCTAssertEqual(restored?.guideIcons, imported.guideIcons)
        XCTAssertEqual(restored?.matches["app"]?.guideChannelID, "g1")
    }

    func testGuideImportDecodesCachesWrittenBeforeChannelIcons() throws {
        let guide = LiveTVGuideImport(
            programs: [], matchedChannelCount: 1, guideChannelCount: 1, programCount: 0,
            coverageStart: nil, coverageEnd: nil, guideChannels: ["g": ["G"]],
            guideIcons: ["g": try XCTUnwrap(URL(string: "https://img.example/g.png"))]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(guide)) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "guideIcons"))
        let old = try JSONDecoder().decode(
            LiveTVGuideImport.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(old.guideIcons.isEmpty)
        XCTAssertEqual(old.guideChannels, ["g": ["G"]])
        let current = try JSONDecoder().decode(LiveTVGuideImport.self, from: JSONEncoder().encode(guide))
        XCTAssertEqual(current.guideIcons, guide.guideIcons)
    }

    func testChannelDecodesCachesWrittenBeforeGuideLogos() throws {
        let value = channel(id: "app", guideID: "g", guideLogoURL: URL(string: "https://img.example/g.png"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "guideLogoURL"))
        let old = try JSONDecoder().decode(
            LiveTVPrototypeChannel.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(old.guideLogoURL)
        XCTAssertEqual(old.id, "app")
        let current = try JSONDecoder().decode(LiveTVPrototypeChannel.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(current.guideLogoURL, value.guideLogoURL)
    }

    // MARK: Matching

    func testMatchedChannelsGainTheirGuideIconWithoutChangingTheMatch() throws {
        let xml = Data("""
        <tv>
          <channel id="g1"><display-name>One</display-name><icon src="https://img.example/one.png"/></channel>
          <channel id="g2"><display-name>Two</display-name></channel>
        </tv>
        """.utf8)
        let channels = [
            channel(id: "one", guideID: "g1", logoURL: URL(string: "https://playlist.example/one.png")),
            channel(id: "two", guideID: "g2"),
            channel(id: "none", guideID: "missing")
        ]
        let guide = try LiveTVXMLTVParser().parseXML(data: xml, channels: channels, now: now)
        XCTAssertEqual(Set(guide.matches.keys), ["one", "two"])
        let result = LiveTVGuideMatcher.channels(channels) { _ in guide }
        XCTAssertEqual(result.map(\.id), ["one", "two", "none"])
        XCTAssertEqual(result[0].guideLogoURL?.absoluteString, "https://img.example/one.png")
        XCTAssertEqual(result[0].logoURL?.absoluteString, "https://playlist.example/one.png")
        XCTAssertNil(result[1].guideLogoURL)
        XCTAssertNil(result[2].guideLogoURL)
        XCTAssertEqual(result[0].playlistSourceID, channels[0].playlistSourceID)
        XCTAssertEqual(LiveTVGuideMatcher.channels(channels) { _ in nil }, channels)
    }

    // MARK: Choice

    func testWithoutAModelAPlaylistChannelDrawsItsNameNotTheProviderLogoOrAnUnmeasuredIcon() throws {
        let guide = try XCTUnwrap(URL(string: "https://guide.example/a.png"))
        let playlist = try XCTUnwrap(URL(string: "https://playlist.example/a.png"))
        XCTAssertNil(channel(id: "a", guideID: "g", guideLogoURL: guide).displayedLogoURL)
        let both = channel(id: "a", guideID: "g", logoURL: playlist, guideLogoURL: guide)
        XCTAssertNil(both.displayedLogoURL)
        XCTAssertNil(both.playerItem(program: nil).logoURL)
    }

    // MARK: Helpers

    private func channel(
        id: String, guideID: String?, logoURL: URL? = nil, guideLogoURL: URL? = nil
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 1, name: id, category: "Test", symbol: "tv.fill", accent: 0,
            source: .iptv, tagline: "Test", logoURL: logoURL,
            streamURL: URL(string: "https://example.com/live.m3u8"), guideID: guideID,
            guideLogoURL: guideLogoURL
        )
    }
}
#endif
