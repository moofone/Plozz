import XCTest
@testable import CoreModels

final class LiveTVFavoriteFilterStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveTVFavoriteFilterStoreTests.\(UUID().uuidString)")
    }

    func testFirstRunHasNoFilters() throws {
        XCTAssertEqual(try LiveTVFavoriteFilterStore(defaults: defaults).load(), [])
    }

    func testFiltersKeepTheirOrderAcrossReloads() throws {
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        let filters = [LiveTVFavoriteFilter(tagIDs: ["sports", "4k"]), LiveTVFavoriteFilter(tagIDs: ["kids"]), LiveTVFavoriteFilter(tagIDs: ["canada"])]
        try store.save(filters)
        XCTAssertEqual(try LiveTVFavoriteFilterStore(defaults: defaults).load(), filters)
    }

    /// Filters saved before names existed have no `name` key and still load; a typed name persists across reloads.
    func testNameIsOptionalAndPersists() throws {
        let key = SettingsKey.scoped(LiveTVFavoriteFilterStore.baseKey, namespace: nil)
        defaults.set(Data(#"[{"id":"a","tagIDs":["news"]}]"#.utf8), forKey: key)
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        XCTAssertEqual(try store.load(), [LiveTVFavoriteFilter(id: "a", tagIDs: ["news"])])
        try store.save([LiveTVFavoriteFilter(id: "a", tagIDs: ["news"], name: "Evening")])
        XCTAssertEqual(try LiveTVFavoriteFilterStore(defaults: defaults).load().first?.name, "Evening")
    }

    func testProfilesAreIsolated() throws {
        let primary = LiveTVFavoriteFilterStore(defaults: defaults)
        let second = LiveTVFavoriteFilterStore(defaults: defaults, namespace: "profile-2")
        let third = LiveTVFavoriteFilterStore(defaults: defaults, namespace: "profile-3")
        try primary.save([LiveTVFavoriteFilter(tagIDs: ["news"])])
        try second.save([LiveTVFavoriteFilter(tagIDs: ["kids"])])
        XCTAssertEqual(try primary.load().map(\.tagIDs), [["news"]])
        XCTAssertEqual(try second.load().map(\.tagIDs), [["kids"]])
        XCTAssertEqual(try third.load(), [])
    }

    func testUnreadableValueIsReportedAndNotReplaced() throws {
        let key = SettingsKey.scoped(LiveTVFavoriteFilterStore.baseKey, namespace: nil)
        defaults.set(Data("not json".utf8), forKey: key)
        let store = LiveTVFavoriteFilterStore(defaults: defaults)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? LiveTVFavoriteFilterStoreError, .decodingFailed) }
        XCTAssertThrowsError(try store.save([LiveTVFavoriteFilter(tagIDs: ["news"])]))
        XCTAssertEqual(defaults.data(forKey: key), Data("not json".utf8))
    }

    func testSameTagsIgnoreOrder() {
        XCTAssertTrue(LiveTVFavoriteFilter(tagIDs: ["a", "b"]).hasSameTags(as: ["b", "a"]))
        XCTAssertFalse(LiveTVFavoriteFilter(tagIDs: ["a", "b"]).hasSameTags(as: ["a"]))
    }
}
