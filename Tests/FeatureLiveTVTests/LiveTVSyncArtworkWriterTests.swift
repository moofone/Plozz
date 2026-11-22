#if canImport(UIKit)
import CoreModels
import CoreUI
import MetadataKit
import UIKit
import XCTest
@testable import FeatureLiveTV
@testable import FeatureLiveTVCore

/// The production sync-time writer: a refresh that committed a changed channel icon prepares both themes; replaying an
/// unchanged refresh submits nothing; a restart restores from the persisted store without any download.
final class LiveTVSyncArtworkWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncArtwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private struct SavedLineupProvider: ServerLiveTVProviding {
        let channels: [ServerLiveTVChannel]
        func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot? {
            ServerLiveTVCatalogSnapshot(channels: channels, supportsGuide: true)
        }
        func liveTVAvailability() async throws -> ServerLiveTVAvailability { .init(status: .available, channelCount: channels.count) }
        func liveTVChannels() async throws -> [ServerLiveTVChannel] { XCTFail("must not fetch"); return [] }
        func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
        func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease { throw CancellationError() }
    }

    private final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) { lock.withLock { urls.append(url) } }
        var count: Int { lock.withLock { urls.count } }
    }

    private func pngData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 20, y: 10, width: 120, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 50, y: 30, width: 60, height: 20))
        }
    }

    private struct Fixture {
        let service: LiveTVChannelLogoService
        let source: LiveTVServerSource
        let iconURL: URL
        let scope: LiveTVSyncArtworkWriter.Scope
    }

    private func fixture(isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) throws -> Fixture {
        let store = LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("logos.json"))
        let service = LiveTVChannelLogoService(
            store: store, directory: TMDbNetworkDirectory(fileURL: directory.appendingPathComponent("networks.json")),
            wikidata: WikidataLogoDirectory(fileURL: directory.appendingPathComponent("wikidata.json")),
            accessProvider: { .disabled })
        let source = LiveTVServerSource(id: "source-1", name: "Sync", accountID: "account-1")
        let iconURL = URL(string: "https://example.test/\(UUID().uuidString)/channel.png")!
        let nativeID = "7"
        let key = LiveTVChannelLogoKey(
            sourceID: source.id, channelID: LiveTVServerCatalog.channelID(source: source, nativeID: nativeID))
        XCTAssertTrue(store.setOverride(.url(iconURL), for: key))
        let provider = SavedLineupProvider(channels: [ServerLiveTVChannel(id: nativeID, name: "Sync Channel")])
        let scope = LiveTVSyncArtworkWriter.Scope(
            accountIDs: [source.accountID],
            resolver: { _ in LiveTVAuthorizedServerProvider(accountID: "account-1", authorizationID: "auth", kind: .iptv, provider: provider) },
            sources: { [source] }, isCurrent: isCurrent)
        return Fixture(service: service, source: source, iconURL: iconURL, scope: scope)
    }

    private func committed(_ ids: [String]) -> LiveTVGuideRefreshResult {
        LiveTVGuideRefreshResult(committedInputs: [
            "account-1": SavedGuideCommittedInputs(lineupRevision: "r", changedLineupChannelIDs: ids)
        ])
    }

    func testAcceptedChangedIconBuildsBothThemesAndUnchangedReplaySubmitsNothing() async throws {
        let fixture = try fixture()
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let downloads = Downloads()
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return data
        })
        let identity = ThemedChannelLogoIdentity(url: fixture.iconURL, providerRequestsDarkBackground: false)

        // First run after launch: bootstrap restores only (nothing persisted yet), then the committed change builds.
        let first = await writer.publish(committed(["7"]), scope: fixture.scope)
        XCTAssertEqual(first.built, 1)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertTrue(cache.contains(identity), "the pair holds both themes")

        // Unchanged validation: a refresh that committed nothing submits no preparations.
        let replay = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(replay.submitted, 0)
        XCTAssertEqual(downloads.count, 1)
        // The same change reported again does not rebuild a logo that is already cached.
        let again = await writer.publish(committed(["7"]), scope: fixture.scope)
        XCTAssertEqual(again.submitted, 0)
        XCTAssertEqual(downloads.count, 1)
    }

    func testRestartBootstrapRestoresPersistedPairWithoutDownloadAndIgnoresTransferOnly() async throws {
        let fixture = try fixture()
        let data = pngData()
        let seeding = LiveTVSyncArtworkWriter(
            cache: ThemedChannelLogoArtworkCache(capacity: 10), logoService: fixture.service, logoData: { _ in data })
        let seeded = await seeding.publish(committed(["7"]), scope: fixture.scope)
        XCTAssertEqual(seeded.built, 1)

        let downloads = Downloads()
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let restarted = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return nil
        })
        // A run that only transferred (nothing committed) still bootstraps the persisted pair, restore-only.
        var transferOnly = LiveTVGuideRefreshResult()
        transferOnly.transferredAccountIDs = ["account-1"]
        let summary = await restarted.publish(transferOnly, scope: fixture.scope)
        XCTAssertEqual(summary.restored, 1)
        XCTAssertEqual(summary.built, 0)
        XCTAssertEqual(downloads.count, 0)
        XCTAssertTrue(cache.contains(ThemedChannelLogoIdentity(url: fixture.iconURL, providerRequestsDarkBackground: false)))
        let second = await restarted.publish(transferOnly, scope: fixture.scope)
        XCTAssertEqual(second.submitted, 0)
    }

    func testRetiredScopePublishesNothing() async throws {
        let fixture = try fixture(isCurrent: { false })
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let downloads = Downloads()
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return data
        })
        let summary = await writer.publish(committed(["7"]), scope: fixture.scope)
        XCTAssertEqual(summary.submitted, 0)
        XCTAssertEqual(downloads.count, 0)
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: Bootstrap fill of never-prepared logos

    private struct ManyFixture {
        let service: LiveTVChannelLogoService
        let scope: LiveTVSyncArtworkWriter.Scope
        let urls: [URL]
        let channels: [ServerLiveTVChannel]
        let source: LiveTVServerSource
    }

    private func manyFixture(count: Int, isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) throws -> ManyFixture {
        let store = LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("many-logos.json"))
        let service = LiveTVChannelLogoService(
            store: store, directory: TMDbNetworkDirectory(fileURL: directory.appendingPathComponent("networks.json")),
            wikidata: WikidataLogoDirectory(fileURL: directory.appendingPathComponent("wikidata.json")),
            accessProvider: { .disabled })
        let source = LiveTVServerSource(id: "source-1", name: "Sync", accountID: "account-1")
        let run = UUID().uuidString
        var urls: [URL] = []
        var channels: [ServerLiveTVChannel] = []
        for index in 0..<count {
            let url = URL(string: "https://example.test/\(run)/\(index).png")!
            urls.append(url)
            let nativeID = String(index)
            let key = LiveTVChannelLogoKey(
                sourceID: source.id, channelID: LiveTVServerCatalog.channelID(source: source, nativeID: nativeID))
            XCTAssertTrue(store.setOverride(.url(url), for: key))
            channels.append(ServerLiveTVChannel(id: nativeID, name: "Channel \(index)"))
        }
        let provider = SavedLineupProvider(channels: channels)
        let scope = LiveTVSyncArtworkWriter.Scope(
            accountIDs: [source.accountID],
            resolver: { _ in LiveTVAuthorizedServerProvider(accountID: "account-1", authorizationID: "auth", kind: .iptv, provider: provider) },
            sources: { [source] }, isCurrent: isCurrent)
        return ManyFixture(service: service, scope: scope, urls: urls, channels: channels, source: source)
    }

    func testBootstrapPreparesEveryResolvedButUnpreparedLogoOnceAndSecondBootstrapDownloadsNothing() async throws {
        let fixture = try manyFixture(count: 40)
        let cache = ThemedChannelLogoArtworkCache(capacity: 100)
        let downloads = Downloads()
        let data = pngData()
        let marks = LiveTVGuideStationMarkIndex()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return data
        }, stationMarks: marks)
        let before = marks.generation
        let first = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(first.built, 40)
        XCTAssertEqual(downloads.count, 40)
        XCTAssertEqual(cache.count, 40)
        XCTAssertGreaterThan(marks.generation, before, "rows are told when artwork was prepared")

        await writer.reset()
        let second = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(second.submitted, 0)
        XCTAssertEqual(downloads.count, 40)
    }

    func testMatchArrivingAfterEmptyBootstrapPublishesPreparedStationMark() async throws {
        let fixture = try fixture()
        let id = LiveTVServerCatalog.channelID(source: fixture.source, nativeID: "7")
        let key = LiveTVChannelLogoKey(sourceID: fixture.source.id, channelID: id)
        XCTAssertTrue(fixture.service.store.setOverride(nil, for: key))
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let marks = LiveTVGuideStationMarkIndex()
        let downloads = Downloads()
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return data
        }, stationMarks: marks)

        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertTrue(marks.hasCommitted(accountID: fixture.source.accountID))
        XCTAssertNil(marks.presentation(forChannelID: id)?.identity)
        XCTAssertEqual(downloads.count, 0)

        let identity = LiveTVChannelLogoIdentity(key: key, nameKey: "syncchannel")
        let file = "Synthetic \(UUID().uuidString).png"
        XCTAssertTrue(fixture.service.store.recordWikidataMatches([identity: .logo(qid: "Q42", file: file)]))
        let next = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(next.built, 1, "matching must not wait for a changed guide refresh")
        let published = try XCTUnwrap(marks.presentation(forChannelID: id)?.identity)
        XCTAssertTrue(cache.contains(published))
        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(downloads.count, 1, "unchanged artwork must not be downloaded again")
    }

    func testBootstrapPreparesMoreThanFifteenHundredDistinctLogos() async throws {
        let fixture = try manyFixture(count: 1_600)
        let cache = ThemedChannelLogoArtworkCache(capacity: 4_000)
        let downloads = Downloads()
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return data
        }, stationMarks: LiveTVGuideStationMarkIndex())
        let summary = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(summary.built, 1_600)
        XCTAssertEqual(cache.count, 1_600)
    }

    func testFailedLogoIsNotRetriedByLaterBootstrapInTheSameLaunch() async throws {
        let fixture = try manyFixture(count: 3)
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let downloads = Downloads()
        let data = pngData()
        let bad = fixture.urls[1]
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return url == bad ? nil : data
        }, stationMarks: LiveTVGuideStationMarkIndex())
        let first = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(first.built, 2)
        XCTAssertEqual(first.unavailable, 1)
        XCTAssertEqual(downloads.count, 3)
        await writer.reset()
        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(downloads.count, 3, "the failed URL waits for the next launch or a changed refresh")
    }

    func testCancelledBootstrapStopsAndPublishesNoMoreArtwork() async throws {
        let fixture = try manyFixture(count: 200)
        let cache = ThemedChannelLogoArtworkCache(capacity: 500)
        let data = pngData()
        let downloads = Downloads()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            try? await Task.sleep(nanoseconds: 5_000_000)
            return data
        }, stationMarks: LiveTVGuideStationMarkIndex())
        let task = Task { await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope) }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        _ = await task.value
        let settled = cache.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(settled, 200)
        XCTAssertEqual(cache.count, settled, "nothing is prepared after cancellation")
    }

    // MARK: Fixes 2

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var committedAtFirstDownload: Bool?
        func recordFirst(_ committed: Bool) { lock.withLock { if committedAtFirstDownload == nil { committedAtFirstDownload = committed } } }
        var first: Bool? { lock.withLock { committedAtFirstDownload } }
    }

    func testMarksAreCommittedBeforeTheFirstDownload() async throws {
        let fixture = try manyFixture(count: 10)
        let marks = LiveTVGuideStationMarkIndex()
        let order = Order()
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(
            cache: ThemedChannelLogoArtworkCache(capacity: 100), logoService: fixture.service,
            logoData: { _ in order.recordFirst(marks.hasCommitted(accountID: "account-1")); return data }, stationMarks: marks)
        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(order.first, true, "rows can draw persisted logos and names while the rest download")
    }

    func testRestartWithEveryLogoOnDiskDownloadsNothingAndRestoresThemAll() async throws {
        let fixture = try manyFixture(count: 50)
        let data = pngData()
        let seeding = LiveTVSyncArtworkWriter(
            cache: ThemedChannelLogoArtworkCache(capacity: 100), logoService: fixture.service, logoData: { _ in data },
            stationMarks: LiveTVGuideStationMarkIndex())
        let seeded = await seeding.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(seeded.built, 50)

        let downloads = Downloads()
        let cache = ThemedChannelLogoArtworkCache(capacity: 100)
        let restarted = LiveTVSyncArtworkWriter(
            cache: cache, logoService: fixture.service, logoData: { url in downloads.record(url); return nil },
            stationMarks: LiveTVGuideStationMarkIndex())
        let summary = await restarted.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(summary.restored, 50)
        XCTAssertEqual(summary.built + summary.unavailable, 0)
        XCTAssertEqual(downloads.count, 0)
        XCTAssertEqual(cache.count, 50)
    }

    func testEachUnpreparedLogoIsProbedOnDiskOncePerBootstrap() async throws {
        let fixture = try manyFixture(count: 30)
        let cache = ThemedChannelLogoArtworkCache(capacity: 100)
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(
            cache: cache, logoService: fixture.service, logoData: { _ in data }, stationMarks: LiveTVGuideStationMarkIndex())
        let summary = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(summary.built, 30)
        XCTAssertEqual(cache.preparedStoreProbeCount, 30, "one restore probe each, none repeated by the download pass or the build")
    }

    func testSyncNowThatCommittedNothingRetriesFailedLogosOnce() async throws {
        let fixture = try manyFixture(count: 3)
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let downloads = Downloads()
        let data = pngData()
        let bad = fixture.urls[1]
        let working = Flag(false)
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: fixture.service, logoData: { url in
            downloads.record(url)
            return url == bad && !working.isOn ? nil : data
        }, stationMarks: LiveTVGuideStationMarkIndex())
        let first = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(first.unavailable, 1)
        XCTAssertEqual(downloads.count, 3)

        // A scheduled-looking replay that is not a delivered refresh does nothing.
        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(downloads.count, 3)

        // Sync Now commits nothing and the logo still fails: exactly one more attempt, then no more until the next Sync Now.
        let stillFailing = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope, retriesFailedLogos: true)
        XCTAssertEqual(stillFailing.unavailable, 1)
        XCTAssertEqual(downloads.count, 4)

        working.isOn = true
        let recovered = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope, retriesFailedLogos: true)
        XCTAssertEqual(recovered.built, 1)
        XCTAssertEqual(downloads.count, 5)
        XCTAssertEqual(cache.count, 3)
        _ = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope, retriesFailedLogos: true)
        XCTAssertEqual(downloads.count, 5, "nothing failed any more")
    }

    func testRequiredLogosSurviveACacheSmallerThanTheLineup() async throws {
        let fixture = try manyFixture(count: 120)
        let cache = ThemedChannelLogoArtworkCache(capacity: 50)
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(
            cache: cache, logoService: fixture.service, logoData: { _ in data }, stationMarks: LiveTVGuideStationMarkIndex())
        let summary = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope)
        XCTAssertEqual(summary.built, 120)
        XCTAssertEqual(cache.count, 120, "capacity is 50, but every logo the lineup draws is kept")
    }

    /// Measurement, not a gate: runs only when `/tmp/plozz-measure-logo-fill` exists on the host, and writes the numbers there.
    func testFillOfSixThousandThreeHundredStubbedLogosIsMeasured() async throws {
        let marker = "/tmp/plozz-measure-logo-fill"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker), "opt-in measurement")
        let count = 6_300
        let fixture = try manyFixture(count: count)
        let cache = ThemedChannelLogoArtworkCache(capacity: 4_000)
        let data = pngData()
        let writer = LiveTVSyncArtworkWriter(
            cache: cache, logoService: fixture.service, logoData: { _ in data }, stationMarks: LiveTVGuideStationMarkIndex())
        func measure(_ work: () async -> Void) async -> (wall: Double, cpu: Double) {
            let cpuStart = Self.cpuSeconds()
            let start = ContinuousClock.now
            await work()
            let elapsed = start.duration(to: .now)
            return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, Self.cpuSeconds() - cpuStart)
        }
        let planning = await measure {
            _ = LiveTVSyncArtworkPlanner.channelPlans(
                channels: fixture.channels, sources: [fixture.source], accountID: "account-1", kind: .iptv, logoService: fixture.service)
            _ = LiveTVSyncArtworkPlanner.candidates(
                channels: fixture.channels, onlyChannelIDs: nil, sources: [fixture.source], accountID: "account-1", kind: .iptv,
                logoService: fixture.service, limit: Int.max)
        }
        var summary = LiveTVSyncArtworkWriter.Summary()
        let fill = await measure { summary = await writer.publish(LiveTVGuideRefreshResult(), scope: fixture.scope) }
        XCTAssertEqual(summary.built, count)
        XCTAssertEqual(cache.count, count, "no required logo is evicted, though capacity is 4,000")
        // A relaunch: every pair is on disk, so nothing downloads or decodes images.
        let relaunchCache = ThemedChannelLogoArtworkCache(capacity: 4_000)
        let relaunched = LiveTVSyncArtworkWriter(
            cache: relaunchCache, logoService: fixture.service, logoData: { _ in nil }, stationMarks: LiveTVGuideStationMarkIndex())
        var restored = LiveTVSyncArtworkWriter.Summary()
        let relaunch = await measure { restored = await relaunched.publish(LiveTVGuideRefreshResult(), scope: fixture.scope) }
        XCTAssertEqual(restored.restored, count)
        let line = """
            LOGO-FILL-2 (\(count) stubbed logos, 160x80 PNG each)
            planning(plans+candidates): wall=\(planning.wall)s cpu=\(planning.cpu)s
            fill: wall=\(fill.wall)s cpu=\(fill.cpu)s cpu/logo=\(fill.cpu / Double(count) * 1000)ms
            relaunch restore: wall=\(relaunch.wall)s cpu=\(relaunch.cpu)s cpu/logo=\(relaunch.cpu / Double(count) * 1000)ms\n
            """
        try line.write(toFile: marker + ".result", atomically: true, encoding: .utf8)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
#endif
