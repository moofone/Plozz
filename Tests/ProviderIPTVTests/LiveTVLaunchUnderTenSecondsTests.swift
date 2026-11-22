import CoreModels
import CoreNetworking
import FeatureLiveTVCore
import Foundation
import Synchronization
@testable import ProviderIPTV
import XCTest

/// STARTUP-10S: a relaunch over saved Live TV data (real `IPTVProvider`/`IPTVClient`, concrete `LiveTVGuideIndex`, the real
/// import model) at provider size: ~56 k live rows, ~4.4 k guide stations, ~230 k programmes, and a VOD catalogue refresh
/// running while Live TV opens. Generated synthetically; only the HTTP transport (`IPTVFixture`) and the clock are fakes.
@MainActor
final class LiveTVLaunchUnderTenSecondsTests: XCTestCase {
    private static let liveRows = 56_000
    private static let stations = 4_400
    private static let programmesPerStation = 52

    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    private final class MemorySecrets: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
        func string(for key: String) -> String? { lock.withLock { values[key] } }
        func readString(for key: String) throws -> String? { string(for: key) }
        func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }

    private final class LastSeenMemory: LiveTVLastSeenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: LiveTVLastSeenSnapshot?
        func load() -> LiveTVLastSeenSnapshot? { lock.withLock { snapshot } }
        func save(_ snapshot: LiveTVLastSeenSnapshot?) { lock.withLock { self.snapshot = snapshot } }
    }

    private struct IndexBridge: IPTVGuideIndexLoading {
        let index: LiveTVGuideIndex
        let interval: TimeInterval

        var updateInterval: TimeInterval? { interval }

        func programmes(
            url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date, trustsGuideIDs: Bool,
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
            url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date, trustsGuideIDs: Bool,
            catalogRevision: String?, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
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

    private static func xmltv(around base: Date) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMddHHmmss"
        let stamps = (0...programmesPerStation).map {
            format.string(from: base.addingTimeInterval(TimeInterval($0 - 4) * 3 * 3_600)) + " +0000"
        }
        var document = Data(#"<?xml version="1.0"?><tv>"#.utf8)
        document.reserveCapacity(60_000_000)
        for station in 0..<stations {
            document.append(Data(#"<channel id="g\#(station)"><display-name>CA: Channel \#(station) HD</display-name></channel>"#.utf8))
        }
        for station in 0..<stations {
            for slot in 0..<programmesPerStation {
                document.append(Data((
                    #"<programme start="\#(stamps[slot])" stop="\#(stamps[slot + 1])" channel="g\#(station)">"#
                    + "<title>Show \(station)-\(slot)</title><desc>Generated description for the fixture.</desc></programme>"
                ).utf8))
            }
        }
        document.append(Data("</tv>".utf8))
        return document
    }

    private static func liveStreams() -> Data {
        var json = "["
        for index in 0..<liveRows {
            if index > 0 { json += "," }
            let guide = index < stations ? "g\(index)" : ""
            json += #"{"stream_id":\#(index + 1),"num":\#(index + 1),"name":"CA: Channel \#(index) HD","epg_channel_id":"\#(guide)","category_id":"1"}"#
        }
        return Data((json + "]").utf8)
    }

    private static func vod(_ count: Int, key: String, id: String) -> Data {
        Data(("[" + (0..<count).map { #"{"\#(id)":\#($0 + 1),"name":"Title \#($0)","container_extension":"mkv","category_id":"1"}"# }
            .joined(separator: ",") + "]").utf8)
    }

    private final class Stopwatch: @unchecked Sendable {
        let start = ContinuousClock.now
        func ms() -> Int {
            let parts = start.duration(to: .now).components
            return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        }
    }

    func testRelaunchWithSavedGuideAndARunningVODRefreshPublishesTheLineupWithoutTouchingTheGuideSource() async throws {
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let document = Self.xmltv(around: base)
        let live = Self.liveStreams()
        let movies = Self.vod(30_000, key: "movies", id: "stream_id")
        let series = Self.vod(5_000, key: "series", id: "series_id")
        let validator = "\"guide-v1\""
        let holdVOD = Mutex(false)
        let vodStarted = Mutex(false)
        let releaseVOD = DispatchSemaphore(value: 0)
        IPTVFixture.state.handler = { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            let action = query?.first { $0.name == "action" }?.value
            if request.url?.path == "/prefix/xmltv.php" {
                // A short server-stated lifetime, as the owner's provider sends.
                let headers = ["ETag": validator, "Cache-Control": "max-age=300"]
                if request.value(forHTTPHeaderField: "If-None-Match") == validator { return (304, headers, Data()) }
                return (200, headers, document)
            }
            switch action {
            case nil: return (200, [:], Data(#"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]}}"#.utf8))
            case "get_live_categories", "get_vod_categories", "get_series_categories":
                return (200, [:], Data(#"[{"category_id":"1","category_name":"CA| General"}]"#.utf8))
            case "get_live_streams": return (200, [:], live)
            case "get_vod_streams":
                if holdVOD.withLock({ $0 }) {
                    vodStarted.withLock { $0 = true }
                    guard releaseVOD.wait(timeout: .now() + 20) == .success else { throw URLError(.timedOut) }
                }
                return (200, [:], movies)
            case "get_series": return (200, [:], series)
            default: return (404, [:], Data())
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indexDirectory = root.appendingPathComponent("saved-index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
            username: "fixture-user", password: "fixture-password"
        )
        let secrets = MemorySecrets()
        let lastSeen = LastSeenMemory()
        let server = LiveTVServerSource(id: "iptv", name: "IPTV", accountID: "probe", isEnabled: true)

        func makeProvider(session: UserSession, clock: @escaping @Sendable () -> Date) throws -> (IPTVProvider, LiveTVGuideIndex) {
            let index = LiveTVGuideIndex(
                cache: LiveTVIndexedCache(
                    url: indexDirectory.appendingPathComponent("guide.sqlite"), namespace: "launch",
                    authorizationScope: "account-xmltv-v1", secureStore: secrets
                ),
                preferredLanguage: nil, clock: clock, updateInterval: { 43_200 }
            )
            let provider = try IPTVProvider(
                context: .init(
                    session: session, accountID: "probe", credentialRevision: .init(),
                    localMediaContext: .init(accountID: "probe", profileID: "viewer", profileNamespace: nil)
                ),
                cacheDirectory: root, configuration: IPTVFixture.configuration(),
                guideIndex: IndexBridge(index: index, interval: 43_200)
            )
            return (provider, index)
        }

        // Session 1 (not timed): the lineup, the VOD catalogues and the guide are imported and saved once.
        let setup = Stopwatch()
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Probe", deviceID: "fixture", cacheDirectory: root,
            configuration: IPTVFixture.configuration()
        )
        let (first, firstIndex) = try makeProvider(session: session, clock: { Date() })
        let firstImports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { _ in
                LiveTVAuthorizedServerProvider(accountID: "probe", authorizationID: "a1", kind: .iptv, provider: first, viewerScopeID: "viewer")
            }, lastSeen: lastSeen
        )
        let firstModel = LiveTVPrototypeModel(now: base, channels: [])
        await firstImports.reload(into: firstModel, forceServerRefresh: false)
        await firstImports.saveLastSeen(from: firstModel)?.value
        let seeded = IPTVFixture.state.requests.filter { $0.url?.path == "/prefix/xmltv.php" }.count
        print("STARTUP10S setup ms=\(setup.ms()) channels=\(firstModel.channels.count) xmltvRequests=\(seeded)")
        XCTAssertEqual(firstModel.channels.count, Self.liveRows)
        XCTAssertEqual(seeded, 1, "the guide is downloaded and indexed once")
        await first.teardown()
        await firstIndex.cancel()

        // The relaunch, twelve-plus hours later by the guide's clock: the saved guide's server-stated lifetime
        // (`max-age=300`) and the profile's 12 h interval have both lapsed. The VOD catalogue is older than its
        // refresh ceiling, so opening Live TV overlaps a catalogue refresh, as at the owner's launches.
        let later = Date().addingTimeInterval(13 * 3_600)
        let catalogURL = root.appendingPathComponent(credential.identity.uuidString + ".sqlite")
        let catalog = try IPTVCatalog(url: catalogURL, key: credential.catalogKey)
        try catalog.setState("movies", String(Date().addingTimeInterval(-7_200).timeIntervalSince1970))
        try catalog.setState("series", String(Date().addingTimeInterval(-7_200).timeIntervalSince1970))
        let before = IPTVFixture.state.requests.count
        let (second, secondIndex) = try makeProvider(session: session, clock: { later })
        addTeardownBlock {
            await second.teardown()
            await secondIndex.cancel()
        }
        holdVOD.withLock { $0 = true }
        defer { releaseVOD.signal() }
        let vodRefresh = Task { _ = try? await second.libraries() }
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { _ in
                LiveTVAuthorizedServerProvider(accountID: "probe", authorizationID: "a2", kind: .iptv, provider: second, viewerScopeID: "viewer")
            }, lastSeen: lastSeen
        )
        let model = LiveTVPrototypeModel(now: base, channels: [])
        let admissionDeadline = ContinuousClock.now + .seconds(3)
        while !vodStarted.withLock({ $0 }), ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(vodStarted.withLock { $0 }, "The VOD request must already be active when Live TV opens")
        let watch = Stopwatch()
        var publishedAt: Int?
        var rowsAt: Int?
        var listingsAt: Int?
        let reload = Task { await imports.reload(into: model, forceServerRefresh: false) }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if rowsAt == nil, model.channels.count > 0 { rowsAt = watch.ms() }
                if model.channels.count == Self.liveRows {
                    if publishedAt == nil { publishedAt = watch.ms() }
                    if model.guideChannels.prefix(12).contains(where: {
                        !model.programs(for: $0.channel.id, from: base, hours: 3).isEmpty
                    }) {
                        listingsAt = watch.ms()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await reload.value
        let idle = watch.ms()
        // A poll may not get another turn after the final listing publication.
        if listingsAt == nil, model.guideChannels.prefix(12).contains(where: {
            !model.programs(for: $0.channel.id, from: base, hours: 3).isEmpty
        }) { listingsAt = idle }
        poll.cancel()
        releaseVOD.signal()
        await vodRefresh.value
        let xmltvAtLaunch = IPTVFixture.state.requests.dropFirst(before).filter { $0.url?.path == "/prefix/xmltv.php" }.count
        let vodRequests = IPTVFixture.state.requests.dropFirst(before).filter {
            let action = $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
                .first { $0.name == "action" }?.value
            return action == "get_vod_streams" || action == "get_series"
        }.count
        let published = try XCTUnwrap(publishedAt, "the full lineup never reached the model")
        print("STARTUP10S relaunch savedRowsMs=\(rowsAt ?? -1) lineupPublishedMs=\(published) listingsMs=\(listingsAt ?? -1) liveTVReloadMs=\(idle)"
              + " xmltvRequests=\(xmltvAtLaunch) vodRefreshRequests=\(vodRequests) load=\(ProcessInfo.processInfo.thermalState.rawValue)")
        XCTAssertEqual(xmltvAtLaunch, 0, "a relaunch with a saved guide never downloads or parses the XMLTV")
        XCTAssertLessThan(published, 10_000, "the saved full lineup must publish within the launch budget")
        XCTAssertLessThan(published, 2_000, "the lineup is published in under 2 s")
        XCTAssertLessThan(idle, 10_000, "the Live TV reload finishes in under 10 s")
        let withListings = model.guideChannels.prefix(12).filter { !model.programs(for: $0.channel.id, from: base, hours: 3).isEmpty }
        XCTAssertFalse(withListings.isEmpty, "the first rows have listings from the saved guide")
    }
}
