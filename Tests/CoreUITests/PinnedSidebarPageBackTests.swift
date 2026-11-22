import XCTest
@testable import CoreUI

/// The shell asks the page to close an open panel before it treats Back, or Select on the current destination, as its own.
@MainActor
final class PinnedSidebarPageBackTests: XCTestCase {
    func testPageBackIsNotHandledWithoutAPageHandler() {
        XCTAssertFalse(PlozzPinnedSidebarInteraction().performPageBack())
    }

    func testPageBackReportsWhetherThePageClosedAPanel() {
        let interaction = PlozzPinnedSidebarInteraction()
        var panelOpen = true
        interaction.pageBackHandler = {
            guard panelOpen else { return false }
            panelOpen = false
            return true
        }
        XCTAssertTrue(interaction.performPageBack())
        XCTAssertFalse(interaction.performPageBack(), "nothing left to close: the shell may treat the press as its own")
    }

    func testPageHoldIsReleasedExplicitly() {
        let interaction = PlozzPinnedSidebarInteraction()
        interaction.setPageHoldsFocus(true)
        XCTAssertTrue(interaction.pageHoldsFocus)
        interaction.setPageHoldsFocus(false)
        XCTAssertFalse(interaction.pageHoldsFocus)
    }

    /// Set Up My Channels: the panel's exit command and the shell's handler can both receive one press. Each press closes exactly one
    /// panel (lineup, then tray) and the duplicate delivery is ignored, so the shell never reaches the sidebar-opening branch.
    func testOneEscapePerPanelNeverReachesTheSidebar() {
        TVBackConsumption.reset()
        defer { TVBackConsumption.reset() }
        let interaction = PlozzPinnedSidebarInteraction()
        var open = ["tray", "lineup"]
        var sidebarOpened = false
        interaction.pageBackHandler = {
            guard !open.isEmpty else { return false }
            open.removeLast()
            return true
        }
        func press(at time: TimeInterval) {
            // The panel's exit command, when the system delivers it first...
            if TVBackConsumption.claim(at: time) { _ = interaction.pageBackHandler?() }
            // ...and the shell's handler for the same press.
            if !TVBackConsumption.wasJustConsumed(at: time + 0.01), !interaction.performPageBack() { sidebarOpened = true }
        }
        press(at: 100)
        XCTAssertEqual(open, ["tray"], "the first Escape closes only Set Up My Channels")
        XCTAssertFalse(sidebarOpened)
        press(at: 101)
        XCTAssertTrue(open.isEmpty, "the second closes the tray")
        XCTAssertFalse(sidebarOpened)
    }
}
