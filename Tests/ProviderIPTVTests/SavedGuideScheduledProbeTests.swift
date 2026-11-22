import CoreModels
import CoreNetworking
import FeatureLiveTVCore
import Foundation
import Synchronization
@testable import ProviderIPTV
import XCTest

/// The scheduled automatic-update tick driven through the real `IPTVProvider`, `IPTVClient`
/// and a concrete `LiveTVGuideIndex`. Only the clock, the authorized-provider resolver, the
/// sleep and the HTTP transport (a local `IPTVFixture`) are fakes.
final class SavedGuideScheduledProbeTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    private static let interval: TimeInterval = 3_600
    private static let validator = "\"guide-v1\""

    /// The thin protocol bridge from `IPTVGuideIndexLoading` to the concrete index, mapping
    /// models exactly as the app's account index does.
    private struct IndexBridge: IPTVGuideIndexLoading {
        let index: LiveTVGuideIndex
        var updateInterval: TimeInterval? { SavedGuideScheduledProbeTests.interval }

        func programmes(
            url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
            trustsGuideIDs: Bool,
            catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
            download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
        ) async throws -> [ServerLiveTVProgramme] {
            let allChannels = try await catalog()
            return try await index.programs(
                from: url, catalog: allChannels.map(Self.channel), channels: channels.map(Self.channel),
                range: DateInterval(start: from, end: to), trustsGuideIDs: trustsGuideIDs, revalidate: download
            ).map(Self.programme)
        }

        func cachedProgrammes(
            url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
            trustsGuideIDs: Bool, catalogRevision: String?,
            catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
        ) async throws -> [ServerLiveTVProgramme]? {
            try await index.cachedPrograms(
                from: url, channels: channels.map(Self.channel), range: DateInterval(start: from, end: to),
                trustsGuideIDs: trustsGuideIDs, catalogRevision: catalogRevision,
                catalog: { try await catalog().map(Self.channel) }
            )?.map(Self.programme)
        }

        func updateSaved(
            url: URL, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
            download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
        ) async throws -> Date? {
            try await index.updateSaved(from: url, catalog: { try await catalog().map(Self.channel) }, revalidate: download)
        }

        func invalidate() async { await index.invalidate() }
        func cancel() async { await index.cancel() }

        private static func programme(_ program: LiveTVPrototypeProgram) -> ServerLiveTVProgramme {
            ServerLiveTVProgramme(
                id: program.id, channelID: program.channelID, title: program.title, subtitle: program.subtitle,
                overview: program.details?.description, startDate: program.start, endDate: program.end,
                imageURL: program.details?.artworkURL, categories: program.details?.categories ?? []
            )
        }

        private static func channel(_ channel: IPTVProvider.IPTVGuideChannel) -> LiveTVPrototypeChannel {
            LiveTVPrototypeChannel(
                id: channel.id, number: 0, name: channel.name, category: "Live TV", symbol: "tv",
                accent: 0, source: .iptv, tagline: "", guideID: channel.guideID,
                guideName: channel.guideName, country: channel.country,
                groups: channel.groups.isEmpty ? nil : channel.groups
            )
        }
    }

    private final class MemorySecrets: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
        func string(for key: String) -> String? { lock.withLock { values[key] } }
        func readString(for key: String) throws -> String? { string(for: key) }
        func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }

    private static func xmltv(around base: Date) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMddHHmmss"
        func stamp(_ hours: Int) -> String {
            format.string(from: base.addingTimeInterval(TimeInterval(hours) * 3_600)) + " +0000"
        }
        var document = #"<?xml version="1.0"?><tv><channel id="news"><display-name>News</display-name></channel>"#
        document += #"<channel id="sports"><display-name>Sports</display-name></channel>"#
        for (guideID, title) in [("news", "News"), ("sports", "Sports")] {
            for hour in -1..<30 {
                document += #"<programme start="\#(stamp(hour))" stop="\#(stamp(hour + 1))" channel="\#(guideID)">"#
                document += "<title>\(title) \(hour)</title></programme>"
            }
        }
        return Data((document + "</tv>").utf8)
    }

    private struct Counts: Equatable {
        var xmltv = 0, lineup = 0, native = 0, other = 0
    }

    private func counts(since start: Int = 0) -> Counts {
        var result = Counts()
        for request in IPTVFixture.state.requests.dropFirst(start) {
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            let action = query?.first { $0.name == "action" }?.value
            if request.url?.path == "/prefix/xmltv.php" { result.xmltv += 1 }
            else if action == "get_live_streams" { result.lineup += 1 }
            else if action == "get_simple_data_table" { result.native += 1 }
            else { result.other += 1 }
        }
        return result
    }

    @MainActor
    func testFrozenDueTickThroughSavedProviderIndexAndTransport() async throws {
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let clock = Mutex(base)
        let document = Self.xmltv(around: base)
        let validator = Self.validator
        IPTVFixture.state.handler = { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            let action = query?.first { $0.name == "action" }?.value
            if request.url?.path == "/prefix/xmltv.php" {
                // A runaway revalidation loop ends here instead of hanging the test.
                let received = IPTVFixture.state.requests.filter { $0.url?.path == "/prefix/xmltv.php" }.count
                if received > 4 { return (404, [:], Data()) }
                let headers = ["ETag": validator, "Cache-Control": "max-age=3600"]
                if request.value(forHTTPHeaderField: "If-None-Match") == validator { return (304, headers, Data()) }
                return (200, headers, document)
            }
            guard query?.first(where: { $0.name == "username" })?.value == "fixture-user",
                  query?.first(where: { $0.name == "password" })?.value == "fixture-password" else {
                return (401, [:], Data())
            }
            switch action {
            case nil:
                return (200, [:], Data(#"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]}}"#.utf8))
            case "get_live_categories", "get_vod_categories", "get_series_categories":
                return (200, [:], Data(#"[{"category_id":"1","category_name":"News"}]"#.utf8))
            case "get_live_streams":
                return (200, [:], Data(#"[{"stream_id":10,"name":"News","epg_channel_id":"news","category_id":"1"},{"stream_id":11,"name":"Sports","epg_channel_id":"sports","category_id":"1"}]"#.utf8))
            case "get_vod_streams":
                return (200, [:], Data(#"[{"stream_id":"20","name":"Movie","container_extension":"mkv"}]"#.utf8))
            case "get_series":
                return (200, [:], Data(#"[{"series_id":30,"name":"Series"}]"#.utf8))
            case "get_simple_data_table":
                return (200, [:], Data(#"{"epg_listings":[]}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        // The real provider, client and a concrete saved index in a temporary store.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indexDirectory = root.appendingPathComponent("saved-index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let cache = LiveTVIndexedCache(
            url: indexDirectory.appendingPathComponent("guide.sqlite"), namespace: "scheduled-probe",
            authorizationScope: "account-xmltv-v1", secureStore: MemorySecrets()
        )
        let index = LiveTVGuideIndex(
            cache: cache, preferredLanguage: nil, clock: { clock.withLock { $0 } }, updateInterval: { Self.interval }
        )
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
            username: "fixture-user", password: "fixture-password"
        )
        // Setup phase 1: sign-in authenticates and imports live, movies and series (the lineup once).
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Probe", deviceID: "fixture",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let provider = try IPTVProvider(
            context: .init(
                session: session, accountID: "probe", credentialRevision: .init(),
                localMediaContext: .init(accountID: "probe", profileID: "viewer", profileNamespace: nil)
            ),
            cacheDirectory: root, configuration: IPTVFixture.configuration(), guideIndex: IndexBridge(index: index)
        )
        addTeardownBlock {
            await provider.teardown()
            await index.cancel()
            try? FileManager.default.removeItem(at: root)
        }

        let signInCounts = counts()
        XCTAssertEqual(signInCounts.lineup, 1, "Sign-in imports the lineup once")
        XCTAssertEqual(signInCounts.xmltv, 0)
        XCTAssertEqual(signInCounts.other, 6, "authentication, three category lists, movies and series")
        let seedStart = IPTVFixture.state.requests.count

        // Setup phase 2, saved state: one real guide download through the index.
        let window = (from: base, to: base.addingTimeInterval(3 * 3_600))
        let channelIDs = ["live:10", "live:11"]
        let seeded = try await provider.liveTVGuide(channelIDs: channelIDs, from: window.from, to: window.to)
        XCTAssertFalse(seeded.isEmpty)
        XCTAssertEqual(Set(seeded.map(\.channelID)), Set(channelIDs))
        let seedCounts = counts(since: seedStart)
        XCTAssertEqual(seedCounts.xmltv, 1, "The guide is imported once through the index")
        XCTAssertEqual(signInCounts.lineup + seedCounts.lineup, 1, "The lineup is imported once across setup")
        XCTAssertEqual(seedCounts.native, 0)

        // Not yet due: the saved guide is reported as due later and nothing is requested.
        let before = IPTVFixture.state.requests.count
        let notDue = try await provider.updateSavedLiveTVGuide()
        XCTAssertEqual(counts(since: before), Counts())
        XCTAssertGreaterThan(try XCTUnwrap(notDue), base)

        // The scheduled path. The start delay is the frozen tick: the clock jumps two intervals
        // so the saved guide is due, while the lineup (committed seconds ago) is not.
        let waits = Mutex<[TimeInterval]>([])
        let resolved = Mutex<[String]>([])
        let account = LiveTVAuthorizedServerProvider(
            accountID: "probe", authorizationID: "authorization", kind: .iptv, provider: provider
        )
        let start = IPTVFixture.state.requests.count
        await LiveTVGuideAutoUpdate.run(
            accountIDs: ["probe", "unauthorized"], interval: Self.interval,
            resolver: { id in
                resolved.withLock { $0.append(id) }
                return id == "probe" ? account : nil
            },
            now: { clock.withLock { $0 } },
            sleep: { seconds in
                let count = waits.withLock { $0.append(seconds); return $0.count }
                if count == 1 { clock.withLock { $0 = base.addingTimeInterval(2 * Self.interval) } }
                if count == 2 { throw CancellationError() }
            }
        )

        // One scheduled pass: start delay, one pass, then a wait that is never under five minutes.
        XCTAssertEqual(waits.withLock { $0 }, [LiveTVGuideAutoUpdate.startDelay, 300])
        XCTAssertEqual(resolved.withLock { $0 }, ["probe", "unauthorized"])
        XCTAssertEqual(counts(since: start), Counts(xmltv: 1, lineup: 0, native: 0, other: 0),
                       "One validation of the saved guide; no lineup, native listing or other request")
        let validation = try XCTUnwrap(IPTVFixture.state.requests.dropFirst(start).first)
        XCTAssertEqual(validation.url?.path, "/prefix/xmltv.php")
        XCTAssertEqual(validation.value(forHTTPHeaderField: "If-None-Match"), validator)

        // The 304 was consumed: the saved guide answers the original window again, from disk.
        clock.withLock { $0 = base.addingTimeInterval(60) }
        let answered = IPTVFixture.state.requests.count
        let after = try await provider.liveTVGuide(channelIDs: channelIDs, from: window.from, to: window.to)
        XCTAssertEqual(Set(after.map(\.id)), Set(seeded.map(\.id)))
        XCTAssertEqual(counts(since: answered), Counts(), "The revalidated saved guide serves without a request")
    }
}
