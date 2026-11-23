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

    /// A programme that began before the scrolled-to edge shows its title at the edge, not at its off-screen start;
    /// near its end the title keeps the minimum title width and leaves with the cell.
    func testTitleOfAProgrammeStartingOffScreenStartsAtTheVisibleEdge() {
        typealias M = PrototypeGuideCellMetrics
        XCTAssertEqual(M.titleLead(offset: 0, cellX: 0, cellWidth: 1_200), 0)
        XCTAssertEqual(M.titleLead(offset: 300, cellX: 500, cellWidth: 1_200), 0, "a cell on screen keeps its title")
        XCTAssertEqual(M.titleLead(offset: 1_546, cellX: 1_000, cellWidth: 1_200), 546)
        XCTAssertEqual(M.titleLead(offset: 2_150, cellX: 1_000, cellWidth: 1_200), 1_200 - M.minimumTitleWidth)
        XCTAssertEqual(M.titleLead(offset: 5_000, cellX: 1_000, cellWidth: 80), 0, "too narrow for a title")
        XCTAssertEqual(M.titleLead(offset: .nan, cellX: 0, cellWidth: 1_200), 0)
    }

    /// Mockup `appleHero`: one meta line (no time while on now; labels inline, category first, no country) and the
    /// synopsis alone, so the description keeps its two lines in the fixed-height hero.
    func testHeroMetaLineAndDescriptionFollowTheMockup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_US")
        let channel = LiveTVPrototypeChannel(
            id: "c", number: 1, name: "CA EN: CITYTV TORONTO HD", category: "News", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", tags: [.country("CA"), .language("EN"), .hd])
        let details = LiveTVProgramDetails(description: "  Debra gets her sanctuary.\n", categories: [" ", "Reality"])
        func program(from: TimeInterval, to: TimeInterval, subtitle: String = "") -> LiveTVPrototypeProgram {
            LiveTVPrototypeProgram(
                id: "p", channelID: "c", title: "Home Town Takeover", subtitle: subtitle,
                start: now.addingTimeInterval(from), end: now.addingTimeInterval(to), details: details)
        }
        XCTAssertNil(PrototypeGlassHero.metaWords(for: program(from: -600, to: 600), now: now, ended: false, locale: locale))
        XCTAssertEqual(PrototypeGlassHero.metaWords(for: program(from: -600, to: 600, subtitle: "Bandshell"),
                                                    now: now, ended: false, locale: locale), "Bandshell")
        let later = PrototypeGlassHero.metaWords(for: program(from: 3_600, to: 7_200), now: now, ended: false, locale: locale)
        XCTAssertNotNil(later)
        XCTAssertTrue(later?.contains("\u{2013}") == true, "a later programme says when it is on")
        XCTAssertTrue(PrototypeGlassHero.metaWords(for: program(from: -7_200, to: -3_600), now: now, ended: true,
                                                   locale: locale)?.hasPrefix("Ended") == true)
        let labels = PrototypeGlassHero.programmeLabels(for: program(from: -600, to: 600), channel: channel)
        XCTAssertEqual(labels.first, "Reality")
        XCTAssertFalse(labels.contains("CA"), "the country belongs to the channel row, not the programme")
        XCTAssertEqual(labels, ["Reality", "EN", "HD"])
        XCTAssertEqual(PrototypeGlassHero.description(of: program(from: -600, to: 600, subtitle: "Bandshell")),
                       "Debra gets her sanctuary.", "the episode is on the meta line, not repeated in the synopsis")
        XCTAssertNil(PrototypeGlassHero.description(of: LiveTVPrototypeProgram(
            id: "q", channelID: "c", title: "Bare", subtitle: "", start: now, end: now.addingTimeInterval(60))))
    }

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
    /// The hero's free shade (mockup `.herofree`): no panel, a 50% black shape 70 × 90 px past the text, radius 120, blur 46, at the
    /// hero's scale at both sizes.
    func testHeroShadeFollowsThePlozzLikeDesignAtBothSizes() {
        XCTAssertEqual(PrototypeGlassHero.shade(.hd1080), .init(vertical: 70, horizontal: 90, cornerRadius: 120, blur: 46))
        let uhd = LiveTVGlassLayout.uhd4K
        XCTAssertEqual(PrototypeGlassHero.shade(uhd), .init(vertical: uhd.ui(70), horizontal: uhd.ui(90), cornerRadius: uhd.ui(120), blur: uhd.ui(46)))
        XCTAssertEqual(PrototypeGlassHero.Shade.opacity, 0.5)
        // The heading pill sits on Watch's line, on the sheet and off it.
        XCTAssertEqual(PrototypeGlassHero.headingDropPoints(.hd1080, onSheet: true), 0)
        XCTAssertEqual(PrototypeGlassHero.headingDropPoints(.uhd4K, onSheet: false), 0)
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
