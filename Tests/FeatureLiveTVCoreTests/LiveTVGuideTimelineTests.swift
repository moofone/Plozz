import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideTimelineTests: XCTestCase {
    func testInactiveRowsOnlyExposeCurrentContentUntilNativeNavigationIsRequested() {
        let current = LiveTVGuideFocusTarget.program(channelID: "channel", programID: "current")
        let future = LiveTVGuideFocusTarget.program(channelID: "channel", programID: "future")
        let logo = LiveTVGuideFocusTarget.channel("channel")
        let inactive = LiveTVGuideRowFocusPolicy(entryTarget: current, isActiveRow: false, usesNativeNavigation: false)
        XCTAssertTrue(inactive.allows(current))
        XCTAssertFalse(inactive.allows(future))
        XCTAssertFalse(inactive.allows(logo))
        for policy in [
            LiveTVGuideRowFocusPolicy(entryTarget: current, isActiveRow: true, usesNativeNavigation: false),
            LiveTVGuideRowFocusPolicy(entryTarget: current, isActiveRow: false, usesNativeNavigation: true)
        ] {
            XCTAssertTrue(policy.allows(current))
            XCTAssertTrue(policy.allows(future))
            XCTAssertTrue(policy.allows(logo))
            XCTAssertFalse(policy.allows(.program(channelID: "other", programID: "current")))
        }
    }

    func testCurrentEntryGatePreservesGapsAndRepeatedChannelOccurrences() {
        let gap = LiveTVGuideFocusTarget.channelContent("channel", slotID: "gap", section: .favorites)
        let policy = LiveTVGuideRowFocusPolicy(entryTarget: gap, isActiveRow: false, usesNativeNavigation: false)
        XCTAssertTrue(policy.allows(gap))
        XCTAssertFalse(policy.allows(.channelContent("channel", slotID: "gap", section: .channels)))
        XCTAssertFalse(policy.allows(.channelContent("channel", slotID: "later-gap", section: .favorites)))
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func program(_ id: String, _ from: TimeInterval, _ to: TimeInterval) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: id, channelID: "channel", title: id, subtitle: "",
            start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)
        )
    }

    func testNoGuideProducesOneHonestGap() {
        let end = start.addingTimeInterval(7_200)
        let slots = LiveTVGuideTimeline.slots(programs: [], from: start, to: end)
        XCTAssertEqual(slots.count, 1)
        XCTAssertNil(slots[0].program)
        XCTAssertEqual(slots[0].start, start)
        XCTAssertEqual(slots[0].end, end)
    }

    func testLeadingMiddleAndTrailingGapsKeepProgramsOnTheirClock() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [program("later", 4_000, 6_000), program("first", 600, 2_400)],
            from: start, to: start.addingTimeInterval(7_200)
        )
        XCTAssertEqual(slots.map { $0.program?.id }, [nil, "first", nil, "later", nil])
        XCTAssertEqual(slots.map { $0.start.timeIntervalSince(start) }, [0, 600, 2_400, 4_000, 6_000])
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince(start) }, [600, 2_400, 4_000, 6_000, 7_200])
        XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
    }

    func testOverlapsAndWindowEdgesDoNotOverrunTheGrid() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [
                program("first", -600, 1_800), program("overlap", 1_200, 3_600),
                program("covered", 1_300, 1_500), program("last", 3_600, 8_000)
            ],
            from: start, to: start.addingTimeInterval(7_200)
        )
        XCTAssertEqual(slots.map { $0.program?.id }, ["first", "overlap", "last"])
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +), 7_200)
        XCTAssertEqual(slots[1].start, slots[0].end)
        XCTAssertEqual(slots[2].start, slots[1].end)
    }

    func testShortLeadingSliceKeepsTheOriginalProgramTimes() throws {
        let original = program("already-started", -1_080, 660)
        let slots = LiveTVGuideTimeline.slots(
            programs: [original, program("next", 660, 2_400)],
            from: start, to: start.addingTimeInterval(7_200)
        )
        let leading = try XCTUnwrap(slots.first)
        XCTAssertEqual(leading.start, start)
        XCTAssertEqual(leading.end.timeIntervalSince(leading.start), 660)
        XCTAssertEqual(leading.program, original)
        XCTAssertEqual(slots[1].start, original.end)
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +), 7_200)
    }

    // MARK: Slivers

    func testAnEmptyIntervalThinnerThanTheMinimumIsAbsorbedByTheProgrammeBeforeIt() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [program("a", 0, 1_800), program("b", 1_830, 3_600)],
            from: start, to: start.addingTimeInterval(3_600), minimumDuration: 120)
        XCTAssertEqual(slots.map { $0.program?.id }, ["a", "b"])
        XCTAssertEqual(slots.map { $0.start.timeIntervalSince(start) }, [0, 1_830])
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince(start) }, [1_830, 3_600])
    }

    func testALeadingProgrammeSliverHandsItsTimeToTheNextProgramme() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [program("ending", -1_790, 30), program("next", 30, 1_800)],
            from: start, to: start.addingTimeInterval(1_800), minimumDuration: 120)
        XCTAssertEqual(slots.map { $0.program?.id }, ["next"])
        XCTAssertEqual(slots[0].start, start)
        XCTAssertEqual(slots[0].end, start.addingTimeInterval(1_800))
    }

    func testALeadingEmptySliverAndATrailingSliverAreAbsorbedToo() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [program("only", 40, 1_790)],
            from: start, to: start.addingTimeInterval(1_800), minimumDuration: 120)
        XCTAssertEqual(slots.map { $0.program?.id }, ["only"])
        XCTAssertEqual(slots[0].start, start)
        XCTAssertEqual(slots[0].end, start.addingTimeInterval(1_800))
    }

    func testSliversNeverChangeTheSpanAndNoSlotIsThinnerThanTheMinimum() {
        let programs = [
            program("a", -100, 60), program("b", 60, 1_000), program("c", 1_050, 1_080),
            program("d", 1_080, 3_000), program("e", 3_010, 3_500)
        ]
        let end = start.addingTimeInterval(3_600)
        let slots = LiveTVGuideTimeline.slots(programs: programs, from: start, to: end, minimumDuration: 120)
        XCTAssertEqual(slots.first?.start, start)
        XCTAssertEqual(slots.last?.end, end)
        for (before, after) in zip(slots, slots.dropFirst()) { XCTAssertEqual(before.end, after.start) }
        for slot in slots { XCTAssertGreaterThanOrEqual(slot.end.timeIntervalSince(slot.start), 120, slot.id) }
        XCTAssertEqual(slots.compactMap { $0.program?.id }, ["b", "d", "e"])
    }

    func testWithoutAMinimumTheSlotsAreUnchanged() {
        let programs = [program("a", 0, 1_800), program("b", 1_830, 3_600)]
        let end = start.addingTimeInterval(3_600)
        XCTAssertEqual(
            LiveTVGuideTimeline.slots(programs: programs, from: start, to: end, minimumDuration: 0),
            LiveTVGuideTimeline.slots(programs: programs, from: start, to: end))
    }

    // MARK: Minimum width (Final fix 2)

    func testMinimumDurationConvertsAWidthIntoGuideTime() {
        XCTAssertEqual(
            LiveTVGuideTimeline.minimumDuration(viewportSeconds: 10_800, timelineWidth: 1_500, minimumSlotWidth: 72), 518.4, accuracy: 0.001)
        XCTAssertEqual(LiveTVGuideTimeline.minimumDuration(viewportSeconds: 10_800, timelineWidth: 0, minimumSlotWidth: 72), 0)
    }

    /// The sim showed a ~3 minute clipped programme left of "Live PD" (A&E) and a ~5 minute one between two BBC News cells,
    /// both wider than the corner radii but too thin to read; with the tvOS minimum they are absorbed.
    func testShapesFromTheSimAreAbsorbedAtTheTVMinimum() {
        let minimum = LiveTVGuideTimeline.minimumDuration(viewportSeconds: 10_800, timelineWidth: 1_560, minimumSlotWidth: 72)
        XCTAssertGreaterThan(minimum, 400)
        let ae = LiveTVGuideTimeline.slots(
            programs: [program("ending", -1_700, 200), program("live-pd", 200, 3_000), program("next", 3_000, 5_000)],
            from: start, to: start.addingTimeInterval(10_800), minimumDuration: minimum)
        XCTAssertEqual(ae.compactMap { $0.program?.id }.first, "live-pd")
        XCTAssertEqual(ae.first?.start, start)
        let bbc = LiveTVGuideTimeline.slots(
            programs: [
                program("bbc-1", 0, 1_800), program("business", 1_800, 3_000), program("blip", 3_000, 3_300),
                program("bbc-2", 3_300, 5_000), program("tail", 10_000, 12_000)],
            from: start, to: start.addingTimeInterval(10_800), minimumDuration: minimum)
        XCTAssertEqual(bbc.compactMap { $0.program?.id }, ["bbc-1", "business", "bbc-2", "tail"].filter { $0 != "blip" })
        for slot in bbc { XCTAssertGreaterThanOrEqual(slot.end.timeIntervalSince(slot.start), minimum, slot.id) }
        XCTAssertEqual(bbc.last?.end, start.addingTimeInterval(10_800))
    }

    func testZeroLengthAndOverlappingListingsLeaveNoSlotBelowTheMinimum() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [
                program("a", 0, 3_000), program("zero", 3_000, 3_000), program("inside", 3_100, 3_200),
                program("b", 3_000, 6_000), program("edge", 10_600, 12_000)],
            from: start, to: start.addingTimeInterval(10_800), minimumDuration: 500)
        for slot in slots { XCTAssertGreaterThanOrEqual(slot.end.timeIntervalSince(slot.start), 500, slot.id) }
        XCTAssertEqual(slots.first?.start, start)
        XCTAssertEqual(slots.last?.end, start.addingTimeInterval(10_800))
    }
}
