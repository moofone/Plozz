import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVChannelLogoSyncTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVChannelLogoSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var millis: Double
        init(_ millis: Double) { self.millis = millis }
        var date: Date { lock.withLock { Date(timeIntervalSince1970: millis / 1_000) } }
        func set(_ value: Double) { lock.withLock { millis = value } }
    }

    private func makeStore(_ name: String, clock: Clock) -> LiveTVChannelLogoStore {
        LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("\(name).json"), now: { clock.date })
    }

    private let key = LiveTVChannelLogoKey(sourceID: "playlist-1", channelID: "ch:1")
    private let mine = URL(string: "https://example.com/mine.png")!

    func testRecordNamesRoundTripAndStayWithinTheLimit() throws {
        let name = try XCTUnwrap(LiveTVChannelLogoSync.recordName(for: key))
        XCTAssertTrue(name.hasPrefix("logo:"))
        XCTAssertEqual(LiveTVChannelLogoSync.key(forRecordName: name), key)
        XCTAssertNil(LiveTVChannelLogoSync.key(forRecordName: "logo:bad"))
        XCTAssertNil(LiveTVChannelLogoSync.key(forRecordName: "liveTV:a:channel:b"))
        let huge = LiveTVChannelLogoKey(sourceID: "s", channelID: String(repeating: "x", count: 400))
        XCTAssertNil(LiveTVChannelLogoSync.recordName(for: huge), "an oversize name is not synced")
    }

    func testOverrideAndMatchReachAnotherDevice() throws {
        let clock = Clock(1_000)
        let first = makeStore("a", clock: clock)
        let second = makeStore("b", clock: clock)
        first.setOverride(.url(mine), for: key)
        let other = LiveTVChannelLogoKey(sourceID: "playlist-1", channelID: "ch-2")
        first.recordMatches([.init(key: other, nameKey: "ctv"): .network(id: 110, filePath: "/ctv.png")])
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(first))
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(LiveTVChannelLogoSync.apply(records.mapValues { Optional($0) }, to: second))
        XCTAssertEqual(second.override(for: key), .url(mine))
        XCTAssertEqual(second.match(for: .init(key: other, nameKey: "ctv")), .network(id: 110, filePath: "/ctv.png"))
    }

    func testNetworkOverrideCarriesItsLogoPathSoTheOtherDeviceCanDrawIt() throws {
        let clock = Clock(1_000)
        let first = makeStore("a", clock: clock)
        let second = makeStore("b", clock: clock)
        first.recordNetwork(.init(networkID: 110, name: "CTV", originCountry: "CA", filePath: "/ctv.png"))
        first.setOverride(.tmdbNetwork(110), for: key)
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(first))
        LiveTVChannelLogoSync.apply(records.mapValues { Optional($0) }, to: second)
        XCTAssertEqual(second.override(for: key), .tmdbNetwork(110))
        XCTAssertEqual(second.network(id: 110)?.filePath, "/ctv.png")
    }

    func testNewerChangeWinsAndAnOlderRemoteRecordIsIgnored() throws {
        let clock = Clock(5_000)
        let local = makeStore("local", clock: clock)
        local.setOverride(.url(mine), for: key)
        let remote = makeStore("remote", clock: Clock(1_000))
        remote.setOverride(.url(URL(string: "https://example.com/old.png")!), for: key)
        let older = try XCTUnwrap(LiveTVChannelLogoSync.capture(remote))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(older.mapValues { Optional($0) }, to: local))
        XCTAssertEqual(local.override(for: key), .url(mine))

        let newer = makeStore("newer", clock: Clock(9_000))
        newer.setOverride(.url(URL(string: "https://example.com/new.png")!), for: key)
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(newer))
        XCTAssertTrue(LiveTVChannelLogoSync.apply(records.mapValues { Optional($0) }, to: local))
        XCTAssertEqual(local.override(for: key), .url(URL(string: "https://example.com/new.png")!))
    }

    func testResetToAutomaticRemovesTheRecordAndTheOtherDeviceDropsTheOverride() throws {
        let clock = Clock(1_000)
        let first = makeStore("a", clock: clock)
        let second = makeStore("b", clock: clock)
        first.setOverride(.url(mine), for: key)
        let name = try XCTUnwrap(LiveTVChannelLogoSync.recordName(for: key))
        LiveTVChannelLogoSync.apply(try XCTUnwrap(LiveTVChannelLogoSync.capture(first)).mapValues { Optional($0) }, to: second)
        XCTAssertNotNil(second.override(for: key))
        first.setOverride(nil, for: key)
        XCTAssertNil(try XCTUnwrap(LiveTVChannelLogoSync.capture(first))[name], "the record is gone, which deletes it in iCloud")
        XCTAssertTrue(LiveTVChannelLogoSync.apply([name: nil], to: second))
        XCTAssertNil(second.override(for: key))
    }

    func testResetKeepsAnAutomaticMatchRecord() throws {
        let first = makeStore("a", clock: Clock(1_000))
        first.recordMatches([.init(key: key, nameKey: "ctv"): .network(id: 110, filePath: "/ctv.png")])
        first.setOverride(.url(mine), for: key)
        first.setOverride(nil, for: key)
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(first))
        let record = try JSONDecoder().decode(
            LiveTVChannelLogoSyncRecord.self, from: XCTUnwrap(records[XCTUnwrap(LiveTVChannelLogoSync.recordName(for: key))])
        )
        XCTAssertNil(record.override)
        XCTAssertEqual(record.match?.kind, "tmdb")
    }

    func testRemovingASourceRemovesItsRecords() throws {
        let store = makeStore("a", clock: Clock(1_000))
        let kept = LiveTVChannelLogoKey(sourceID: "playlist-2", channelID: "c")
        store.setOverride(.url(mine), for: key)
        store.setOverride(.url(mine), for: kept)
        XCTAssertEqual(try XCTUnwrap(LiveTVChannelLogoSync.capture(store)).count, 2)
        store.removeSource("playlist-1")
        let remaining = try XCTUnwrap(LiveTVChannelLogoSync.capture(store))
        XCTAssertEqual(Set(remaining.keys), [try XCTUnwrap(LiveTVChannelLogoSync.recordName(for: kept))])
    }

    func testWithoutSyncTheStoreStillWorksLocally() {
        let store = makeStore("a", clock: Clock(1_000))
        XCTAssertNil(store.onLocalChange)
        XCTAssertTrue(store.setOverride(.url(mine), for: key))
        XCTAssertEqual(store.override(for: key), .url(mine))
    }

    func testLocalChangesNotifyTheSyncLayer() {
        let store = makeStore("a", clock: Clock(1_000))
        let counter = NSLock()
        nonisolated(unsafe) var count = 0
        store.onLocalChange = { counter.withLock { count += 1 } }
        store.setOverride(.url(mine), for: key)
        store.setOverride(.url(mine), for: key)
        XCTAssertEqual(counter.withLock { count }, 1, "an unchanged write is not a change")
        store.removeSource("playlist-1")
        XCTAssertEqual(counter.withLock { count }, 2)
    }

    func testAnUnreadableFileIsNeverPublishedAsAnEmptyStore() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("broken.json")
        try Data("{broken".utf8).write(to: url)
        let store = LiveTVChannelLogoStore(fileURL: url)
        XCTAssertFalse(store.isLoaded)
        XCTAssertNil(LiveTVChannelLogoSync.capture(store))
    }

    func testUnknownVersionsKindsAndBadPayloadsAreIgnored() throws {
        let store = makeStore("a", clock: Clock(1_000))
        let name = try XCTUnwrap(LiveTVChannelLogoSync.recordName(for: key))
        func record(_ json: String) -> [String: Data?] { [name: Data(json.utf8)] }
        let base = #""sourceID":"playlist-1","channelID":"ch:1","modifiedAt":5"#
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record(#"{"version":2,\#(base),"override":{"kind":"url","url":"https://a.com/x.png"}}"#), to: store))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record(#"{"version":1,\#(base),"override":{"kind":"wikidata","url":"https://a.com/x.png"}}"#), to: store))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record(#"{"version":1,\#(base),"override":{"kind":"url","url":"file:///etc/passwd"}}"#), to: store))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record(#"{"version":1,\#(base),"override":{"kind":"tmdb","networkID":1,"filePath":"//evil/x.png"}}"#), to: store))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record(#"{"version":1,"sourceID":"other","channelID":"ch:1","modifiedAt":5,"override":{"kind":"url","url":"https://a.com/x.png"}}"#), to: store))
        XCTAssertFalse(LiveTVChannelLogoSync.apply(record("not json"), to: store))
        XCTAssertNil(store.override(for: key))
        XCTAssertTrue(LiveTVChannelLogoSync.apply(record(#"{"version":1,\#(base),"override":{"kind":"url","url":"https://a.com/x.png"}}"#), to: store))
    }

    func testOverridesAreKeptFirstWhenTheRecordLimitIsReached() throws {
        let store = makeStore("a", clock: Clock(1_000))
        var updates: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch] = [:]
        for index in 0..<(LiveTVChannelLogoSync.maximumRecords + 10) {
            updates[.init(key: .init(sourceID: "s", channelID: "m\(index)"), nameKey: "n")] = .none(directoryDate: Date())
        }
        store.recordMatches(updates)
        store.setOverride(.url(mine), for: key)
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(store))
        XCTAssertEqual(records.count, LiveTVChannelLogoSync.maximumRecords)
        XCTAssertNotNil(records[try XCTUnwrap(LiveTVChannelLogoSync.recordName(for: key))])
    }

    func testWikidataMatchSyncsAndIsNotConfusedWithTMDB() throws {
        let first = makeStore("a", clock: Clock(1_000))
        let second = makeStore("b", clock: Clock(1_000))
        first.recordWikidataMatches([.init(key: key, nameKey: "citytv"): .logo(qid: "Q5", file: "Citytv logo.svg")])
        let records = try XCTUnwrap(LiveTVChannelLogoSync.capture(first))
        LiveTVChannelLogoSync.apply(records.mapValues { Optional($0) }, to: second)
        XCTAssertEqual(second.wikidataMatch(for: .init(key: key, nameKey: "citytv")), .logo(qid: "Q5", file: "Citytv logo.svg"))
        XCTAssertNil(second.match(for: .init(key: key, nameKey: "citytv")))
        XCTAssertNil(second.wikidataMatch(for: .init(key: key, nameKey: "renamed")))
    }
}
