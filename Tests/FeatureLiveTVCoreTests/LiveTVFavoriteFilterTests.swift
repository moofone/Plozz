import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVFavoriteFilterTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveTVFavoriteFilterTests.\(UUID().uuidString)")
    }

    private func model(favoriteFilterStore: (any LiveTVFavoriteFilterStoring)? = nil) -> LiveTVPrototypeModel {
        LiveTVPrototypeModel(channels: [
            channel("1", "CA EN: CTV HD", ["CA| NEWS EN"]), channel("2", "CA EN: CBC HD", ["CA| NEWS EN"]),
            channel("3", "US EN: CNN 4K", ["US| NEWS ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]), channel("4", "CA EN: TSN 4K", ["CA| SPORT"]),
            channel("5", "CA FR: AHC", ["CA| DOCUMENTARY FR"]),
            channel("6", "#### SPORTSNET ####", ["CA| SPORT"]),
            channel("7", "TSN+ 01 | Leafs vs. Bruins (2026-11-19 21:25:00)", ["CA| TSN+ PPV"])
        ], favoriteFilterStore: favoriteFilterStore)
    }

    /// A store whose profile has already been offered the Debug-only "Canada News" seed and has no filters, so these tests see an empty
    /// profile as a release build does.
    private func unseededStore(namespace: String?) -> LiveTVFavoriteFilterStore {
        let store = LiveTVFavoriteFilterStore(defaults: defaults, namespace: namespace)
        _ = try? store.load(seeding: LiveTVFavoriteFilter(id: "test-seed.canada-news", tagIDs: ["canada", "news"], name: "Canada News"))
        try? store.save([])
        return store
    }

    // MARK: Store: create, edit, order, delete

    func testFirstRunHasNoFilterAndShowsAllChannels() {
        let model = model()
        XCTAssertEqual(model.favoriteFilterList, [])
        XCTAssertNil(model.selectedFavoriteFilterID)
        XCTAssertNil(model.favoriteFilterHeadingTitle)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "2", "3", "4", "5"], "markers and events are not in My Channels")
    }

    /// The picker's name box: a typed name is kept and shown; one that is empty or just the tags' own name keeps following the tags;
    /// renaming alone is a change Save accepts, and an unchanged name is not.
    func testTypedNameIsSavedShownAndCountsAsAChange() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["sports", "4k"], name: "  Match day "))
        XCTAssertEqual(filter.name, "Match day")
        XCTAssertEqual(model.favoriteFilterName(filter), "Match day")
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["sports", "4k"], name: "Match day", editing: filter.id), .unchanged)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["sports", "4k"], name: "Late games", editing: filter.id), .ok)
        XCTAssertTrue(model.updateFavoriteFilter(id: filter.id, tagIDs: ["sports", "4k"], name: "Late games"))
        XCTAssertEqual(model.favoriteFilterList.first?.name, "Late games")
        XCTAssertTrue(model.updateFavoriteFilter(id: filter.id, tagIDs: ["sports", "4k"], name: "Sports · 4K"))
        XCTAssertNil(model.favoriteFilterList.first?.name, "the tags' own name is not stored: it keeps following the tags")
    }

#if DEBUG
    // MARK: Test-only "Canada News" seed

    func testSeedUsesRealCatalogTagsAndIsOfferedOnceAsAnOrdinaryFilter() throws {
        let seed = LiveTVFavoriteFilterTestSeed.filter
        for id in seed.tagIDs { XCTAssertNotNil(LiveTVFilterTagCatalog.tag(id: id), "\(id) is a catalog tag") }
        XCTAssertEqual(Set(seed.tagIDs), ["canada", "news"])
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        let first = model(favoriteFilterStore: store)
        XCTAssertEqual(first.favoriteFilterList.map(\.id), [seed.id])
        XCTAssertEqual(first.favoriteFilterName(first.favoriteFilterList[0]), "Canada News")
        XCTAssertNil(first.selectedFavoriteFilterID, "seeded, not selected: My Channels is still the default")
        // Persisted, so a relaunch reads it back without adding a second.
        XCTAssertEqual(model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults)).favoriteFilterList.map(\.id), [seed.id])
    }

    func testDeletedOrEditedSeedIsNeverReAddedOrOverwritten() throws {
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        let first = model(favoriteFilterStore: store)
        let seedID = LiveTVFavoriteFilterTestSeed.filter.id
        XCTAssertTrue(first.updateFavoriteFilter(id: seedID, tagIDs: ["canada", "sports"], name: "Mine"))
        let edited = model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults))
        XCTAssertEqual(edited.favoriteFilterList.first?.name, "Mine")
        XCTAssertEqual(edited.favoriteFilterList.first?.tagIDs, ["canada", "sports"])
        XCTAssertTrue(edited.deleteFavoriteFilter(id: seedID))
        XCTAssertEqual(model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults)).favoriteFilterList, [], "not re-added")
    }

    func testSeedIsAddedToExistingFiltersOnceAndNotDuplicatedByTheSameTags() throws {
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        try store.save([LiveTVFavoriteFilter(id: "mine", tagIDs: ["kids"])])
        XCTAssertEqual(model(favoriteFilterStore: store).favoriteFilterList.map(\.id), ["mine", LiveTVFavoriteFilterTestSeed.filter.id])
        // A profile that already made the same filter keeps just that one.
        let other = UserDefaults(suiteName: "LiveTVFavoriteFilterTests.\(UUID().uuidString)")!
        let otherStore = LiveTVFavoriteFilterStore(defaults: other)
        try otherStore.save([LiveTVFavoriteFilter(id: "theirs", tagIDs: ["news", "canada"])])
        XCTAssertEqual(model(favoriteFilterStore: otherStore).favoriteFilterList.map(\.id), ["theirs"])
    }

    func testSeedIsPerProfile() throws {
        let a = LiveTVFavoriteFilterStore(defaults: defaults)
        let b = LiveTVFavoriteFilterStore(defaults: defaults, namespace: "profile-2")
        XCTAssertEqual(model(favoriteFilterStore: a).favoriteFilterList.count, 1)
        XCTAssertTrue(model(favoriteFilterStore: a).deleteFavoriteFilter(id: LiveTVFavoriteFilterTestSeed.filter.id))
        XCTAssertEqual(model(favoriteFilterStore: b).favoriteFilterList.count, 1, "the other profile is offered it separately")
    }
#endif

    func testCreateNamesTheFilterFromItsTagsAndRejectsEmptyAndDuplicates() throws {
        let model = model()
        XCTAssertNil(model.createFavoriteFilter(tagIDs: []))
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["sports", "4k"]))
        XCTAssertEqual(model.favoriteFilterName(filter), "Sports · 4K")
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["4k", "sports"]), .duplicate, "same tags in another order")
        XCTAssertNil(model.createFavoriteFilter(tagIDs: ["4k", "sports"]))
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["sports", "4k"], editing: filter.id), .unchanged)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["sports"], editing: filter.id), .ok)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["not-a-tag"]), .noTags, "unknown tags are dropped")
        XCTAssertEqual(model.favoriteFilterList.count, 1)
    }

    // MARK: Save

    func testSavingAFilterStoresItAndItSurvivesARelaunchAndTheCheckRulesDecideWhenSaveIsOn() throws {
        let store = unseededStore(namespace: "p1")
        let model = model(favoriteFilterStore: store)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: []), .noTags, "Save is off with no tags")
        let created = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada", "news"]))
        XCTAssertTrue(model.selectFavoriteFilter(created.id), "the new filter is selected after Save")
        XCTAssertEqual(model.favoriteFilterHeadingTitle, "Canada · News")
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["news", "canada"]), .duplicate)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["canada", "news"], editing: created.id), .unchanged)
        XCTAssertEqual(model.checkFavoriteFilter(tagIDs: ["canada"], editing: created.id), .ok)
        let relaunched = self.model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertEqual(relaunched.favoriteFilterList.map(\.tagIDs), [["canada", "news"]])
        let otherProfile = self.model(favoriteFilterStore: unseededStore(namespace: "p2"))
        XCTAssertEqual(otherProfile.favoriteFilterList, [])
    }

    func testEditMoveAndDeleteKeepOrder() throws {
        let model = model()
        let a = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["news"]))
        let b = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["sports"]))
        let c = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada"]))
        XCTAssertEqual(model.favoriteFilterList.map(\.id), [a.id, b.id, c.id])
        XCTAssertTrue(model.moveFavoriteFilter(id: c.id, .up))
        XCTAssertEqual(model.favoriteFilterList.map(\.id), [a.id, c.id, b.id])
        XCTAssertFalse(model.moveFavoriteFilter(id: a.id, .up), "already first")
        XCTAssertFalse(model.moveFavoriteFilter(id: b.id, .down), "already last")
        XCTAssertTrue(model.updateFavoriteFilter(id: a.id, tagIDs: ["news", "4k"]))
        XCTAssertEqual(model.favoriteFilterList.first?.tagIDs, ["news", "4k"])
        XCTAssertFalse(model.updateFavoriteFilter(id: a.id, tagIDs: ["sports"]), "another filter already has these tags")
        XCTAssertTrue(model.deleteFavoriteFilter(id: c.id))
        XCTAssertEqual(model.favoriteFilterList.map(\.id), [a.id, b.id])
        XCTAssertFalse(model.deleteFavoriteFilter(id: c.id))
    }

    func testFiltersPersistPerProfileAndReload() throws {
        let first = unseededStore(namespace: "p1")
        let model = model(favoriteFilterStore: first)
        _ = model.createFavoriteFilter(tagIDs: ["news"])
        _ = model.createFavoriteFilter(tagIDs: ["sports", "4k"])
        let reloaded = self.model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertEqual(reloaded.favoriteFilterList.map(\.tagIDs), [["news"], ["sports", "4k"]])
        XCTAssertNil(reloaded.selectedFavoriteFilterID, "the selection is a session choice")
        let other = self.model(favoriteFilterStore: unseededStore(namespace: "p2"))
        XCTAssertEqual(other.favoriteFilterList, [], "another profile has its own filters")
    }

    func testFailedSaveLeavesTheListAsItWasAndReportsTheIssue() {
        let store = FailingStore()
        let model = model(favoriteFilterStore: store)
        XCTAssertNil(model.createFavoriteFilter(tagIDs: ["news"]))
        XCTAssertEqual(model.favoriteFilterList, [])
        XCTAssertEqual(model.favoriteFilters.issue, .saveFailed)
    }

    func testUnreadableStoreBlocksChangesInsteadOfOverwriting() {
        defaults.set(Data("junk".utf8), forKey: SettingsKey.scoped("com.plozz.liveTV.favoriteFilters", namespace: "p1"))
        let model = model(favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertEqual(model.favoriteFilters.issue, .loadFailed)
        XCTAssertNil(model.createFavoriteFilter(tagIDs: ["news"]))
    }

    // MARK: Selection drives the guide

    func testSelectingAFilterSetsTheGuideChannelSetAndHeading() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada", "news"]))
        XCTAssertTrue(model.selectFavoriteFilter(filter.id))
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "2"])
        XCTAssertEqual(model.visibleChannels.count, 2)
        XCTAssertEqual(model.favoriteFilterHeadingTitle, "Canada · News")
        XCTAssertEqual(model.favoriteFilterCount(filter), 2)
        XCTAssertTrue(model.selectFavoriteFilter(nil))
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "2", "3", "4", "5"])
        XCTAssertNil(model.favoriteFilterHeadingTitle)
    }

    func testSelectionNeverIncludesSectionMarkers() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["sports"]))
        model.selectFavoriteFilter(filter.id)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["4"], "channel 6 is a ## marker")
        XCTAssertEqual(model.favoriteFilterCount(filter), 1)
    }

    func testAFilterRequiringLiveEventsShowsTheEventsLineupOthersDoNot() throws {
        let model = model()
        let events = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["live-events"]))
        let canada = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada"]))
        model.selectFavoriteFilter(canada.id)
        XCTAssertFalse(model.guideChannels.contains { $0.channel.id == "7" }, "events stay out of an ordinary filter")
        model.selectFavoriteFilter(events.id)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["7"])
    }

    func testSelectingClearsAProviderGroupAndResetFiltersClearsTheSelection() throws {
        let model = model()
        model.category = "CA| NEWS EN"
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada"]))
        model.selectFavoriteFilter(filter.id)
        XCTAssertNil(model.category)
        model.resetFilters()
        XCTAssertNil(model.selectedFavoriteFilterID)
    }

    func testEditingTheSelectedFilterUpdatesTheGuideAndDeletingItReturnsToMyChannels() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada"]))
        model.selectFavoriteFilter(filter.id)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "2", "4", "5"])
        XCTAssertTrue(model.updateFavoriteFilter(id: filter.id, tagIDs: ["canada", "french"]))
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["5"])
        XCTAssertEqual(model.favoriteFilterHeadingTitle, "Canada · French")
        XCTAssertTrue(model.deleteFavoriteFilter(id: filter.id))
        XCTAssertNil(model.selectedFavoriteFilterID)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "2", "3", "4", "5"])
    }

    func testUnknownFilterIDSelectsNothing() {
        let model = model()
        XCTAssertFalse(model.selectFavoriteFilter("missing"))
        XCTAssertNil(model.selectedFavoriteFilterID)
    }

    // MARK: Live tags

    func testFavouriteChannelsTagAndCountsFollowStarring() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["favourite-channels", "news"]))
        XCTAssertEqual(model.favoriteFilterCount(filter), 0)
        model.selectFavoriteFilter(filter.id)
        XCTAssertEqual(model.guideChannels.map(\.channel.id), [])
        model.toggleFavorite("2")
        model.toggleFavorite("4")
        XCTAssertEqual(model.favoriteFilterCount(filter), 1)
        XCTAssertEqual(Set(model.visibleChannels.map(\.id)), ["2"], "the guide follows the stars at once")
        model.toggleFavorite("2")
        XCTAssertEqual(model.visibleChannels.map(\.id), [])
    }

    func testRecentlyWatchedTagFollowsWatching() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["recently-watched"]))
        model.selectFavoriteFilter(filter.id)
        XCTAssertEqual(model.visibleChannels.map(\.id), [])
        model.tune("3")
        XCTAssertTrue(model.recordWatched("3"))
        XCTAssertEqual(model.visibleChannels.map(\.id), ["3"])
        XCTAssertEqual(model.favoriteFilterCount(filter), 1)
    }

    // MARK: Catalogue replacement

    func testSelectionSurvivesACatalogueReplacementAndUsesTheNewLineup() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada", "news"]))
        model.selectFavoriteFilter(filter.id)
        try model.replaceChannels([channel("9", "CA EN: CTV HD", ["CA| NEWS EN"]), channel("8", "US EN: CNN", ["US| NEWS"])])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["9"])
    }

    func testBackgroundPreparedBuildGivesTheSameSelection() async throws {
        let lineup = (1...40).map { channel("\($0)", $0.isMultiple(of: 2) ? "CA EN: CTV \($0) HD" : "US EN: CNN \($0)", [$0.isMultiple(of: 2) ? "CA| NEWS EN" : "US| NEWS"]) }
        let model = LiveTVPrototypeModel(channels: [])
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["canada", "news"]))
        model.selectFavoriteFilter(filter.id)
        await model.prepareCatalog(channels: lineup)
        try model.replaceChannels(lineup)
        XCTAssertEqual(model.preparedInstallCount, 1)
        XCTAssertEqual(Set(model.visibleChannels.map(\.id)), Set(lineup.filter { $0.name.hasPrefix("CA") }.map(\.id)))
    }

    func testGuideCategoriesAddGenreTags() throws {
        let model = model()
        let filter = try XCTUnwrap(model.createFavoriteFilter(tagIDs: ["movies"]))
        model.selectFavoriteFilter(filter.id)
        XCTAssertEqual(model.visibleChannels.map(\.id), [])
        let start = model.now
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "p1", channelID: "5", title: "Film", subtitle: "", start: start, end: start.addingTimeInterval(3_600),
                details: LiveTVProgramDetails(categories: ["Movie"]))
        ])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["5"])
    }

    private func channel(_ id: String, _ name: String, _ groups: [String]) -> LiveTVPrototypeChannel {
        .init(id: id, number: Int(id) ?? 1, name: name, category: groups[0], symbol: "tv", accent: 0,
              source: .iptv, tagline: "", groups: groups)
    }
}

private struct FailingStore: LiveTVFavoriteFilterStoring {
    func load() throws -> [LiveTVFavoriteFilter] { [] }
    func save(_ filters: [LiveTVFavoriteFilter]) throws { throw LiveTVFavoriteFilterStoreError.encodingFailed }
}
