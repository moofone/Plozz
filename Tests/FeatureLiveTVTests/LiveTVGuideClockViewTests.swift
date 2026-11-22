#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import FeatureLiveTVCore
import XCTest
@testable import FeatureLiveTV

/// GUIDE-TIME rule 4 and GUIDE-PLAYING A/B: the guide cell's clipped edge, the playing bars and the
/// hold menu, at both the 1080p and the 4K layout tokens.
final class LiveTVGuideClockViewTests: XCTestCase {
    override func tearDown() { LiveTVGlassLayout.override = nil; super.tearDown() }

    private let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
    private let tokens: [(String, LiveTVGlassLayout)] = [("1080p", .hd1080), ("4K", .uhd4K)]

    private func program(from: TimeInterval, to: TimeInterval) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: "p", channelID: "c", title: "Forrest Gump", subtitle: "",
            start: windowStart.addingTimeInterval(from), end: windowStart.addingTimeInterval(to))
    }

    // MARK: Clipped in-progress cells

    func testAProgrammeBegunBeforeTheWindowIsClippedFlatOnItsLeadingSide() {
        for (name, layout) in tokens {
            LiveTVGlassLayout.override = layout
            let running = program(from: -2_400, to: 3_000)
            let slot = LiveTVGuideTimeline.slots(
                programs: [running], from: windowStart, to: windowStart.addingTimeInterval(10_800))[0]
            XCTAssertEqual(slot.start, windowStart, name)
            XCTAssertTrue(
                PrototypeGuideCellMetrics.continuesBeforeWindow(programStart: running.start, slotStart: slot.start), name)
            let flat = PrototypeGuideCellMetrics.cornerRadii(radius: PrototypeLayout.programRadius, clipsLeading: true)
            XCTAssertEqual(flat.topLeading, 0, name)
            XCTAssertEqual(flat.bottomLeading, 0, name)
            XCTAssertEqual(flat.topTrailing, PrototypeLayout.programRadius, name)
            XCTAssertEqual(flat.bottomTrailing, PrototypeLayout.programRadius, name)
        }
    }

    func testAProgrammeStartingInsideTheWindowKeepsItsRoundedCorners() {
        let inside = program(from: 600, to: 3_000)
        XCTAssertFalse(PrototypeGuideCellMetrics.continuesBeforeWindow(programStart: inside.start, slotStart: inside.start))
        let rounded = PrototypeGuideCellMetrics.cornerRadii(radius: 22, clipsLeading: false)
        XCTAssertEqual([rounded.topLeading, rounded.bottomLeading, rounded.topTrailing, rounded.bottomTrailing], [22, 22, 22, 22])
    }

    func testTheClippedCellStartsAtTheTimelineEdgeAndTheWindowSpansTheTokenMinutes() {
        let width: CGFloat = 1_920
        for (name, layout) in tokens {
            LiveTVGlassLayout.override = layout
            XCTAssertEqual(PrototypeLayout.viewportSeconds(for: width), TimeInterval(layout.windowMinutes * 60), name)
            let running = program(from: -2_400, to: 3_000)
            let slot = LiveTVGuideTimeline.slots(
                programs: [running], from: windowStart, to: windowStart.addingTimeInterval(PrototypeLayout.timelineSpanSeconds))[0]
            // Only the part inside the window is drawn: from the edge to the end.
            XCTAssertEqual(
                PrototypeLayout.timelineX(slot.end.timeIntervalSince(slot.start), for: width),
                PrototypeLayout.timelineX(3_000, for: width), accuracy: 0.001, name)
        }
        LiveTVGlassLayout.override = .uhd4K
        XCTAssertEqual(PrototypeLayout.viewportSeconds(for: width), 10_800)
    }

    func testTheClippedCellsFullTimesStillComeFromTheProgramme() {
        let running = program(from: -2_400, to: 3_000)
        // The hero and panel read the programme, not the clipped slot.
        XCTAssertEqual(running.start, windowStart.addingTimeInterval(-2_400))
        XCTAssertEqual(running.end.timeIntervalSince(windowStart), 3_000)
    }

    // MARK: Auto-advance with the guide scrolled right

    func testAShiftKeepsTheLeftEdgeMomentAtBothTokens() {
        let width: CGFloat = 1_920
        for (name, layout) in tokens {
            LiveTVGlassLayout.override = layout
            let perSecond = PrototypeLayout.timelineX(1, for: width)
            let scrolled = PrototypeLayout.timelineX(5_400, for: width)
            let shifted = LiveTVGuideClock.timelineAfterShift(
                anchor: windowStart, offset: scrolled, newAnchor: windowStart.addingTimeInterval(1_800),
                pointsPerSecond: perSecond)
            XCTAssertEqual(
                shifted.anchor.timeIntervalSince1970 + Double(shifted.offset / perSecond),
                windowStart.timeIntervalSince1970 + 5_400, accuracy: 0.01, name)
        }
    }

    // MARK: Playing indicator

    func testOnlyThePlayingChannelsNowCellShowsTheBars() {
        XCTAssertTrue(PrototypeGuideEqMetrics.isShown(channelIsPlaying: true, phase: .onNow))
        XCTAssertFalse(PrototypeGuideEqMetrics.isShown(channelIsPlaying: false, phase: .onNow))
        XCTAssertFalse(PrototypeGuideEqMetrics.isShown(channelIsPlaying: true, phase: .upcoming))
        XCTAssertFalse(PrototypeGuideEqMetrics.isShown(channelIsPlaying: true, phase: .ended))
    }

    func testTheBarsFollowTheMockupsSizesAndAnimation() {
        XCTAssertEqual(PrototypeGuideEqMetrics.barWidth, 0.17)
        XCTAssertEqual(PrototypeGuideEqMetrics.barGap, 0.13)
        XCTAssertEqual(PrototypeGuideEqMetrics.height, 0.78)
        XCTAssertEqual(PrototypeGuideEqMetrics.restingScales, [0.55, 1, 0.4])
        XCTAssertEqual(PrototypeGuideEqMetrics.period, 1.1)
        // 0.4 at the start of a cycle, 1 halfway, back to 0.4 at the end; the delays offset the bars.
        XCTAssertEqual(PrototypeGuideEqMetrics.scale(bar: 0, at: 0), 0.4, accuracy: 0.001)
        XCTAssertEqual(PrototypeGuideEqMetrics.scale(bar: 0, at: 0.55), 1, accuracy: 0.001)
        XCTAssertEqual(PrototypeGuideEqMetrics.scale(bar: 0, at: 1.1), 0.4, accuracy: 0.001)
        XCTAssertNotEqual(
            PrototypeGuideEqMetrics.scale(bar: 1, at: 0), PrototypeGuideEqMetrics.scale(bar: 0, at: 0), accuracy: 0.05)
    }

    func testTheBarsScaleWithTheCellFontAtBothTokens() {
        for (name, layout) in tokens {
            LiveTVGlassLayout.override = layout
            let font = layout.cellFontSize
            XCTAssertEqual(
                PrototypeGuideEqMetrics.width(fontSize: font),
                font * (0.17 * 3 + 0.13 * 2), accuracy: 0.001, name)
        }
    }

    // MARK: Hold menu

    func testTheHoldMenuOffersWatchOnlyForProgrammesThatCanBeWatched() {
        func ids(offersWatch: Bool) -> [String] {
            LiveTVGlassContextEntry.entries(
                offersWatch: offersWatch, isPlayingChannel: false, offersMultiview: true, isFavorite: false,
                canChangeLogo: false).map(\.id)
        }
        XCTAssertEqual(ids(offersWatch: true), ["watch", "multiview", "favorite", "details"])
        XCTAssertEqual(ids(offersWatch: false), ["multiview", "favorite", "details"])
    }

    func testTheHoldMenuShowsResumeOnThePlayingChannel() {
        let entries = LiveTVGlassContextEntry.entries(
            offersWatch: true, isPlayingChannel: true, offersMultiview: false, isFavorite: true, canChangeLogo: true)
        XCTAssertEqual(entries.map(\.id), ["watch", "favorite", "details", "logo"])
        XCTAssertEqual(entries.first?.title, String(localized: "Resume"))
    }
}
#endif
