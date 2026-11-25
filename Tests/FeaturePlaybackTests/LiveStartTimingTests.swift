#if DEBUG && canImport(UIKit)
import XCTest
@testable import FeaturePlayback

final class LiveStartTimingTests: XCTestCase {
    func testSummaryAttributesEachSegmentWithoutIdentifyingTheStream() throws {
        var timing = LiveStartTiming(selectedAt: 10, id: "abc")
        timing.markAddressResolved(at: 10.2)
        timing.markAddressResolved(at: 11)
        let line = try XCTUnwrap(timing.markFirstFrame(at: 12, relayFirstByteMilliseconds: 600))
        XCTAssertEqual(
            line,
            "LIVE_START id=abc select→address=200ms address→firstUpstreamByte=600ms"
                + " firstByte→firstFrame=1200ms address→firstFrame=1800ms total=2000ms rebuffers=0"
        )
        XCTAssertNil(timing.markFirstFrame(at: 13, relayFirstByteMilliseconds: 600))
    }

    func testMissingRelayByteIsReportedAsUnknownAndOversizedByteIsClamped() throws {
        var unknown = LiveStartTiming(selectedAt: 0, id: "u")
        unknown.markAddressResolved(at: 0.1)
        let line = try XCTUnwrap(unknown.markFirstFrame(at: 1, relayFirstByteMilliseconds: nil))
        XCTAssertTrue(line.contains("address→firstUpstreamByte=unknown firstByte→firstFrame=unknown"))

        var clamped = LiveStartTiming(selectedAt: 0, id: "c")
        clamped.markAddressResolved(at: 0)
        let clampedLine = try XCTUnwrap(clamped.markFirstFrame(at: 1, relayFirstByteMilliseconds: 5_000))
        XCTAssertTrue(clampedLine.contains("address→firstUpstreamByte=1000ms firstByte→firstFrame=0ms"))
    }

    func testRebufferingCountsStallsAndReportsEachDuration() throws {
        var timing = LiveStartTiming(selectedAt: 0, id: "r")
        XCTAssertNil(timing.observeBuffering(true, at: 0.5))
        XCTAssertEqual(timing.rebuffers, 0)
        _ = timing.markFirstFrame(at: 1, relayFirstByteMilliseconds: nil)
        XCTAssertNil(timing.observeBuffering(true, at: 2))
        XCTAssertNil(timing.observeBuffering(true, at: 2.5))
        XCTAssertEqual(try XCTUnwrap(timing.observeBuffering(false, at: 3.25)), "LIVE_STALL id=r n=1 duration=1250ms")
        XCTAssertNil(timing.observeBuffering(false, at: 4))
        XCTAssertNil(timing.observeBuffering(true, at: 5))
        XCTAssertEqual(try XCTUnwrap(timing.observeBuffering(false, at: 5.1)), "LIVE_STALL id=r n=2 duration=100ms")
        XCTAssertEqual(timing.rebuffers, 2)
    }

    @MainActor
    func testFirstPresentedFrameIsNoticedWithinOneShortTick() async throws {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        engine.liveSnapshot.phase = .loading
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/channel.m3u8")!
        )
        defer { model.stop() }
        await model.start()
        XCTAssertFalse(model.hasPresentedFrame)

        engine.liveSnapshot.firstFrameReady = true
        engine.liveSnapshot.phase = .playing
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.hasPresentedFrame, "a 250 ms poll would not have observed the frame yet")
    }
}
#endif
