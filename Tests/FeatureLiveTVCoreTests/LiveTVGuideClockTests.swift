import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// GUIDE-TIME and GUIDE-PLAYING E: one model-owned clock drives the window start, the "now"
/// programme, the hero's actions and the guide's ticks.
@MainActor
final class LiveTVGuideClockTests: XCTestCase {
    /// A :00 boundary (1.8e9 is a multiple of 1,800), so offsets read as clock minutes.
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double, _ seconds: Double = 0) -> Date {
        base.addingTimeInterval(minutes * 60 + seconds)
    }

    private func program(
        _ id: String, _ channelID: String, from start: Date, minutes: Double
    ) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: id, channelID: channelID, title: id, subtitle: "",
            start: start, end: start.addingTimeInterval(minutes * 60))
    }

    private func model(now: Date, programs: (String) -> [LiveTVPrototypeProgram] = { _ in [] }) throws
        -> (LiveTVPrototypeModel, String) {
        let model = LiveTVPrototypeModel(now: now, channels: LiveTVPrototypeCatalog.channels)
        let channelID = model.channels[0].id
        try model.replacePrograms(programs(channelID))
        return (model, channelID)
    }

    // MARK: Return from the player (Back < 100 ms)

    func testAFreshClockDefersTheReturnCatchUpOutOfTheBackPath() throws {
        let (model, _) = try model(now: at(22))
        XCTAssertEqual(model.returnCatchUp(at: at(22, 5)), .deferred)
        XCTAssertEqual(model.returnCatchUp(at: at(22, 29)), .deferred)
    }

    func testAStaleClockOrACrossedSlotCatchesUpBeforeTheGuideShows() throws {
        let (model, _) = try model(now: at(22))
        XCTAssertEqual(model.returnCatchUp(at: at(22, 30)), .immediate, "the label refresh is due")
        XCTAssertEqual(model.returnCatchUp(at: at(62)), .immediate, "40 minutes in the picture")
        let (nearSlot, _) = try self.model(now: at(29, 50))
        XCTAssertEqual(nearSlot.returnCatchUp(at: at(30, 5)), .immediate, "the window start moved")
    }

    // MARK: Window start

    func testTheWindowStartIsNowFlooredToTheHalfHour() {
        XCTAssertEqual(LiveTVGuideClock.windowStart(for: at(22)), base)
        XCTAssertEqual(LiveTVGuideClock.windowStart(for: base), base)
        XCTAssertEqual(LiveTVGuideClock.windowStart(for: at(30)), at(30))
        XCTAssertEqual(LiveTVGuideClock.windowStart(for: at(29, 59)), base)
        XCTAssertEqual(LiveTVGuideClock.windowStart(for: at(52)), at(30))
    }

    func testAModelOpenedMidSlotStartsItsWindowAtTheSlot() throws {
        let (model, _) = try model(now: at(22))
        XCTAssertEqual(model.guideWindowStart, base)
    }

    func testTheWindowAdvancesWhenTheClockCrossesAHalfHour() throws {
        let (model, _) = try model(now: at(22))
        model.synchronizeClock(to: at(29, 59))
        XCTAssertEqual(model.guideWindowStart, base)
        model.synchronizeClock(to: at(30))
        XCTAssertEqual(model.guideWindowStart, at(30))
    }

    func testReturningAfterFortyMinutesRecomputesEverythingInOnePass() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("a", id, from: at(0), minutes: 30), program("b", id, from: at(30), minutes: 30),
             program("c", id, from: at(60), minutes: 30)]
        }
        XCTAssertEqual(model.currentProgram(for: channelID)?.id, "a")
        model.synchronizeClock(to: at(62))
        XCTAssertEqual(model.guideWindowStart, at(60))
        XCTAssertEqual(model.currentProgram(for: channelID)?.id, "c")
    }

    // MARK: Auto-advance while the guide is in use

    func testTheWindowDoesNotMoveUnderAnActivePress() throws {
        let (model, _) = try model(now: at(29))
        model.synchronizeClock(to: at(29, 58))
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 2))
        XCTAssertEqual(model.guideWindowStart, base, "a press 4 s ago holds the window")
        XCTAssertTrue(model.guideWindowAdvanceIsDeferred)
        model.synchronizeClock(to: at(30, 5))
        XCTAssertEqual(model.guideWindowStart, base, "7 s idle is not enough")
        model.synchronizeClock(to: at(30, 6))
        XCTAssertEqual(model.guideWindowStart, at(30), "8 s idle releases it")
        XCTAssertFalse(model.guideWindowAdvanceIsDeferred)
    }

    func testAnAdvanceDeferredTwiceStillLandsOnTheCurrentSlot() throws {
        let (model, _) = try model(now: at(29, 58))
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 2))
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 9))
        XCTAssertEqual(model.guideWindowStart, base, "a second press restarts the idle wait")
        model.synchronizeClock(to: at(30, 10))
        XCTAssertEqual(model.guideWindowStart, at(30))
    }

    func testNowAlignsTheWindowImmediately() throws {
        let (model, _) = try model(now: at(29, 58))
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 2))
        XCTAssertEqual(model.guideWindowStart, base)
        model.alignGuideWindowToNow()
        XCTAssertEqual(model.guideWindowStart, at(30))
    }

    // MARK: Focus when the window moves

    func testAnEndedFocusedProgrammeMovesToTheChannelsCurrentOne() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("a", id, from: at(0), minutes: 30), program("b", id, from: at(30), minutes: 30)]
        }
        model.synchronizeClock(to: at(31))
        XCTAssertEqual(model.programToFocusAfterWindowShift(focusedProgramID: "a", channelID: channelID)?.id, "b")
        XCTAssertNil(model.programToFocusAfterWindowShift(focusedProgramID: "b", channelID: channelID))
    }

    func testAProgrammeStillRunningStaysFocusedWhenTheWindowMoves() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("long", id, from: at(-60), minutes: 170)]
        }
        model.synchronizeClock(to: at(31))
        XCTAssertNil(model.programToFocusAfterWindowShift(focusedProgramID: "long", channelID: channelID))
    }

    func testATickNeverMovesFocusWhileTheWindowIsHeld() throws {
        let (model, channelID) = try model(now: at(29, 58)) { id in
            [program("a", id, from: at(0), minutes: 30), program("b", id, from: at(30), minutes: 30)]
        }
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 3))
        XCTAssertEqual(model.guideWindowStart, base)
        XCTAssertNil(model.programToFocusAfterWindowShift(focusedProgramID: "a", channelID: channelID))
    }

    // MARK: Ticks

    func testTheNextTickIsTheNearestBoundaryAndNeverLaterThanThirtySeconds() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("a", id, from: at(0), minutes: 22.5), program("b", id, from: at(22, 30), minutes: 60)]
        }
        XCTAssertEqual(model.nextClockDeadline(channelIDs: [channelID]), at(22, 30), "a programme boundary in 30 s")
        XCTAssertEqual(model.nextClockDeadline(channelIDs: []), at(22, 30), "the label refresh")
        model.synchronizeClock(to: at(29, 50))
        XCTAssertEqual(model.nextClockDeadline(channelIDs: []), at(30), "the half hour")
        model.synchronizeClock(to: at(24))
        XCTAssertEqual(model.nextClockDeadline(channelIDs: [channelID]), at(24, 30))
    }

    func testAnEndingProgrammeBetweenTicksIsAnEarlierDeadline() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("a", id, from: at(0), minutes: 22 + 10.0 / 60), program("b", id, from: at(22, 10), minutes: 60)]
        }
        XCTAssertEqual(model.nextClockDeadline(channelIDs: [channelID]), at(22, 10))
    }

    func testADeferredAdvanceWakesWhenTheGuideGoesIdle() throws {
        let (model, _) = try model(now: at(29, 58))
        model.noteGuideInteraction()
        model.synchronizeClock(to: at(30, 2))
        XCTAssertEqual(model.nextClockDeadline(channelIDs: []), at(30, 6))
    }

    // MARK: "Now" derived state

    func testCrossingAnEndTimeChangesThePhaseAndTheHeroActions() throws {
        let (model, channelID) = try model(now: at(22)) { id in
            [program("a", id, from: at(0), minutes: 30), program("b", id, from: at(30), minutes: 30)]
        }
        let a = try XCTUnwrap(model.programs(for: channelID, from: at(0), hours: 1).first { $0.id == "a" })
        XCTAssertEqual(LiveTVProgramPhase(program: a, now: model.now), .onNow)
        XCTAssertEqual(
            LiveTVHeroActions(program: a, isPlayingChannel: true, now: model.now).primary, .watch(resumes: true))
        model.synchronizeClock(to: at(30))
        XCTAssertEqual(LiveTVProgramPhase(program: a, now: model.now), .ended)
        let ended = LiveTVHeroActions(program: a, isPlayingChannel: true, now: model.now)
        XCTAssertEqual(ended.primary, .none)
        XCTAssertFalse(ended.showsMultiview)
        XCTAssertTrue(ended.showsEndedLabel)
    }

    func testTheLeftLabelCountsDown() {
        func text(_ minutes: Double) -> String {
            LiveTVGlassFormatting.leftShort(remaining: minutes * 60).map { String(localized: $0) } ?? ""
        }
        XCTAssertEqual(text(28), "28m left")
        XCTAssertEqual(text(27), "27m left")
        XCTAssertEqual(text(0.5), "")
    }

    // MARK: Hero actions and selection

    func testHeroActionsForEndedNowAndFutureProgrammes() {
        let ended = program("e", "c", from: at(-60), minutes: 30)
        let now = program("n", "c", from: at(-10), minutes: 30)
        let future = program("f", "c", from: at(30), minutes: 30)
        let clock = at(0)
        let endedActions = LiveTVHeroActions(program: ended, isPlayingChannel: false, now: clock)
        XCTAssertEqual(endedActions.primary, .none)
        XCTAssertFalse(endedActions.showsMultiview)
        XCTAssertTrue(endedActions.showsEndedLabel)
        XCTAssertEqual(LiveTVHeroActions(program: now, isPlayingChannel: false, now: clock).primary, .watch(resumes: false))
        XCTAssertEqual(LiveTVHeroActions(program: now, isPlayingChannel: true, now: clock).primary, .watch(resumes: true))
        XCTAssertTrue(LiveTVHeroActions(program: now, isPlayingChannel: true, now: clock).showsMultiview)
        XCTAssertEqual(LiveTVHeroActions(program: future, isPlayingChannel: true, now: clock).primary, .upcoming)
        XCTAssertEqual(LiveTVHeroActions(program: nil, isPlayingChannel: true, now: clock).primary, .watch(resumes: true))
    }

    func testAnEndedProgrammeNeverOffersResumeEvenOnThePlayingChannel() {
        let ended = program("e", "c", from: at(-60), minutes: 30)
        XCTAssertEqual(LiveTVHeroActions(program: ended, isPlayingChannel: true, now: at(0)).primary, .none)
    }

    func testSelectOnAnEndedCellDoesNothing() {
        let ended = program("e", "c", from: at(-60), minutes: 30)
        let now = program("n", "c", from: at(-10), minutes: 30)
        let future = program("f", "c", from: at(30), minutes: 30)
        XCTAssertEqual(LiveTVGuideCellSelection.action(for: ended, now: at(0), picksChannel: false), .nothing)
        XCTAssertEqual(LiveTVGuideCellSelection.action(for: now, now: at(0), picksChannel: false), .tune)
        XCTAssertEqual(LiveTVGuideCellSelection.action(for: future, now: at(0), picksChannel: false), .details)
        XCTAssertEqual(LiveTVGuideCellSelection.action(for: ended, now: at(0), picksChannel: true), .tune)
    }

    // MARK: Time zones, DST and the window start (autoshift audit 5)

    private func zoned(_ id: String, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testTheWindowStartFloorsToTheLocalHalfHourInAQuarterHourZone() {
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")! // UTC+5:45
        XCTAssertEqual(
            LiveTVGuideClock.windowStart(for: zoned("Asia/Kathmandu", 2026, 3, 1, 22, 22), in: kathmandu),
            zoned("Asia/Kathmandu", 2026, 3, 1, 22, 0))
        XCTAssertEqual(
            LiveTVGuideClock.windowStart(for: zoned("Asia/Kathmandu", 2026, 3, 1, 22, 31), in: kathmandu),
            zoned("Asia/Kathmandu", 2026, 3, 1, 22, 30))
        XCTAssertEqual(
            LiveTVGuideClock.nextSlotBoundary(after: zoned("Asia/Kathmandu", 2026, 3, 1, 22, 22), in: kathmandu),
            zoned("Asia/Kathmandu", 2026, 3, 1, 22, 30))
    }

    func testTheWindowStartFollowsAZoneChange() {
        let instant = zoned("Asia/Kathmandu", 2026, 3, 1, 22, 22)
        XCTAssertNotEqual(
            LiveTVGuideClock.windowStart(for: instant, in: TimeZone(identifier: "Asia/Kathmandu")!),
            LiveTVGuideClock.windowStart(for: instant, in: TimeZone(identifier: "UTC")!))
    }

    func testTheShortDayOfTheSpringTransitionHasNoMissingOrDuplicateSlot() {
        let zone = TimeZone(identifier: "America/New_York")! // 2026-03-08: 02:00 -> 03:00
        var date = zoned("America/New_York", 2026, 3, 8, 0, 0)
        var starts: [Date] = []
        while date < zoned("America/New_York", 2026, 3, 9, 0, 0) {
            let start = LiveTVGuideClock.windowStart(for: date, in: zone)
            if starts.last != start { starts.append(start) }
            XCTAssertLessThanOrEqual(start, date)
            XCTAssertEqual(LiveTVGuideClock.nextSlotBoundary(after: date, in: zone), start.addingTimeInterval(1_800))
            date = date.addingTimeInterval(300)
        }
        XCTAssertEqual(starts.count, 46, "a 23-hour day has 46 half-hour slots")
        XCTAssertEqual(Set(starts).count, 46)
    }

    func testTheLongDayOfTheAutumnTransitionHasEverySlotOnce() {
        let zone = TimeZone(identifier: "America/New_York")! // 2026-11-01: 02:00 -> 01:00
        var date = zoned("America/New_York", 2026, 11, 1, 0, 0)
        var starts: [Date] = []
        while date < zoned("America/New_York", 2026, 11, 2, 0, 0) {
            let start = LiveTVGuideClock.windowStart(for: date, in: zone)
            if starts.last != start { starts.append(start) }
            date = date.addingTimeInterval(300)
        }
        XCTAssertEqual(starts.count, 50, "a 25-hour day has 50 half-hour slots")
        XCTAssertEqual(Set(starts).count, 50)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testMidnightAdvancesTheWindowToTheNewDay() throws {
        let zone = TimeZone(identifier: "America/Toronto")!
        let late = zoned("America/Toronto", 2026, 6, 1, 23, 59, 50)
        let (model, _) = try model(now: late)
        XCTAssertEqual(model.guideWindowStart, LiveTVGuideClock.windowStart(for: late, in: zone))
        model.synchronizeClock(to: zoned("America/Toronto", 2026, 6, 2, 0, 0, 1))
        XCTAssertEqual(model.guideWindowStart, LiveTVGuideClock.windowStart(
            for: zoned("America/Toronto", 2026, 6, 2, 0, 0, 1), in: zone))
    }

    // MARK: Auto-advance keeps a scrolled guide where the viewer is (autoshift audit 3)

    func testAShiftKeepsTheVisibleTimeWhenTheGuideIsScrolledRight() {
        let perSecond: CGFloat = 0.5
        let shifted = LiveTVGuideClock.timelineAfterShift(
            anchor: base, offset: 3_600 * perSecond, newAnchor: at(30), pointsPerSecond: perSecond)
        XCTAssertEqual(shifted.anchor, at(30))
        XCTAssertEqual(shifted.offset, 1_800 * perSecond, accuracy: 0.001)
        let beforeVisible = base.addingTimeInterval(Double(3_600 * perSecond / perSecond))
        let afterVisible = shifted.anchor.addingTimeInterval(Double(shifted.offset / perSecond))
        XCTAssertEqual(afterVisible, beforeVisible, "the same moment stays at the left edge")
    }

    func testAShiftThatOutrunsTheScrollClampsToTheNewWindowStart() {
        let shifted = LiveTVGuideClock.timelineAfterShift(
            anchor: base, offset: 600 * 0.5, newAnchor: at(30), pointsPerSecond: 0.5)
        XCTAssertEqual(shifted.anchor, at(30))
        XCTAssertEqual(shifted.offset, 0)
    }

    func testAnUnscrolledGuideShiftsItsAnchorOnly() {
        let shifted = LiveTVGuideClock.timelineAfterShift(
            anchor: base, offset: 0, newAnchor: at(30), pointsPerSecond: 0.5)
        XCTAssertEqual(shifted.anchor, at(30))
        XCTAssertEqual(shifted.offset, 0)
    }

    // MARK: A shift recomputes rows once (autoshift audit 7)

    func testOneShiftIsCheapForSixHundredAndFiftySixThousandChannels() async throws {
        for count in [600, 56_000] {
            let channels = await Task.detached {
                (0..<count).map { index in
                    LiveTVPrototypeChannel(
                        id: "c\(index)", number: index, name: "Channel \(index)", category: "Group \(index % 50)",
                        symbol: "tv", accent: 0, source: .iptv, tagline: "")
                }
            }.value
            let model = LiveTVPrototypeModel(now: at(29, 59), channels: channels)
            let revisionBefore = model.catalogRevision
            let clock = ContinuousClock()
            let elapsed = clock.measure { model.synchronizeClock(to: at(30, 1)) }
            XCTAssertEqual(model.guideWindowStart, at(30))
            XCTAssertEqual(model.catalogRevision, revisionBefore, "a shift does not rebuild the lineup")
            let milliseconds = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1_000
            XCTAssertLessThan(milliseconds, 8, "\(count) channels")
        }
    }
}
