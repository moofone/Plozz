import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Hiding a channel through the existing hidden-channels feature, with the real provider row names of the Yoopa feeds.
@MainActor
final class LiveTVHideYoopaTests: XCTestCase {
    private final class Store: LiveTVPreferencesStoring, @unchecked Sendable {
        var value = LiveTVPreferences(favoriteIDs: [], recentChannelIDs: [])
        func load() throws -> LiveTVPreferences { value }
        func save(_ preferences: LiveTVPreferences) throws { value = preferences }
    }

    private func row(_ id: String, _ number: Int, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: number, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
    }

    private var lineup: [LiveTVPrototypeChannel] {
        [
            row("fr", 1, "CA FR: YOOPA HD", "CA| GENERAL FR"),
            row("ca", 2, "CA: YOOPA", "CA| CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            row("keep", 3, "CA: CBC CALGARY HD", "CA| CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ")
        ]
    }

    func testHidingBothYoopaFeedsRemovesThemEverywhereAndShowRestoresThem() throws {
        let store = Store()
        let channels = lineup
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        model.toggleFavorite("fr")
        model.toggleFavorite("ca")
        model.toggleFavorite("keep")
        XCTAssertEqual(model.categoryChannelCount(nil), 3)

        XCTAssertTrue(model.hideChannel(channels[0]))
        XCTAssertTrue(model.hideChannel(channels[1]))

        XCTAssertEqual(model.visibleChannels.map(\.id), ["keep"], "guide rows")
        XCTAssertEqual(Set(model.guideChannels.map(\.channel.id)), ["keep"], "a favourite appears in its Favorites and All rows")
        XCTAssertEqual(model.unhiddenCatalogChannels.map(\.id), ["keep"], "My Channels pre-filter")
        XCTAssertEqual(model.programmeSearchChannelIDs, ["keep"], "programme search")
        XCTAssertEqual(model.categoryChannelCount(nil), 1, "category counts")
        let canada = model.filterTagSections().flatMap(\.tags).first { $0.tag.title == "Canada" }
        XCTAssertEqual(canada?.count, 1, "favourite-filter tag counts leave the hidden rows out")
        XCTAssertEqual(model.browsingCategories.map(\.channelCount).reduce(0, +), 1)
        model.favoritesOnly = true
        XCTAssertEqual(model.visibleChannels.map(\.id), ["keep"], "favourites results")
        model.favoritesOnly = false
        model.query = "YOOPA"
        XCTAssertTrue(model.visibleChannels.isEmpty, "name search")
        model.query = ""

        // The Hidden channels list reads these stored entries.
        XCTAssertEqual(Set(store.value.hiddenChannels.map(\.id)), ["fr", "ca"])
        XCTAssertEqual(Set(store.value.hiddenChannels.map(\.name)), ["CA FR: YOOPA HD", "CA: YOOPA"])

        // Persistence round trip.
        let reloaded = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertEqual(reloaded.visibleChannels.map(\.id), ["keep"])
        XCTAssertEqual(reloaded.hiddenChannelIDs, ["fr", "ca"])

        XCTAssertTrue(model.showChannel("fr"))
        XCTAssertTrue(model.showChannel("ca"))
        XCTAssertEqual(Set(model.visibleChannels.map(\.id)), ["fr", "ca", "keep"])
        XCTAssertTrue(store.value.hiddenChannels.isEmpty)
        XCTAssertEqual(model.categoryChannelCount(nil), 3)
    }
}
