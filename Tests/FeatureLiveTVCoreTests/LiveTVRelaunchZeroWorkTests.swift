import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// A relaunch over an unchanged lineup and store does no Live TV logo work: no Keychain read per channel, no write, no changed
/// record stamp, no iCloud publish, no region recount, no network. Lineup 43k channels, store 55k records.
@MainActor
final class LiveTVRelaunchZeroWorkTests: XCTestCase {
    private static let sourceID = "server-relaunch"
    private static let listDate = Date(timeIntervalSince1970: 1_794_050_400.123_456)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVRelaunchZeroWorkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
        subscript(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
        var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    }

    private func lineup(_ count: Int) -> [LiveTVPrototypeChannel] {
        (0..<count).map { index in
            LiveTVPrototypeChannel(
                id: "ch-\(index)", number: index + 1, name: index % 3 == 0 ? "CA EN: CBC HALIFAX \(index % 50) HD" : "CA EN: NETWORK \(index) HD",
                category: "CA| GENERAL EN", symbol: "tv", accent: 0, source: .iptv, tagline: "", playlistSourceID: Self.sourceID,
                groups: ["CA| GENERAL EN"])
        }
    }

    private func makeService(_ counter: Counter) -> LiveTVChannelLogoService {
        LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(
                fileURL: directory.appendingPathComponent("channel-logos.json"), writeDelay: 0.2, batchDelay: 0.2),
            directory: .init(fileURL: directory.appendingPathComponent("n.json"), fetch: { _ in counter.bump("network"); return Data() }),
            wikidata: .init(fileURL: directory.appendingPathComponent("w.json"), fetch: { _ in counter.bump("network"); return (Data(), 500) }),
            accessProvider: { counter.bump("access-read"); return .directToken("t") },
            measureGuideIcon: { _ in counter.bump("network"); return .raster(width: 600, height: 300) },
            measureLogoColour: { _ in counter.bump("network"); return false })
    }

    /// Outcomes dated by a list download, the way an earlier launch stored them: the date has sub-millisecond digits.
    func testAnOutcomeRecordedAgainWithTheDateThatCameBackFromDiskChangesNothing() throws {
        let channels = lineup(50)
        let counter = Counter()
        let first = makeService(counter)
        var tmdb: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch] = [:]
        var wikidata: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch] = [:]
        for channel in channels {
            let identity = LiveTVChannelLogoIdentity(channel: channel)
            tmdb[identity] = .none(directoryDate: Self.listDate)
            wikidata[identity] = .none(directoryDate: Self.listDate)
        }
        first.store.recordMatches(tmdb)
        first.store.recordWikidataMatches(wikidata)
        first.store.flush()

        let second = makeService(counter)
        var published = 0
        second.store.onLocalChange = { published += 1 }
        let stamps = second.store.syncSnapshot().map(\.modified).reduce(0, +)
        let baseline = second.store.writeCount
        // The list is unchanged, so the same outcome is recorded again; the stored date went through a file.
        second.store.recordMatches(tmdb)
        second.store.recordWikidataMatches(wikidata)
        second.store.flush()
        XCTAssertEqual(second.store.syncSnapshot().map(\.modified).reduce(0, +), stamps, "no stamp changed")
        XCTAssertEqual(second.store.writeCount, baseline, "no write")
        XCTAssertEqual(published, 0, "nothing published to iCloud")
        XCTAssertTrue(LiveTVChannelLogoStore.isSameInstant(Self.listDate.addingTimeInterval(-0.0005), orLater: Self.listDate))
        XCTAssertFalse(LiveTVChannelLogoStore.isSameInstant(Self.listDate.addingTimeInterval(-5), orLater: Self.listDate))
    }

    func testTheRealLaunchSequenceOverAFortyThreeThousandLineupDoesNoWork() async throws {
        let channels = lineup(43_000)
        let counter = Counter()
        let first = makeService(counter)
        var tmdb: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch] = [:]
        var wikidata: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch] = [:]
        for channel in channels {
            let identity = LiveTVChannelLogoIdentity(channel: channel)
            tmdb[identity] = .none(directoryDate: Self.listDate)
            wikidata[identity] = .none(directoryDate: Self.listDate)
        }
        for index in 0..<12_000 {
            tmdb[.init(key: .init(sourceID: Self.sourceID, channelID: "gone-\(index)"), nameKey: "gone\(index)")] = .none(directoryDate: Self.listDate)
        }
        first.store.recordMatches(tmdb)
        first.store.recordWikidataMatches(wikidata)
        first.store.noteCompleteLineup(channelIDsBySource: [Self.sourceID: Set(channels.map(\.id))], iconURLs: [])
        first.store.flush()

        // First launch of this lineup: counts are computed once and saved.
        let firstModel = LiveTVPrototypeModel(channels: [], logoService: first)
        try firstModel.replaceChannels(channels, isCompleteLineup: true)
        try await settle(firstModel, channels: channels)
        first.store.flush()
        XCTAssertEqual(first.regionalCountStats.saved, 1)

        // The relaunch.
        let relaunch = Counter()
        let second = makeService(relaunch)
        var published = 0
        second.store.onLocalChange = { published += 1 }
        let stamps = second.store.syncSnapshot().map(\.modified).reduce(0, +)
        let baseline = second.store.writeCount
        let model = LiveTVPrototypeModel(channels: [], logoService: second)
        try model.replaceChannels(Array(channels.prefix(150)), isCompleteLineup: false)
        try model.replaceChannels(channels, isCompleteLineup: true)
        try await settle(model, channels: channels)
        second.store.flush()

        let line = "RELAUNCHZERO load=\(Self.load()) accessReads=\(relaunch["access-read"]) network=\(relaunch["network"]) writes=\(second.store.writeCount - baseline) published=\(published) regionStats=\(second.regionalCountStats) firstLaunchAccessReads=\(counter["access-read"])"
        print(line)
        if let path = ProcessInfo.processInfo.environment["PLOZZ_LOGO_PERF_REPORT"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_PLOZZ_LOGO_PERF_REPORT"] {
            try? (line + "\n").appendingToFile(path)
        }
        XCTAssertEqual(relaunch["network"], 0, "no network, no measuring")
        XCTAssertLessThanOrEqual(relaunch["access-read"], 12, "the TMDB access (a Keychain read) is read per pass, never per channel; reads: \(relaunch["access-read"])")
        XCTAssertEqual(second.store.writeCount, baseline, "no write")
        XCTAssertEqual(second.store.syncSnapshot().map(\.modified).reduce(0, +), stamps, "no stamp changed")
        XCTAssertEqual(published, 0, "nothing published")
        XCTAssertEqual(second.regionalCountStats.saved, 0, "no region recount saved")
        XCTAssertEqual(second.regionalCountStats.loaded, 1, "the complete lineup's counts are read back")
    }

    private static func load() -> String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return averages.map { String(format: "%.1f", $0) }.joined(separator: "/")
    }

    private func settle(_ model: LiveTVPrototypeModel, channels: [LiveTVPrototypeChannel]) async throws {
        for _ in 0..<600 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(25)) }
        _ = model.regionLabel(for: channels[0])
        try await Task.sleep(for: .milliseconds(1_800))
        _ = model.regionLabel(for: channels[0])
        try await Task.sleep(for: .milliseconds(1_800))
    }
}

private extension String {
    func appendingToFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + self).write(to: url, atomically: true, encoding: .utf8)
    }
}
