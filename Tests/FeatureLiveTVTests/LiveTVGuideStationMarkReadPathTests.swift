#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import MetadataKit
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeatureLiveTV
@testable import FeatureLiveTVCore

/// The real IPTV guide mark read path: rows read the identity the sync writer committed and the prepared pair it built, offline.
/// This proves one row's hit, miss and theme switch; it is not an end-to-end open-time measurement.
@MainActor
final class LiveTVGuideStationMarkReadPathTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StationMark-\(UUID().uuidString)")
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

    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 20, y: 10, width: 120, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 50, y: 30, width: 60, height: 20))
        }
    }

    private func render(_ channel: LiveTVPrototypeChannel, marks: LiveTVGuideStationMarks, theme: ThemePalette) throws -> Data {
        let mark = PrototypeStationMark(
            channel: channel, plateSize: CGSize(width: 252, height: 82), cornerRadius: PrototypeLayout.rowRadius,
            usesBareLogo: true, usesSyncedMarks: true)
            .environment(\.liveTVGuideStationMarks, marks)
            .environment(\.themePalette, theme)
            .frame(width: 252, height: 82)
            .background(Color.black)
        let renderer = ImageRenderer(content: mark)
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }

    func testSyncedRowHitMissAndThemeSwitchReadOnlyMemory() async throws {
        let store = LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("logos.json"))
        let service = LiveTVChannelLogoService(
            store: store, directory: TMDbNetworkDirectory(fileURL: directory.appendingPathComponent("networks.json")),
            wikidata: WikidataLogoDirectory(fileURL: directory.appendingPathComponent("wikidata.json")),
            accessProvider: { .disabled })
        let source = LiveTVServerSource(id: "source-1", name: "Sync", accountID: "account-1")
        let iconURL = URL(string: "https://example.test/\(UUID().uuidString)/channel.png")!
        let missURL = URL(string: "https://example.test/\(UUID().uuidString)/unprepared.png")!
        let hitID = LiveTVServerCatalog.channelID(source: source, nativeID: "7")
        let missID = LiveTVServerCatalog.channelID(source: source, nativeID: "8")
        XCTAssertTrue(store.setOverride(.url(iconURL), for: LiveTVChannelLogoKey(sourceID: source.id, channelID: hitID)))
        XCTAssertTrue(store.setOverride(.url(missURL), for: LiveTVChannelLogoKey(sourceID: source.id, channelID: missID)))
        let provider = SavedLineupProvider(channels: [
            ServerLiveTVChannel(id: "7", name: "Sync Channel"), ServerLiveTVChannel(id: "8", name: "Missing Logo")])
        let scope = LiveTVSyncArtworkWriter.Scope(
            accountIDs: [source.accountID],
            resolver: { _ in LiveTVAuthorizedServerProvider(accountID: "account-1", authorizationID: "auth", kind: .iptv, provider: provider) },
            sources: { [source] }, isCurrent: { true })

        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let index = LiveTVGuideStationMarkIndex()
        let data = pngData()
        let downloads = Loads()
        let writer = LiveTVSyncArtworkWriter(cache: cache, logoService: service, logoData: { url in
            downloads.record()
            // Only the first logo is downloadable: the second stays unprepared (a miss).
            return url == iconURL ? data : nil
        }, stationMarks: index)
        let summary = await writer.publish(
            LiveTVGuideRefreshResult(committedInputs: [
                "account-1": SavedGuideCommittedInputs(lineupRevision: "r", changedLineupChannelIDs: ["7", "8"])]),
            scope: scope)
        XCTAssertEqual(summary.built, 1)
        XCTAssertEqual(summary.unavailable, 1)
        XCTAssertTrue(index.covers(sourceID: source.id))

        func channel(_ id: String, _ name: String) -> LiveTVPrototypeChannel {
            LiveTVPrototypeChannel(
                id: id, number: 1, name: name, category: "Live TV", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                configuredSourceID: source.id)
        }
        let hit = channel(hitID, "Sync Channel"), miss = channel(missID, "Missing Logo")
        let marks = LiveTVGuideStationMarks(index: index, cache: cache)
        XCTAssertEqual(marks.read(hit), .logo(ThemedChannelLogoIdentity(url: iconURL, providerRequestsDarkBackground: false), regionLabel: nil))
        XCTAssertEqual(marks.read(miss), .name)

        let downloadsBeforeRender = downloads.value
        let hitDark = try render(hit, marks: marks, theme: .dark)
        let hitLight = try render(hit, marks: marks, theme: .light)
        let missDark = try render(miss, marks: marks, theme: .dark)
        XCTAssertNotEqual(hitDark, missDark, "a prepared logo and the safe name text draw differently")
        XCTAssertNotEqual(hitLight, missDark, "the light variant of the same pair draws from the same lookup")
        XCTAssertEqual(downloads.value, downloadsBeforeRender, "rendering never downloads")
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            XCTAssertNotNil(cache.prepared(for: ThemedChannelLogoIdentity(url: iconURL, providerRequestsDarkBackground: false), theme: theme))
            XCTAssertNil(
                ChannelLogoExtractionLoader.cached(url: iconURL, providerRequestsDarkBackground: false, theme: theme),
                "the row never went through the async loader")
        }

        // A channel of another provider keeps its own path; revocation drops everything the writer committed.
        let playlist = LiveTVPrototypeChannel(
            id: "playlist-1", number: 2, name: "Playlist", category: "Live TV", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", configuredSourceID: "playlist-source")
        XCTAssertEqual(marks.read(playlist), .unsynced)
        index.revoke()
        XCTAssertEqual(marks.read(hit), .unsynced)
        XCTAssertFalse(index.hasCommitted(accountID: "account-1"))
    }

    func testCommitNotifiesRowsThatReadBeforeIt() {
        let index = LiveTVGuideStationMarkIndex()
        let revision = index.currentRevision
        let notified = expectation(description: "a row that drew a name before the commit is invalidated")
        withObservationTracking {
            _ = index.presentation(forChannelID: "c1")
        } onChange: {
            notified.fulfill()
        }
        index.commit(
            accountID: "a", sourceIDs: ["s"],
            presentations: ["c1": LiveTVGuideStationMarkPresentation(identity: nil, regionLabel: nil, sportsGlyphSymbol: nil)],
            revision: revision)
        wait(for: [notified], timeout: 1)
    }

    func testStaleCommitDoesNotNotify() {
        let index = LiveTVGuideStationMarkIndex()
        let stale = index.currentRevision
        index.revoke()
        let generation = index.generation
        XCTAssertFalse(index.commit(accountID: "a", sourceIDs: ["s"], presentations: [:], revision: stale))
        XCTAssertEqual(index.generation, generation)
    }
}
#endif
