import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Your Lineup is applied on every way a provider's list is read: the server lineup (fresh, saved, last seen) before
/// mapping, preparing, publishing or any guide request, not only the playlist import.
@MainActor
final class LiveTVLineupSourcePathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let server = LiveTVServerSource(id: "server-one", name: "IPTV", accountID: "account")

    /// What a real provider list holds: country prefixes on names, "24/7" rows whose country is only in their group,
    /// a country with no prefix at all, and a country that is not in the default lineup.
    private var list: [ServerLiveTVChannel] {
        [
            ServerLiveTVChannel(id: "n1", name: "CA EN: CTV HD", groups: ["CA| CANADA"]),
            ServerLiveTVChannel(id: "n2", name: "US: ESPN", groups: ["US| SPORTS"]),
            ServerLiveTVChannel(id: "n3", name: "24/7: 30 ROCK", groups: ["US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]),
            ServerLiveTVChannel(id: "n4", name: "24/7: Bad Girls", groups: ["UK| 24/7 DRAMA"]),
            ServerLiveTVChannel(id: "n5", name: "DE: Das Erste", groups: ["DE| GERMANY"]),
            ServerLiveTVChannel(id: "n6", name: "FR: TF1", groups: ["FR| FRANCE"]),
            ServerLiveTVChannel(id: "n7", name: "24/7: Le Chef", groups: ["FR| 24/7 CUISINE"]),
            ServerLiveTVChannel(id: "n8", name: "Ultra HD Nature", groups: ["Ultra HD · 24/7"])
        ]
    }

    /// Published display names (the country prefix and quality tags are cleaned off).
    private let keptNames: Set<String> = [
        "CTV", "ESPN", "24/7: 30 ROCK", "24/7: Bad Girls", "Ultra HD Nature"
    ]

    private func authorized(_ provider: LineupServerProvider) -> LiveTVAuthorizedServerProvider {
        LiveTVAuthorizedServerProvider(
            accountID: server.accountID, authorizationID: "profile", kind: .iptv, provider: provider,
            viewerScopeID: "viewer")
    }

    private func imports(
        _ provider: LineupServerProvider, lastSeen: (any LiveTVLastSeenStoring)? = nil
    ) -> (LiveTVPrototypeImportModel, LiveTVLineupState) {
        let context = authorized(provider)
        let model = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context }, lastSeen: lastSeen)
        let lineup = LiveTVLineupState(store: nil)
        model.lineupState = lineup
        return (model, lineup)
    }

    func testServerLineupNeverMapsPreparesOrRequestsGuidesForLeftOutRows() async throws {
        let provider = LineupServerProvider(channels: list)
        let (imports, lineup) = imports(provider)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)

        XCTAssertEqual(Set(model.channels.map(\.name)), keptNames, "only the lineup's rows are published")
        let nativeIDs = Set(imports.serverChannelReferences.values.map(\.channelID))
        XCTAssertEqual(nativeIDs, ["n1", "n2", "n3", "n4", "n8"], "no left-out row is mapped into the catalogue")
        let requested = await provider.requestedGuideChannelIDs
        XCTAssertFalse(requested.isEmpty)
        XCTAssertEqual(Set(requested).count, requested.count)
        XCTAssertEqual(requested.count, 5, "the guide is asked only for kept rows")
        XCTAssertEqual(lineup.inventory.total, 8, "the sheet still counts the whole list")
        XCTAssertEqual(lineup.inventory.codeCounts["FR"], 2)
        XCTAssertEqual(Set(lineup.leftOut.map(\.name)), ["DE: Das Erste", "FR: TF1", "24/7: Le Chef"])
        XCTAssertEqual(imports.serverSources.first?.channelCount, 5)
    }

    func testServerRowsTakeTheirCountryFromTheGroupWhenTheNameHasNone() {
        let result = LiveTVLineupFilter.apply(.standard, to: list)
        XCTAssertTrue(result.kept.contains { $0.name == "24/7: 30 ROCK" }, "US| 24/7 group is the US")
        XCTAssertTrue(result.kept.contains { $0.name == "24/7: Bad Girls" }, "UK| 24/7 group is the UK")
        XCTAssertFalse(result.kept.contains { $0.name == "24/7: Le Chef" }, "FR| 24/7 group is France")
        XCTAssertEqual(result.summary.keptByCountry, ["CA": 1, "US": 2, "GB": 1])
        XCTAssertEqual(result.summary.keptByGroupWithoutCountry, ["Ultra HD · 24/7": 1])
    }

    func testSavedServerCatalogueIsNarrowedToTheLineupBeforeItIsMapped() async throws {
        let provider = LineupServerProvider(channels: list)
        let (imports, lineup) = imports(provider)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.restoreCachedServerCatalogs(into: model)
        XCTAssertEqual(Set(model.channels.map(\.name)), keptNames)
        XCTAssertEqual(Set(imports.serverChannelReferences.values.map(\.channelID)), ["n1", "n2", "n3", "n4", "n8"])
        XCTAssertEqual(lineup.inventory.total, 8)
    }

    func testLastSeenRowsSavedUnderAnEarlierLineupAreNarrowed() async throws {
        let provider = LineupServerProvider(channels: list)
        let context = authorized(provider)
        let catalog = try LiveTVServerCatalog(source: server, context: context, channels: list)
        let entries = zip(list, catalog.channels).map { LiveTVLastSeenSnapshot.Entry(nativeID: $0.id, channel: $1) }
        let snapshot = LiveTVLastSeenSnapshot(
            sources: [.init(sourceID: server.id, accountID: server.accountID, kind: .iptv, entries: entries, viewerScopeID: "viewer")],
            browse: .init(categories: [], categoryCounts: [:], totalCount: entries.count))
        let started = expectation(description: "Lineup read suspended")
        let suspended = LineupServerProvider(channels: list, suspendsChannels: started)
        let (imports, _) = imports(suspended, lastSeen: LineupLastSeenStore(snapshot))
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model, forceServerRefresh: false) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(Set(model.channels.map(\.name)), keptNames, "the last-seen rows are cut to the lineup")
        await suspended.resume()
        await task.value
    }

    func testOnlyEventsThatAreOnAreKeptNotIdleSlotsOrNamesThatMentionEvents() {
        let rows = [
            ServerLiveTVChannel(id: "e1", name: "DE: Live Event (2026-11-17 20:00:00)", groups: ["DE| PPV"]),
            ServerLiveTVChannel(id: "e2", name: "- NO EVENT STREAMING - ESPN+ 14", groups: ["DE| PPV"]),
            ServerLiveTVChannel(id: "e3", name: "NO EVENT STREAMING", groups: ["DE| PPV"]),
            ServerLiveTVChannel(id: "e4", name: "DE: Event Horizon TV", groups: ["DE| Documentaries"])
        ]
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(result.kept.map(\.id), ["e1"], "an idle slot or a channel that only says 'event' is not an event to keep")
        XCTAssertEqual(result.summary.keptAlways, 1)
    }

    func testAppliedLogLineNamesWhyRowsWereKeptAndDropped() {
        let result = LiveTVLineupFilter.apply(.standard, to: list)
        let fields = result.summary.logFields(source: "iptv")
        XCTAssertTrue(fields.contains("source=iptv read=8 kept=5 dropped=3"), fields)
        XCTAssertTrue(fields.contains("byReason=country:4,region:0,nocountry:1,always:0,adult:0"), fields)
        XCTAssertTrue(fields.contains("US=2"), fields)
        XCTAssertFalse(fields.contains("http"), "no URL is ever logged")
    }
}

private final class LineupLastSeenStore: LiveTVLastSeenStoring, @unchecked Sendable {
    private let snapshot: LiveTVLastSeenSnapshot
    init(_ snapshot: LiveTVLastSeenSnapshot) { self.snapshot = snapshot }
    func load() -> LiveTVLastSeenSnapshot? { snapshot }
    func save(_ snapshot: LiveTVLastSeenSnapshot?) {}
}

private actor LineupServerProvider: ServerLiveTVProviding {
    let channels: [ServerLiveTVChannel]
    private let suspendsChannels: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestedGuideChannelIDs: [String] = []

    init(channels: [ServerLiveTVChannel], suspendsChannels: XCTestExpectation? = nil) {
        self.channels = channels
        self.suspendsChannels = suspendsChannels
    }

    func resume() { continuation?.resume(); continuation = nil }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        ServerLiveTVAvailability(status: .available, channelCount: channels.count)
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        if let suspendsChannels {
            await withCheckedContinuation { continuation = $0; suspendsChannels.fulfill() }
        }
        return channels
    }

    func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot? {
        .init(channels: channels, supportsGuide: true)
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        requestedGuideChannelIDs += channelIDs
        return []
    }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        throw ServerLiveTVError.unsupportedPlaybackMode
    }
}
