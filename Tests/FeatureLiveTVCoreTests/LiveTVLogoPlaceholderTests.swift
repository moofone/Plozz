import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// The playlist provider's own logo is never drawn. The logo a channel draws is the user's choice, a TMDB/Wikidata match, a
/// guide (XMLTV) icon that is measured crisp and not a placeholder, or else the channel's name.
@MainActor
final class LiveTVLogoPlaceholderTests: XCTestCase {
    private func channel(
        _ id: String, _ name: String, guide: String? = nil, provider: String? = nil, source: String = "playlist-1"
    ) -> LiveTVPrototypeChannel {
        .init(
            id: id, number: 1, name: name, category: "News", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            logoURL: provider.flatMap(URL.init(string:)), playlistSourceID: source,
            guideLogoURL: guide.flatMap(URL.init(string:))
        )
    }

    private let flag = "https://cdn.example/flags/ca.png"

    private func lineup() -> [LiveTVPrototypeChannel] {
        (1...5).map { channel("f\($0)", "CA EN: STATION \($0) HD", guide: flag) }
            + [
                channel("cbc1", "CA EN: CBC CALGARY HD", guide: "https://cdn.example/cbc.png"),
                channel("cbc2", "CA EN: CBC EDMONTON HD", guide: "https://cdn.example/cbc.png"),
                channel("cbc3", "CA EN: CBC MONTREAL", guide: "https://cdn.example/cbc.png"),
                channel("solo", "CA EN: UNIQUE", guide: "https://cdn.example/unique.png")
            ]
    }

    private func makeService(measure: @escaping @Sendable (URL) async -> LiveTVLogoSize?) -> LiveTVChannelLogoService {
        let tmp = FileManager.default.temporaryDirectory
        return LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: tmp.appendingPathComponent("ph-\(UUID().uuidString).json")),
            directory: .init(fileURL: tmp.appendingPathComponent("n-\(UUID().uuidString).json"), fetch: { _ in Data() }),
            wikidata: .init(fileURL: tmp.appendingPathComponent("w-\(UUID().uuidString).json"), fetch: { _ in (Data(), 500) }),
            accessProvider: { .disabled },
            measureGuideIcon: measure
        )
    }

    /// A model whose logos have been resolved and whose guide icons are measured.
    private func resolvedModel(
        _ channels: [LiveTVPrototypeChannel], service: LiveTVChannelLogoService? = nil,
        measure: @escaping @Sendable (URL) async -> LiveTVLogoSize? = { _ in .raster(width: 1_000, height: 400) }
    ) async throws -> LiveTVPrototypeModel {
        let model = LiveTVPrototypeModel(channels: channels, logoService: service ?? makeService(measure: measure))
        model.resolveLogos()
        for _ in 0..<400 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(model.isResolvingLogos, "the logo run finished")
        return model
    }

    func testAGuideIconSharedByFiveBrandsIsAPlaceholderAndTheChannelDrawsItsName() async throws {
        let model = try await resolvedModel(lineup())
        XCTAssertNil(model.effectiveLogoURL(for: lineup()[0]))
        XCTAssertNil(model.placeholderScreeningKey(for: lineup()[0]))
    }

    func testAChannelWithOnlyAProviderLogoDrawsItsName() async throws {
        let only = channel("p", "CA EN: UNIQUE", provider: "https://cdn.example/provider.png")
        let model = try await resolvedModel([only])
        XCTAssertNil(model.effectiveLogoURL(for: only))
        XCTAssertNil(only.displayedLogoURL)
    }

    func testProviderLogosAreNeverDownloadedMeasuredOrScreened() async throws {
        let measured = MeasuredURLs()
        let only = channel("p", "CA EN: UNIQUE", provider: "https://cdn.example/provider.png")
        _ = try await resolvedModel([only]) { url in measured.add(url); return .vector }
        XCTAssertTrue(measured.urls.isEmpty)
        let crowd = (1...4).map { channel("c\($0)", "BRAND \($0)", provider: flag) }
        XCTAssertTrue(LiveTVLogoPlaceholders.placeholders(in: crowd).isEmpty, "provider logos take no part in placeholder screening")
    }

    func testACrispGuideIconIsDrawnAndASoftOrUnmeasurableOneIsNot() async throws {
        let crisp = channel("a", "CA EN: ALPHA", guide: "https://guide.example/crisp.png")
        let vector = channel("v", "CA EN: VECTOR", guide: "https://guide.example/v.svg")
        let soft = channel("b", "CA EN: BETA", guide: "https://guide.example/soft.png")
        let broken = channel("c", "CA EN: GAMMA", guide: "https://guide.example/broken.png")
        let model = try await resolvedModel([crisp, vector, soft, broken]) { url in
            switch url.lastPathComponent {
            case "crisp.png": .raster(width: 1_000, height: 400)
            case "v.svg": .vector
            case "soft.png": .raster(width: 150, height: 50)
            default: nil
            }
        }
        XCTAssertEqual(model.effectiveLogoURL(for: crisp)?.absoluteString, "https://guide.example/crisp.png")
        XCTAssertEqual(model.effectiveLogoURL(for: vector)?.absoluteString, "https://guide.example/v.svg")
        XCTAssertNil(model.effectiveLogoURL(for: soft))
        XCTAssertNil(model.effectiveLogoURL(for: broken))
    }

    func testAGuideIconIsNotDrawnBeforeItIsMeasured() {
        let model = LiveTVPrototypeModel(channels: lineup(), logoService: makeService { _ in .vector })
        XCTAssertNil(model.effectiveLogoURL(for: lineup()[8]))
    }

    func testARealGuideIconSharedByRegionalVariantsOfOneBrandIsKept() async throws {
        let model = try await resolvedModel(lineup())
        XCTAssertEqual(model.effectiveLogoURL(for: lineup()[5])?.absoluteString, "https://cdn.example/cbc.png")
        XCTAssertEqual(LiveTVLogoPlaceholders.brandKey("CA EN: CBC CALGARY HD"), LiveTVLogoPlaceholders.brandKey("CA EN: CBC EDMONTON HD"))
    }

    func testAGuideIconSharedByCountryEditionsOfOneChannelIsKept() async throws {
        let logo = "https://cdn.example/heaven.png"
        let channels = [channel("a", "7th Heaven", guide: logo), channel("b", "7th Heaven DK", guide: logo), channel("c", "7th Heaven NO", guide: logo)]
        XCTAssertEqual(LiveTVLogoPlaceholders.brandKey("7th Heaven DK"), LiveTVLogoPlaceholders.brandKey("7th Heaven"))
        let model = try await resolvedModel(channels)
        XCTAssertEqual(model.effectiveLogoURL(for: channels[1])?.absoluteString, logo)
        XCTAssertNotEqual(LiveTVLogoPlaceholders.brandKey("TV NO"), LiveTVLogoPlaceholders.brandKey("TV"), "a two-word name keeps its last word")
    }

    func testTwoBrandsSharingAURLAreNotEnoughButThreeAre() {
        let two = [channel("a", "ALPHA", guide: "https://x/y.png"), channel("b", "BETA", guide: "https://x/y.png")]
        XCTAssertTrue(LiveTVLogoPlaceholders.placeholders(in: two).isEmpty)
        XCTAssertEqual(LiveTVLogoPlaceholders.placeholders(in: two + [channel("c", "GAMMA", guide: "https://x/y.png")]).count, 1)
    }

    func testSourcesAreCountedSeparately() {
        let channels = [
            channel("a", "ALPHA", guide: "https://x/y.png", source: "one"),
            channel("b", "BETA", guide: "https://x/y.png", source: "two"),
            channel("c", "GAMMA", guide: "https://x/y.png", source: "three")
        ]
        XCTAssertTrue(LiveTVLogoPlaceholders.placeholders(in: channels).isEmpty)
    }

    func testAFlagTheUserChoseIsKept() async throws {
        let service = makeService { _ in .vector }
        let station = lineup()[0]
        let mine = try XCTUnwrap(URL(string: flag))
        _ = service.chooseURL(mine.absoluteString, for: LiveTVChannelLogoKey(channel: station))
        let model = try await resolvedModel(lineup(), service: service)
        XCTAssertEqual(model.effectiveLogoURL(for: station), mine)
        XCTAssertNil(model.placeholderScreeningKey(for: station), "a chosen logo is never screened")
    }

    func testAUserChoiceBeatsACrispGuideIcon() async throws {
        let service = makeService { _ in .vector }
        let solo = channel("s", "CA EN: UNIQUE", guide: "https://guide.example/unique.png")
        let mine = try XCTUnwrap(URL(string: "https://mine.example/logo.png"))
        _ = service.chooseURL(mine.absoluteString, for: LiveTVChannelLogoKey(channel: solo))
        let model = try await resolvedModel([solo], service: service)
        XCTAssertEqual(model.effectiveLogoURL(for: solo), mine)
    }

    func testServiceNeverFallsBackToTheProviderLogo() {
        let service = makeService { _ in .vector }
        let item = channel("p", "CA EN: UNIQUE", provider: "https://cdn.example/provider.png")
        XCTAssertNil(service.displayedLogoURL(for: item))
    }

    func testFallbackNameIsTheCleanedChannelName() {
        XCTAssertEqual(LiveTVPrototypeModel.fallbackLogoName(for: lineup()[5]), "CBC CALGARY")
    }

    func testSectionMarkerRowsDoNotCount() {
        let markers = (1...4).map { channel("m\($0)", "##### SPORTS \($0) #####", guide: "https://x/y.png") }
        XCTAssertTrue(LiveTVLogoPlaceholders.placeholders(in: markers).isEmpty)
    }

    private final class MeasuredURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] { lock.withLock { stored } }
        func add(_ url: URL) { lock.withLock { stored.append(url) } }
    }
}
