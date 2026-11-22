import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// Live TV logos must never cost the main thread anything that grows with the lineup: a 43k-channel lineup and a 55k-record store
/// (names and groups are synthetic). Lines `LOGOPERF …` go to the test log and to the file named by `PLOZZ_LOGO_PERF_REPORT`.
@MainActor
final class LiveTVLogoMainThreadTests: XCTestCase {
    private static let sourceID = "server-perf"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVLogoMainThreadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func lineup(_ count: Int = 43_000) -> [LiveTVPrototypeChannel] {
        (0..<count).map { index in
            let name: String
            var groups = ["CA| GENERAL EN"]
            switch index % 12 {
            case 0:
                name = "US ESPN+ \(index % 400) Team \(index) vs Team \(index + 1) Nov \(index % 28 + 1) 5:00pm ET (2026-11-\(String(format: "%02d", index % 28 + 1)) 17:00)"
                groups = ["US| ESPN+ PPV"]
            case 1:
                name = "US: NBA \(index % 30): Boston Celtics vs Miami Heat (2026-11-18 19:00)"
                groups = ["US| NBA"]
            case 2, 3: name = "CA EN: CBC CITY\(index % 60) HD"
            default: name = "CA EN: NETWORK \(index) HD"
            }
            return LiveTVPrototypeChannel(
                id: "server-channel-\(index)", number: index + 1, name: name, category: groups[0], symbol: "tv", accent: 0,
                source: .iptv, tagline: "", playlistSourceID: Self.sourceID, groups: groups)
        }
    }

    private final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TMDbAccess
        init(_ value: TMDbAccess) { self.value = value }
        var current: TMDbAccess { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    /// Counts everything a logo pass could do that costs network, decoding or disk.
    private final class Work: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
        subscript(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
        var total: Int { lock.withLock { counts.values.reduce(0, +) } }
        var summary: String { lock.withLock { counts.description } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
    }

    private func makeService(
        access: TMDbAccess = .directToken("t"), writeDelay: TimeInterval = 0.3, name: String = "store",
        work: Work = Work(), clock: Clock = Clock(Date(timeIntervalSince1970: 1_794_050_400))
    ) -> LiveTVChannelLogoService {
        LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(
                fileURL: directory.appendingPathComponent("\(name).json"), writeDelay: writeDelay, batchDelay: writeDelay,
                now: { clock.now }),
            directory: .init(fileURL: directory.appendingPathComponent("n-\(name).json"), fetch: { _ in work.bump("tmdb-network"); return Data() }),
            wikidata: .init(fileURL: directory.appendingPathComponent("w-\(name).json"), fetch: { _ in work.bump("wikidata-network"); return (Data(), 500) }),
            accessProvider: { access },
            measureGuideIcon: { _ in work.bump("icon-size"); return .raster(width: 600, height: 300) },
            measureLogoColour: { _ in work.bump("colour"); return false })
    }

    /// A result for every channel of `channels` (and `extra` stale records), as a settled lineup leaves the store.
    private func seed(_ store: LiveTVChannelLogoStore, for channels: [LiveTVPrototypeChannel], extra: Int = 12_000) {
        let date = Date(timeIntervalSince1970: 1_794_050_400)
        var matches: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch] = [:]
        var wikidata: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch] = [:]
        for channel in channels {
            let identity = LiveTVChannelLogoIdentity(channel: channel)
            matches[identity] = .none(directoryDate: date)
            wikidata[identity] = identity.nameKey.hasPrefix("event:") && identity.nameKey != "event:espn+"
                ? .logo(qid: "Q1", file: "League.svg") : .none(directoryDate: date)
        }
        for index in 0..<extra {
            let identity = LiveTVChannelLogoIdentity(
                key: .init(sourceID: Self.sourceID, channelID: "gone-\(index)"), nameKey: "gone\(index)")
            matches[identity] = .none(directoryDate: date)
        }
        store.recordMatches(matches)
        store.recordWikidataMatches(wikidata)
        store.recordNetwork(TMDbNetworkLogo(networkID: 1, name: "N", originCountry: "CA", filePath: "/n.png"))
        // The state a settled launch leaves: the complete lineup that was matched has stamped its records.
        store.noteCompleteLineup(channelIDsBySource: [Self.sourceID: Set(channels.map(\.id))], iconURLs: [])
    }

    /// The machine's load average at the time of a measurement, recorded with every timing.
    private static func load() -> String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return averages.map { String(format: "%.1f", $0) }.joined(separator: "/")
    }

    private func report(_ line: String) {
        print("LOGOPERF \(line)")
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_LOGO_PERF_REPORT"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_PLOZZ_LOGO_PERF_REPORT"] else { return }
        let handle = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path)! }()
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// Measures how long the main thread goes without servicing its queue while it is awaited work.
    private final class StallMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var worst: TimeInterval = 0
        private var thread: Thread?

        func start() {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let sent = ContinuousClock.now
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { done.signal() }
                    done.wait()
                    let elapsed = (ContinuousClock.now - sent).seconds
                    lock.withLock { worst = max(worst, elapsed) }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
        }

        func stop() -> TimeInterval {
            lock.withLock { running = false }
            return lock.withLock { worst }
        }
    }

    // MARK: Store

    func testWritesAreCoalescedAndNeverOnTheMainThread() async throws {
        let channels = lineup(8_000)
        let service = makeService(writeDelay: 0.3)
        seed(service.store, for: channels, extra: 2_000)
        service.store.flush()
        let baseline = service.store.writeCount

        var worst = Duration.zero
        let clock = ContinuousClock()
        for batch in 0..<60 {
            let identity = LiveTVChannelLogoIdentity(channel: channels[batch])
            let elapsed = clock.measure {
                service.store.recordMatches([identity: .network(id: batch, filePath: "/\(batch).png")])
            }
            worst = max(worst, elapsed)
        }
        XCTAssertLessThan(worst, .milliseconds(50), "a store mutation never encodes or writes on the caller's thread")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(service.store.writeCount - baseline, 1, "60 changes inside one settle period share a write")
        XCTAssertFalse(service.store.lastWriteWasOnMainThread)
        XCTAssertEqual(LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("store.json")).match(
            for: LiveTVChannelLogoIdentity(channel: channels[59])), .network(id: 59, filePath: "/59.png"))
    }

    func testAnIdenticalPassChangesNothingAndWritesNothing() async throws {
        let channels = lineup(8_000)
        let service = makeService(writeDelay: 0.2)
        seed(service.store, for: channels, extra: 0)
        service.store.flush()
        let baseline = service.store.writeCount
        let stamps = service.store.syncSnapshot().map(\.modified).reduce(0, +)

        seed(service.store, for: channels, extra: 0)
        service.store.recordNetwork(TMDbNetworkLogo(networkID: 1, name: "N", originCountry: "CA", filePath: "/n.png"))
        service.store.noteAccess(enabled: false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(service.store.writeCount, baseline, "nothing semantically changed: nothing is written")
        XCTAssertEqual(service.store.syncSnapshot().map(\.modified).reduce(0, +), stamps, "and nothing is stamped for iCloud")
    }

    // MARK: Lineup maintenance never forgets from a partial view

    private func storedCount(_ store: LiveTVChannelLogoStore) -> Int { store.syncSnapshot().count }

    func testCachedRowsThenTheFullLineupPruneNothingAndMatchNothing() async throws {
        let channels = lineup(3_000)
        let work = Work()
        let service = makeService(writeDelay: 0.2, work: work)
        seed(service.store, for: channels, extra: 0)
        service.store.flush()
        let before = storedCount(service.store)
        let model = LiveTVPrototypeModel(channels: [], logoService: service)

        // The launch applies the few rows saved last time first, then the provider's lineup arrives.
        try model.replaceChannels(Array(channels.prefix(150)), isCompleteLineup: false)
        for _ in 0..<200 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(storedCount(service.store), before, "cached rows prune nothing")
        try model.replaceChannels(channels, isCompleteLineup: true)
        for _ in 0..<400 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(storedCount(service.store), before, "the complete lineup keeps every record")
        XCTAssertEqual(work["tmdb-network"] + work["wikidata-network"], 0, "and re-matches nothing: no request was made")
        XCTAssertTrue(service.pendingRequests(channels.map(LiveTVLogoRequest.init(channel:))).isEmpty)
    }

    func testAFilterThatHidesChannelsPrunesNothing() {
        let channels = lineup(1_000)
        let service = makeService()
        seed(service.store, for: channels, extra: 0)
        let before = storedCount(service.store)
        // A country filter keeps a quarter of the lineup: the other channels are simply not in the applied lineup.
        let kept = Array(channels.prefix(250))
        for _ in 0..<3 {
            XCTAssertEqual(service.noteCompleteLineup(channelIDsBySource: [Self.sourceID: Set(kept.map(\.id))], iconURLs: []), 0)
        }
        XCTAssertEqual(storedCount(service.store), before)
    }

    func testAChannelMissingFromCompleteLineupsIsDroppedOnlyAfterTheGracePeriod() {
        let channels = lineup(100)
        let clock = Clock(Date(timeIntervalSince1970: 1_794_050_400))
        let service = makeService(clock: clock)
        seed(service.store, for: channels, extra: 0)
        let gone = channels[7]
        let rest = Set(channels.map(\.id)).subtracting([gone.id])
        let identity = LiveTVChannelLogoIdentity(channel: gone)
        let override = LiveTVChannelLogoKey(sourceID: Self.sourceID, channelID: channels[8].id)
        service.store.setOverride(.tmdbNetwork(1), for: override)

        XCTAssertEqual(service.noteCompleteLineup(channelIDsBySource: [Self.sourceID: Set(channels.map(\.id))], iconURLs: []), 0)
        clock.now.addTimeInterval(10 * 86_400)
        XCTAssertEqual(service.noteCompleteLineup(channelIDsBySource: [Self.sourceID: rest], iconURLs: []), 0, "10 days: inside the grace period")
        XCTAssertNotNil(service.store.match(for: identity))
        clock.now.addTimeInterval(31 * 86_400)
        XCTAssertEqual(service.noteCompleteLineup(channelIDsBySource: [Self.sourceID: rest.subtracting([channels[8].id])], iconURLs: []), 2,
                       "31 days unseen: dropped (the stamps of the rest were refreshed, so only the two missing go)")
        XCTAssertNil(service.store.match(for: identity))
        XCTAssertEqual(service.store.override(for: override), .tmdbNetwork(1), "an override is never pruned")
    }

    func testARecordNeverStampedStartsItsGraceWhenFirstMissing() {
        let channels = lineup(50)
        let clock = Clock(Date(timeIntervalSince1970: 1_794_050_400))
        let service = makeService(clock: clock)
        seed(service.store, for: channels, extra: 0)
        // The store has never seen a complete lineup (a v1 file), and the first one lists only part of it.
        XCTAssertEqual(service.noteCompleteLineup(channelIDsBySource: [Self.sourceID: Set(channels.prefix(10).map(\.id))], iconURLs: []), 0)
        XCTAssertEqual(storedCount(service.store), 50)
    }

    // MARK: Version 1 migration

    private struct V1Document: Codable {
        struct Override: Codable { let key: LiveTVChannelLogoKey; let value: LiveTVChannelLogoOverride }
        struct Match: Codable { let key: LiveTVChannelLogoKey; let nameKey: String; let value: LiveTVChannelLogoMatch }
        struct Wikidata: Codable { let key: LiveTVChannelLogoKey; let nameKey: String; let value: LiveTVWikidataLogoMatch }
        struct Modified: Codable { let key: LiveTVChannelLogoKey; let at: Int64 }
        var version = 1
        var overrides: [Override] = []
        var matches: [Match] = []
        var networks: [TMDbNetworkLogo] = []
        var accessWasEnabled = true
        var modified: [Modified]?
        var wikidataMatches: [Wikidata]?
    }

    func testAVersionOneStoreOfTheOwnersShapeMigratesWithEveryRecord() throws {
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        var document = V1Document()
        var matchCount = 0
        var wikidataCount = 0
        for index in 0..<5_000 {
            let key = LiveTVChannelLogoKey(sourceID: "server-\(index % 3)", channelID: "server-channel-\(index)")
            switch index % 4 {
            case 0: document.matches.append(.init(key: key, nameKey: "name\(index)", value: .network(id: index, filePath: "/\(index).png")))
            case 1: document.matches.append(.init(key: key, nameKey: "name\(index)", value: .none(directoryDate: date)))
            case 2: document.matches.append(.init(key: key, nameKey: "name\(index)", value: .show(id: index, filePath: "/s\(index).png")))
            default: break
            }
            if index % 4 != 3 { matchCount += 1 }
            if index % 3 == 0 {
                document.wikidataMatches = (document.wikidataMatches ?? []) + [.init(
                    key: key, nameKey: "name\(index)",
                    value: index % 2 == 0 ? .logo(qid: "Q\(index)", file: "F\(index).svg") : .none(directoryDate: date))]
                wikidataCount += 1
            }
            document.modified = (document.modified ?? []) + [.init(key: key, at: Int64(index))]
        }
        document.networks = [
            TMDbNetworkLogo(networkID: 1, name: "N", originCountry: "CA", filePath: "/n.png", pixelWidth: 300, pixelHeight: 100, variantPaths: ["/n.png", "/m.png"])]
        document.overrides = [.init(key: .init(sourceID: "server-0", channelID: "o"), value: .url(URL(string: "https://example.com/a.png")!))]
        let file = directory.appendingPathComponent("v1.json")
        try JSONEncoder().encode(document).write(to: file)

        let store = LiveTVChannelLogoStore(fileURL: file, writeDelay: 0.1, batchDelay: 0.1)
        XCTAssertTrue(store.isLoaded)
        let items = store.syncSnapshot()
        XCTAssertEqual(items.filter { $0.match != nil }.count, matchCount)
        XCTAssertEqual(items.filter { $0.wikidata != nil }.count, wikidataCount)
        XCTAssertEqual(store.network(id: 1)?.variantPaths, ["/n.png", "/m.png"])
        XCTAssertEqual(store.override(for: .init(sourceID: "server-0", channelID: "o")), .url(URL(string: "https://example.com/a.png")!))

        // A launch with a cached lineup, then a complete one that lists none of these channels, loses nothing; the file becomes v2.
        XCTAssertEqual(store.noteCompleteLineup(channelIDsBySource: ["server-0": ["other"], "server-1": ["other"], "server-2": ["other"]], iconURLs: []), 0)
        store.flush()
        let reloaded = LiveTVChannelLogoStore(fileURL: file)
        XCTAssertEqual(reloaded.syncSnapshot().filter { $0.match != nil }.count, matchCount)
        XCTAssertEqual(reloaded.syncSnapshot().filter { $0.wikidata != nil }.count, wikidataCount)
        XCTAssertEqual(reloaded.network(id: 1), store.network(id: 1))
    }

    // MARK: Settled launch: nothing runs

    func testASecondFullPassOverAnUnchangedLineupAndStoreDoesNoWork() async throws {
        var channels = lineup(2_000).map { channel in
            LiveTVPrototypeChannel(
                id: channel.id, number: channel.number, name: channel.name, category: channel.category, symbol: channel.symbol,
                accent: channel.accent, source: channel.source, tagline: channel.tagline, playlistSourceID: channel.playlistSourceID,
                groups: channel.groups, guideLogoURL: URL(string: "https://icons.example/\(channel.number % 700).png"))
        }
        channels = Array(channels)
        let work = Work()
        let first = makeService(writeDelay: 0.2, name: "relaunch", work: work)
        seed(first.store, for: channels, extra: 0)
        let model = LiveTVPrototypeModel(channels: channels, logoService: first)
        for _ in 0..<400 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(700))
        first.store.flush()
        XCTAssertGreaterThan(work["icon-size"], 0, "the first pass measures each distinct guide icon once")
        XCTAssertLessThanOrEqual(work["icon-size"], 700)

        // Relaunch: a new service over the saved file, the same lineup, applied cached-then-complete.
        let relaunchWork = Work()
        let second = makeService(writeDelay: 0.2, name: "relaunch", work: relaunchWork)
        report("RELAUNCHDEBUG loaded=\(second.store.isLoaded) icon0=\(String(describing: second.store.iconSize(for: URL(string: "https://icons.example/5.png")!))) records=\(second.store.syncSnapshot().count)")
        let baseline = second.store.writeCount
        let again = LiveTVPrototypeModel(channels: [], logoService: second)
        try again.replaceChannels(Array(channels.prefix(150)), isCompleteLineup: false)
        try again.replaceChannels(channels, isCompleteLineup: true)
        for _ in 0..<400 where again.isResolvingLogos { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(700))
        report("RELAUNCHWORK \(relaunchWork.summary) firstPass=\(work.summary)")
        XCTAssertEqual(relaunchWork.total, 0, "zero matching, measuring and network requests")
        XCTAssertEqual(second.store.writeCount, baseline, "zero writes")

        // And the same lineup applied again (a guide batch, a refetch that changed nothing) does nothing either.
        try again.replaceChannels(channels, isCompleteLineup: true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(relaunchWork.total, 0)
        XCTAssertEqual(second.store.writeCount, baseline)
    }

    func testMeasurementsAreKeptInTheStoreAcrossRelaunch() throws {
        let file = directory.appendingPathComponent("m.json")
        let store = LiveTVChannelLogoStore(fileURL: file, writeDelay: 0.1, batchDelay: 0.1)
        let icon = URL(string: "https://icons.example/a.png")!
        let logo = URL(string: "https://logos.example/b.png")!
        var sizes: [URL: LiveTVLogoSize?] = [:]
        sizes[icon] = .some(.raster(width: 600, height: 300))
        sizes[URL(string: "https://icons.example/v.svg")!] = .some(.vector)
        sizes[URL(string: "https://icons.example/x.png")!] = .some(nil)
        store.recordIconSizes(sizes)
        store.recordMonochrome(true, for: logo)
        store.flush()
        let reloaded = LiveTVChannelLogoStore(fileURL: file)
        XCTAssertEqual(reloaded.iconSize(for: icon), .some(.raster(width: 600, height: 300)))
        XCTAssertEqual(reloaded.iconSize(for: URL(string: "https://icons.example/v.svg")!), .some(.vector))
        XCTAssertNotNil(reloaded.iconSize(for: URL(string: "https://icons.example/x.png")!), "known, and unmeasurable")
        XCTAssertNil(reloaded.iconSize(for: URL(string: "https://icons.example/never.png")!), "never measured")
        XCTAssertEqual(reloaded.isMonochrome(logo), .some(true))
    }

    // MARK: Identity

    func testAnEventChannelKeepsItsIdentityWhenTheProviderRenamesItForTheNextEvent() {
        func event(_ name: String, _ group: String) -> LiveTVPrototypeChannel {
            LiveTVPrototypeChannel(
                id: "e", number: 1, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
                playlistSourceID: Self.sourceID, groups: [group])
        }
        let first = LiveTVChannelLogoIdentity(channel: event("US ESPN+ 056 Grand Slam of Curling National Nov 17 3:00pm ET (2026-11-17 15:00)", "US| ESPN+ PPV"))
        let second = LiveTVChannelLogoIdentity(channel: event("US ESPN+ 056 Western Carolina vs Cincinnati Nov 18 5:00pm ET (2026-11-18 17:00)", "US| ESPN+ PPV"))
        XCTAssertEqual(first, second, "the logo of an event channel is its broadcaster's, not the event's")
        let nba1 = LiveTVChannelLogoIdentity(channel: event("US: NBA 05: Boston Celtics vs Miami Heat (2026-11-18 19:00)", "US| NBA"))
        let nba2 = LiveTVChannelLogoIdentity(channel: event("US: NBA 05: Denver Nuggets vs Utah Jazz (2026-11-19 19:00)", "US| NBA"))
        XCTAssertEqual(nba1, nba2)
        let renamed = LiveTVChannelLogoIdentity(channel: LiveTVPrototypeChannel(
            id: "e", number: 1, name: "CA EN: CTV CALGARY", category: "x", symbol: "tv", accent: 0, source: .iptv, tagline: "", playlistSourceID: Self.sourceID))
        let regular = LiveTVChannelLogoIdentity(channel: LiveTVPrototypeChannel(
            id: "e", number: 1, name: "CA EN: CTV EDMONTON", category: "x", symbol: "tv", accent: 0, source: .iptv, tagline: "", playlistSourceID: Self.sourceID))
        XCTAssertNotEqual(renamed, regular, "an ordinary channel's identity still follows its name")
    }

    // MARK: Launch and refetch

    func testRelaunchWithAnUnchangedLineupMatchesNothingAndWritesNothing() async throws {
        let channels = lineup(6_000)
        let service = makeService(writeDelay: 0.2)
        seed(service.store, for: channels, extra: 0)
        service.store.flush()
        let baseline = service.store.writeCount
        let stamps = service.store.syncSnapshot().map(\.modified).reduce(0, +)

        let requests = channels.map(LiveTVLogoRequest.init(channel:))
        XCTAssertTrue(service.pendingRequests(requests).isEmpty, "every channel has a stored result for its inputs")

        let model = LiveTVPrototypeModel(channels: channels, logoService: service)
        for _ in 0..<400 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(model.isResolvingLogos)
        XCTAssertEqual(service.store.writeCount, baseline, "no store write")
        XCTAssertEqual(service.store.syncSnapshot().map(\.modified).reduce(0, +), stamps, "no record changed")
    }

    func testARefetchWithOneRenamedChannelMatchesExactlyThatChannel() async throws {
        let channels = lineup(6_000)
        let service = makeService(writeDelay: 0.2)
        seed(service.store, for: channels, extra: 0)
        service.store.flush()
        var edited = channels
        let target = 4_321
        let old = edited[target]
        edited[target] = LiveTVPrototypeChannel(
            id: old.id, number: old.number, name: "CA EN: BRAND NEW NETWORK HD", category: old.category, symbol: old.symbol,
            accent: old.accent, source: old.source, tagline: old.tagline, playlistSourceID: old.playlistSourceID, groups: old.groups)

        let pending = service.pendingRequests(edited.map(LiveTVLogoRequest.init(channel:)))
        XCTAssertEqual(pending.map(\.key), [LiveTVChannelLogoKey(channel: edited[target])], "only the renamed channel needs matching")
    }

    // MARK: Main-thread gates

    private final class Preferences: LiveTVPreferencesStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var value = LiveTVPreferences()
        func load() throws -> LiveTVPreferences { lock.withLock { value } }
        func save(_ preferences: LiveTVPreferences) throws { lock.withLock { value = preferences } }
    }

    func testALargeLineupNeverBlocksTheMainThreadForLong() async throws {
        let channels = lineup()
        let service = makeService(writeDelay: 0.5)
        seed(service.store, for: channels)
        service.store.flush()
        let baseline = service.store.writeCount
        let clock = ContinuousClock()

        // The pre-change cost of the same work on the main thread, for the report: the whole-document write on every mutation,
        // the priority order built twice, and a sports parse of every channel.
        let legacyWrite = clock.measure { _ = LegacyReplica.encodeWholeStore(service.store) }
        let legacyOrder = clock.measure {
            _ = LiveTVPrototypeModel.logoPriorityOrder(channels: channels, visible: [], favoriteIDs: [])
            _ = LiveTVPrototypeModel.logoPriorityOrder(channels: channels, visible: [], favoriteIDs: [])
            _ = channels.compactMap { LiveTVSportsEventParser.parse($0.name, groups: $0.groups ?? []) }
            _ = channels.map(LiveTVLogoRequest.init(channel:))
        }
        let legacyRegion = clock.measure {
            var counts: [URL: Int] = [:]
            for other in channels where LiveTVChannelRegion.region(for: other) != nil {
                if let url = service.displayedLogoURL(for: other) { counts[url, default: 0] += 1 }
            }
        }

        // The app's path: an empty model, the catalogue derived in the background, then the lineup applied.
        let model = LiveTVPrototypeModel(channels: [], preferencesStore: Preferences(), logoService: service)
        let monitor = StallMonitor()
        monitor.start()
        let prepare = await clock.measure { await model.prepareCatalog(channels: channels) }
        var applyError: Error?
        let apply = clock.measure { do { try model.replaceChannels(channels) } catch { applyError = error } }
        XCTAssertNil(applyError)
        for _ in 0..<800 where model.isResolvingLogos { try await Task.sleep(for: .milliseconds(20)) }
        let launchStall = monitor.stop()
        XCTAssertEqual(model.channels.count > 0, true)

        // Audit: the other main-thread paths over the whole lineup. The filter sheet is opened after the lineup has settled.
        try await Task.sleep(for: .milliseconds(2_500))
        let passesBefore = model.filterCountPassesOnMainActor
        let tags = clock.measure { _ = model.filterTagSections(selectedTagIDs: []) }
        let passesDuringSheetOpen = model.filterCountPassesOnMainActor - passesBefore
        let region = clock.measure { _ = model.filterTagSections(selectedTagIDs: []).first { $0.id == LiveTVFilterTag.Section.region.rawValue } }
        let search = clock.measure { model.query = "cbc" }
        let cbcExamined = model.filterCandidatesExamined
        model.query = ""
        let rareSearch = clock.measure { model.query = "network 4242 " }
        let rareExamined = model.filterCandidatesExamined
        let rareFound = model.visibleChannels.count
        let clear = clock.measure { model.query = "" }

        let steadyMonitor = StallMonitor()
        steadyMonitor.start()
        // Steady state: scrolling reads a logo and a region label per row.
        var rows = 0
        let reads = clock.measure {
            for channel in model.channels.prefix(2_000) {
                _ = model.effectiveLogoURL(for: channel)
                _ = model.regionLabel(for: channel)
                rows += 1
            }
        }
        try await Task.sleep(for: .milliseconds(1_500))
        let steadyStall = steadyMonitor.stop()

        report("lineup=\(channels.count) storeRecords=\(service.store.syncSnapshot().count) " +
               "LEGACY wholeStoreEncodeOnMain=\(legacyWrite) requestBuildOnMain=\(legacyOrder) regionCountOnMain=\(legacyRegion) " +
               "NOW prepareCatalog(background)=\(prepare) replaceChannelsOnMain=\(apply) worstMainStallLaunch=\(Int(launchStall * 1_000))ms " +
               "worstMainStallSteady=\(Int(steadyStall * 1_000))ms rowReads(2000)=\(reads) " +
               "load=\(Self.load()) filterTagSections=\(tags) mainActorCountPassesAtSheetOpen=\(passesDuringSheetOpen) searchCbcExamined=\(cbcExamined) searchRare=\(rareSearch) rareExamined=\(rareExamined) rareFound=\(rareFound) of \(channels.count) regionSection=\(region) searchCbc=\(search) searchClear=\(clear) storeWrites=\(service.store.writeCount - baseline)")
        // Deterministic gates first (they do not depend on machine load), then the wall-clock ones.
        XCTAssertEqual(passesDuringSheetOpen, 0, "opening the filter sheet counts nothing on the main actor: the background made the counts")
        XCTAssertGreaterThan(rareFound, 0)
        XCTAssertLessThanOrEqual(rareExamined, 50, "a query examines only the channels whose text contains it, not the lineup")
        XCTAssertEqual(cbcExamined, 7_168, "a query examines exactly the channels that contain it")
        XCTAssertLessThan(tags, .milliseconds(50), "the filter sheet reads counts the background already made (load \(Self.load()))")
        // "cbc" matches a sixth of this synthetic lineup (7,168 channels), so its cost is that of building 7,168 rows; the realistic
        // narrowing query is the gate.
        XCTAssertLessThan(rareSearch, .milliseconds(50), "a narrowing query scans precomputed text (load \(Self.load()))")
        XCTAssertLessThan(apply, .milliseconds(250), "applying a prepared 43k lineup holds the main thread under 250 ms")
        XCTAssertLessThan(launchStall, 0.25, "no main-thread block over 250 ms while the lineup is applied")
        XCTAssertLessThan(steadyStall, 0.05, "no main-thread block over 50 ms in steady state")
        XCTAssertLessThanOrEqual(service.store.writeCount - baseline, 1, "the only write is the one pruning 12,000 stale records")
        XCTAssertFalse(service.store.lastWriteWasOnMainThread)
        XCTAssertEqual(rows, 2_000)
    }

    func testWhereTheMainThreadTimeOfApplyingALineupGoes() {
        let channels = lineup()
        let clock = ContinuousClock()
        var parts: [String] = []
        func time(_ name: String, _ body: () -> Void) { parts.append("\(name)=\(Int(clock.measure(body).seconds * 1_000))ms") }
        var ids = Set<String>()
        time("idSet") { ids = Set(channels.map(\.id)) }
        var order: [String] = []
        time("numberingOrder") { order = LiveTVPrototypeModel.numberingOrder(channels) }
        var numbers = LiveTVStableChannelNumbers.empty
        time("assigning") { numbers = LiveTVStableChannelNumbers.empty.assigning(orderedChannelIDs: order, at: Date()) }
        time("numbersEqual") { _ = numbers == LiveTVStableChannelNumbers.empty }
        var numbered = channels
        time("renumbered") { numbered = LiveTVPrototypeModel.renumbered(channels, using: numbers) }
        time("channelsEqual") { _ = numbered == channels }
        time("channelsEqualSame") { _ = channels == channels }
        time("placeholders") { _ = LiveTVLogoPlaceholders.placeholders(in: channels) }
        time("widestDigits") { _ = LiveTVPrototypeModel.widestNumberDigits(channels) }
        time("encodeNumbers") { _ = try? JSONEncoder().encode(LiveTVPreferences(stableChannelNumbers: numbers)) }
        report("PROFILE " + parts.joined(separator: " ") + " ids=\(ids.count)")
    }

    func testLaunchLoadOfAFiftyFiveThousandRecordStore() throws {
        let channels = lineup()
        let seeded = makeService(writeDelay: 0.2, name: "launch")
        seed(seeded.store, for: channels)
        seeded.store.flush()
        let file = directory.appendingPathComponent("launch.json")
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let clock = ContinuousClock()
        let load = clock.measure { _ = LiveTVChannelLogoStore(fileURL: file) }
        report("storeFile=\(size / 1_000_000).\(size / 10_000 % 100)MB records=\(seeded.store.syncSnapshot().count) launchLoad=\(load)")
        XCTAssertLessThan(load, .seconds(2))
    }
}

private extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}

/// What a mutation used to do on the calling thread: build, sort and encode the whole document.
private enum LegacyReplica {
    private struct Record: Codable { let key: LiveTVChannelLogoKey; let nameKey: String; let at: Int64 }

    static func encodeWholeStore(_ store: LiveTVChannelLogoStore) -> Data {
        let rows = store.syncSnapshot().map { Record(key: $0.key, nameKey: $0.match?.nameKey ?? "", at: $0.modified) }
            .sorted { ($0.key.sourceID, $0.key.channelID) < ($1.key.sourceID, $1.key.channelID) }
        return (try? JSONEncoder().encode(rows + rows)) ?? Data()
    }
}
