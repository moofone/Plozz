import CoreModels
import CoreNetworking
import FeatureLiveTVCore
import Foundation
import XCTest
import zlib
@testable import ProviderIPTV

/// User-added extra XMLTV guides: they fill channels the provider's guide has nothing for and never replace or break it.
final class IPTVExtraGuideTests: XCTestCase {
    private let primary = URL(string: "https://cdn.test/primary.xml")!
    private let extra = URL(string: "http://cdn.test/extra.xml.gz")!
    private let window = (from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500))

    override func setUp() {
        IPTVFixture.state.reset()
    }

    // MARK: Credential

    func testCredentialSavedBeforeExtraGuidesDecodesWithNoneAndKeepsItsGuides() throws {
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list.m3u")),
            guideURL: primary, additionalGuideURLs: [extra]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(Data(base64Encoded: credential.encoded()))
        ) as? [String: Any])
        XCTAssertNil(object["mergedGuideURLs"], "Without extras the new key is not written, so older builds read the same record")
        object["mergedGuideURLs"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        let decoded = try IPTVCredential.decode(legacy)
        XCTAssertEqual(decoded.extraGuideURLs, [])
        XCTAssertEqual(decoded.explicitGuideURLs, [primary, extra], "Existing guide addresses keep replacing the provider's guide")
    }

    func testExtraGuidesRoundTripAndReplacingThemKeepsIdentityAndCatalogKey() throws {
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
            username: "u", password: "p", extraGuideURLs: [extra]
        )
        XCTAssertTrue(credential.explicitGuideURLs.isEmpty, "Extras never count as the provider's replacement guide")
        let decoded = try IPTVCredential.decode(credential.encoded())
        XCTAssertEqual(decoded.extraGuideURLs, [extra])
        let replaced = try decoded.replacingExtraGuideURLs([primary])
        XCTAssertEqual(replaced.extraGuideURLs, [primary])
        XCTAssertEqual(replaced.identity, credential.identity)
        XCTAssertEqual(replaced.catalogKey, credential.catalogKey)
        XCTAssertEqual(try replaced.replacingExtraGuideURLs([]).extraGuideURLs, [])
        XCTAssertThrowsError(try decoded.replacingExtraGuideURLs([extra, extra]))
        XCTAssertThrowsError(try decoded.replacingExtraGuideURLs([URL(string: "ftp://cdn.test/a.xml")!]))
        XCTAssertThrowsError(try decoded.replacingExtraGuideURLs((0..<32).map { URL(string: "https://cdn.test/\($0).xml")! }))
    }

    func testExtraGuideNeverReceivesTheProviderHeadersOnAnotherOrigin() throws {
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list.m3u")),
            headers: ["Authorization": "Bearer secret"], extraGuideURLs: [extra]
        )
        XCTAssertTrue(credential.guideHeaders(for: extra).isEmpty)
    }

    // MARK: Merge

    func testExtraFillsOnlyRowsTheProviderGuideHasNoListingsFor() async throws {
        IPTVFixture.state.handler = Self.handler(extraBody: Data("<tv>extra</tv>".utf8))
        let calls = Calls()
        let provider = try await makeProvider(extras: [extra]) { data, url, channels, from, to in
            calls.record(url: url, channels: channels.map(\.id))
            if url == self.primary {
                return [.init(id: "p10", channelID: "live:10", title: "Provider", startDate: from, endDate: to)]
            }
            XCTAssertEqual(data, Data("<tv>extra</tv>".utf8))
            return channels.map { .init(id: "x\($0.id)", channelID: $0.id, title: "Extra", startDate: from, endDate: to) }
        }
        let rows = try await provider.liveTVGuide(
            channelIDs: ["live:10", "live:11", "live:12"], from: window.from, to: window.to
        )
        XCTAssertEqual(rows.filter { $0.channelID == "live:10" }.map(\.title), ["Provider"])
        XCTAssertEqual(rows.filter { $0.channelID != "live:10" }.map(\.channelID).sorted(), ["live:11", "live:12"])
        XCTAssertEqual(calls.channels(for: extra), [["live:11", "live:12"]], "The extra guide is offered only rows without listings")
        XCTAssertEqual(calls.channels(for: primary).count, 1)
        let status = IPTVExtraGuideStatusStore.shared.statuses(for: try await credentialIdentity(provider), urls: [extra])
        XCTAssertEqual(status.first?.channelCount, 2, "Coverage: the extra guide supplied two channels")
        XCTAssertNotNil(status.first?.loadedAt)
        XCTAssertEqual(status.first?.couldNotLoad, false)
    }

    func testExtraGuideIsNotReadWhenTheProviderGuideCoversEveryRow() async throws {
        IPTVFixture.state.handler = Self.handler(extraBody: Data("<tv/>".utf8))
        let provider = try await makeProvider(extras: [extra]) { _, url, channels, from, to in
            XCTAssertEqual(url, self.primary, "No gap, so the extra guide is never downloaded")
            return channels.map { .init(id: $0.id, channelID: $0.id, title: "Provider", startDate: from, endDate: to) }
        }
        let rows = try await provider.liveTVGuide(channelIDs: ["live:10", "live:11"], from: window.from, to: window.to)
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(IPTVFixture.state.requests.contains { $0.url == extra })
    }

    func testSecondExtraGuideOnlyFillsWhatTheFirstExtraLeftEmpty() async throws {
        let second = URL(string: "https://cdn.test/second.xml")!
        IPTVFixture.state.handler = Self.handler(extraBody: Data("<tv/>".utf8), also: [second: Data("<tv/>".utf8)])
        let calls = Calls()
        let provider = try await makeProvider(extras: [extra, second]) { _, url, channels, from, to in
            calls.record(url: url, channels: channels.map(\.id))
            if url == self.primary { return [] }
            let answered = url == self.extra ? channels.filter { $0.id == "live:10" } : channels
            return answered.map { .init(id: "\(url.host!)\($0.id)", channelID: $0.id, title: url.lastPathComponent, startDate: from, endDate: to) }
        }
        let rows = try await provider.liveTVGuide(channelIDs: ["live:10", "live:11"], from: window.from, to: window.to)
        XCTAssertEqual(calls.channels(for: second), [["live:11"]])
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: Isolation

    func testExtraGuideFailureNeverBreaksTheProviderGuideAndIsNotRetriedImmediately() async throws {
        IPTVFixture.state.handler = { request in
            if request.url == self.extra { return (404, [:], Data()) }
            return try Self.handler(extraBody: Data())(request)
        }
        let provider = try await makeProvider(extras: [extra]) { _, url, channels, from, to in
            XCTAssertEqual(url, self.primary)
            return channels.filter { $0.id == "live:10" }
                .map { .init(id: "p", channelID: $0.id, title: "Provider", startDate: from, endDate: to) }
        }
        for _ in 0..<2 {
            let rows = try await provider.liveTVGuide(channelIDs: ["live:10", "live:11"], from: window.from, to: window.to)
            XCTAssertEqual(rows.map(\.title), ["Provider"], "A failing extra guide leaves the provider's listings untouched")
        }
        XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url == extra }.count, 1, "A failed extra waits out a back-off")
        let status = IPTVExtraGuideStatusStore.shared.statuses(for: try await credentialIdentity(provider), urls: [extra])
        XCTAssertEqual(status.first?.couldNotLoad, true)
    }

    func testExtraGuideFailureDoesNotStartTheProviderGuideBackoff() async throws {
        IPTVFixture.state.handler = { request in
            if request.url == self.extra { return (429, ["Retry-After": "3600"], Data()) }
            return try Self.handler(extraBody: Data())(request)
        }
        let provider = try await makeProvider(extras: [extra]) { _, url, channels, from, to in
            channels.map { .init(id: $0.id, channelID: $0.id, title: "Provider", startDate: from, endDate: to) }
                .filter { _ in url == self.primary }
        }
        _ = try await provider.liveTVGuide(channelIDs: ["live:11"], from: window.from, to: window.to)
        IPTVFixture.state.handler = Self.handler(extraBody: Data())
        let again = try await provider.liveTVGuide(channelIDs: ["live:10"], from: window.from, to: window.to)
        XCTAssertEqual(again.map(\.title), ["Provider"])
    }

    func testFailedProviderGuideStillDeliversExtraListingsAsAPartialResult() async throws {
        IPTVFixture.state.handler = { request in
            if request.url == self.primary { return (404, [:], Data()) }
            return try Self.handler(extraBody: Data("<tv/>".utf8))(request)
        }
        let provider = try await makeProvider(extras: [extra]) { _, url, channels, from, to in
            channels.map { .init(id: $0.id, channelID: $0.id, title: "Extra", startDate: from, endDate: to) }
        }
        do {
            _ = try await provider.liveTVGuide(channelIDs: ["live:11"], from: window.from, to: window.to)
            XCTFail("The provider guide's failure must stay visible")
        } catch {
            let partial = try XCTUnwrap(error as? ServerLiveTVPartialGuideError)
            XCTAssertEqual(partial.programmes.map(\.title), ["Extra"])
            XCTAssertEqual(partial.failure as? AppError, .notFound)
        }
    }

    // MARK: Formats

    func testGzipExtraGuideIsParsedByTheStreamingParser() async throws {
        let xml = """
        <tv><channel id="ext.news"><display-name>News</display-name></channel>
        <programme start="19700101000200 +0000" stop="19700101000700 +0000" channel="ext.news"><title>Gzip Evening</title></programme></tv>
        """
        IPTVFixture.state.handler = Self.handler(extraBody: try Self.gzip(Data(xml.utf8)))
        let provider = try await makeProvider(extras: [extra]) { data, url, channels, from, to in
            if url == self.primary { return [] }
            XCTAssertEqual(Array(data.prefix(2)), [0x1f, 0x8b], "The extra guide arrives compressed, as the size caps expect")
            let prototypes = channels.map {
                LiveTVPrototypeChannel(
                    id: $0.id, number: 0, name: $0.name, category: "Live TV", symbol: "tv", accent: 0, source: .iptv,
                    tagline: "", guideID: "ext.news", guideName: $0.guideName, country: $0.country
                )
            }
            return try LiveTVXMLTVParser().parse(gzipData: data, channels: prototypes, now: from).programs.map {
                .init(id: $0.id, channelID: $0.channelID, title: $0.title, startDate: $0.start, endDate: $0.end)
            }
        }
        let rows = try await provider.liveTVGuide(channelIDs: ["live:10"], from: window.from, to: window.to)
        XCTAssertEqual(rows.map(\.title), ["Gzip Evening"])
    }

    func testPlaylistWithOnlyAnExtraGuideSupportsAGuide() async throws {
        IPTVFixture.state.handler = { request in
            if request.url?.path == "/list.m3u" {
                return (200, [:], Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"a\",Alpha\nhttps://provider.test/a.ts\n".utf8))
            }
            return try Self.handler(extraBody: Data("<tv/>".utf8))(request)
        }
        for extras in [[URL](), [extra]] {
            let credential = try IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list.m3u")),
                discoversPlaylistGuides: false, extraGuideURLs: extras
            )
            let provider = try await makeProvider(credential: credential) { _, _, _, _, _ in [] }
            let availability = try await provider.liveTVAvailability()
            XCTAssertEqual(availability.supportsGuide, !extras.isEmpty)
        }
    }

    // MARK: Support

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(URL, [String])] = []
        func record(url: URL, channels: [String]) { lock.withLock { all.append((url, channels)) } }
        func channels(for url: URL) -> [[String]] { lock.withLock { all.filter { $0.0 == url }.map(\.1) } }
    }

    private static func handler(
        extraBody: Data, also: [URL: Data] = [:]
    ) -> @Sendable (URLRequest) throws -> IPTVFixture.Response {
        { request in
            if request.url?.host == "cdn.test" {
                if let body = also[request.url!] { return (200, [:], body) }
                return (200, [:], request.url?.lastPathComponent.hasPrefix("primary") == true ? Data("<tv>primary</tv>".utf8) : extraBody)
            }
            if request.url?.path == "/prefix/xmltv.php" { return (404, [:], Data()) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let payload: String
            switch items.first(where: { $0.name == "action" })?.value {
            case nil: payload = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]}}"#
            case "get_live_categories", "get_vod_categories", "get_series_categories":
                payload = #"[{"category_id":"1","category_name":"News"}]"#
            case "get_live_streams":
                payload = #"[{"stream_id":10,"name":"News","epg_channel_id":"news","category_id":"1"},{"stream_id":11,"name":"Sports","category_id":"1"},{"stream_id":12,"name":"Movies","category_id":"1"}]"#
            default: payload = "[]"
            }
            return (200, ["Content-Type": "application/json"], Data(payload.utf8))
        }
    }

    private func makeProvider(
        extras: [URL], guideLoader: @escaping IPTVProvider.IPTVGuideLoader
    ) async throws -> IPTVProvider {
        try await makeProvider(
            credential: IPTVCredential(
                mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
                username: "fixture-user", password: "fixture-password", guideURL: primary, extraGuideURLs: extras
            ),
            guideLoader: guideLoader
        )
    }

    private func makeProvider(
        credential: IPTVCredential, guideLoader: @escaping IPTVProvider.IPTVGuideLoader
    ) async throws -> IPTVProvider {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Guide", deviceID: "fixture",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "guide", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "guide", profileID: "viewer", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration(), guideLoader: guideLoader
        )
        addTeardownBlock { await provider.teardown() }
        return provider
    }

    private func credentialIdentity(_ provider: IPTVProvider) async throws -> UUID {
        try IPTVCredential.decode(provider.session.accessToken).identity
    }

    private static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream, Z_BEST_SPEED, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { throw LiveTVSourceImportError.invalidGuide }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: data.count + 1_024)
        let produced: Int = try input.withUnsafeMutableBytes { inBytes in
            try output.withUnsafeMutableBytes { outBytes in
                stream.next_in = inBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_in = uInt(inBytes.count)
                stream.next_out = outBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outBytes.count)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw LiveTVSourceImportError.invalidGuide }
                return outBytes.count - Int(stream.avail_out)
            }
        }
        return Data(output.prefix(produced))
    }
}
