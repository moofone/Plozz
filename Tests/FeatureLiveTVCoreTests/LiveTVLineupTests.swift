import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVLineupTests: XCTestCase {
    private func channel(
        _ id: String, _ name: String, group: String?, country: String? = nil
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: Int(id.filter(\.isNumber)) ?? 0, name: name, category: group ?? "Live", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", country: country, groups: group.map { [$0] })
    }

    private var rows: [LiveTVPrototypeChannel] {
        [
            channel("1", "CA EN: CTV HD", group: "CA| CANADA"),
            channel("2", "CA FR: ICI Radio-Canada", group: "CA| CANADA"),
            channel("3", "US: ESPN", group: "US| SPORTS"),
            channel("4", "UK: BBC One", group: "UK| GENERAL"),
            channel("5", "DE: Das Erste", group: "DE| GERMANY"),
            channel("6", "FR: TF1", group: "FR| FRANCE"),
            channel("7", "Ultra HD Nature", group: "Ultra HD · 24/7"),
            channel("8", "Sport On Air 1", group: "Sport On Air"),
            channel("9", "Mystery", group: nil),
            channel("10", "Late Night", group: "US| XXX Adult"),
            channel("11", "DE: Live Event (2026-11-17 20:00)", group: "DE| PPV EVENTS"),
            channel("12", "ES: Antena 3", group: "ES| SPAIN", country: "ES"),
            channel("13", "Nothing", group: "Elsewhere"),
            channel("14", "Also", group: "Elsewhere")
        ]
    }

    func testStandardLineupIsCanadaUnitedStatesAndUnitedKingdom() {
        XCTAssertEqual(LiveTVLineup.standard.placeIDs, ["CA", "US", "GB"])
        XCTAssertTrue(LiveTVLineup.standard.keepsFavouritesAndRecents)
        XCTAssertTrue(LiveTVLineup.standard.keepsLiveEvents)
        XCTAssertTrue(LiveTVLineup.standard.searchesLeftOut)
        XCTAssertFalse(LiveTVLineup.standard.includesAdult)
        XCTAssertTrue(LiveTVLineup.standard.removedGroupIDs.isEmpty)
    }

    func testFilterKeepsLineupCountriesGroupsWithoutACountryAndEvents() {
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(result.kept.map(\.id), ["1", "2", "3", "4", "7", "8", "9", "11", "13", "14"])
        XCTAssertEqual(result.leftOut.map(\.id), ["5", "6", "10", "12"], "the adult row is left out and searchable by name")
    }

    func testInventoryCountsEveryRowOfTheListIncludingLeftOutCountries() {
        let inventory = LiveTVLineupFilter.apply(.standard, to: rows).inventory
        XCTAssertEqual(inventory.total, 14)
        XCTAssertEqual(inventory.codeCounts["CA"], 2)
        XCTAssertEqual(inventory.codeCounts["DE"], 2)
        XCTAssertEqual(inventory.codeCounts["GB"], 1)
        XCTAssertEqual(inventory.adultCount, 1)
        XCTAssertEqual(inventory.groups.first { $0.id == "Elsewhere" }?.count, 2)
        XCTAssertEqual(inventory.groups.first { $0.id == "" }?.title, "Everything Else")
        XCTAssertEqual(inventory.keptCount(by: .standard), 2 + 1 + 1 + 5, "CA 2, US 1, GB 1, groups: 7, 8, Mystery, 2 Elsewhere")
    }

    func testRemovedGroupAndLiveEventSwitch() {
        var lineup = LiveTVLineup.standard
        lineup.removedGroupIDs = ["Elsewhere"]
        lineup.keepsLiveEvents = false
        let kept = LiveTVLineupFilter.apply(lineup, to: rows).kept.map(\.id)
        XCTAssertFalse(kept.contains("13"))
        XCTAssertFalse(kept.contains("11"))
        XCTAssertTrue(kept.contains("9"))
    }

    func testAGroupsCountryWinsOverANamePrefixThatIsAnotherCountryCode() {
        // "TV" is Tuvalu's ISO code, but "US| TV" is a US group.
        let rows = [channel("1", "TV: Weather Now", group: "US| TV"), channel("2", "CA EN: CTV", group: nil)]
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(result.kept.map(\.id), ["1", "2"])
        XCTAssertEqual(result.inventory.codeCounts, ["US": 1, "CA": 1])
    }

    func testRegionAndCountryChipsAddCountries() {
        let lineup = LiveTVLineup(placeIDs: ["DE", "region.latin-america"])
        XCTAssertTrue(lineup.keeps(code: "DE"))
        XCTAssertTrue(lineup.keeps(code: "MX"))
        XCTAssertFalse(lineup.keeps(code: "CA"))
    }

    func testFavouritesStayWhateverTheirCountry() {
        let keep: Set<String> = ["scoped-6"]
        let result = LiveTVLineupFilter.apply(.standard, to: rows, keepIDs: keep) { "scoped-" + $0.id }
        XCTAssertTrue(result.kept.contains { $0.id == "6" })
        XCTAssertFalse(result.kept.contains { $0.id == "5" })
        var off = LiveTVLineup.standard
        off.keepsFavouritesAndRecents = false
        XCTAssertFalse(LiveTVLineupFilter.apply(off, to: rows, keepIDs: keep) { "scoped-" + $0.id }.kept.contains { $0.id == "6" })
    }

    func testAdultIsNeverLoadedUnlessIncluded() {
        let keep: Set<String> = ["10"]
        XCTAssertFalse(LiveTVLineupFilter.apply(.standard, to: rows, keepIDs: keep).kept.contains { $0.id == "10" })
        var lineup = LiveTVLineup.standard
        lineup.includesAdult = true
        XCTAssertTrue(LiveTVLineupFilter.apply(lineup, to: rows).kept.contains { $0.id == "10" })
    }

    func testSearchFindsALeftOutChannelByNameOnly() {
        let state = LiveTVLineupState(store: nil)
        let result = LiveTVLineupFilter.apply(state.applied, to: rows)
        state.record(inventory: result.inventory, leftOut: result.leftOut)
        XCTAssertEqual(state.leftOutChannels(matching: "tf1").map(\.id), ["6"])
        XCTAssertTrue(state.leftOutChannels(matching: "t").isEmpty, "a single letter is not a search")
        state.toggleKeep(.searchLeftOut)
        XCTAssertTrue(state.apply())
        XCTAssertTrue(state.leftOutChannels(matching: "tf1").isEmpty)
    }

    // MARK: Sheet semantics

    private func state(store: (any LiveTVLineupStoring)? = nil) -> LiveTVLineupState {
        let state = LiveTVLineupState(store: store)
        state.record(inventory: LiveTVLineupFilter.apply(state.applied, to: rows).inventory, leftOut: [])
        return state
    }

    func testNothingChangesUntilApplyAndBackDiscards() {
        let state = state()
        XCTAssertFalse(state.hasChanges)
        state.togglePlace("DE")
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.applied, .standard)
        XCTAssertEqual(state.draftCount, state.inventory.keptCount(by: .standard) + 2)
        state.discard()
        XCTAssertFalse(state.hasChanges)
        state.togglePlace("DE")
        XCTAssertTrue(state.apply())
        XCTAssertTrue(state.applied.placeIDs.contains("DE"))
        XCTAssertFalse(state.apply(), "nothing left to apply")
    }

    func testSectionsAreSortedByCountSearchableAndHideGroupsWhileSearching() {
        let state = state()
        let sections = state.sections()
        XCTAssertEqual(sections.map(\.kind), [.countries, .withoutCountry, .adult].filter { kind in sections.contains { $0.kind == kind } })
        XCTAssertEqual(sections[0].chips.first?.count, 2)
        XCTAssertEqual(sections[0].chips.filter(\.isOn).map(\.id).sorted(), ["CA", "GB", "US"])
        XCTAssertTrue(sections.first { $0.kind == .withoutCountry }?.chips.allSatisfy(\.isOn) == true)
        let found = state.sections(query: "germ")
        XCTAssertEqual(found.map(\.kind), [.countries])
        XCTAssertEqual(found[0].chips.map(\.id), ["DE"])
        XCTAssertTrue(state.sections(query: "zzzz").isEmpty)
    }

    func testAdultCannotBeTurnedOn() {
        let state = state()
        let adult = state.sections().first { $0.kind == .adult }?.chips.first
        XCTAssertNotNil(adult)
        state.toggle(adult!)
        XCTAssertFalse(state.draft.includesAdult)
        XCTAssertFalse(state.isAdultAvailable)
    }

    func testLineupIsPerProfile() throws {
        let defaults = UserDefaults(suiteName: "LiveTVLineupTests.\(UUID().uuidString)")!
        let first = LiveTVLineupState(store: LiveTVLineupStore(defaults: defaults, namespace: "alice"))
        first.togglePlace("DE")
        XCTAssertTrue(first.apply())
        let again = LiveTVLineupState(store: LiveTVLineupStore(defaults: defaults, namespace: "alice"))
        XCTAssertTrue(again.applied.placeIDs.contains("DE"))
        let other = LiveTVLineupState(store: LiveTVLineupStore(defaults: defaults, namespace: "bob"))
        XCTAssertEqual(other.applied, .standard)
    }

    func testUnreadableStoredLineupKeepsStandardAndIsNotOverwritten() {
        let defaults = UserDefaults(suiteName: "LiveTVLineupTests.\(UUID().uuidString)")!
        defaults.set("not data", forKey: "com.plozz.liveTV.lineup")
        let state = LiveTVLineupState(store: LiveTVLineupStore(defaults: defaults))
        XCTAssertTrue(state.storeFailed)
        XCTAssertEqual(state.applied, .standard)
        state.togglePlace("DE")
        XCTAssertFalse(state.apply())
        XCTAssertEqual(defaults.string(forKey: "com.plozz.liveTV.lineup"), "not data")
    }

    func testFavouriteFilterWithAMissingCountryNamesIt() {
        let state = state()
        XCTAssertNil(state.missingCountryNotice(forTagIDs: [LiveTVFilterTagCatalog.tagID("Canada")]))
        XCTAssertEqual(
            state.missingCountryNotice(forTagIDs: [LiveTVFilterTagCatalog.tagID("Germany")]),
            "Germany isn’t in My Channels — add it with Set Up My Channels")
    }

    // MARK: The import cuts before the guide, storage and tags

    func testImportNeverHandsLeftOutRowsToTheGuideOrTheCatalogue() async throws {
        let url = URL(string: "https://example.test/lineup.m3u")!
        let source = LiveTVPlaylistSource(id: "lineup", name: "lineup", playlistURL: url, guideURLs: [URL(string: "https://example.test/g.xml")!])
        let loader = SpyLoader(channels: rows)
        let imports = LiveTVPrototypeImportModel(configuration: .init(playlists: [source]), loader: loader)
        let lineup = LiveTVLineupState(store: nil)
        imports.lineupState = lineup
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let submitted = Set(await loader.submitted.flatMap { $0 })
        XCTAssertEqual(submitted.count, 10, "ten of fourteen rows reach the guide")
        XCTAssertFalse(submitted.contains("DE: Das Erste"))
        XCTAssertTrue(submitted.contains("DE: Live Event (2026-11-17 20:00)"), "events stay")
        XCTAssertEqual(model.channels.count, 10, "every kept row loads")
        XCTAssertEqual(lineup.inventory.total, 14)
        XCTAssertEqual(lineup.leftOut.count, 4)
        XCTAssertFalse(model.channels.contains { $0.name.contains("Das Erste") })
    }
}

private actor SpyLoader: LiveTVSourceLoading {
    let channels: [LiveTVPrototypeChannel]
    private(set) var submitted: [[String]] = []

    init(channels: [LiveTVPrototypeChannel]) { self.channels = channels }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        LiveTVPlaylistImport(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        submitted.append(channels.map(\.name))
        return try LiveTVXMLTVParser().parseXML(data: Data("<tv></tv>".utf8), channels: channels, now: now)
    }
}
