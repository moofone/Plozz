#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import XCTest
@testable import FeatureLiveTV

final class PrototypeGuideGlassTests: XCTestCase {
    override func setUp() { super.setUp(); LiveTVGlassLayout.override = .hd1080 }
    override func tearDown() { LiveTVGlassLayout.override = nil; super.tearDown() }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func program(from: TimeInterval, to: TimeInterval) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: "p", channelID: "c", title: "Show", subtitle: "",
            start: now.addingTimeInterval(from), end: now.addingTimeInterval(to))
    }

    func testToneFollowsTheClock() {
        XCTAssertEqual(PrototypeGuideTone(program: program(from: 600, to: 1_800), now: now), .upcoming)
        XCTAssertEqual(PrototypeGuideTone(program: program(from: -600, to: 600), now: now), .onNow)
        XCTAssertEqual(PrototypeGuideTone(program: program(from: -600, to: 0), now: now), .ended)
        XCTAssertEqual(PrototypeGuideTone(program: program(from: 0, to: 600), now: now), .onNow)
        XCTAssertEqual(PrototypeGuideTone(program: nil, now: now), .noData)
    }

    /// Plozz-like: the dark palette's fill (11%) and fillSubtle (6%), its secondary-less title tiers and the 36% tertiary of a finished cell.
    func testToneFillAndInkOpacities() {
        XCTAssertEqual(PrototypeGuideTone.upcoming.fillOpacity, 0.11)
        XCTAssertEqual(PrototypeGuideTone.onNow.fillOpacity, 0.11)
        XCTAssertEqual(PrototypeGuideTone.ended.fillOpacity, 0.06)
        XCTAssertEqual(PrototypeGuideTone.noData.fillOpacity, 0.06)
        XCTAssertEqual(PrototypeGuideTone.upcoming.inkOpacity, 1)
        XCTAssertEqual(PrototypeGuideTone.onNow.inkOpacity, 0.8)
        XCTAssertEqual(PrototypeGuideTone.ended.inkOpacity, 0.36)
        XCTAssertEqual(PrototypeGuideTone.noData.inkOpacity, 0.36)
        XCTAssertEqual(ThemePalette.dark.fill, Color.white.opacity(PrototypeGuideTone.upcoming.fillOpacity), "ThemePalette.dark.fill")
        XCTAssertEqual(ThemePalette.dark.fillSubtle, Color.white.opacity(PrototypeGuideTone.ended.fillOpacity), "ThemePalette.dark.fillSubtle")
        XCTAssertEqual(ThemePalette.dark.tertiaryText, Color.white.opacity(PrototypeGuideTone.ended.inkOpacity), "ThemePalette.dark.tertiaryText")
        XCTAssertEqual(ThemePalette.dark.secondaryText, Color.white.opacity(PrototypePlayingGlass.rulerInkOpacity), "ThemePalette.dark.secondaryText")
    }

    func testTitleHidesBelowOneHundredTenPoints() {
        XCTAssertFalse(PrototypeGuideCellMetrics.showsTitle(cellWidth: 109.9))
        XCTAssertTrue(PrototypeGuideCellMetrics.showsTitle(cellWidth: 110))
    }

    /// The played track is drawn in the cell's own size (no focus scale): its right edge is where now is.
    func testFocusedTrackEndsWhereNowIsAndClampsToTheCell() {
        XCTAssertEqual(PrototypeGuideCellMetrics.elapsedFillWidth(elapsed: 259.1, cellWidth: 346), 259.1, accuracy: 0.001)
        XCTAssertEqual(PrototypeGuideCellMetrics.elapsedFillWidth(elapsed: 0, cellWidth: 300), 0)
        XCTAssertEqual(PrototypeGuideCellMetrics.elapsedFillWidth(elapsed: -20, cellWidth: 300), 0)
        XCTAssertEqual(PrototypeGuideCellMetrics.elapsedFillWidth(elapsed: 900, cellWidth: 300), 300, accuracy: 0.001)
    }

    /// Already playing: the SDK glass path is taken exactly when a picture plays under the guide on tvOS 26 with transparency allowed.
    func testPlayingGlassIsTheSDKPathOnlyWhenAPictureIsPlayingAndTransparencyIsAllowed() {
        func uses(picture: Bool = true, multiview: Bool = false, reduce: Bool = false, contrast: Bool = false, sdk: Bool = true) -> Bool {
            PrototypePlayingGlass.usesSDKGlass(
                hasPicture: picture, isMultiview: multiview, reduceTransparency: reduce, increasedContrast: contrast, sdkHasLiquidGlass: sdk)
        }
        XCTAssertTrue(uses())
        XCTAssertFalse(uses(picture: false), "nothing playing keeps today's look")
        XCTAssertFalse(uses(multiview: true))
        XCTAssertFalse(uses(reduce: true), "Reduce Transparency keeps the opaque fills")
        XCTAssertFalse(uses(contrast: true))
        XCTAssertFalse(uses(sdk: false), "older systems keep their fallback")
    }

    /// The Plozz-like values of the mockup's `.screen.pz` (template.html): tint 40%, rim 12%, the 20 px gap, focus and ink tiers.
    func testPlayingGlassValuesFollowTheMockup() {
        XCTAssertEqual(PrototypePlayingGlass.panelTintOpacity, 0.4)
        XCTAssertEqual(PrototypePlayingGlass.rimOpacity, 0.12)
        XCTAssertEqual(PrototypePlayingGlass.sheetPadding, 20)
        XCTAssertEqual(PrototypePlayingGlass.focusedPlateFillOpacity, 0.2)
        XCTAssertEqual(PrototypePlayingGlass.focusedEndedInkOpacity, 0.45)
        XCTAssertEqual(PrototypePlayingGlass.focusedTrackOpacity, 0.1)
        XCTAssertEqual(PrototypePlayingGlass.rulerInkOpacity, 0.6)
        XCTAssertEqual(PrototypePlayingGlass.heroMetaOpacity, 0.6)
        XCTAssertEqual(PrototypePlayingGlass.heroDescriptionOpacity, 0.82)
    }

    /// FeaturePlayback's own scrim (LiveChannelTransport.scrim): 55% from the top over a quarter of the height (at most 220), 70% from the
    /// bottom over 55% (at least 420).
    func testPlayingScrimMatchesTheLivePlayersScrim() {
        XCTAssertEqual(PrototypePlayingGlass.scrimTopOpacity, 0.55)
        XCTAssertEqual(PrototypePlayingGlass.scrimBottomOpacity, 0.7)
        XCTAssertEqual(PrototypePlayingGlass.scrimTopHeight(canvasHeight: 1_080), 220, "20% of 1080 is 216; the player caps at 220")
        XCTAssertEqual(PrototypePlayingGlass.scrimTopHeight(canvasHeight: 600), 150)
        XCTAssertEqual(PrototypePlayingGlass.scrimBottomHeight(canvasHeight: 1_080), 594, accuracy: 0.001)
        XCTAssertEqual(PrototypePlayingGlass.scrimBottomHeight(canvasHeight: 600), 420)
    }

    /// Focus is a solid white card with black ink (a finished programme's at 45%); at rest the tone's white.
    func testCellInkIsBlackWhenFocusedAndTheToneWhiteAtRest() {
        XCTAssertEqual(PrototypeGuideCellTitle.ink(tone: .upcoming, focused: true), Color.black.opacity(1))
        XCTAssertEqual(PrototypeGuideCellTitle.ink(tone: .onNow, focused: true), Color.black.opacity(1))
        XCTAssertEqual(PrototypeGuideCellTitle.ink(tone: .ended, focused: true), Color.black.opacity(0.45))
        XCTAssertEqual(PrototypeGuideCellTitle.ink(tone: .upcoming, focused: false), Color.white.opacity(1))
        XCTAssertEqual(PrototypeGuideCellTitle.ink(tone: .ended, focused: false), Color.white.opacity(0.36))
    }

    #if os(tvOS)
    /// The hero's glass panel: 24 px padding all round and the sheet's radius (cell radius + 20 px), at both layouts' pixel scale.
    func testHeroGlassPanelFollowsThePlozzLikeDesignAtBothSizes() {
        XCTAssertEqual(PrototypeGlassHero.backingPadding(.hd1080), 24)
        XCTAssertEqual(PrototypeGlassHero.backingCornerRadius(.hd1080), 44)
        XCTAssertEqual(PrototypeGlassHero.backingPadding(.uhd4K), 18, accuracy: 0.001)
        XCTAssertEqual(PrototypeGlassHero.backingCornerRadius(.uhd4K), 31.5, accuracy: 0.001, "22 + 20 px, × 0.75")
        XCTAssertEqual(PrototypeGlassHero.headingDropPoints(.hd1080, onSheet: true), 24)
        XCTAssertEqual(PrototypeGlassHero.headingDropPoints(.hd1080, onSheet: false), 19.5)
    }
    #endif

    #if os(tvOS)
    /// The narrowed column keeps the full logo box with numbers hidden, and shrinks the logo's cell to the zone when they show.
    func testLogoReferenceCellFitsTheNarrowedLogoZone() {
        let zoneWithoutNumbers = PrototypeLayout.stationColumnWidth - PrototypeLayout.plateLeadingInset - PrototypeLayout.plateLogoTrailingInset
        XCTAssertGreaterThanOrEqual(zoneWithoutNumbers, 164)
        XCTAssertEqual(PrototypeGuidePlateContent.logoReferenceWidth(zoneWidth: zoneWithoutNumbers, scale: 1), 252)
        let zoneWithNumbers = zoneWithoutNumbers - PrototypeLayout.plateNumberWidth
        let reference = PrototypeGuidePlateContent.logoReferenceWidth(zoneWidth: zoneWithNumbers, scale: 1)
        XCTAssertEqual(reference * 164 / 252, zoneWithNumbers, accuracy: 0.001, "the logo box is exactly the zone")
    }

    func testLiquidGlassGuideMetrics() {
        XCTAssertEqual(PrototypeLayout.rowHeight, 82)
        XCTAssertEqual(PrototypeLayout.rowGap, 10)
        XCTAssertEqual(PrototypeLayout.stationColumnWidth, 204)
        XCTAssertEqual(PrototypeLayout.columnGap, 12)
        XCTAssertEqual(PrototypeLayout.cellGap, 12)
        XCTAssertEqual(PrototypeLayout.rowRadius, 24)
        XCTAssertEqual(PrototypeLayout.rulerHeight, 52)
        // First cell starts 216 pt right of the plate's leading edge.
        XCTAssertEqual(PrototypeLayout.stationColumnWidth + PrototypeLayout.columnGap, 216)
        // 1696 pt guide: the ruler spans 2 h across the timeline width.
        XCTAssertEqual(PrototypeLayout.timelineWidth(for: 1_696), 1_480)
    }
    #endif
}
#endif
