import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVChannelLogoStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("channel-logos.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVChannelLogoStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let key = LiveTVChannelLogoKey(sourceID: "playlist-1", channelID: "ch-1")
    private lazy var identity = LiveTVChannelLogoIdentity(key: key, nameKey: "ctvcalgary")

    func testRoundTripsOverridesMatchesAndNetworksAcrossLaunches() throws {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        let other = LiveTVChannelLogoKey(sourceID: "playlist-1", channelID: "ch-2")
        let url = try XCTUnwrap(URL(string: "https://example.com/logo.png"))
        XCTAssertTrue(store.setOverride(.url(url), for: key))
        XCTAssertTrue(store.setOverride(.tmdbNetwork(110), for: other))
        XCTAssertTrue(store.recordMatches([
            identity: .network(id: 110, filePath: "/ctv.png"),
            .init(key: .init(sourceID: "playlist-1", channelID: "ch-3"), nameKey: "x"): .none(directoryDate: Date(timeIntervalSince1970: 5))
        ]))
        let network = TMDbNetworkLogo(networkID: 110, name: "CTV", originCountry: "CA", filePath: "/ctv.png")
        XCTAssertTrue(store.recordNetwork(network))

        store.flush()
        let reopened = LiveTVChannelLogoStore(fileURL: fileURL)
        XCTAssertEqual(reopened.override(for: key), .url(url))
        XCTAssertEqual(reopened.override(for: other), .tmdbNetwork(110))
        XCTAssertEqual(reopened.match(for: identity), .network(id: 110, filePath: "/ctv.png"))
        XCTAssertEqual(reopened.network(id: 110), network)
        XCTAssertEqual(
            reopened.match(for: .init(key: .init(sourceID: "playlist-1", channelID: "ch-3"), nameKey: "x")),
            .none(directoryDate: Date(timeIntervalSince1970: 5))
        )
    }

    func testMatchAppliesOnlyWhileTheChannelNameIsUnchanged() {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        store.recordMatches([identity: .network(id: 1, filePath: "/a.png")])
        XCTAssertNil(store.match(for: .init(key: key, nameKey: "renamed")))
        XCTAssertEqual(store.match(for: key, nameKey: nil), .network(id: 1, filePath: "/a.png"))
    }

    func testFileIsVersionedAndAnUnknownVersionIsIgnored() throws {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        XCTAssertTrue(store.setOverride(.tmdbNetwork(7), for: key))
        store.flush()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, LiveTVChannelLogoStore.version)
        object["version"] = LiveTVChannelLogoStore.version + 1
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        XCTAssertNil(LiveTVChannelLogoStore(fileURL: fileURL).override(for: key))
    }

    func testCorruptFileStartsEmptyAndIsReplacedOnTheNextWrite() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: fileURL)
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        XCTAssertNil(store.override(for: key))
        XCTAssertTrue(store.setOverride(.tmdbNetwork(1), for: key))
        store.flush()
        XCTAssertEqual(LiveTVChannelLogoStore(fileURL: fileURL).override(for: key), .tmdbNetwork(1))
    }

    func testWritesAreAtomicAndLeaveNoTemporaryFiles() throws {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        for index in 0..<20 {
            XCTAssertTrue(store.setOverride(.tmdbNetwork(index), for: key))
        }
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["channel-logos.json"])
        XCTAssertNoThrow(try JSONDecoder().decode(
            [String: AnyDecodable].self, from: Data(contentsOf: fileURL)
        ))
    }

    func testRemovingASourceRemovesItsEntriesOnly() {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        let kept = LiveTVChannelLogoKey(sourceID: "playlist-2", channelID: "ch-1")
        store.setOverride(.tmdbNetwork(1), for: key)
        store.setOverride(.tmdbNetwork(2), for: kept)
        store.recordMatches([
            identity: .network(id: 1, filePath: "/a.png"),
            .init(key: kept, nameKey: "n"): .none(directoryDate: Date())
        ])
        XCTAssertTrue(store.removeSource("playlist-1"))
        store.flush()
        let reopened = LiveTVChannelLogoStore(fileURL: fileURL)
        XCTAssertNil(reopened.override(for: key))
        XCTAssertNil(reopened.match(for: identity))
        XCTAssertEqual(reopened.override(for: kept), .tmdbNetwork(2))
        XCTAssertNotNil(reopened.match(for: .init(key: kept, nameKey: "n")))
    }

    func testURLValidation() {
        XCTAssertNotNil(LiveTVChannelLogoStore.validatedURL("https://example.com/a.png"))
        XCTAssertNotNil(LiveTVChannelLogoStore.validatedURL("  http://example.com/a.png  "))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("ftp://example.com/a.png"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("file:///etc/passwd"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("javascript:alert(1)"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("https://user:pass@example.com/a.png"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("https://user@example.com/a.png"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL("https:///a.png"))
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL(""))
        let long = "https://example.com/" + String(repeating: "a", count: LiveTVChannelLogoStore.maximumURLLength)
        XCTAssertNil(LiveTVChannelLogoStore.validatedURL(long))
        let limit = "https://example.com/" + String(repeating: "a", count: LiveTVChannelLogoStore.maximumURLLength - 20)
        XCTAssertNotNil(LiveTVChannelLogoStore.validatedURL(limit))
    }

    func testStoreRefusesAnInvalidURLOverride() throws {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        XCTAssertFalse(store.setOverride(.url(try XCTUnwrap(URL(string: "file:///tmp/a.png"))), for: key))
        XCTAssertNil(store.override(for: key))
    }

    func testNegativeResultsClearOnDirectoryRefreshOrWhenAccessBecomesEnabled() {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        let positive = LiveTVChannelLogoIdentity(key: .init(sourceID: "s", channelID: "p"), nameKey: "p")
        let negative = LiveTVChannelLogoIdentity(key: .init(sourceID: "s", channelID: "n"), nameKey: "n")
        store.recordMatches([positive: .network(id: 1, filePath: "/a.png"), negative: .none(directoryDate: Date())])
        XCTAssertEqual(store.clearNegativeMatches(), 1)
        XCTAssertNil(store.match(for: negative))
        XCTAssertNotNil(store.match(for: positive))

        store.recordMatches([negative: .none(directoryDate: Date())])
        XCTAssertTrue(store.noteAccess(enabled: true), "disabled to enabled")
        XCTAssertNil(store.match(for: negative))
        store.recordMatches([negative: .none(directoryDate: Date())])
        XCTAssertFalse(store.noteAccess(enabled: true), "already enabled")
        XCTAssertNotNil(store.match(for: negative))
        XCTAssertFalse(store.noteAccess(enabled: false))
        XCTAssertTrue(store.noteAccess(enabled: true))
        XCTAssertNotNil(store.match(for: positive))
    }

    func testAccessStateSurvivesRelaunch() {
        let store = LiveTVChannelLogoStore(fileURL: fileURL)
        store.noteAccess(enabled: true)
        store.flush()
        XCTAssertFalse(LiveTVChannelLogoStore(fileURL: fileURL).noteAccess(enabled: true))
    }

    func testStoreLivesInApplicationSupportNotCaches() {
        let path = LiveTVChannelLogoStore.defaultFileURL().path
        XCTAssertTrue(path.contains("Application Support"), path)
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
