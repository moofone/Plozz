#if canImport(SwiftUI)
import XCTest
import Combine
@testable import CoreUI

@MainActor
final class PinnedSidebarInteractionTests: XCTestCase {
    func testSearchResultFocusIsIndependentOfHeroFocusAndOpenRequests() {
        let interaction = PlozzPinnedSidebarInteraction()
        XCTAssertFalse(interaction.searchResultsHaveFocus)
        interaction.setSearchResultsFocused(true)
        interaction.requestOpen()
        XCTAssertTrue(interaction.searchResultsHaveFocus)
        XCTAssertFalse(interaction.heroHasFocus)
        XCTAssertEqual(interaction.openRequest, 1)
        interaction.setSearchResultsFocused(false)
        XCTAssertFalse(interaction.searchResultsHaveFocus)
    }

    func testMovingBetweenSearchResultsDoesNotRepublishTheSameFocusState() {
        let interaction = PlozzPinnedSidebarInteraction()
        var publications = 0
        let subscription = interaction.objectWillChange.sink { publications += 1 }
        interaction.setSearchResultsFocused(true)
        interaction.setSearchResultsFocused(true)
        interaction.setSearchResultsFocused(false)
        interaction.setSearchResultsFocused(false)
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(subscription) {}
    }

    func testRailExpansionMirrorsTheShellAndRepeatsDoNotPublish() {
        let interaction = PlozzPinnedSidebarInteraction()
        var publications = 0
        let subscription = interaction.objectWillChange.sink { publications += 1 }
        XCTAssertFalse(interaction.railIsExpanded)
        interaction.setRailExpanded(true)
        interaction.setRailExpanded(true)
        XCTAssertTrue(interaction.railIsExpanded)
        interaction.setRailExpanded(false)
        XCTAssertFalse(interaction.railIsExpanded)
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(subscription) {}
    }
}
#endif
