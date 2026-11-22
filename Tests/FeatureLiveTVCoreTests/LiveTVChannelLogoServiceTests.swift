import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVChannelLogoServiceTests: XCTestCase {
    /// Gzip of 13 TMDB networks including CBC, CTV, Global TV and Global News.
    private static let networkExport = Data(base64Encoded: "H4sIAAAAAAAC/6tWykxRslIwMtZRUMpLzE0FspWcnZwVQlJzUssyizPz85RquaohigwNDZBVhYQhpCyNLExwyRkZGKIajiRlamKBS87EwBiniZYGljjlDJFNdM/JT0rMUUBWYGaOZq6CX2p5sYJzRmJeXmoOQp2FhbEJpkkgtUiWISlwRHa8GZKEH4qPTcyM0OUAHmQrsIQBAAA=")!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVChannelLogoServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var requests: [String] { lock.withLock { paths } }
        func record(_ path: String) { lock.withLock { paths.append(path) } }
    }

    private final class AccessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TMDbAccess
        init(_ value: TMDbAccess) { self.value = value }
        var current: TMDbAccess { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private final class Published: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [LiveTVChannelLogoKey: URL] = [:]
        var urls: [LiveTVChannelLogoKey: URL] { lock.withLock { all } }
        func add(_ urls: [LiveTVChannelLogoKey: URL]) { lock.withLock { all.merge(urls) { $1 } } }
    }

    static let wikidataAnswer = Data(#"""
    {"results":{"bindings":[
      {"item":{"value":"http://www.wikidata.org/entity/Q5"},"itemLabel":{"value":"Citytv"},
       "logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/Citytv%20logo.svg"},"alts":{"value":""}}
    ]}}
    """#.utf8)

    private func makeService(
        access: AccessBox, counter: Counter, failTMDB: Bool = false,
        wikidataStatus: Int = 500, wikidataBody: Data = Data()
    ) -> LiveTVChannelLogoService {
        let store = LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("logos.json"))
        let networks = TMDbNetworkDirectory(
            fileURL: directory.appendingPathComponent("networks.json"),
            fetch: { _ in
                counter.record("directory")
                return Self.networkExport
            },
            now: { Date(timeIntervalSince1970: 1_794_050_400) }
        )
        let http = MetadataDiscoveryHTTPClient(send: { request in
            let url = request.url!
            counter.record(url.path)
            if failTMDB { throw URLError(.notConnectedToInternet) }
            let body: String
            switch url.path {
            case "/3/network/110": body = #"{"id":110,"name":"CTV","origin_country":"CA"}"#
            case "/3/network/110/images": body = #"{"id":110,"logos":[{"file_path":"/ctv.png","width":1000,"height":500,"file_type":".png","vote_average":1}]}"#
            case "/3/network/9284": body = #"{"id":9284,"name":"CTV","origin_country":""}"#
            case "/3/network/9284/images": body = #"{"id":9284,"logos":[{"file_path":"/other.png","width":10,"height":5,"file_type":".png","vote_average":1}]}"#
            case "/3/network/403": body = #"{"id":403,"name":"CTV","origin_country":"TW"}"#
            case "/3/network/403/images": body = #"{"id":403,"logos":[]}"#
            case "/3/network/2909": body = #"{"id":2909,"name":"CTV","origin_country":"BY"}"#
            case "/3/network/2909/images": body = #"{"id":2909,"logos":[]}"#
            default: body = "{}"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
        return LiveTVChannelLogoService(
            store: store, directory: networks,
            wikidata: WikidataLogoDirectory(
                fileURL: directory.appendingPathComponent("wikidata.json"),
                fetch: { request in
                    counter.record("wikidata")
                    return (wikidataBody, wikidataStatus)
                },
                now: { Date(timeIntervalSince1970: 1_794_050_400) }, sleep: { _ in }
            ),
            accessProvider: { access.current }, http: http
        )
    }

    private func channel(
        id: String = "ch-1", name: String = "CA EN: CTV CALGARY", source: LiveTVPrototypeSource = .iptv,
        logoURL: URL? = URL(string: "https://provider.example/ctv.png")
    ) -> LiveTVPrototypeChannel {
        .init(
            id: id, number: 1, name: name, category: "News", symbol: "tv", accent: 0, source: source,
            tagline: "", logoURL: logoURL, playlistSourceID: "playlist-1", groups: ["CA|Local"]
        )
    }

    private func resolve(_ service: LiveTVChannelLogoService, _ channels: [LiveTVPrototypeChannel]) async -> [LiveTVChannelLogoKey: URL] {
        let published = Published()
        await service.resolve(channels.map(LiveTVLogoRequest.init(channel:))) { published.add($0) }
        return published.urls
    }

    private final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[LiveTVChannelLogoKey: URL]] = []
        var list: [[LiveTVChannelLogoKey: URL]] { lock.withLock { all } }
        func add(_ urls: [LiveTVChannelLogoKey: URL]) { lock.withLock { all.append(urls) } }
    }

    func testVisibleChannelsAreResolvedInTheFirstBatchOfALargeCatalog() async throws {
        let counter = Counter()
        let service = makeService(access: AccessBox(.directToken("token")), counter: counter)
        let visible = (0..<20).map { channel(id: "visible-\($0)", name: "CA EN: CTV CALGARY") }
        let rest = (0..<20_000).map { channel(id: "rest-\($0)", name: "ZZ\($0) UNKNOWN") }
        let ordered = LiveTVPrototypeModel.logoPriorityOrder(
            channels: rest + visible, visible: visible, favoriteIDs: ["rest-5"]
        )
        XCTAssertEqual(ordered.prefix(20).map(\.id), visible.map(\.id))
        XCTAssertEqual(ordered[20].id, "rest-5")
        XCTAssertEqual(ordered.count, 20_020)

        let batches = Batches()
        let task = Task { await service.resolve(ordered.prefix(300).map(LiveTVLogoRequest.init(channel:))) { batches.add($0) } }
        await task.value
        let first = try XCTUnwrap(batches.list.first)
        XCTAssertEqual(Set(first.keys), Set(visible.map(LiveTVChannelLogoKey.init(channel:))), "the first batch holds the visible rows")
    }

    func testTMDBMatchWinsOverTheProviderLogoAndIsStored() async throws {
        let counter = Counter()
        let service = makeService(access: AccessBox(.userToken("t")), counter: counter)
        let item = channel()
        let urls = await resolve(service, [item])
        XCTAssertEqual(urls[LiveTVChannelLogoKey(channel: item)]?.absoluteString, "https://image.tmdb.org/t/p/original/ctv.png")
        XCTAssertEqual(service.displayedLogoURL(for: item)?.absoluteString, "https://image.tmdb.org/t/p/original/ctv.png")
    }

    func testMatchesAreRequestedOnceAndSurviveRelaunch() async throws {
        let counter = Counter()
        let access = AccessBox(.userToken("t"))
        let first = makeService(access: access, counter: counter)
        let item = channel()
        _ = await resolve(first, [item])
        let requestsAfterFirst = counter.requests.count
        first.store.flush()
        let second = makeService(access: access, counter: counter)
        let urls = await resolve(second, [item])
        XCTAssertEqual(counter.requests.count, requestsAfterFirst, "no repeat TMDB or directory requests")
        XCTAssertNotNil(urls[LiveTVChannelLogoKey(channel: item)])
    }

    func testUserOverrideBeatsTMDBAndTheProviderAndResetRestoresAutomatic() async throws {
        let service = makeService(access: AccessBox(.userToken("t")), counter: Counter())
        let item = channel()
        _ = await resolve(service, [item])
        let chosen = try XCTUnwrap(service.chooseURL("https://example.com/mine.png", for: LiveTVChannelLogoKey(channel: item)))
        XCTAssertEqual(service.displayedLogoURL(for: item), chosen)
        let restored = service.resetOverride(for: LiveTVChannelLogoIdentity(channel: item))
        XCTAssertEqual(restored?.absoluteString, "https://image.tmdb.org/t/p/original/ctv.png")
    }

    func testDisabledAccessMakesNoRequestsAndIgnoresStoredMatches() async throws {
        let counter = Counter()
        let access = AccessBox(.userToken("t"))
        let service = makeService(access: access, counter: counter)
        let item = channel()
        _ = await resolve(service, [item])
        let requests = counter.requests.filter { $0 != "wikidata" }.count
        access.current = .disabled
        let urls = await resolve(service, [item])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertEqual(counter.requests.filter { $0 != "wikidata" }.count, requests, "no TMDB request once access is off")
        XCTAssertNil(service.displayedLogoURL(for: item), "the provider logo is never the fallback; the name is drawn")
    }

    func testOverrideStillAppliesWithoutTMDBAccess() async throws {
        let service = makeService(access: AccessBox(.disabled), counter: Counter())
        let item = channel()
        let chosen = try XCTUnwrap(service.chooseURL("https://example.com/mine.png", for: LiveTVChannelLogoKey(channel: item)))
        let urls = await resolve(service, [item])
        XCTAssertEqual(urls[LiveTVChannelLogoKey(channel: item)], chosen)
    }

    func testTMDBFailureStoresNothingSoTheChannelIsRetried() async throws {
        let counter = Counter()
        let access = AccessBox(.userToken("t"))
        let failing = makeService(access: access, counter: counter, failTMDB: true)
        let item = channel()
        let urls = await resolve(failing, [item])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertNil(failing.store.match(for: LiveTVChannelLogoIdentity(channel: item)))
        let working = makeService(access: access, counter: Counter())
        let retried = await resolve(working, [item])
        XCTAssertNotNil(retried[LiveTVChannelLogoKey(channel: item)])
    }

    func testProviderChannelsOtherThanIPTVAreNotMatchedAutomatically() async {
        let counter = Counter()
        let service = makeService(access: AccessBox(.userToken("t")), counter: counter)
        let urls = await resolve(service, [channel(source: .jellyfin)])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertFalse(counter.requests.contains { $0.hasPrefix("/3/network") })
    }

    func testChoosingAnInvalidURLChangesNothing() {
        let service = makeService(access: AccessBox(.disabled), counter: Counter())
        let item = channel()
        XCTAssertNil(service.chooseURL("file:///etc/passwd", for: LiveTVChannelLogoKey(channel: item)))
        XCTAssertFalse(service.store.hasOverride(LiveTVChannelLogoKey(channel: item)))
    }

    func testSearchNeedsNoKey() async {
        let service = makeService(access: AccessBox(.disabled), counter: Counter())
        let results = await service.searchNetworks("global")
        XCTAssertEqual(Set(results.map(\.entry.name)), ["Global TV", "Global News"])
    }

    func testWikidataLogoIsUsedWithoutAnyTMDBKey() async throws {
        let counter = Counter()
        let service = makeService(access: AccessBox(.disabled), counter: counter, wikidataStatus: 200, wikidataBody: Self.wikidataAnswer)
        let item = channel(name: "CA EN: CITYTV TORONTO")
        let urls = await resolve(service, [item])
        XCTAssertEqual(
            urls[LiveTVChannelLogoKey(channel: item)]?.absoluteString,
            "https://commons.wikimedia.org/wiki/Special:FilePath/Citytv%20logo.svg?width=704"
        )
        XCTAssertFalse(counter.requests.contains { $0.hasPrefix("/3/") }, "no TMDB request without a key")
    }

    func testTMDBMatchTakesPrecedenceOverWikidata() async throws {
        let service = makeService(access: AccessBox(.userToken("t")), counter: Counter(), wikidataStatus: 200, wikidataBody: Self.wikidataAnswer)
        let item = channel()
        let urls = await resolve(service, [item])
        XCTAssertEqual(urls[LiveTVChannelLogoKey(channel: item)]?.absoluteString, "https://image.tmdb.org/t/p/original/ctv.png")
    }

    func testWikidataFailureStoresNothingAndDrawsTheName() async throws {
        let service = makeService(access: AccessBox(.disabled), counter: Counter())
        let item = channel(name: "CA EN: CITYTV TORONTO")
        let urls = await resolve(service, [item])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertNil(service.displayedLogoURL(for: item))
    }

    static let leagueAnswer = Data(#"""
    {"results":{"bindings":[
      {"item":{"value":"http://www.wikidata.org/entity/Q1215892"},"itemLabel":{"value":"National Hockey League"},
       "logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/NHL%20shield.svg"},"alts":{"value":""}}
    ]}}
    """#.utf8)

    func testLeagueTaggedEventChannelGetsTheWikidataLeagueBadgeWithoutAKey() async throws {
        let service = makeService(access: AccessBox(.disabled), counter: Counter(), wikidataStatus: 200, wikidataBody: Self.leagueAnswer)
        let event = channel(id: "ev", name: "(Apple) (NHL) 004 |  Toronto vs. Boston  (2026-11-19 21:25:00)")
        let urls = await resolve(service, [event])
        XCTAssertEqual(
            urls[LiveTVChannelLogoKey(channel: event)]?.absoluteString,
            "https://commons.wikimedia.org/wiki/Special:FilePath/NHL%20shield.svg?width=704"
        )
    }

    func testEventChannelKeepsItsGlyphWhenTheLeagueLookupFails() async throws {
        let service = makeService(access: AccessBox(.disabled), counter: Counter())
        let event = channel(id: "ev", name: "(Apple) (NHL) 004 |  Toronto vs. Boston  (2026-11-19 21:25:00)")
        let urls = await resolve(service, [event])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertNil(service.store.wikidataMatch(for: LiveTVChannelLogoIdentity(channel: event)), "a failure stores nothing")
    }

    func testUserOverrideBeatsTheLeagueBadge() async throws {
        let service = makeService(access: AccessBox(.disabled), counter: Counter(), wikidataStatus: 200, wikidataBody: Self.leagueAnswer)
        let event = channel(id: "ev", name: "(Apple) (NHL) 004 |  Toronto vs. Boston  (2026-11-19 21:25:00)")
        let mine = URL(string: "https://example.com/mine.png")!
        service.store.setOverride(.url(mine), for: LiveTVChannelLogoKey(channel: event))
        _ = await resolve(service, [event])
        XCTAssertEqual(service.displayedLogoURL(for: event), mine)
    }

    func testBelarusianCTVDoesNotMatchACanadianChannel() async throws {
        let body = Data(#"""
        {"results":{"bindings":[
          {"item":{"value":"http://www.wikidata.org/entity/Q3918845"},"itemLabel":{"value":"CTV"},
           "logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/Belarus%20CTV.svg"},"alts":{"value":""}}
        ]}}
        """#.utf8)
        // A US-tagged channel must not use the Canadian list, and a country with no list is never matched.
        let service = makeService(access: AccessBox(.disabled), counter: Counter(), wikidataStatus: 200, wikidataBody: body)
        let other = LiveTVPrototypeChannel(
            id: "by", number: 2, name: "BY: CTV", category: "News", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", logoURL: nil, playlistSourceID: "playlist-1", groups: ["BY|News"]
        )
        let urls = await resolve(service, [other])
        XCTAssertTrue(urls.isEmpty)
    }
}
