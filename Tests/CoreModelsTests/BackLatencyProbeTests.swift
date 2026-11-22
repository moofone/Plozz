import XCTest
@testable import CoreModels

/// GUIDE-PLAYING part D: Back from the player to the guide, and the reverse, are timed from the
/// press to the destination's first committed frame. Median < 100 ms and worst < 150 ms over 10 presses.
@MainActor
final class BackLatencyProbeTests: XCTestCase {
    private final class Clock {
        var instant = ContinuousClock.now
        func advance(milliseconds: Int) { instant = instant.advanced(by: .milliseconds(milliseconds)) }
    }

    private func press(
        _ probe: BackLatencyProbe, _ clock: Clock, _ transition: BackLatencyProbe.Transition, milliseconds: Int
    ) -> Duration? {
        probe.pressed(transition)
        clock.advance(milliseconds: milliseconds)
        return probe.presented(transition)
    }

    func testAPressIsTimedUntilTheDestinationPresents() {
        let clock = Clock()
        let probe = BackLatencyProbe(now: { clock.instant })
        XCTAssertEqual(press(probe, clock, .playerToGuide, milliseconds: 42), .milliseconds(42))
        XCTAssertEqual(probe.samples(.playerToGuide), [.milliseconds(42)])
        XCTAssertTrue(probe.samples(.guideToPlayer).isEmpty)
    }

    func testPresentingWithoutAPressOrForAnotherTransitionIsNotASample() {
        let clock = Clock()
        let probe = BackLatencyProbe(now: { clock.instant })
        XCTAssertNil(probe.presented(.playerToGuide))
        probe.pressed(.guideToPlayer)
        clock.advance(milliseconds: 30)
        XCTAssertNil(probe.presented(.playerToGuide), "the other direction's press is not consumed")
        XCTAssertEqual(probe.presented(.guideToPlayer), .milliseconds(30))
        XCTAssertNil(probe.presented(.guideToPlayer), "one press is one sample")
    }

    func testTenPressesMeetTheTargetWhenTheMedianIsUnder100AndTheWorstUnder150() {
        let clock = Clock()
        let probe = BackLatencyProbe(now: { clock.instant })
        for milliseconds in [60, 70, 80, 90, 95, 99, 100, 110, 120, 149] {
            _ = press(probe, clock, .playerToGuide, milliseconds: milliseconds)
        }
        XCTAssertEqual(probe.median(.playerToGuide), .milliseconds(97))
        XCTAssertEqual(probe.worst(.playerToGuide), .milliseconds(149))
        XCTAssertTrue(probe.meetsTarget(.playerToGuide))
    }

    func testASlowMedianOrAWorstPressMissesTheTarget() {
        let clock = Clock()
        let slowMedian = BackLatencyProbe(now: { clock.instant })
        for milliseconds in [90, 100, 100, 120, 130] { _ = press(slowMedian, clock, .guideToPlayer, milliseconds: milliseconds) }
        XCTAssertFalse(slowMedian.meetsTarget(.guideToPlayer))

        let slowWorst = BackLatencyProbe(now: { clock.instant })
        for milliseconds in [50, 50, 50, 50, 150] { _ = press(slowWorst, clock, .guideToPlayer, milliseconds: milliseconds) }
        XCTAssertFalse(slowWorst.meetsTarget(.guideToPlayer), "150 ms is not under 150 ms")

        XCTAssertFalse(BackLatencyProbe(now: { clock.instant }).meetsTarget(.playerToGuide), "no samples is not a pass")
    }

    func testResetForgetsSamplesAndAPendingPress() {
        let clock = Clock()
        let probe = BackLatencyProbe(now: { clock.instant })
        _ = press(probe, clock, .playerToGuide, milliseconds: 10)
        probe.pressed(.playerToGuide)
        probe.reset()
        XCTAssertNil(probe.presented(.playerToGuide))
        XCTAssertTrue(probe.samples(.playerToGuide).isEmpty)
    }
}
