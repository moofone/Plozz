import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

/// Final per-item details are fetched once and cached; only a changed listing entry or a manual
/// rebuild fetches them again. The stub transport counts the real requests.
final class IPTVIdentityCacheTests: XCTestCase {
    private final class Listing: @unchecked Sendable {
        private let lock = NSLock()
        private var moviesJSON: String
        private var seriesJSON: String
        init(movies: String, series: String) { moviesJSON = movies; seriesJSON = series }
        var movies: String { get { lock.withLock { moviesJSON } } set { lock.withLock { moviesJSON = newValue } } }
        var series: String { get { lock.withLock { seriesJSON } } set { lock.withLock { seriesJSON = newValue } } }
    }

    private static let baseMovies = #"[{"stream_id":"20","name":"Tagged","tmdb":"123","added":"10"},{"stream_id":"21","name":"Untagged","added":"11"}]"#
    private static let baseSeries = #"[{"series_id":30,"name":"Show","last_modified":"100"}]"#

    private var root: URL!
    private var credential: IPTVCredential!
    private var listing: Listing!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        listing = Listing(movies: Self.baseMovies, series: Self.baseSeries)
        // One credential identity names the catalogue file, so a relaunch reuses the same cache.
        credential = try! IPTVCredential(
            mode: .xtream, address: URL(string: "https://provider.test")!,
            username: "fixture-user", password: "fixture-password"
        )
        IPTVFixture.state.reset()
        let listing = listing!
        IPTVFixture.state.handler = { request in
            let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            let action = components.queryItems?.first { $0.name == "action" }?.value
            let payload: String
            switch action {
            case nil: payload = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8"]}}"#
            case "get_vod_categories", "get_series_categories", "get_live_categories": payload = "[]"
            case "get_vod_streams": payload = listing.movies
            case "get_series": payload = listing.series
            case "get_live_streams": payload = "[]"
            case "get_vod_info": payload = #"{"info":{"plot":"Plot","tmdb_id":"555"},"movie_data":{"container_extension":"mkv"}}"#
            case "get_series_info":
                payload = #"{"info":{"plot":"Series plot"},"episodes":{"1":[{"id":31,"episode_num":1,"title":"Pilot","container_extension":"mp4"}]}}"#
            default: throw URLError(.unsupportedURL)
            }
            return (200, ["Content-Type": "application/json"], Data(payload.utf8))
        }
    }

    override func tearDown() {
        IPTVFixture.state.reset()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeClient() throws -> IPTVClient {
        try IPTVClient(credential: credential, directory: root, configuration: IPTVFixture.configuration())
    }

    private func requests(_ action: String) -> Int {
        IPTVFixture.state.requests.filter { $0.url?.query?.contains("action=\(action)") == true }.count
    }

    private func movies(_ client: IPTVClient) async throws -> [MediaItem] {
        try await client.page(library: "movies", kind: .movie, page: .init(limit: 50)).items
    }

    func testListingIDIsIdentityCompleteWithoutAnyDetailRequest() async throws {
        let client = try makeClient()
        let items = try await movies(client)
        XCTAssertEqual(items.first { $0.id == "movie:20" }?.catalogIdentityIsComplete, true)
        XCTAssertEqual(items.first { $0.id == "movie:21" }?.catalogIdentityIsComplete, false)
        XCTAssertEqual(requests("get_vod_info"), 0)
    }

    func testDetailsAreFetchedOnceAcrossRepeatsRelaunchAndListingRefetch() async throws {
        let client = try makeClient()
        _ = try await movies(client)
        let first = try await client.record("movie:21", details: true)
        XCTAssertEqual(first.item.providerIDs["tmdb"], "555")
        _ = try await client.record("movie:21", details: true)
        XCTAssertEqual(requests("get_vod_info"), 1)
        let fetched = try await movies(client)
        XCTAssertEqual(fetched.first { $0.id == "movie:21" }?.catalogIdentityIsComplete, true)

        // Relaunch: a new client over the same cache directory, listing refetched unchanged.
        let relaunched = try makeClient()
        try await relaunched.ensureCatalog("movies", force: true)
        let again = try await relaunched.record("movie:21", details: true)
        XCTAssertEqual(again.item.providerIDs["tmdb"], "555", "Stored details survive an unchanged listing refetch.")
        XCTAssertEqual(requests("get_vod_info"), 1)
        XCTAssertEqual(requests("get_vod_streams"), 2)
    }

    func testNewListingEntryCostsExactlyOneDetailRequest() async throws {
        let client = try makeClient()
        _ = try await movies(client)
        _ = try await client.record("movie:21", details: true)
        XCTAssertEqual(requests("get_vod_info"), 1)

        listing.movies = #"[{"stream_id":"20","name":"Tagged","tmdb":"123","added":"10"},{"stream_id":"21","name":"Untagged","added":"11"},{"stream_id":"22","name":"New","added":"12"}]"#
        try await client.ensureCatalog("movies", force: true)
        let items = try await movies(client)
        XCTAssertEqual(items.count, 3)
        // The index pass reads only locally derived completeness; the one new item needs details.
        XCTAssertEqual(items.filter { !$0.catalogIdentityIsComplete }.map(\.id), ["movie:22"])
        _ = try await client.record("movie:22", details: true)
        _ = try await client.record("movie:21", details: true)
        _ = try await client.record("movie:20", details: true)
        XCTAssertEqual(requests("get_vod_info"), 3, "movie 21 stays cached; the new item and the display-only tagged item fetch once each.")
    }

    func testChangedListingEntryIsDerivedAgain() async throws {
        let client = try makeClient()
        _ = try await movies(client)
        _ = try await client.record("movie:21", details: true)
        listing.movies = #"[{"stream_id":"20","name":"Tagged","tmdb":"123","added":"10"},{"stream_id":"21","name":"Untagged 2","added":"11"}]"#
        try await client.ensureCatalog("movies", force: true)
        _ = try await client.record("movie:21", details: true)
        XCTAssertEqual(requests("get_vod_info"), 2)
    }

    func testSeriesInfoIsFetchedOnceUntilItsListingEntryChanges() async throws {
        let client = try makeClient()
        let seasons = try await client.children("series:30")
        XCTAssertEqual(seasons.map(\.id), ["season:30:1"])
        _ = try await client.children(seasons[0].id)
        _ = try await client.children("series:30")
        XCTAssertEqual(requests("get_series_info"), 1, "Hero and detail reads serve the stored episodes.")

        let relaunched = try makeClient()
        try await relaunched.ensureCatalog("series", force: true)
        let episodes = try await relaunched.children("season:30:1")
        XCTAssertEqual(episodes.map(\.id), ["episode:30:31"], "Episodes survive an unchanged listing refetch.")
        XCTAssertEqual(requests("get_series_info"), 1)

        listing.series = #"[{"series_id":30,"name":"Show","last_modified":"200"}]"#
        try await relaunched.ensureCatalog("series", force: true)
        _ = try await relaunched.children("series:30")
        XCTAssertEqual(requests("get_series_info"), 2)
    }

    func testListingFingerprintChangesOnlyWhenTheListingDoes() async throws {
        let client = try makeClient()
        _ = try await movies(client)
        _ = try await client.page(library: "series", kind: .series, page: .init(limit: 50))
        let first = try await client.listingFingerprint()
        XCTAssertNotNil(first)
        try await client.ensureCatalog("movies", force: true)
        let unchanged = try await client.listingFingerprint()
        XCTAssertEqual(first, unchanged)
        listing.movies = Self.baseMovies.replacingOccurrences(of: "Untagged", with: "Renamed")
        try await client.ensureCatalog("movies", force: true)
        let changed = try await client.listingFingerprint()
        XCTAssertNotEqual(first, changed)
    }

    func testManualRebuildFetchesDetailsAgain() async throws {
        let client = try makeClient()
        _ = try await movies(client)
        _ = try await client.record("movie:21", details: true)
        let fingerprint = try await client.listingFingerprint()
        XCTAssertNotNil(fingerprint)
        try await client.forgetFetchedDetails()
        let cleared = try await client.listingFingerprint()
        XCTAssertNil(cleared)
        _ = try await client.record("movie:21", details: true)
        XCTAssertEqual(requests("get_vod_info"), 2)
    }
}
