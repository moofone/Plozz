import Foundation
import XCTest
@testable import MetadataKit

final class TMDbNetworkDirectoryTests: XCTestCase {
    /// Gzip of one JSON object per line: 13 networks including CBC, CTV, Global TV and NBC.
    static let canadianExport = Data(base64Encoded: "H4sIAAAAAAAC/6tWykxRslIwMtZRUMpLzE0FspWcnZwVQlJzUssyizPz85RquaohigwNDZBVhYQhpCyNLExwyRkZGKIajiRlamKBS87EwBiniZYGljjlDJFNdM/JT0rMUUBWYGaOZq6CX2p5sYJzRmJeXmoOQp2FhbEJpkkgtUiWISlwRHa8GZKEH4qPTcyM0OUAHmQrsIQBAAA=")!
    /// Gzip of three networks: Alpha Network, Beta, Alpha.
    static let smallExport = Data(base64Encoded: "H4sIAAAAAAAC/6tWykxRslIw1FFQykvMTQUylRxzCjISFfxSS8rzi7KVarmqIUqMkJQ4pZYkImSM0TUr1QIAH2QVDlcAAAA=")!

    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TMDbNetworkDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private var fileURL: URL { directoryURL.appendingPathComponent("directory.json") }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var all: [URL] { lock.withLock { urls } }
        func record(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86_400) } }
    }

    private let start = Date(timeIntervalSince1970: 1_794_050_400)  // 2026-11-07 11:20 UTC

    func testGzipDecodeParsesEveryNetworkLine() throws {
        let networks = try XCTUnwrap(TMDbNetworkDirectory.parse(compressed: Self.canadianExport))
        XCTAssertEqual(networks.count, 13)
        XCTAssertEqual(networks.first, TMDbNetworkEntry(id: 23, name: "CBC Television"))
        XCTAssertEqual(networks.filter { $0.name == "CTV" }.map(\.id), [110, 9284, 403, 2909])
    }

    func testGzipDecodeRejectsGarbageTruncationAndOversizeOutput() {
        XCTAssertNil(GzipDecoder.inflate(Data("not gzip".utf8), maximumBytes: 1_000))
        XCTAssertNil(GzipDecoder.inflate(Self.canadianExport.prefix(40), maximumBytes: 1_000_000))
        XCTAssertNil(GzipDecoder.inflate(Self.canadianExport, maximumBytes: 10))
    }

    func testExportURLUsesHTTPSAndTheUTCDate() throws {
        let url = try XCTUnwrap(TMDbNetworkDirectory.exportURL(for: Date(timeIntervalSince1970: 1_794_050_400)))
        XCTAssertEqual(url.absoluteString, "https://files.tmdb.org/p/exports/tv_network_ids_11_07_2026.json.gz")
    }

    func testRefreshDownloadsOnceThenWaitsThirtyDays() async throws {
        let requests = Requests()
        let clock = Clock(start)
        let directory = TMDbNetworkDirectory(
            fileURL: fileURL, fetch: { url in requests.record(url); return Self.canadianExport }, now: { clock.now }
        )
        let first = await directory.refreshIfNeeded()
        XCTAssertEqual(first, .refreshed)
        clock.advance(days: 29)
        let second = await directory.refreshIfNeeded()
        XCTAssertEqual(second, .current)
        XCTAssertEqual(requests.all.count, 1)
        clock.advance(days: 2)
        let third = await directory.refreshIfNeeded()
        XCTAssertEqual(third, .refreshed)
        XCTAssertEqual(requests.all.count, 2)
    }

    func testListSurvivesRelaunchWithoutAnotherDownload() async throws {
        let requests = Requests()
        let clock = Clock(start)
        let fetch: TMDbNetworkDirectory.Fetch = { url in requests.record(url); return Self.canadianExport }
        let first = TMDbNetworkDirectory(fileURL: fileURL, fetch: fetch, now: { clock.now })
        _ = await first.refreshIfNeeded()
        let relaunched = TMDbNetworkDirectory(fileURL: fileURL, fetch: fetch, now: { clock.now })
        let outcome = await relaunched.refreshIfNeeded()
        let count = await relaunched.networks().count
        XCTAssertEqual(outcome, .current)
        XCTAssertEqual(count, 13)
        XCTAssertEqual(requests.all.count, 1)
    }

    func testFailedRefreshKeepsTheLastGoodCopy() async throws {
        let clock = Clock(start)
        let succeeds = TMDbNetworkDirectory(
            fileURL: fileURL, fetch: { _ in Self.canadianExport }, now: { clock.now }
        )
        _ = await succeeds.refreshIfNeeded()
        clock.advance(days: 31)
        let failing = TMDbNetworkDirectory(
            fileURL: fileURL, fetch: { _ in throw URLError(.notConnectedToInternet) }, now: { clock.now }
        )
        let outcome = await failing.refreshIfNeeded()
        let networks = await failing.networks()
        let stale = await failing.isStale()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(networks.count, 13)
        XCTAssertTrue(stale)
    }

    func testCorruptDownloadKeepsTheLastGoodCopy() async throws {
        let clock = Clock(start)
        let first = TMDbNetworkDirectory(fileURL: fileURL, fetch: { _ in Self.canadianExport }, now: { clock.now })
        _ = await first.refreshIfNeeded()
        clock.advance(days: 31)
        let second = TMDbNetworkDirectory(fileURL: fileURL, fetch: { _ in Data("<html>".utf8) }, now: { clock.now })
        let outcome = await second.refreshIfNeeded()
        let networks = await second.networks()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(networks.count, 13)
    }

    func testMissingTodayFallsBackToEarlierDaysUpToSeven() async throws {
        let requests = Requests()
        let directory = TMDbNetworkDirectory(fileURL: fileURL, fetch: { url in
            requests.record(url)
            if requests.all.count < 4 { throw MetadataDiscoveryHTTPError.status(403, retryAfter: nil) }
            return Self.smallExport
        }, now: { self.start })
        let outcome = await directory.refreshIfNeeded()
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(requests.all.map { $0.lastPathComponent }, [
            "tv_network_ids_11_07_2026.json.gz", "tv_network_ids_11_06_2026.json.gz",
            "tv_network_ids_11_05_2026.json.gz", "tv_network_ids_11_04_2026.json.gz"
        ])
    }

    func testGivesUpAfterEightMissingDays() async throws {
        let requests = Requests()
        let directory = TMDbNetworkDirectory(fileURL: fileURL, fetch: { url in
            requests.record(url)
            throw MetadataDiscoveryHTTPError.status(404, retryAfter: nil)
        }, now: { self.start })
        let outcome = await directory.refreshIfNeeded()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(requests.all.count, 8)
    }

    func testSearchMatchesEveryWordAndRanksExactThenPrefix() async throws {
        let directory = TMDbNetworkDirectory(fileURL: fileURL, fetch: { _ in Self.smallExport }, now: { self.start })
        let alpha = await directory.search("alpha")
        XCTAssertEqual(alpha.map(\.name), ["Alpha", "Alpha Network"])
        let multi = await directory.search("network alpha")
        XCTAssertEqual(multi.map(\.name), ["Alpha Network"])
        let none = await directory.search("zzz")
        XCTAssertTrue(none.isEmpty)
        let blank = await directory.search("   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testSearchRefreshesAListOlderThanThirtyDays() async throws {
        let requests = Requests()
        let clock = Clock(start)
        let directory = TMDbNetworkDirectory(
            fileURL: fileURL, fetch: { url in requests.record(url); return Self.smallExport }, now: { clock.now }
        )
        _ = await directory.search("beta")
        XCTAssertEqual(requests.all.count, 1)
        clock.advance(days: 10)
        _ = await directory.search("beta")
        XCTAssertEqual(requests.all.count, 1)
        clock.advance(days: 25)
        _ = await directory.search("beta")
        XCTAssertEqual(requests.all.count, 2)
    }

    func testWrittenFileIsNotInTheCachesDirectory() {
        let path = TMDbNetworkDirectory.defaultFileURL().path
        XCTAssertTrue(path.contains("Application Support"), path)
        XCTAssertFalse(path.contains("/Caches/"), path)
    }
}
