import XCTest
@testable import CoreModels

final class LiveTVStableChannelNumbersTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LiveTVStableChannelNumbersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    func testNumbersStartAtOneAndFollowTheGivenOrder() {
        let numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["b", "a", "c"], at: day)
        XCTAssertEqual(numbers.number(for: "b"), 1)
        XCTAssertEqual(numbers.number(for: "a"), 2)
        XCTAssertEqual(numbers.number(for: "c"), 3)
    }

    func testAssignedNumbersSurviveReorderingAndGetNewChannelsTheNextFreeNumber() {
        let first = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["a", "b", "c"], at: day)
        let later = first.assigning(orderedChannelIDs: ["c", "new", "b", "a"], at: day.addingTimeInterval(60))
        XCTAssertEqual(["a", "b", "c"].map(later.number(for:)), [1, 2, 3])
        XCTAssertEqual(later.number(for: "new"), 4)
    }

    func testARemovedChannelKeepsItsNumberReservedAndGetsItBackWhenItReturns() {
        let first = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["a", "b", "c"], at: day)
        let withoutB = first.assigning(orderedChannelIDs: ["a", "c", "d"], at: day.addingTimeInterval(60))
        XCTAssertEqual(withoutB.number(for: "d"), 4, "A removed channel's number is not reused")
        let returned = withoutB.assigning(orderedChannelIDs: ["b", "a", "c", "d"], at: day.addingTimeInterval(120))
        XCTAssertEqual(returned.number(for: "b"), 2)
    }

    func testMergeKeepsTheEarliestAssignmentAndNeverSharesANumber() {
        let deviceA = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["x", "y"], at: day)
        let deviceB = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["z", "x"], at: day.addingTimeInterval(30))
        // B's "z" holds 1 (assigned later than A's "x" = 1) and B's "x" holds 2 (later than A's 1).
        let merged = deviceA.merging(deviceB)
        XCTAssertEqual(merged.number(for: "x"), 1, "The earliest assignment wins")
        XCTAssertEqual(merged.number(for: "y"), 2)
        XCTAssertEqual(merged.number(for: "z"), 3, "The later of two channels with one number moves to the next free number")
        XCTAssertEqual(Set(merged.assignments.values.map(\.number)).count, merged.assignments.count)
        XCTAssertEqual(deviceB.merging(deviceA), merged, "Both devices converge on the same numbers")
    }

    func testMergeIsIdempotent() {
        let a = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["x", "y"], at: day)
        let b = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["z", "x"], at: day.addingTimeInterval(30))
        let merged = a.merging(b)
        XCTAssertEqual(merged.merging(a).merging(b), merged)
        XCTAssertEqual(merged.merging(merged), merged)
    }

    func testInvalidAndOversizedInputIsNormalized() {
        let numbers = LiveTVStableChannelNumbers(assignments: [
            "zero": .init(number: 0, assignedAt: 1), "huge": .init(number: 1_000_000, assignedAt: 1),
            "": .init(number: 4, assignedAt: 1),
            "one": .init(number: 7, assignedAt: 1), "two": .init(number: 7, assignedAt: 2)
        ])
        XCTAssertEqual(Set(numbers.assignments.keys), ["one", "two"])
        XCTAssertEqual(numbers.number(for: "one"), 7)
        XCTAssertEqual(numbers.number(for: "two"), 8)

        let ids = (0..<(LiveTVStableChannelNumbers.maximumAssignments + 10)).map { "channel-\($0)" }
        let full = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ids, at: day)
        XCTAssertEqual(full.assignments.count, LiveTVStableChannelNumbers.maximumAssignments)
        XCTAssertNil(full.number(for: ids.last!))
    }

    func testCodableRoundTripIsVersionedAndAnUnknownVersionReadsAsEmpty() throws {
        let numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["a", "b"], at: day)
        let data = try JSONEncoder().encode(numbers)
        XCTAssertEqual(try JSONDecoder().decode(LiveTVStableChannelNumbers.self, from: data), numbers)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, LiveTVStableChannelNumbers.currentVersion)
        let future = Data(#"{"version":99,"ids":["a"],"numbers":[1],"assignedAt":[1]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(LiveTVStableChannelNumbers.self, from: future).isEmpty)
        let ragged = Data(#"{"version":1,"ids":["a","b"],"numbers":[1],"assignedAt":[1]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LiveTVStableChannelNumbers.self, from: ragged))
    }

    func testMigratingAChannelIdentityMovesItsNumber() {
        let numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["old", "other"], at: day)
        let migrated = numbers.migratingChannelIDs(["old": "new"])
        XCTAssertEqual(migrated.number(for: "new"), 1)
        XCTAssertNil(migrated.number(for: "old"))
        XCTAssertEqual(migrated.number(for: "other"), 2)
    }

    func testNumbersPersistWithTheProfileAndStayIsolatedBetweenProfiles() throws {
        let defaults = makeDefaults()
        let owner = LiveTVPreferencesStore(defaults: defaults, namespace: nil)
        let guest = LiveTVPreferencesStore(defaults: defaults, namespace: "guest")
        let numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["a", "b"], at: day)
        try owner.save(LiveTVPreferences(stableChannelNumbers: numbers))
        XCTAssertEqual(try LiveTVPreferencesStore(defaults: defaults, namespace: nil).load().stableChannelNumbers, numbers)
        XCTAssertTrue(try guest.load().stableChannelNumbers.isEmpty)
        try guest.save(LiveTVPreferences(
            stableChannelNumbers: LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["b"], at: day)))
        XCTAssertEqual(try guest.load().stableChannelNumbers.number(for: "b"), 1)
        XCTAssertEqual(try owner.load().stableChannelNumbers.number(for: "b"), 2)
    }

    func testPreferencesWrittenBeforeNumbersExistLoadWithNone() throws {
        let legacy = Data(#"{"favoriteIDs":["a"],"recentChannelIDs":[]}"#.utf8)
        let preferences = try JSONDecoder().decode(LiveTVPreferences.self, from: legacy)
        XCTAssertTrue(preferences.stableChannelNumbers.isEmpty)
        XCTAssertEqual(preferences.favoriteIDs, ["a"])
    }

    func testChannelOperationsKeepNumbers() {
        let numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: ["a"], at: day)
        let preferences = LiveTVPreferences(stableChannelNumbers: numbers)
        XCTAssertEqual(preferences.hidingChannel(id: "a", name: "A").stableChannelNumbers, numbers)
        XCTAssertEqual(preferences.restoringChannel(id: "a").stableChannelNumbers, numbers)
        XCTAssertEqual(preferences.restoringAllChannels().stableChannelNumbers, numbers)
        XCTAssertEqual(preferences.migratingChannelIDs([:]).stableChannelNumbers, numbers)
    }

    func testShowChannelNumbersIsOffByDefaultAndPersistsPerProfile() {
        let defaults = makeDefaults()
        XCTAssertFalse(LiveTVViewSettings().showsChannelNumbers)
        XCTAssertFalse(LiveTVViewSettingsStore(defaults: defaults).load().showsChannelNumbers)
        let guestStore = LiveTVViewSettingsStore(defaults: defaults, namespace: "guest")
        var settings = guestStore.load()
        settings.showsChannelNumbers = true
        guestStore.save(settings)
        XCTAssertTrue(LiveTVViewSettingsStore(defaults: defaults, namespace: "guest").load().showsChannelNumbers)
        XCTAssertFalse(LiveTVViewSettingsStore(defaults: defaults).load().showsChannelNumbers)
    }
}
