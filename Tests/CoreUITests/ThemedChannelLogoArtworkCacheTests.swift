#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

/// The sync writer builds both theme variants once; the cache-only read path is a plain lookup with no decode, analysis,
/// preparation, disk traffic or task, including when the theme flips.
final class ThemedChannelLogoArtworkCacheTests: XCTestCase {
    private var savedDirectory: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        savedDirectory = PreparedChannelLogoStore.directory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThemedLogos-\(UUID().uuidString)")
        PreparedChannelLogoStore.directory = directory
    }

    override func tearDownWithError() throws {
        PreparedChannelLogoStore.directory = savedDirectory
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "LogoRule", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private struct Counters: Equatable {
        let decode: Int, prepared: Int, load: Int, save: Int, files: Int
    }

    private func counters() -> Counters {
        Counters(
            decode: ChannelLogoExtractionLoader.decodeCount, prepared: ChannelLogoExtractionLoader.preparedCount,
            load: PreparedChannelLogoStore.loadCount, save: PreparedChannelLogoStore.saveCount,
            files: (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0)
    }

    private let identity = ThemedChannelLogoIdentity(url: URL(string: "https://example.test/cbc.png")!, providerRequestsDarkBackground: false)

    func testWriterBuildsBothThemesAndLookupHitsWithoutForbiddenWork() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let data = try fixture("CBC_16644.png")
        XCTAssertEqual(cache.store(identity: identity, logoData: { data }), .built)

        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: data))
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let expected = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: theme)
            let hit = try XCTUnwrap(cache.prepared(for: identity, theme: theme))
            XCTAssertEqual(hit.isDark, expected.isDark)
            XCTAssertEqual(hit.needsTextFallback, expected.needsTextFallback)
            XCTAssertEqual(hit.readableShare, expected.readableShare)
            XCTAssertEqual(hit.image.size, expected.image.size)
        }

        let before = counters()
        for _ in 0..<50 {
            XCTAssertNotNil(cache.prepared(for: identity, theme: .dark))
            XCTAssertNotNil(cache.prepared(for: identity, theme: .light))  // theme switch
        }
        XCTAssertEqual(counters(), before)
    }

    func testMissReturnsNilWithoutForbiddenWorkOrWrites() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let before = counters()
        XCTAssertNil(cache.prepared(for: identity, theme: .dark))
        XCTAssertNil(cache.prepared(for: identity, theme: .light))
        XCTAssertFalse(cache.contains(identity))
        XCTAssertEqual(counters(), before)
        XCTAssertEqual(cache.store(identity: identity, logoData: { nil }), .unavailable)
        XCTAssertEqual(cache.store(identity: identity, logoData: { Data([1, 2, 3]) }), .unavailable)
        XCTAssertEqual(cache.count, 0)
    }

    func testFlagIsPartOfIdentity() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let data = try fixture("CBC_16644.png")
        cache.store(identity: identity, logoData: { data })
        let flagged = ThemedChannelLogoIdentity(url: identity.url, providerRequestsDarkBackground: true)
        XCTAssertNil(cache.prepared(for: flagged, theme: .dark))
    }

    func testRestoreUsesPersistedValuesWithoutRecompute() throws {
        let data = try fixture("CBC_16644.png")
        ThemedChannelLogoArtworkCache(capacity: 10).store(identity: identity, logoData: { data })

        let fresh = ThemedChannelLogoArtworkCache(capacity: 10)
        let before = counters()
        XCTAssertTrue(fresh.restoreFromStore(identity: identity))
        let after = counters()
        XCTAssertEqual(after.load, before.load + 2)
        XCTAssertEqual(after.decode, before.decode)
        XCTAssertEqual(after.prepared, before.prepared)
        XCTAssertEqual(after.save, before.save)
        XCTAssertNotNil(fresh.prepared(for: identity, theme: .light))
        // The writer reuses persisted values too: its data closure is never asked.
        let again = ThemedChannelLogoArtworkCache(capacity: 10)
        XCTAssertEqual(again.store(identity: identity, logoData: { XCTFail("recomputed"); return nil }), .restoredFromStore)
    }

    func testRestoreMissCachesNothing() {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        XCTAssertFalse(cache.restoreFromStore(identity: identity))
        XCTAssertEqual(cache.count, 0)
    }

    func testCapacityDropsOldestFirst() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 2)
        let data = try fixture("CBC_16644.png")
        let ids = (0..<3).map {
            ThemedChannelLogoIdentity(url: URL(string: "https://example.test/\($0).png")!, providerRequestsDarkBackground: false)
        }
        for id in ids { cache.store(identity: id, logoData: { data }) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.contains(ids[0]))
        XCTAssertTrue(cache.contains(ids[2]))
    }

    func testRequiredLogosAreNeverEvictedAndOthersGoOldestFirst() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 2)
        let data = try fixture("CBC_16644.png")
        let ids = (0..<4).map {
            ThemedChannelLogoIdentity(url: URL(string: "https://example.test/req\($0).png")!, providerRequestsDarkBackground: false)
        }
        cache.require([.init(identity: ids[0], variants: nil)])
        for id in ids { cache.store(identity: id, logoData: { data }) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.contains(ids[0]), "required, though the oldest")
        XCTAssertFalse(cache.contains(ids[1]))
        XCTAssertFalse(cache.contains(ids[2]))
        XCTAssertTrue(cache.contains(ids[3]))
    }

    func testMoreRequiredLogosThanCapacityAreAllKept() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 2)
        let data = try fixture("CBC_16644.png")
        let ids = (0..<6).map {
            ThemedChannelLogoIdentity(url: URL(string: "https://example.test/all\($0).png")!, providerRequestsDarkBackground: false)
        }
        cache.require(ids.map { .init(identity: $0, variants: nil) })
        for id in ids { cache.store(identity: id, logoData: { data }) }
        XCTAssertEqual(cache.count, 6)
        XCTAssertTrue(ids.allSatisfy(cache.contains))
    }

    func testKnownUnpreparedSkipsTheDiskProbe() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let data = try fixture("CBC_16644.png")
        cache.store(identity: identity, knownUnprepared: true, logoData: { data })
        XCTAssertEqual(cache.preparedStoreProbeCount, 0)
        let other = ThemedChannelLogoIdentity(url: URL(string: "https://example.test/probe.png")!, providerRequestsDarkBackground: false)
        cache.store(identity: other, logoData: { data })
        XCTAssertEqual(cache.preparedStoreProbeCount, 1)
    }

    func testNetworkLogoPicksBestVariantPerThemeAndNeverFallsBackToText() throws {
        let cache = ThemedChannelLogoArtworkCache(capacity: 10)
        let first = URL(string: "https://example.test/net-a.png")!
        let second = URL(string: "https://example.test/net-b.png")!
        let datas = [first: try fixture("CBC_16644.png"), second: try fixture("CBC_16644.png")]
        let id = ThemedChannelLogoIdentity(url: first, providerRequestsDarkBackground: false)
        XCTAssertEqual(cache.storeNetworkLogo(identity: id, variants: [first, second], variantData: { datas[$0] }), .built)
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let hit = try XCTUnwrap(cache.prepared(for: id, theme: theme))
            XCTAssertFalse(hit.needsTextFallback)
        }
        XCTAssertEqual(
            cache.storeNetworkLogo(identity: id, variants: [first, second], variantData: { _ in nil }), .restoredFromStore)
        let empty = ThemedChannelLogoIdentity(url: URL(string: "https://example.test/none.png")!, providerRequestsDarkBackground: false)
        XCTAssertEqual(cache.storeNetworkLogo(identity: empty, variants: [empty.url], variantData: { _ in nil }), .unavailable)
    }

    func testArtworkCacheOptInIsOffByDefault() {
        let size = CGSize(width: 100, height: 60)
        _ = ChannelLogoArtwork(name: "A", logoURL: identity.url, size: size, cornerRadius: 4)
        _ = ChannelLogoArtwork(
            name: "A", logoURL: identity.url, size: size, cornerRadius: 4, style: .bare(),
            preparedArtworkCache: ThemedChannelLogoArtworkCache(capacity: 1))
    }
}
#endif
