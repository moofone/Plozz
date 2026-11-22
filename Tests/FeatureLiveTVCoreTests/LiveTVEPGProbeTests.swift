import CoreModels
import CoreNetworking
import Foundation
import Synchronization
import XCTest
@testable import FeatureLiveTVCore

/// The DEBUG probe's sampling rule and pacing, and the DEBUG station dump on the import path the app takes.
final class LiveTVEPGProbeTests: XCTestCase {
    private func row(_ id: String, _ name: String, country: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: "Live TV", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: nil, country: country)
    }

    func testSampleSpreadsOverCountriesAndNameStylesAndSkipsOtherCountries() {
        var rows: [LiveTVPrototypeChannel] = []
        for index in 0..<30 { rows.append(row("us-local-\(index)", "US: KABC\(index) ABC", country: "US")) }
        for index in 0..<30 { rows.append(row("ca-other-\(index)", "CA: Channel \(index)", country: "CA")) }
        rows.append(row("gb-1", "UK: Sky Sports Main Event", country: "GB"))
        rows.append(row("gb-2", "UK: HBO West", country: "GB"))
        rows.append(row("de-1", "DE: Das Erste", country: "DE"))
        let picked = LiveTVEPGProbe.sample(unguided: rows, count: 6)
        XCTAssertEqual(picked.count, 6)
        XCTAssertFalse(picked.contains { $0.channel.id == "de-1" }, "only CA, US and GB rows are sampled")
        XCTAssertEqual(Set(picked.map(\.country)), ["CA", "US", "GB"])
        XCTAssertTrue(picked.contains { $0.channel.id == "gb-1" } && picked.contains { $0.channel.id == "gb-2" },
                      "small buckets (regional sports, west feed) are not crowded out by large ones")
        XCTAssertEqual(LiveTVEPGProbe.sample(unguided: rows, count: 6), picked, "the same lineup gives the same sample")
        XCTAssertEqual(LiveTVEPGProbe.sample(unguided: rows, count: 500).count, 62, "never more than the eligible rows")
    }

    func testNameStyles() {
        XCTAssertEqual(LiveTVEPGProbe.style(ofName: "US: WNBC NBC 4 New York"), .callSign)
        XCTAssertEqual(LiveTVEPGProbe.style(ofName: "CA: TSN 1"), .regionalSports)
        XCTAssertEqual(LiveTVEPGProbe.style(ofName: "US: Bally Sports West"), .westFeed)
        XCTAssertEqual(LiveTVEPGProbe.style(ofName: "US: HBO 2"), .premium)
        XCTAssertEqual(LiveTVEPGProbe.style(ofName: "US: Food Network"), .other)
    }

    private func probeRows(_ count: Int) -> [LiveTVEPGProbe.Row] {
        (0..<count).map { LiveTVEPGProbe.Row(channel: row("r\($0)", "US: Row \($0)", country: "US"), country: "US", style: .other) }
    }

    func testProbeIsSequentialPacedAndSummarisesPerCountry() async {
        let pauses = Mutex<[Duration]>([])
        let asked = Mutex<[String]>([])
        let lines = await LiveTVEPGProbe.probe(
            rows: probeRows(3), nativeID: { $0.id }, unguidedCount: 9,
            request: { id in
                asked.withLock { $0.append(id) }
                switch id {
                case "r0": return LiveTVEPGProbeResult(channelID: id, listingCount: 2, epgID: "Known.us", statusClass: 2, elapsedMilliseconds: 40)
                case "r1": return LiveTVEPGProbeResult(channelID: id, listingCount: 0, epgID: "Missing.us", statusClass: 2, elapsedMilliseconds: 41)
                default: return LiveTVEPGProbeResult(channelID: id, listingCount: 0, epgID: nil, statusClass: 2, elapsedMilliseconds: 42)
                }
            },
            isInXMLTV: { $0 == "known.us" }, pause: { duration in pauses.withLock { $0.append(duration) } }, log: { _ in })
        XCTAssertEqual(asked.withLock { $0 }, ["r0", "r1", "r2"])
        XCTAssertEqual(pauses.withLock { $0 }, [.milliseconds(250), .milliseconds(250)], "a pause before every request but the first")
        XCTAssertTrue(lines.contains { $0.contains("row=US: Row 0") && $0.contains("httpStatus=2xx") && $0.contains("ms=40") && $0.contains("epgID=presentInXMLTV") })
        XCTAssertTrue(lines.contains { $0.contains("row=US: Row 1") && $0.contains("epgID=absentFromXMLTV") })
        XCTAssertTrue(lines.contains("EPG_PROBE summary country=US sampled=3 withListings=1 epgIdPresentInXMLTV=1 epgIdAbsent=1 noEpgId=1"))
        XCTAssertTrue(lines.contains("EPG_PROBE summary country=CA sampled=0 withListings=0 epgIdPresentInXMLTV=0 epgIdAbsent=0 noEpgId=0"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("EPG_PROBE summary unguidedRows=9 sampled=3 answered=3 withListings=1") })
    }

    func testProbeStopsAfterFiveConsecutiveFailures() async {
        let asked = Mutex(0)
        let lines = await LiveTVEPGProbe.probe(
            rows: probeRows(20), nativeID: { $0.id }, unguidedCount: 20,
            request: { id in
                asked.withLock { $0 += 1 }
                return LiveTVEPGProbeResult(channelID: id, outcome: .failed, statusClass: 5, elapsedMilliseconds: 3)
            },
            isInXMLTV: { _ in nil }, pause: { _ in }, log: { _ in })
        XCTAssertEqual(asked.withLock { $0 }, 5)
        XCTAssertTrue(lines.contains { $0.contains("stoppedEarly=true") && $0.contains("answered=0") })
    }

    func testProbeNeverLogsAnythingButTheRowNameAndCounts() async {
        let lines = await LiveTVEPGProbe.probe(
            rows: probeRows(1), nativeID: { _ in "stream-12345" }, unguidedCount: 1,
            request: { LiveTVEPGProbeResult(channelID: $0, listingCount: 1, epgID: "x", statusClass: 2, elapsedMilliseconds: 1) },
            isInXMLTV: { _ in true }, pause: { _ in }, log: { _ in })
        XCTAssertFalse(lines.contains { $0.contains("stream-12345") || $0.contains("http://") || $0.contains("https://") })
    }
}

/// `guide-stations.jsonl` is written by the import path the app takes (`LiveTVGuideIndex` → `LiveTVIndexedCache.importGuide`),
/// even when a saved guide with the same content already exists and the launch asked for a forced re-import.
final class LiveTVStationDumpImportPathTests: XCTestCase {
    private let url = URL(string: "https://fixture.test/guide.xml")!
    private let now = Date(timeIntervalSince1970: 100)
    private var range: DateInterval { DateInterval(start: now, duration: 400) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stations-\(UUID().uuidString)")
        LiveTVGuideSnapshotWriter.testingArguments = ["Plozz", "-PlozzLiveTVMetadataAudit", "YES", "-PlozzLiveTVForceGuideReimport", "YES"]
        LiveTVGuideSnapshotWriter.testingDirectory = directory
        LiveTVGuideSnapshotWriter.resetStationDumpForTesting()
    }

    override func tearDown() {
        LiveTVGuideSnapshotWriter.testingArguments = nil
        LiveTVGuideSnapshotWriter.testingDirectory = nil
        LiveTVGuideSnapshotWriter.resetStationDumpForTesting()
        try? FileManager.default.removeItem(at: directory)
    }

    private func channel(_ id: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: "News", category: "Live TV", symbol: "tv", accent: 0, source: .iptv, tagline: "", guideID: "news")
    }

    private var document: XMLTVDownloadedDocument {
        .init(data: Data("""
        <tv><channel id="news"><display-name>News</display-name></channel>
        <channel id="quiet"><display-name>Quiet</display-name></channel>
        <programme channel="news" start="19700101000140 +0000" stop="19700101000820 +0000"><title>Bulletin</title></programme>
        <programme channel="news" start="19700101000900 +0000" stop="19700101001000 +0000"><title>Later</title></programme>
        <programme channel="ghost" start="19700101000140 +0000" stop="19700101000820 +0000"><title>Orphan</title></programme></tv>
        """.utf8), expiresAt: .distantFuture, permitsPersistence: true)
    }

    func testForcedReimportReadsAnUnchangedSavedGuideAndWritesEveryStation() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        LiveTVGuideSnapshotWriter.testingArguments = ["Plozz"]   // first import, no dump asked for
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { self.document }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("guide-stations.jsonl").path))

        LiveTVGuideSnapshotWriter.testingArguments = ["Plozz", "-PlozzLiveTVMetadataAudit", "-PlozzLiveTVForceGuideReimport"]
        XCTAssertTrue(LiveTVGuideSnapshotWriter.stationDumpOwed())
        let saved = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertNil(saved, "the saved guide must not answer while the station dump is owed")
        let downloads = Mutex(0)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
            downloads.withLock { $0 += 1 }
            return self.document   // the same content: normally "unchanged", no parse
        }
        XCTAssertEqual(downloads.withLock { $0 }, 1)
        XCTAssertFalse(LiveTVGuideSnapshotWriter.stationDumpOwed(), "owed only until the file is written")

        let text = try String(contentsOf: directory.appendingPathComponent("guide-stations.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "two declared stations and one undeclared id")
        XCTAssertTrue(lines.contains { $0.contains("\"id\":\"news\"") && $0.contains("\"programmes\":2") && $0.contains("\"declared\":true") })
        XCTAssertTrue(lines.contains { $0.contains("\"id\":\"quiet\"") && $0.contains("\"programmes\":0") })
        XCTAssertTrue(lines.contains { $0.contains("\"id\":\"ghost\"") && $0.contains("\"declared\":false") })
        XCTAssertFalse(text.contains("http"), "no icons or URLs")
    }
}
