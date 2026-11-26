#if DEBUG && canImport(UIKit)
import CoreModels
import XCTest
@testable import FeaturePlayback

final class LiveStartTimingTests: XCTestCase {
    func testSummaryAttributesEachSegmentWithoutIdentifyingTheStream() throws {
        var timing = LiveStartTiming(selectedAt: 10, id: "abc")
        timing.markAddressResolved(at: 10.2)
        timing.markAddressResolved(at: 11)
        let line = try XCTUnwrap(timing.markFirstFrame(at: 12, relayRequestFirstByteMilliseconds: 600))
        XCTAssertEqual(
            line,
            "LIVE_START id=abc select→address=200ms address→firstUpstreamByte=600ms"
                + " firstByte→firstFrame=1200ms address→firstFrame=1800ms total=2000ms rebuffers=0"
        )
        XCTAssertNil(timing.markFirstFrame(at: 13, relayRequestFirstByteMilliseconds: 600))
    }

    func testRelayStartedLongBeforeTheTuneDoesNotSwallowTheFirstByteSplit() throws {
        var request = PlaybackDeliveryEvidence.Request(
            sequence: 1, resource: .root, method: .get, startedMilliseconds: 60_000
        )
        request.firstByteMilliseconds = 300
        var timing = LiveStartTiming(selectedAt: 100, id: "w")
        timing.markAddressResolved(at: 100.1)
        let line = try XCTUnwrap(timing.markFirstFrame(
            at: 101, relayRequestFirstByteMilliseconds: LiveStartTiming.requestFirstByteMilliseconds(of: request)
        ))
        XCTAssertTrue(line.contains("address→firstUpstreamByte=300ms firstByte→firstFrame=600ms"), line)
    }

    func testStallAtOrAboveTheAdaptationThresholdIsCounted() throws {
        var timing = LiveStartTiming(selectedAt: 0, id: "t")
        _ = timing.markFirstFrame(at: 1, relayRequestFirstByteMilliseconds: nil)
        _ = timing.observeBuffering(true, at: 2)
        XCTAssertEqual(try XCTUnwrap(timing.observeBuffering(false, at: 3.5)), "LIVE_STALL id=t n=1 duration=1500ms counted=true")
    }

    func testMissingRelayByteIsReportedAsUnknownAndOversizedByteIsClamped() throws {
        var unknown = LiveStartTiming(selectedAt: 0, id: "u")
        unknown.markAddressResolved(at: 0.1)
        let line = try XCTUnwrap(unknown.markFirstFrame(at: 1, relayRequestFirstByteMilliseconds: nil))
        XCTAssertTrue(line.contains("address→firstUpstreamByte=unknown firstByte→firstFrame=unknown"))

        var clamped = LiveStartTiming(selectedAt: 0, id: "c")
        clamped.markAddressResolved(at: 0)
        let clampedLine = try XCTUnwrap(clamped.markFirstFrame(at: 1, relayRequestFirstByteMilliseconds: 5_000))
        XCTAssertTrue(clampedLine.contains("address→firstUpstreamByte=1000ms firstByte→firstFrame=0ms"))
    }

    func testRebufferingCountsStallsAndReportsEachDuration() throws {
        var timing = LiveStartTiming(selectedAt: 0, id: "r")
        XCTAssertNil(timing.observeBuffering(true, at: 0.5))
        XCTAssertEqual(timing.rebuffers, 0)
        _ = timing.markFirstFrame(at: 1, relayRequestFirstByteMilliseconds: nil)
        XCTAssertNil(timing.observeBuffering(true, at: 2))
        XCTAssertNil(timing.observeBuffering(true, at: 2.5))
        XCTAssertEqual(try XCTUnwrap(timing.observeBuffering(false, at: 3.25)), "LIVE_STALL id=r n=1 duration=1250ms counted=false")
        XCTAssertNil(timing.observeBuffering(false, at: 4))
        XCTAssertNil(timing.observeBuffering(true, at: 5))
        XCTAssertEqual(try XCTUnwrap(timing.observeBuffering(false, at: 5.1)), "LIVE_STALL id=r n=2 duration=100ms counted=false")
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

    func testSignalsReportOneStallPerEpisodeOnlyAfterTheMinimumDuration() {
        var signals = LiveBufferAdaptationSignals()
        XCTAssertFalse(signals.observe(isStalling: true, isStablePlaying: false, at: 0).stalled)
        XCTAssertFalse(signals.observe(isStalling: true, isStablePlaying: false, at: 1.4).stalled)
        XCTAssertTrue(signals.observe(isStalling: true, isStablePlaying: false, at: 1.5).stalled)
        XCTAssertFalse(signals.observe(isStalling: true, isStablePlaying: false, at: 9).stalled)
        _ = signals.observe(isStalling: false, isStablePlaying: true, at: 10)
        XCTAssertFalse(signals.observe(isStalling: true, isStablePlaying: false, at: 11).stalled)
        XCTAssertTrue(signals.observe(isStalling: true, isStablePlaying: false, at: 12.6).stalled)
    }

    func testSignalsBatchStablePlaybackIgnoreGapsAndFlushTheRemainder() {
        var signals = LiveBufferAdaptationSignals()
        var reported: TimeInterval = 0
        var time: TimeInterval = 0
        for _ in 0..<130 {   // 130 half-second ticks = 65 s
            time += 0.5
            reported += signals.observe(isStalling: false, isStablePlaying: true, at: time).stableSeconds
        }
        XCTAssertEqual(reported, 60.5, accuracy: 0.6)
        // A suspend gap counts for at most one tick's allowance; a pause counts for nothing.
        _ = signals.observe(isStalling: false, isStablePlaying: true, at: time + 3_600)
        _ = signals.observe(isStalling: false, isStablePlaying: false, at: time + 3_601)
        _ = signals.observe(isStalling: false, isStablePlaying: true, at: time + 3_700)
        let flushed = signals.flush()
        XCTAssertEqual(flushed, 6.5, accuracy: 0.6, "4.5 s carried + one 2 s capped gap; the pause adds nothing")
        XCTAssertEqual(signals.flush(), 0)
    }

    @MainActor
    func testRebufferAfterTheFirstFrameRaisesTheSourcesNextTuneAndStartupWaitsDoNot() async throws {
        let suite = "LiveStartTimingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = LiveBufferAdaptationScope(
            namespace: "profile", sourceID: "source", store: LiveBufferAdaptationStore(defaults: defaults)
        )
        var clock: TimeInterval = 100
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        engine.liveSnapshot.phase = .loading
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            uptime: { clock }, bufferAdaptation: scope
        )
        defer { model.stop() }
        await model.start()
        clock += 10   // a long startup wait is not a stall
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(scope.targetSeconds())

        engine.liveSnapshot.firstFrameReady = true
        engine.liveSnapshot.phase = .playing
        try await Task.sleep(for: .milliseconds(200))
        engine.liveSnapshot.phase = .rebuffering
        try await Task.sleep(for: .milliseconds(200))
        clock += 3
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(scope.targetSeconds(), 4)
    }
}
#endif
