import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVChannelTagTests: XCTestCase {
    func testTagsAreComputedWithCleaningOffAndTheNameIsUnchanged() {
        let model = LiveTVPrototypeModel(channels: [channel("a", "CA EN: CBC CALGARY HD")])
        model.cleanChannelNames = false
        XCTAssertEqual(model.channel(id: "a")?.name, "CA EN: CBC CALGARY HD")
        XCTAssertEqual(model.channel(id: "a")?.tags, [.country("CA"), .language("EN"), .hd])
    }

    func testCleaningRemovesWhatBecameATag() {
        let model = LiveTVPrototypeModel(channels: [channel("a", "CA EN: CBC CALGARY HD")])
        model.cleanChannelNames = true
        XCTAssertEqual(model.channel(id: "a")?.name, "CBC CALGARY")
        XCTAssertEqual(model.channel(id: "a")?.tags, [.country("CA"), .language("EN"), .hd])
    }

    func testPrefixFillsCountryAndLanguageOnlyWhenTheProviderSuppliedNone() {
        let model = LiveTVPrototypeModel(channels: [
            channel("bare", "CA FR: ICI RDI"),
            channel("supplied", "CA FR: ICI RDI", language: "eng", country: "US")
        ])
        XCTAssertEqual(model.channel(id: "bare")?.country, "CA")
        XCTAssertEqual(model.channel(id: "bare")?.language, "FR")
        XCTAssertEqual(model.channel(id: "supplied")?.country, "US")
        XCTAssertEqual(model.channel(id: "supplied")?.language, "eng")
    }

    func testNonIPTVChannelsAreNeverParsed() {
        let model = LiveTVPrototypeModel(channels: [channel("p", "CA EN: Movie HD", source: .plex)])
        model.cleanChannelNames = true
        XCTAssertEqual(model.channel(id: "p")?.name, "CA EN: Movie HD")
        XCTAssertEqual(model.channel(id: "p")?.tags, [])
    }

    func testTagsAreDerivedAndNotEncoded() throws {
        let model = LiveTVPrototypeModel(channels: [channel("a", "CBC HD")])
        let encoded = try JSONEncoder().encode(try XCTUnwrap(model.channel(id: "a")))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("tags"))
        XCTAssertEqual(try JSONDecoder().decode(LiveTVPrototypeChannel.self, from: encoded).tags, [])
    }

    private func channel(
        _ id: String, _ name: String, source: LiveTVPrototypeSource = .iptv, language: String? = nil, country: String? = nil
    ) -> LiveTVPrototypeChannel {
        .init(id: id, number: 1, name: name, category: "News", symbol: "tv", accent: 0,
              source: source, tagline: "", language: language, country: country)
    }
}
