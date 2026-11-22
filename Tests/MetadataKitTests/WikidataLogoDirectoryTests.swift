import Foundation
import XCTest
@testable import MetadataKit

final class WikidataLogoDirectoryTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikidataLogoDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directoryURL) }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var sleeps: [TimeInterval] = []
        private var statuses: [Int]
        private var date = Date(timeIntervalSince1970: 1_794_050_400)
        init(statuses: [Int]) { self.statuses = statuses }
        var allRequests: [URLRequest] { lock.withLock { requests } }
        var allSleeps: [TimeInterval] { lock.withLock { sleeps } }
        func next(_ request: URLRequest) -> Int {
            lock.withLock { requests.append(request); return statuses.isEmpty ? 200 : statuses.removeFirst() }
        }
        func slept(_ value: TimeInterval) { lock.withLock { sleeps.append(value) } }
        var now: Date { lock.withLock { date } }
        func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86_400) } }
    }

    private static let answer = Data(#"""
    {"results":{"bindings":[
     {"item":{"value":"http://www.wikidata.org/entity/Q1"},"itemLabel":{"value":"CTV"},
      "logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/CTV%20logo.svg"},"alts":{"value":"CTV Television Network|CTV Canada"}},
     {"item":{"value":"http://www.wikidata.org/entity/Q2"},"itemLabel":{"value":"Q2"},
      "logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/Nolabel.svg"},"alts":{"value":""}},
     {"item":{"value":"http://www.wikidata.org/entity/Q3"},"itemLabel":{"value":"Evil"},
      "logoFile":{"value":"http://example.com/Special:FilePath/x.svg"},"alts":{"value":""}}
    ]}}
    """#.utf8)

    private func make(_ recorder: Recorder, body: Data = WikidataLogoDirectoryTests.answer) -> WikidataLogoDirectory {
        WikidataLogoDirectory(
            fileURL: directoryURL.appendingPathComponent("d.json"),
            fetch: { request in (body, recorder.next(request)) },
            now: { recorder.now }, sleep: { recorder.slept($0) }
        )
    }

    func testParsesLabelsAliasesAndCommonsFilesAndSkipsTheRest() async {
        let recorder = Recorder(statuses: [200])
        let entries = await make(recorder).channels(country: "CA")
        XCTAssertEqual(entries, [WikidataLogoEntry(qid: "Q1", label: "CTV", altLabels: ["CTV Canada", "CTV Television Network"], file: "CTV logo.svg")])
    }

    func testRequestsSendTheDescriptiveUserAgentAndAskForJSON() async throws {
        let recorder = Recorder(statuses: [200])
        _ = await make(recorder).channels(country: "CA")
        let request = try XCTUnwrap(recorder.allRequests.first)
        XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent")).hasPrefix("Plozz/"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/sparql-results+json")
        XCTAssertEqual(request.url?.host, "query.wikidata.org")
    }

    func testListIsStoredPermanentlyAndRefreshedOnlyAfterThirtyDays() async {
        let recorder = Recorder(statuses: [200, 200])
        let directory = make(recorder)
        _ = await directory.channels(country: "CA")
        _ = await make(recorder).channels(country: "CA")
        XCTAssertEqual(recorder.allRequests.count, 1, "a second launch reads the stored list")
        recorder.advance(days: 31)
        _ = await make(recorder).channels(country: "CA")
        XCTAssertEqual(recorder.allRequests.count, 2)
    }

    func testAFailedRefreshKeepsTheLastGoodList() async {
        let recorder = Recorder(statuses: [200, 500])
        _ = await make(recorder).channels(country: "CA")
        recorder.advance(days: 31)
        let entries = await make(recorder).channels(country: "CA")
        XCTAssertEqual(entries.map(\.qid), ["Q1"])
    }

    func testRateLimitWaitsAMinuteAndRetriesOnce() async {
        let recorder = Recorder(statuses: [429, 200])
        let entries = await make(recorder).channels(country: "CA")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(recorder.allRequests.count, 2)
        XCTAssertTrue(recorder.allSleeps.contains(WikidataLogoDirectory.retryDelay))

        let again = Recorder(statuses: [429, 429, 200])
        let none = await WikidataLogoDirectory(
            fileURL: directoryURL.appendingPathComponent("other.json"),
            fetch: { request in (Self.answer, again.next(request)) }, now: { again.now }, sleep: { _ in }
        ).channels(country: "CA")
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(again.allRequests.count, 2, "a second 429 gives up")
    }

    func testUnsupportedCountriesMakeNoRequest() async {
        let recorder = Recorder(statuses: [])
        let entries = await make(recorder).channels(country: "ZZ")
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(recorder.allRequests.isEmpty)
    }

    func testImageURLsEncodeTheFileNameAndRejectPathTricks() {
        XCTAssertEqual(
            WikidataLogoDirectory.imageURL(file: "CTV logo 2018.svg")?.absoluteString,
            "https://commons.wikimedia.org/wiki/Special:FilePath/CTV%20logo%202018.svg?width=704"
        )
        XCTAssertNil(WikidataLogoDirectory.imageURL(file: "../x.svg"))
        XCTAssertNil(WikidataLogoDirectory.imageURL(file: "a?b.svg"))
    }

    func testTheChannelQueryCoversSubclassesAndFrenchAndEnglishLabels() {
        let query = WikidataLogoDirectory.channelQuery(countryItem: "Q16")
        XCTAssertTrue(query.contains("wdt:P31/wdt:P279* ?type"))
        XCTAssertFalse(WikidataLogoDirectory.channelQuery(countryItem: "Q30").contains("P279"), "the US query is the narrow one")
        XCTAssertTrue(query.contains("rdfs:label|skos:altLabel"))
        XCTAssertTrue(query.contains("LANG(?alt) IN (\"fr\", \"en\")"))
        XCTAssertTrue(query.contains("wikibase:language \"en,fr\""))
        for type in ["Q2001305", "Q1616075", "Q15265344", "Q1254874"] { XCTAssertTrue(query.contains("wd:\(type)"), type) }
    }

    func testCommonsRenditionWidthIsThePanelWidthAndCapped() {
        XCTAssertEqual(WikidataLogoDirectory.renditionWidth, 704)
        XCTAssertEqual(WikidataLogoDirectory.imageURL(file: "A.svg", width: 5_000)?.absoluteString.hasSuffix("?width=1024"), true)
        XCTAssertEqual(WikidataLogoDirectory.imageURL(file: "A.svg", width: 328)?.absoluteString.hasSuffix("?width=328"), true)
    }

    func testLicenceIsReadOnceAndStored() async {
        let recorder = Recorder(statuses: [200])
        let body = Data(#"{"query":{"pages":{"1":{"imageinfo":[{"extmetadata":{"LicenseShortName":{"value":"Public domain"}}}]}}}}"#.utf8)
        let directory = make(recorder, body: body)
        let first = await directory.licence(forFile: "WNBA logo.png")
        let second = await directory.licence(forFile: "WNBA logo.png")
        XCTAssertEqual(first, "Public domain")
        XCTAssertEqual(second, "Public domain")
        XCTAssertEqual(recorder.allRequests.count, 1)
    }
}
