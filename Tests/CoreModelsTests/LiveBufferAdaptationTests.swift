import XCTest
@testable import CoreModels

final class LiveBufferAdaptationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testStartsAtTheEnginesOwnHoldbackAndGrowsOneStepPerStallUpToTheCap() {
        var adaptation = LiveBufferAdaptation()
        XCTAssertNil(adaptation.targetSeconds)
        let expected: [TimeInterval] = [4, 8, 15, 30, 30, 30]
        for (index, target) in expected.enumerated() {
            adaptation.recordStall(at: start.addingTimeInterval(Double(index) * 120))
            XCTAssertEqual(adaptation.targetSeconds, target)
        }
    }

    func testStallsInsideTheDebounceWindowGrowOnlyOnce() {
        var adaptation = LiveBufferAdaptation()
        adaptation.recordStall(at: start)
        adaptation.recordStall(at: start.addingTimeInterval(10))
        adaptation.recordStall(at: start.addingTimeInterval(59))
        XCTAssertEqual(adaptation.targetSeconds, 4)
        adaptation.recordStall(at: start.addingTimeInterval(61))
        XCTAssertEqual(adaptation.targetSeconds, 8)
    }

    func testStablePlaybackGivesBackOneStepPerTenMinutesAndStallRestartsTheClock() {
        var adaptation = LiveBufferAdaptation()
        adaptation.recordStall(at: start)
        adaptation.recordStall(at: start.addingTimeInterval(100))
        XCTAssertEqual(adaptation.targetSeconds, 8)
        adaptation.recordStablePlayback(seconds: 599)
        XCTAssertEqual(adaptation.targetSeconds, 8)
        adaptation.recordStall(at: start.addingTimeInterval(110))   // debounced, but restarts the clock
        adaptation.recordStablePlayback(seconds: 599)
        XCTAssertEqual(adaptation.targetSeconds, 8)
        adaptation.recordStablePlayback(seconds: 1)
        XCTAssertEqual(adaptation.targetSeconds, 4)
        adaptation.recordStablePlayback(seconds: 5_000)
        XCTAssertNil(adaptation.targetSeconds)
        adaptation.recordStablePlayback(seconds: .infinity)
        XCTAssertNil(adaptation.targetSeconds)
    }

    func testPersistsPerProfileAndSourceWithoutStoringIdentifiers() throws {
        try withDefaults { defaults in
            let store = LiveBufferAdaptationStore(defaults: defaults)
            store.recordStall(namespace: "adult", sourceID: "provider-account-123", at: start)
            XCTAssertEqual(LiveBufferAdaptationStore(defaults: defaults)
                .targetSeconds(namespace: "adult", sourceID: "provider-account-123"), 4)
            XCTAssertNil(store.targetSeconds(namespace: "kids", sourceID: "provider-account-123"))
            XCTAssertNil(store.targetSeconds(namespace: nil, sourceID: "provider-account-123"))
            XCTAssertNil(store.targetSeconds(namespace: "adult", sourceID: "other-source"))
            let data = try XCTUnwrap(defaults.data(forKey: LiveBufferAdaptationStore.storageKey))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("provider-account-123"))
            XCTAssertFalse(text.contains("adult"))
        }
    }

    func testDecayToTheHoldbackForgetsTheSourceAndTheStoreIsBounded() throws {
        try withDefaults { defaults in
            let store = LiveBufferAdaptationStore(defaults: defaults)
            store.recordStall(namespace: nil, sourceID: "a", at: start)
            store.recordStablePlayback(namespace: nil, sourceID: "a", seconds: 600, at: start)
            XCTAssertNil(store.targetSeconds(namespace: nil, sourceID: "a"))
            XCTAssertNil(defaults.data(forKey: LiveBufferAdaptationStore.storageKey).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?.first)
            for index in 0..<(LiveBufferAdaptationStore.capacity + 10) {
                store.recordStall(namespace: nil, sourceID: "s\(index)", at: start.addingTimeInterval(Double(index)))
            }
            XCTAssertNil(store.targetSeconds(namespace: nil, sourceID: "s0"))
            XCTAssertEqual(store.targetSeconds(namespace: nil, sourceID: "s\(LiveBufferAdaptationStore.capacity + 9)"), 4)
        }
    }

    func testCorruptStoredDataFallsBackToTheHoldback() throws {
        try withDefaults { defaults in
            defaults.set(Data([1, 2, 3]), forKey: LiveBufferAdaptationStore.storageKey)
            XCTAssertNil(LiveBufferAdaptationStore(defaults: defaults).targetSeconds(namespace: nil, sourceID: "a"))
        }
    }

    func testAdaptationDoesNotTransferWithProfiles() throws {
        try withDefaults { source in
            LiveBufferAdaptationStore(defaults: source).recordStall(namespace: nil, sourceID: "a", at: start)
            for namespace: String? in [nil, "adult"] {
                XCTAssertNil(ProfileSettingsTransfer.capture(namespace: namespace, defaults: source)[LiveBufferAdaptationStore.storageKey])
            }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "LiveBufferAdaptationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
