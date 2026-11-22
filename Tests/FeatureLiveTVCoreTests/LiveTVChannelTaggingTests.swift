import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Tag derivation on rows copied from the provider export (`channels-ca-us-full.json`), through the model so that the
/// name's prefix has filled country and language as it does in the app.
@MainActor
final class LiveTVChannelTaggingTests: XCTestCase {
    private func tags(_ name: String, groups: [String] = [], measured: LiveChannelResolutionLabel? = nil) -> Set<String> {
        let model = LiveTVPrototypeModel(channels: [channel("a", name, groups: groups)])
        let named = model.channel(id: "a")!
        return Set(LiveTVChannelTagIndex.storedTagIDs(of: named, measured: measured))
    }

    func testCanadianEnglishChannelGetsCountryLanguageAndNetwork() {
        let result = tags("CA EN: CTV HD", groups: ["CA| CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertTrue(result.isSuperset(of: ["canada", "english", "ctv"]), "\(result)")
        XCTAssertFalse(result.contains("4k"))
    }

    func testFrenchCanadianChannel() {
        let result = tags("CA FR: AHC", groups: ["CA| DOCUMENTARY FR"])
        XCTAssertTrue(result.isSuperset(of: ["canada", "french", "documentary"]), "\(result)")
    }

    func testProviderGroupGivesTheGenreOnce() {
        XCTAssertTrue(tags("CA EN: CBC EDMONTON HD", groups: ["CA| KIDS EN"]).isSuperset(of: ["kids", "cbc"]))
        XCTAssertTrue(tags("CA EN: CTV CALARY NEWS", groups: ["CA| NEWS EN"]).contains("news"))
        XCTAssertTrue(tags("CA EN: CBC CALGARY HD", groups: ["CA| GENERAL EN"]).contains("entertainment"))
        XCTAssertTrue(tags("US EN: X", groups: ["US| 24/7 KIDS/FAMILY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]).isSuperset(of: ["kids", "family", "24-7"]))
    }

    func testSportsGroupsGiveSportsAndTheSport() {
        let result = tags("CA EN: TSN 1 HD", groups: ["CA| TSN SPORT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertTrue(result.isSuperset(of: ["sports", "tsn"]), "\(result)")
        XCTAssertTrue(tags("US: NHL NETWORK", groups: ["US| SPORT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]).isSuperset(of: ["sports", "ice-hockey"]))
        XCTAssertTrue(tags("US: SOMETHING | Arsenal vs Chelsea", groups: ["CA| SOCCER PPV"]).isSuperset(of: ["sports", "football", "pay-per-view"]))
        XCTAssertTrue(tags("US: GOLF CHANNEL").isSuperset(of: ["sports", "golf"]))
    }

    func testLeagueEventRowsGetTheirSportAndLiveEvents() {
        let result = tags("(Apple) (MLS) 004 |  Seattle vs. Salt Lake  (2026-11-19 21:25:00)", groups: ["US| MLS PPV ⁽ᴮᴷ⁾"])
        XCTAssertTrue(result.isSuperset(of: ["live-events", "football", "sports", "pay-per-view"]), "\(result)")
    }

    func testEventSportComesFromTheCompetitionInTheTitle() {
        let result = tags("Peacock 012 | Premier League: Arsenal vs Chelsea (2026-11-19 21:25:00)", groups: ["US| PEACOCK PPV ⱽᴵᴾ"])
        XCTAssertTrue(result.isSuperset(of: ["live-events", "football", "sports"]), "\(result)")
        XCTAssertFalse(tags("Premier League: Arsenal vs Chelsea").contains("live-events"))
    }

    func testRadioComesFromTheGroupNotAChannelNamedRadioCanada() {
        XCTAssertFalse(tags("CA FR: ICI RADIO CANADA TELE MONCTON HD", groups: ["CA| DOCUMENTARY FR"]).contains("radio"))
        XCTAssertTrue(tags("Some Station", groups: ["UK| RADIO"]).contains("radio"))
    }

    func testUltraHDFollowsTheNameClaimAndTheMeasuredResolution() {
        XCTAssertTrue(tags("US EN: MOVIES 4K").contains("4k"))
        XCTAssertTrue(tags("US EN: MOVIES UHD").contains("4k"))
        XCTAssertFalse(tags("US EN: MOVIES HD").contains("4k"))
        XCTAssertFalse(tags("US EN: MOVIES 4K", measured: .fullHD).contains("4k"), "measured below 2000 lines removes the claim")
        XCTAssertTrue(tags("US EN: MOVIES", measured: .ultraHD).contains("4k"), "measured 4K counts without the tag")
    }

    func testProviderCountryAndLanguageNamesAndCodesAreRead() {
        let model = LiveTVPrototypeModel(channels: [
            channel("a", "Plain", country: "United Kingdom", language: "eng"),
            channel("b", "Plain", country: "UK;IE", language: "Arabic"),
            channel("c", "Plain", country: "SA")
        ])
        XCTAssertTrue(Set(LiveTVChannelTagIndex.storedTagIDs(of: model.channel(id: "a")!)).isSuperset(of: ["united-kingdom", "english"]))
        XCTAssertTrue(Set(LiveTVChannelTagIndex.storedTagIDs(of: model.channel(id: "b")!)).isSuperset(of: ["united-kingdom", "ireland", "arabic"]))
        XCTAssertTrue(Set(LiveTVChannelTagIndex.storedTagIDs(of: model.channel(id: "c")!)).isSuperset(of: ["saudi-arabia", "arabic"]))
    }

    func testSectionMarkersCarryNoTags() {
        let marker = channel("m", "##### TSN SPORT ᴿᴬᵂ ⁶⁰ᶠᵖˢ #####", groups: ["CA| TSN SPORT ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertTrue(marker.isSectionMarker)
        XCTAssertEqual(LiveTVChannelTagIndex.storedTagIDs(of: marker), [])
    }

    func testGuideCategoriesVoteForGenresByMajority() {
        func program(_ id: String, _ categories: [String]) -> LiveTVPrototypeProgram {
            LiveTVPrototypeProgram(
                id: id, channelID: "c", title: "t", subtitle: "", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60),
                details: LiveTVProgramDetails(categories: categories))
        }
        let votes = LiveTVChannelTagging.guideGenreVotes(["c": [
            program("1", ["Sports"]), program("2", ["Sports", "News"]), program("3", ["Sports"]), program("4", ["Movie"]), program("5", [])
        ]])
        XCTAssertEqual(votes["c"], ["sports"], "News 1/4 and Movies 1/4 are minorities; the uncategorised programme is not counted")
    }

    func testIndexIntersectsTagsAndCountsOnlyChannelsWithAll() {
        let model = LiveTVPrototypeModel(channels: [
            channel("a", "CA EN: CTV HD", groups: ["CA| NEWS EN"]), channel("b", "CA EN: CBC HD", groups: ["CA| NEWS EN"]),
            channel("c", "US EN: CNN 4K", groups: ["US| NEWS ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]), channel("d", "CA EN: TSN 4K", groups: ["CA| SPORT"])
        ])
        let channels = model.channels
        let index = LiveTVChannelTagIndex.build(channels: channels, measuredResolution: { _ in nil })
        let none = LiveTVLiveTagMembers()
        func ids(_ tags: [String]) -> [String] { index.positions(matching: tags, channels: channels, live: none).map { channels[$0].id } }
        XCTAssertEqual(ids(["canada", "news"]), ["a", "b"])
        XCTAssertEqual(ids(["news", "4k"]), ["c"])
        XCTAssertEqual(ids(["canada", "news", "4k"]), [])
        XCTAssertEqual(ids(["sports", "4k", "canada"]), ["d"])
        XCTAssertEqual(ids([]), [])
        XCTAssertEqual(ids(["unknown-tag"]), [])
    }

    func testLiveTagsFollowFavouritesAndRecentsWithoutRebuilding() {
        let model = LiveTVPrototypeModel(channels: [
            channel("a", "CA EN: CTV HD", groups: ["CA| NEWS EN"]), channel("b", "CA EN: CBC HD", groups: ["CA| NEWS EN"])
        ])
        let channels = model.channels
        let index = LiveTVChannelTagIndex.build(channels: channels, measuredResolution: { _ in nil })
        func ids(_ live: LiveTVLiveTagMembers, _ tags: [String]) -> [String] {
            index.positions(matching: tags, channels: channels, live: live).map { channels[$0].id }
        }
        XCTAssertEqual(ids(.init(favouriteIDs: ["b"]), ["favourite-channels"]), ["b"])
        XCTAssertEqual(ids(.init(favouriteIDs: ["a", "b"]), ["favourite-channels", "canada"]), ["a", "b"])
        XCTAssertEqual(ids(.init(favouriteIDs: ["a"], recentIDs: ["b"]), ["favourite-channels", "recently-watched"]), ["a", "b"],
                       "both are Channels tags, so they widen: favourite or recently watched")
        XCTAssertEqual(ids(.init(recentIDs: ["b"]), ["recently-watched", "news"]), ["b"])
        XCTAssertFalse(index.storedTagIDs.contains("favourite-channels"))
    }

    func testTagIDsFollowTheMockup() {
        XCTAssertEqual(LiveTVFilterTagCatalog.tagID("Boxing & MMA"), "boxing-and-mma")
        XCTAssertEqual(LiveTVFilterTagCatalog.tagID("Canal+"), "canalplus")
        XCTAssertEqual(LiveTVFilterTagCatalog.tagID("24/7"), "24-7")
        XCTAssertEqual(LiveTVFilterTagCatalog.tagID("Pay-per-view"), "pay-per-view")
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["sports", "4k"]), "Sports · 4K")
        XCTAssertEqual(LiveTVFilterTagCatalog.name(for: ["favourite-channels", "united-kingdom"]), "Favourites · UK")
    }

    func testPickerOffersOnlyTagsTheLineupHasAndPutsTheRegionFirst() {
        let model = LiveTVPrototypeModel(channels: [
            channel("a", "CA EN: CTV HD", groups: ["CA| NEWS EN"]), channel("b", "CA FR: AHC", groups: ["CA| DOCUMENTARY FR"])
        ])
        let sections = model.filterTagSections(region: "CA")
        let all = sections.flatMap(\.tags)
        XCTAssertEqual(sections.first?.id, LiveTVFilterTagSection.suggestedID)
        XCTAssertEqual(sections.first?.tags.first?.tag.id, "canada", "the viewer's region leads Suggested")
        XCTAssertFalse(all.contains { $0.tag.id == "formula-1" }, "no channel carries it")
        XCTAssertFalse(all.contains { $0.tag.id == "united-kingdom" })
        XCTAssertEqual(all.first { $0.tag.id == "news" }?.count, 1)
        XCTAssertEqual(sections.first { $0.id == "countryRegion" }?.tags.first { $0.tag.id == "canada" }?.count, 2)
        XCTAssertTrue(all.contains { $0.tag.id == "favourite-channels" && $0.count == 0 }, "live tags are always offered")
        XCTAssertEqual(model.filterTagSections(query: "fre").flatMap(\.tags).map(\.tag.id), ["french"])
        XCTAssertFalse(model.filterTagSections(query: "fre").contains { $0.id == LiveTVFilterTagSection.suggestedID }, "no Suggested while searching")
    }

    private func channel(
        _ id: String, _ name: String, groups: [String] = [], country: String? = nil, language: String? = nil
    ) -> LiveTVPrototypeChannel {
        .init(id: id, number: id.unicodeScalars.first.map { Int($0.value) } ?? 1, name: name, category: groups.first ?? "News", symbol: "tv", accent: 0,
              source: .iptv, tagline: "", language: language, country: country, groups: groups.isEmpty ? nil : groups)
    }
}
