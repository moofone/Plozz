import Foundation
import MetadataKit
import Observation
import XCTest
@testable import FeatureLiveTVCore

/// From a store holding a TMDB `network` match and a Wikidata `logo` match, through the model's seam, to the URL a plate draws.
@MainActor
final class LiveTVLogoSeamTests: XCTestCase {
    private final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TMDbAccess
        init(_ value: TMDbAccess) { self.value = value }
        var current: TMDbAccess { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private let source = "server-1"

    private func channel(_ id: String, _ name: String, guide: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 1, name: name, category: "News", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            playlistSourceID: source, guideLogoURL: guide.flatMap(URL.init(string:)))
    }

    private func makeService(access: Access, measure: @escaping @Sendable (URL) async -> LiveTVLogoSize? = { _ in nil })
        -> LiveTVChannelLogoService {
        let tmp = FileManager.default.temporaryDirectory
        return LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: tmp.appendingPathComponent("seam-\(UUID().uuidString).json")),
            directory: .init(fileURL: tmp.appendingPathComponent("n-\(UUID().uuidString).json"), fetch: { _ in Data() }),
            wikidata: .init(fileURL: tmp.appendingPathComponent("w-\(UUID().uuidString).json"), fetch: { _ in (Data(), 500) }),
            accessProvider: { access.current }, measureGuideIcon: measure)
    }

    /// AMC has a TMDB network match, E! a Wikidata logo, AMI TV both, and Plain has neither.
    private func seeded(_ service: LiveTVChannelLogoService, _ channels: [LiveTVPrototypeChannel]) {
        let store = service.store
        store.recordNetwork(TMDbNetworkLogo(networkID: 174, name: "AMC", originCountry: "US", filePath: "/amc.png"))
        store.recordMatches([
            LiveTVChannelLogoIdentity(channel: channels[0]): .network(id: 174, filePath: "/amc.png"),
            LiveTVChannelLogoIdentity(channel: channels[2]): .network(id: 174, filePath: "/amc.png"),
            LiveTVChannelLogoIdentity(channel: channels[3]): .none(directoryDate: Date())
        ])
        store.recordWikidataMatches([
            LiveTVChannelLogoIdentity(channel: channels[1]): .logo(qid: "Q5321347", file: "E! Logo 2012.svg"),
            LiveTVChannelLogoIdentity(channel: channels[2]): .logo(qid: "Q2819269", file: "AMItv.svg")
        ])
    }

    private var lineup: [LiveTVPrototypeChannel] {
        [channel("amc", "AMC"), channel("e", "E!"), channel("ami", "AMI TV"), channel("plain", "Plain")]
    }

    func testStoredTMDBAndWikidataMatchesReachTheURLThePlateDraws() {
        let access = Access(.directToken("test"))
        let service = makeService(access: access)
        let channels = lineup
        seeded(service, channels)
        let model = LiveTVPrototypeModel(channels: channels, logoService: service)

        XCTAssertEqual(model.effectiveLogoURL(for: channels[0])?.host, "image.tmdb.org")
        XCTAssertEqual(model.effectiveLogoURL(for: channels[1])?.host, "commons.wikimedia.org")
        XCTAssertEqual(model.effectiveLogoURL(for: channels[1])?.absoluteString.contains("E!%20Logo%202012.svg"), true)
        XCTAssertEqual(model.effectiveLogoURL(for: channels[2])?.host, "image.tmdb.org", "a matched TMDB network logo is never replaced by Wikidata")
        XCTAssertNil(model.effectiveLogoURL(for: channels[3]))
    }

    func testWithoutTMDBAccessTheWikidataLogoStillDrawsAndATMDBOnlyChannelDrawsItsName() {
        let service = makeService(access: Access(.disabled))
        let channels = lineup
        seeded(service, channels)
        let model = LiveTVPrototypeModel(channels: channels, logoService: service)

        XCTAssertNil(model.effectiveLogoURL(for: channels[0]), "TMDB is off: its match is not drawn")
        XCTAssertEqual(model.effectiveLogoURL(for: channels[1])?.host, "commons.wikimedia.org")
        XCTAssertEqual(model.effectiveLogoURL(for: channels[2])?.host, "commons.wikimedia.org")
        XCTAssertNil(model.effectiveLogoURL(for: channels[3]))
    }

    func testTheSeamSummaryCountsChannelsBySource() {
        let access = Access(.directToken("test"))
        let service = makeService(access: access)
        let channels = lineup + [channel("override", "Override")]
        seeded(service, channels)
        XCTAssertTrue(service.store.setOverride(.url(URL(string: "https://example.com/o.png")!), for: LiveTVChannelLogoKey(channel: channels[4])))

        let counts = service.logoSeamCounts(for: channels)
        XCTAssertEqual(counts, LiveTVLogoSeamCounts(override: 1, tmdb: 2, wikidata: 1, xmltv: 0, text: 1, tmdbAccess: true))
        XCTAssertEqual(counts.line, "LIVE_TV event=logoSeam tmdbAccess=true override=1 tmdb=2 wikidata=1 xmltv=0 text=1")

        access.current = .disabled
        XCTAssertEqual(service.logoSeamCounts(for: channels),
                       LiveTVLogoSeamCounts(override: 1, tmdb: 0, wikidata: 2, xmltv: 0, text: 2, tmdbAccess: false))
    }

    func testAPlateThatDrewTheNameRedrawsWhenItsLogoArrives() async throws {
        let service = makeService(access: Access(.disabled))
        let channels = lineup
        let model = LiveTVPrototypeModel(channels: channels, logoService: service)
        XCTAssertNil(model.effectiveLogoURL(for: channels[1]))

        let changed = expectation(description: "the plate's observation fires")
        withObservationTracking { _ = model.effectiveLogoURL(for: channels[1]) } onChange: { changed.fulfill() }
        service.store.recordWikidataMatches([
            LiveTVChannelLogoIdentity(channel: channels[1]): .logo(qid: "Q5321347", file: "E! Logo 2012.svg")
        ])
        model.resolveLogos()
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.effectiveLogoURL(for: channels[1])?.host, "commons.wikimedia.org")
    }

    func testAPlateThatDrewTheNameRedrawsWhenItsGuideIconIsMeasuredCrisp() async throws {
        let service = makeService(access: Access(.disabled)) { _ in .raster(width: 1_000, height: 400) }
        let icon = channel("icon", "Icon", guide: "https://guide.example/icon.png")
        let model = LiveTVPrototypeModel(channels: [icon], logoService: service)
        for _ in 0..<100 where model.effectiveLogoURL(for: icon) != nil { try await Task.sleep(for: .milliseconds(10)) }

        let changed = expectation(description: "the plate's observation fires")
        withObservationTracking { _ = model.effectiveLogoURL(for: icon) } onChange: { changed.fulfill() }
        model.resolveLogos()
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.effectiveLogoURL(for: icon)?.absoluteString, "https://guide.example/icon.png")
    }
}
