import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Plozz-like tag matching: tags of one section widen (any), different sections narrow (all); the auto-name follows; "Save as Default" and
/// "Restore Default"; and the "Hockey" rename keeps the stored identifier.
@MainActor
final class LiveTVFilterTagMatchingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveTVFilterTagMatchingTests.\(UUID().uuidString)")
    }

    private func model(store: (any LiveTVFavoriteFilterStoring)? = nil) -> LiveTVPrototypeModel {
        LiveTVPrototypeModel(channels: [
            channel("1", "CA EN: CTV HD", "CA| NEWS EN"), channel("2", "CA EN: CBC HD", "CA| NEWS EN"),
            channel("3", "US EN: CNN 4K", "US| NEWS"), channel("4", "CA EN: TSN 4K", "CA| SPORT"),
            channel("5", "CA FR: AHC", "CA| DOCUMENTARY FR"), channel("6", "UK EN: BBC One", "UK| NEWS")
        ], favoriteFilterStore: store)
    }

    private func channel(_ id: String, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: Int(id) ?? 1, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
            groups: [group])
    }

    func testTagsOfOneSectionWidenAndSectionsNarrow() {
        let model = model()
        let canada = model.matchingChannelCount(tagIDs: ["canada"])
        let us = model.matchingChannelCount(tagIDs: ["united-states"])
        let english = model.matchingChannelCount(tagIDs: ["english"])
        let both = model.matchingChannelCount(tagIDs: ["canada", "united-states"])
        XCTAssertGreaterThan(canada, 0)
        XCTAssertGreaterThan(us, 0)
        XCTAssertEqual(both, canada + us, "Canada or United States: the union of two disjoint sets")
        let englishEitherCountry = model.matchingChannelCount(tagIDs: ["english", "canada", "united-states"])
        XCTAssertLessThanOrEqual(englishEitherCountry, english)
        XCTAssertLessThanOrEqual(englishEitherCountry, both)
        XCTAssertEqual(
            englishEitherCountry, model.matchingChannelCount(tagIDs: ["canada", "english", "united-states"]),
            "the order picked does not change the match")
        XCTAssertGreaterThan(englishEitherCountry, model.matchingChannelCount(tagIDs: ["english", "canada"]),
                             "adding a country widens")
        XCTAssertLessThan(model.matchingChannelCount(tagIDs: ["english", "canada"]), model.matchingChannelCount(tagIDs: ["canada"]) + 1)
    }

    func testGroupsFollowTheMockupsTagGroups() {
        XCTAssertEqual(
            LiveTVFilterTagCatalog.groups(of: ["english", "canada", "united-states"]), [["english"], ["canada", "united-states"]])
        XCTAssertEqual(LiveTVFilterTagCatalog.groups(of: ["canada", "sports", "united-states"]), [["canada", "united-states"], ["sports"]])
        XCTAssertEqual(LiveTVFilterTagCatalog.groups(of: ["not-a-tag"]), [["not-a-tag"]])
        XCTAssertEqual(LiveTVFilterTagCatalog.groups(of: []), [])
    }

    func testAutoNameJoinsSectionsWithDotAndAlternativesWithOr() {
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["english", "canada", "united-states"]), "English · Canada or US")
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["sports", "4k"]), "Sports · 4K", "different sections")
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["canada"]), "Canada")
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: []), "")
    }

    func testLiveTagsWidenWithinTheirSection() {
        let model = model()
        model.toggleFavorite("1")
        let favourites = model.matchingChannelCount(tagIDs: [LiveTVFilterTagCatalog.favouriteChannelsID])
        XCTAssertEqual(favourites, 1)
        let favouriteOrFourK = model.matchingChannelCount(tagIDs: [LiveTVFilterTagCatalog.favouriteChannelsID, "4k"])
        XCTAssertEqual(favouriteOrFourK, 1 + model.matchingChannelCount(tagIDs: ["4k"]), "Favourite Channels or 4K, both in Channels")
    }

    func testHockeyKeepsTheStoredIdentifier() throws {
        let tag = try XCTUnwrap(LiveTVFilterTagCatalog.tags(in: .sport).first { $0.title == "Hockey" })
        XCTAssertEqual(tag.id, "ice-hockey", "saved filters and the channel tagger keep working without a migration")
        XCTAssertNil(LiveTVFilterTagCatalog.all.first { $0.title == "Ice Hockey" })
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["ice-hockey"]), "Hockey")
    }

    // MARK: Defaults

    func testNoDefaultUntilSavedThenItIsOfferedAndRestorable() {
        let model = model(store: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertEqual(model.favoriteFilterDefaultTagIDs, [])
        XCTAssertFalse(model.canSaveFavoriteFilterDefault([]), "nothing to save")
        XCTAssertFalse(model.canRestoreFavoriteFilterDefault(["sports"]), "no default saved")
        XCTAssertTrue(model.canSaveFavoriteFilterDefault(["english", "canada"]))
        XCTAssertTrue(model.saveFavoriteFilterDefault(tagIDs: ["english", "canada", "english", "not-a-tag"]))
        XCTAssertEqual(model.favoriteFilterDefaultTagIDs, ["english", "canada"])
        XCTAssertFalse(model.canSaveFavoriteFilterDefault(["canada", "english"]), "already the default, in any order")
        XCTAssertFalse(model.canRestoreFavoriteFilterDefault(["canada", "english"]), "the draft already is the default")
        XCTAssertTrue(model.canRestoreFavoriteFilterDefault(["sports"]))
    }

    func testDefaultIsPerProfileAndSurvivesARelaunch() {
        let first = model(store: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertTrue(first.saveFavoriteFilterDefault(tagIDs: ["news"]))
        let relaunched = model(store: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p1"))
        XCTAssertEqual(relaunched.favoriteFilterDefaultTagIDs, ["news"])
        let other = model(store: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "p2"))
        XCTAssertEqual(other.favoriteFilterDefaultTagIDs, [], "another profile has its own")
    }

    // MARK: Search narrowing

    func testSearchNarrowsSectionsToMatchingTagsAndHidesSuggested() {
        let model = model()
        let all = model.filterTagSections()
        XCTAssertEqual(all.first?.id, LiveTVFilterTagSection.suggestedID)
        let found = model.filterTagSections(query: "  CAN ")
        XCTAssertFalse(found.contains { $0.id == LiveTVFilterTagSection.suggestedID })
        XCTAssertFalse(found.isEmpty)
        for section in found { for choice in section.tags { XCTAssertTrue(choice.tag.title.lowercased().contains("can"), choice.tag.title) } }
        XCTAssertEqual(model.filterTagSections(query: "zzzzzz"), [])
    }
}
