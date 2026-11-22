import Foundation
import CoreModels
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVSectionMarkerTests: XCTestCase {
    func testPlaylistSectionHeadersAreMarkers() {
        for name in [
            "#### CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ ####",
            "##### CANADA NEWS ENGLISH #####",
            "####### DAZN PPV CA #######",
            "### Sports ###", "   ### Sports ###  ", "*** Films ***"
        ] {
            XCTAssertTrue(channel(name).isSectionMarker, name)
        }
    }

    func testTwoHashHeadersNeedTheirProviderGroupToCorroborate() {
        let group = "CA| 24/7 CARTOON ᴿᴬᵂ ⁶⁰ᶠᵖˢ"
        XCTAssertTrue(channel("## 24/7 CARTOON ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", category: group).isSectionMarker)
        XCTAssertTrue(channel("## 24/7 CARTOON ##", category: group).isSectionMarker, "The group contains the inner text")
        XCTAssertTrue(channel("## NEWS ##", groups: ["CA| NEWS ENGLISH"]).isSectionMarker)
        // The same decoration with no matching group is a real, decorated channel.
        for name in ["## UK|BBC One H D ##", "## News H D ##", "## BBC One H D ##"] {
            XCTAssertFalse(channel(name, category: "UK| ENTERTAINMENT").isSectionMarker, name)
        }
        XCTAssertTrue(IPTVChannelName.isSectionMarker(name: "## 24/7 CARTOON ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", groupTitle: group))
        XCTAssertFalse(IPTVChannelName.isSectionMarker(name: "## 24/7 CARTOON ##", groupTitle: nil))
    }

    func testRealNamesContainingAHashStayChannels() {
        for name in ["CA: CHANNEL #1", "Columbia at #20 Maryland", "#1 Movies", "Movies ##", "## Movies", "##", "#", "####", "Channel ## 5", "## Movies ##"] {
            XCTAssertFalse(channel(name).isSectionMarker, name)
        }
    }

    func testOnlyPlaylistEntriesCanBeMarkers() {
        XCTAssertFalse(channel("#### X ####", source: .plozz).isSectionMarker)
    }

    @MainActor
    func testMarkersNeverEnterTheGuideCountsOrSearch() {
        let channels = [
            channel("#### CANADA ####", id: "h1", number: 1),
            channel("CBC News", id: "c1", number: 2),
            channel("##### CANADA NEWS #####", id: "h2", number: 3),
            channel("CA: CHANNEL #1", id: "c2", number: 4)
        ]
        let model = LiveTVPrototypeModel(now: Date(), channels: channels)
        XCTAssertEqual(model.channels.map(\.id), ["c1", "c2"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["c1", "c2"])
        XCTAssertEqual(model.guideChannels.count, 2)
        XCTAssertNil(model.channel(id: "h1"))
        model.query = "#####"
        XCTAssertTrue(model.visibleChannels.isEmpty, "A header is not a search result")
    }

    func testEventLookingAndPlaceholderNamesAreNeverMarkers() {
        XCTAssertTrue(channel("##### WHL PPV 1 #####").isSectionMarker)
        for name in [
            "##### Oilers vs Flames 7:00 PM #####", "## UFC 310 @ Nov 16 19:00 ##", "### Habs at Leafs ###",
            "### 2026-11-16 Fight Night ###", "#### NO EVENT STREAMING ####",
            "- NO EVENT STREAMING - | 8K EXCLUSIVE | CA: SPORTSNET PPV 1", ":TSN+  109"
        ] {
            XCTAssertFalse(channel(name, category: "CA| PPV").isSectionMarker, name)
        }
    }

    @MainActor
    func testARenamedSlotFlipsBackOnRefresh() throws {
        let model = LiveTVPrototypeModel(now: Date(), channels: [
            channel("##### WHL PPV 1 #####", id: "slot", number: 1), channel("CBC News", id: "c1", number: 2)
        ])
        XCTAssertNil(model.channel(id: "slot"))
        try model.replaceChannels([
            channel("Oilers vs Flames 7:00 PM", id: "slot", number: 1), channel("CBC News", id: "c1", number: 2)
        ])
        XCTAssertNotNil(model.channel(id: "slot"), "Classification is never stored")
        try model.replaceChannels([
            channel("##### WHL PPV 1 #####", id: "slot", number: 1), channel("CBC News", id: "c1", number: 2)
        ])
        XCTAssertNil(model.channel(id: "slot"))
    }

    @MainActor
    func testAFavouritedOrPlayingMarkerIsStillNeverACatalogChannel() {
        let model = LiveTVPrototypeModel(now: Date(), channels: [
            channel("#### CANADA ####", id: "h1", number: 1), channel("CBC News", id: "c1", number: 2)
        ])
        model.toggleFavorite("h1")
        model.tune("h1")
        XCTAssertNil(model.channel(id: "h1"), "A placeholder is never kept, however it was reached")
        XCTAssertFalse(model.visibleChannels.contains { $0.id == "h1" })
    }

    private func channel(
        _ name: String, source: LiveTVPrototypeSource = .iptv, id: String = "x", number: Int = 1,
        category: String = "Canada", groups: [String]? = nil
    ) -> LiveTVPrototypeChannel {
        .init(id: id, number: number, name: name, category: category, symbol: "tv",
              accent: 0, source: source, tagline: "", groups: groups)
    }
}
