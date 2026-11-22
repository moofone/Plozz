import XCTest
@testable import FeatureLiveTVCore

final class LiveTVChannelLogoPolicyTests: XCTestCase {
    func testProviderLogoIsNeverDisplayed() throws {
        let channel = LiveTVPrototypeChannel(
            id: "a", number: 7, name: "ADULT SWIM", category: "Entertainment", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", logoURL: try XCTUnwrap(URL(string: "https://logos.example/adult-swim.jpg")))
        XCTAssertNotNil(channel.logoURL, "The provider URL stays available for non-display uses")
        XCTAssertNil(channel.displayedLogoURL)
    }
}

final class LiveTVChannelLogoSeamTests: XCTestCase {
    private func service(measure: @escaping @Sendable (URL) async -> LiveTVLogoSize?) -> LiveTVChannelLogoService {
        let tmp = FileManager.default.temporaryDirectory
        return LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: tmp.appendingPathComponent("seam-\(UUID().uuidString).json")),
            directory: .init(fileURL: tmp.appendingPathComponent("n-\(UUID().uuidString).json"), fetch: { _ in Data() }),
            wikidata: .init(fileURL: tmp.appendingPathComponent("w-\(UUID().uuidString).json"), fetch: { _ in (Data(), 500) }),
            accessProvider: { .disabled }, measureGuideIcon: measure
        )
    }

    private func channel(provider: String? = "https://provider.example/p.png", guide: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: "c", number: 1, name: "CA EN: SEAM", category: "News", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            logoURL: provider.flatMap(URL.init(string:)), guideLogoURL: guide.flatMap(URL.init(string:)))
    }

    func testProviderLogoIsNeverReturnedAndOverrideWins() throws {
        let service = service { _ in nil }
        let item = channel()
        XCTAssertNil(service.displayedLogoURL(for: item))
        let mine = try XCTUnwrap(URL(string: "https://mine.example/logo.png"))
        _ = service.chooseURL(mine.absoluteString, for: LiveTVChannelLogoKey(channel: item))
        XCTAssertEqual(service.displayedLogoURL(for: item), mine)
    }

    func testGuideIconIsReturnedOnlyOnceMeasuredCrispAndNotRejected() async throws {
        let service = service { url in url.lastPathComponent == "soft.png" ? .raster(width: 100, height: 40) : .raster(width: 900, height: 300) }
        let crisp = channel(guide: "https://guide.example/crisp.png"), soft = channel(guide: "https://guide.example/soft.png")
        XCTAssertNil(service.displayedLogoURL(for: crisp), "not measured yet")
        _ = await service.guideIconSizes(for: [try XCTUnwrap(crisp.guideLogoURL), try XCTUnwrap(soft.guideLogoURL)])
        XCTAssertEqual(service.displayedLogoURL(for: crisp), crisp.guideLogoURL)
        XCTAssertNil(service.displayedLogoURL(for: soft))
        service.rejectGuideIcons([try XCTUnwrap(crisp.guideLogoURL)])
        XCTAssertNil(service.displayedLogoURL(for: crisp), "a placeholder icon is never drawn")
    }

    func testEventSlotsAndSectionMarkersShareOneClassifier() {
        XCTAssertTrue(LiveTVChannelKind.isEvent(name: "US: UFC 300 PPV EVENT 4", groups: []))
        XCTAssertTrue(LiveTVEventSlotClassifier.isEventSlot(name: "US: UFC 300 PPV EVENT 4", groups: []))
        XCTAssertTrue(LiveTVChannelKind.isEvent(name: "US: ESPN", groups: ["US|PPV"]))
        XCTAssertNotNil(LiveTVEventSlotClassifier.classify(name: "US: ESPN", groups: ["US|PPV"]))
        XCTAssertFalse(LiveTVChannelKind.isEvent(name: "CA EN: CBC CALGARY HD", groups: ["CA EN"]))
    }
}

final class LiveTVChannelMeasuredQualityTests: XCTestCase {
    func testChannelUsesTheMeasuredLabelInPlaceOfItsNameClaim() {
        let store = LiveChannelMeasuredQualityStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("q-\(UUID().uuidString)/m.json"))
        let channel = LiveTVPrototypeChannel(
            id: "16940", number: 1, name: "CA EN: E! HD", category: "Entertainment", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", playlistSourceID: "playlist-1", tags: [.country("CA"), .language("EN"), .hd])
        XCTAssertEqual(channel.displayedTagTexts(in: store), ["CA", "EN", "HD"], "no measurement keeps the claim")
        store.record(height: 720, sourceID: "playlist-1", channelID: "16940")
        XCTAssertEqual(channel.displayedTagTexts(in: store), ["CA", "EN", "720p"])
        let fourK = LiveTVPrototypeChannel(
            id: "4k", number: 2, name: "CA: X 4K", category: "News", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", playlistSourceID: "playlist-1", tags: [.k4])
        XCTAssertEqual(fourK.guideQualityBadgeText(in: store), "4K")
        store.record(height: 1_080, sourceID: "playlist-1", channelID: "4k")
        XCTAssertNil(fourK.guideQualityBadgeText(in: store))
    }
}
