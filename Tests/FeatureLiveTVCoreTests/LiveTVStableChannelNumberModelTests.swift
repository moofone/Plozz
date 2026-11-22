import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVStableChannelNumberModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LiveTVStableChannelNumberModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func channel(_ id: String, providerNumber: Int) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: providerNumber, name: "Channel \(id)", category: "News", symbol: "tv", accent: 0,
            source: .iptv, tagline: "")
    }

    private func numbers(_ model: LiveTVPrototypeModel) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: model.channels.map { ($0.id, $0.number) })
    }

    func testFirstNumbersFollowTheLineupOrderNotTheProviderNumbers() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults())
        let model = LiveTVPrototypeModel(
            channels: [channel("c", providerNumber: 16_986), channel("a", providerNumber: 5), channel("b", providerNumber: 90)],
            preferencesStore: store)
        XCTAssertEqual(numbers(model), ["a": 1, "b": 2, "c": 3])
        XCTAssertEqual(try store.load().stableChannelNumbers.assignments.mapValues(\.number), ["a": 1, "b": 2, "c": 3])
    }

    func testANumberSurvivesAProviderRenumberAndAReorder() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults())
        let model = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 16_986), channel("b", providerNumber: 16_987)], preferencesStore: store)
        XCTAssertEqual(numbers(model), ["a": 1, "b": 2])
        // The provider renumbers the same stream IDs the next day and lists them in another order.
        try model.replaceChannels([channel("b", providerNumber: 16_328), channel("a", providerNumber: 16_484)])
        XCTAssertEqual(numbers(model), ["a": 1, "b": 2])
        // A relaunch reads the same numbers from the profile's store.
        let relaunched = LiveTVPrototypeModel(
            channels: [channel("b", providerNumber: 1), channel("a", providerNumber: 2)], preferencesStore: store)
        XCTAssertEqual(numbers(relaunched), ["a": 1, "b": 2])
    }

    func testANewChannelGetsTheNextFreeNumberAndARemovedOneGetsItsOldNumberBack() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults())
        let model = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 1), channel("b", providerNumber: 2), channel("c", providerNumber: 3)],
            preferencesStore: store)
        try model.replaceChannels([channel("a", providerNumber: 1), channel("c", providerNumber: 2), channel("d", providerNumber: 3)])
        XCTAssertEqual(numbers(model), ["a": 1, "c": 3, "d": 4], "A removed channel's number is not reused")
        try model.replaceChannels([
            channel("a", providerNumber: 1), channel("b", providerNumber: 2), channel("c", providerNumber: 3),
            channel("d", providerNumber: 4)
        ])
        XCTAssertEqual(numbers(model), ["a": 1, "b": 2, "c": 3, "d": 4])
    }

    func testCatalogReplacementAndTheBackgroundPreparationUseTheSameNumbers() async throws {
        let model = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 1)], preferencesStore: LiveTVPreferencesStore(defaults: makeDefaults()))
        let next = [channel("z", providerNumber: 1), channel("a", providerNumber: 2)]
        await model.prepareCatalog(channels: next)
        try model.replaceCatalog(channels: next, programs: [])
        XCTAssertEqual(numbers(model), ["a": 1, "z": 2])
        XCTAssertEqual(model.preparedInstallCount, 1, "The prepared build matches the numbered lineup")
    }

    func testEachProfileHasItsOwnNumbers() throws {
        let defaults = makeDefaults()
        let owner = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 1), channel("b", providerNumber: 2)],
            preferencesStore: LiveTVPreferencesStore(defaults: defaults))
        let guest = LiveTVPrototypeModel(
            channels: [channel("b", providerNumber: 1), channel("a", providerNumber: 2)],
            preferencesStore: LiveTVPreferencesStore(defaults: defaults, namespace: "guest"))
        XCTAssertEqual(numbers(owner), ["a": 1, "b": 2])
        XCTAssertEqual(numbers(guest), ["b": 1, "a": 2])
    }

    func testSavingOtherPreferencesKeepsTheNumbers() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults())
        let model = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 1), channel("b", providerNumber: 2)], preferencesStore: store)
        model.toggleFavorite("b")
        XCTAssertEqual(try store.load().stableChannelNumbers.number(for: "b"), 2)
        XCTAssertEqual(try store.load().favoriteIDs, ["b"])
    }

    func testANumberAMergedPeerAssignedIsNotOverwrittenByTheModelsNextSave() throws {
        let store = LiveTVPreferencesStore(defaults: makeDefaults())
        let model = LiveTVPrototypeModel(
            channels: [channel("a", providerNumber: 1), channel("b", providerNumber: 2)], preferencesStore: store)
        var stored = try store.load()
        stored.stableChannelNumbers = stored.stableChannelNumbers.merging(assignments: ["peer": .init(number: 9, assignedAt: 1)])
        try store.save(stored)
        model.toggleFavorite("a")
        XCTAssertEqual(try store.load().stableChannelNumbers.number(for: "peer"), 9)
    }

    func testChannelNumbersAreHiddenUntilTheSettingTurnsThemOn() {
        XCTAssertFalse(LiveTVPrototypeModel().showsChannelNumbers)
    }

    func testAModelWithoutAPreferencesStoreShowsTheNumbersItWasGiven() {
        let model = LiveTVPrototypeModel(channels: [channel("a", providerNumber: 101)])
        XCTAssertEqual(numbers(model), ["a": 101])
    }
}
