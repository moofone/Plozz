import CoreModels
import Foundation
import XCTest
@testable import AppRuntime

/// Owner policy: final identity data is fetched once and cached forever. These tests drive the
/// index model against a provider that mimics the IPTV catalogue: listing fingerprint, details
/// fetched once, no per-item request for an identified item.
@MainActor
final class IdentityIndexCachePolicyTests: XCTestCase {
    func testSecondLaunchWithUnchangedListingMakesNoRequestsAndNoRebuild() async throws {
        let provider = CachingCatalogProvider(itemCount: 40)
        let store = InMemoryIdentityIndexStore()
        let first = makeModel(provider, store: store)
        first.warmIdentityIndex()
        await first.waitForIdentityWarm()
        let cold = await provider.counts
        XCTAssertEqual(cold.details, 40, "A cold pass fetches each item's details once.")
        XCTAssertGreaterThan(cold.pages, 0)
        XCTAssertEqual(first.identitySnapshot.indexedAccountIDs.count, 1)

        let second = makeModel(provider, store: store)
        second.warmIdentityIndex()
        await second.waitForIdentityWarm()
        let warm = await provider.counts
        XCTAssertEqual(warm.details, cold.details, "Zero detail requests on relaunch.")
        XCTAssertEqual(warm.pages, cold.pages, "Zero index rebuild: no catalogue page was read.")
        XCTAssertEqual(second.identitySnapshot.indexedAccountIDs.count, 1, "The persisted index serves at launch.")
    }

    func testOneNewListingEntryCostsExactlyOneDetailRequest() async throws {
        let provider = CachingCatalogProvider(itemCount: 40)
        let store = InMemoryIdentityIndexStore()
        let first = makeModel(provider, store: store)
        first.warmIdentityIndex()
        await first.waitForIdentityWarm()
        let cold = await provider.counts

        await provider.addListingEntry()
        let second = makeModel(provider, store: store)
        second.warmIdentityIndex()
        await second.waitForIdentityWarm()
        let warm = await provider.counts
        XCTAssertEqual(warm.details - cold.details, 1)
        XCTAssertGreaterThan(warm.pages, cold.pages, "The changed listing is re-read locally.")
    }

    func testListingWithIdentitiesNeedsNoDetailRequests() async throws {
        let provider = CachingCatalogProvider(itemCount: 40, listingCarriesIdentity: true)
        let model = makeModel(provider, store: InMemoryIdentityIndexStore())
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let counts = await provider.counts
        XCTAssertEqual(counts.details, 0)
        XCTAssertEqual(model.identitySnapshot.indexedAccountIDs.count, 1)
    }

    func testRateLimitStopsThePassAtTheFirstRefusal() async throws {
        let provider = CachingCatalogProvider(itemCount: 60)
        await provider.setRateLimited(true)
        let model = makeModel(provider, store: InMemoryIdentityIndexStore())
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let stopped = await provider.counts
        XCTAssertGreaterThan(stopped.details, 0)
        XCTAssertLessThanOrEqual(stopped.details, 5, "Only the bounded in-flight window runs before the stop.")
        XCTAssertTrue(model.identitySnapshot.indexedAccountIDs.isEmpty, "A refused pass is never frozen as complete.")
    }

    func testNoIdentityTrafficWhileALiveStreamIsPlaying() async throws {
        let provider = CachingCatalogProvider(itemCount: 40)
        await provider.setLiveStreamActive(true)
        let model = makeModel(provider, store: InMemoryIdentityIndexStore())
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let counts = await provider.counts
        XCTAssertEqual(counts.details, 0)
        XCTAssertEqual(counts.pages, 0)
    }

    func testManualRebuildClearsDetailsAndRescans() async throws {
        let provider = CachingCatalogProvider(itemCount: 40)
        let store = InMemoryIdentityIndexStore()
        let model = makeModel(provider, store: store)
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let cold = await provider.counts

        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let unchanged = await provider.counts
        XCTAssertEqual(unchanged.details, cold.details)
        XCTAssertEqual(unchanged.pages, cold.pages)

        let accountID = try XCTUnwrap(model.identitySnapshot.indexedAccountIDs.first)
        await model.rebuildLibraryIndex(accountID: accountID)
        await model.waitForIdentityWarm()
        let rebuilt = await provider.counts
        XCTAssertEqual(rebuilt.resets, 1)
        XCTAssertEqual(rebuilt.details - cold.details, 40, "A manual rebuild fetches details again.")
    }

    private func makeModel(_ provider: CachingCatalogProvider, store: InMemoryIdentityIndexStore) -> IdentityIndexModel {
        let account = ResolvedAccount(account: Account(id: "iptv", from: provider.session), provider: provider)
        return IdentityIndexModel(
            activeAccounts: { [account] }, namespace: { "cache-policy" }, onPublish: {},
            persistenceStore: store
        )
    }
}

private actor CachingCatalogProvider: MediaProvider {
    nonisolated let session: UserSession
    nonisolated let kind: ProviderKind = .iptv
    nonisolated let connectionLocality: SourceLocality = .remote
    nonisolated var catalogIdentityRequiresEnrichment: Bool { true }
    private var listing: [Int]
    private var fetched: Set<Int> = []
    private let listingCarriesIdentity: Bool
    private var listingRevision = 1
    private var rateLimited = false
    private var liveActive = false
    private var pages = 0
    private var details = 0
    private var resets = 0

    init(itemCount: Int, listingCarriesIdentity: Bool = false) {
        listing = Array(0..<itemCount)
        self.listingCarriesIdentity = listingCarriesIdentity
        session = UserSession(
            server: .init(id: "iptv", name: "IPTV", baseURL: URL(string: "https://example.invalid")!, provider: .iptv),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    var counts: (pages: Int, details: Int, resets: Int) { (pages, details, resets) }
    func setRateLimited(_ value: Bool) { rateLimited = value }
    func setLiveStreamActive(_ value: Bool) { liveActive = value }
    func addListingEntry() { listing.append((listing.max() ?? -1) + 1); listingRevision += 1 }

    func catalogListingFingerprint() async -> String? { "\(listing.count):\(listingRevision)" }
    func resetCatalogIdentityDetails() async { fetched = []; resets += 1 }
    var hasActiveLiveStream: Bool { get async { liveActive } }

    private func card(_ number: Int) -> MediaItem {
        var item = MediaItem(id: "movie:\(number)", title: "Movie \(number)", kind: .movie)
        if listingCarriesIdentity {
            item.providerIDs = ["Tmdb": "\(number + 1)"]
            item.catalogIdentityIsComplete = true
        } else if fetched.contains(number) {
            item.catalogIdentityIsComplete = true
        }
        return item
    }

    func libraries() async throws -> [MediaLibrary] { [.init(id: "movies", title: "Movies", kind: .movie)] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        pages += 1
        return .init(items: listing.dropFirst(page.startIndex).prefix(page.limit).map(card),
                     startIndex: page.startIndex, totalCount: listing.count)
    }
    func item(id: String) async throws -> MediaItem {
        if rateLimited { details += 1; throw AppError.rateLimited(retryAfter: nil) }
        guard let number = Int(id.dropFirst("movie:".count)) else { throw AppError.notFound }
        if !fetched.contains(number) { details += 1; fetched.insert(number) }
        var item = card(number)
        item.providerIDs = ["Tmdb": "\(number + 1)"]
        return item
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
