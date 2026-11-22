import Foundation
import XCTest
@testable import CoreModels

final class LiveChannelMeasuredQualityTests: XCTestCase {
    private func store() -> LiveChannelMeasuredQualityStore {
        LiveChannelMeasuredQualityStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("measured-\(UUID().uuidString)/measured.json"))
    }

    func testLabelThresholds() {
        XCTAssertEqual(LiveChannelResolutionLabel(height: 2_160), .ultraHD)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 2_000), .ultraHD)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 1_999), .fullHD)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 1_080), .fullHD)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 1_000), .fullHD)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 999), .hd)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 720), .hd)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 700), .hd)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 699), .sd)
        XCTAssertEqual(LiveChannelResolutionLabel(height: 480), .sd)
        XCTAssertEqual(["4K", "1080p", "720p", "SD"], [LiveChannelResolutionLabel.ultraHD, .fullHD, .hd, .sd].map(\.text))
    }

    func testRecorderTakesTheHeightHeldLongestAfterTheFirstTenSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var recorder = LiveChannelResolutionRecorder()
        // 0-10 s at 480 (ignored), then 720 for 60 s with a 6 s dip to 1080 and a 4 s dip to 480.
        recorder.record(height: 480, at: t0)
        recorder.record(height: 720, at: t0.addingTimeInterval(10))
        recorder.record(height: 1_080, at: t0.addingTimeInterval(30))
        recorder.record(height: 720, at: t0.addingTimeInterval(36))
        recorder.record(height: 480, at: t0.addingTimeInterval(60))
        recorder.record(height: 720, at: t0.addingTimeInterval(64))
        XCTAssertEqual(recorder.steadyHeight(endingAt: t0.addingTimeInterval(90)), 720)
    }

    func testRecorderWithNothingHeldLongEnoughHasNoHeight() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var recorder = LiveChannelResolutionRecorder()
        recorder.record(height: 720, at: t0)
        XCTAssertNil(recorder.steadyHeight(endingAt: t0.addingTimeInterval(8)), "the first 10 s never count")
        XCTAssertNil(LiveChannelResolutionRecorder().steadyHeight(endingAt: t0))
    }

    func testStoreKeepsTheModeOfTheLastFivePlaysSoOneSpikeOrDipDoesNotChangeIt() {
        let store = store()
        for height in [720, 720, 720, 720] { store.record(height: height, sourceID: "s", channelID: "16940") }
        store.record(height: 1_080, sourceID: "s", channelID: "16940")
        XCTAssertEqual(store.measuredHeight(sourceID: "s", channelID: "16940"), 720)
        store.record(height: 480, sourceID: "s", channelID: "16940")
        XCTAssertEqual(store.measuredHeight(sourceID: "s", channelID: "16940"), 720)
        // Older plays fall out: after five 1080 plays the 720s are gone.
        for _ in 0..<5 { store.record(height: 1_080, sourceID: "s", channelID: "16940") }
        XCTAssertEqual(store.measuredHeight(sourceID: "s", channelID: "16940"), 1_080)
        XCTAssertNil(store.measuredHeight(sourceID: "s", channelID: "other"))
        XCTAssertNil(store.measuredHeight(sourceID: "other", channelID: "16940"))
    }

    func testStoreSurvivesRelaunch() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("measured-\(UUID().uuidString)/m.json")
        LiveChannelMeasuredQualityStore(fileURL: url).record(height: 720, sourceID: "s", channelID: "1")
        XCTAssertEqual(LiveChannelMeasuredQualityStore(fileURL: url).label(sourceID: "s", channelID: "1"), .hd)
    }

    func testMeasured720pReplacesTheNamesHD() {
        XCTAssertEqual(IPTVChannelTag.displayTexts(for: [.country("CA"), .hd, .fps(60)], measured: .hd), ["CA", "720p", "60fps"])
        XCTAssertEqual(IPTVChannelTag.displayTexts(for: [.fhd, .hdr], measured: .hd), ["720p", "HDR"])
        XCTAssertEqual(IPTVChannelTag.displayTexts(for: [.country("CA")], measured: .sd), ["CA", "SD"],
                       "a measured label is shown even when the name made no claim")
    }

    func testNoMeasurementKeepsTheClaim() {
        XCTAssertEqual(IPTVChannelTag.displayTexts(for: [.country("CA"), .hd], measured: nil), ["CA", "HD"])
        XCTAssertEqual(IPTVChannelTag.guideBadge(in: [.k4], measured: nil), .k4)
    }

    func testMeasured1080pFourKChannelLosesTheGuideBadge() {
        XCTAssertNil(IPTVChannelTag.guideBadge(in: [.k4], measured: .fullHD))
        XCTAssertNil(IPTVChannelTag.guideBadge(in: [.uhd, .hdr], measured: .hd))
        XCTAssertEqual(IPTVChannelTag.guideBadge(in: [.k4], measured: .ultraHD), .k4)
        XCTAssertNil(IPTVChannelTag.guideBadge(in: [.hd], measured: .ultraHD), "a measured 4K channel is not given a badge the name never claimed")
    }
}
