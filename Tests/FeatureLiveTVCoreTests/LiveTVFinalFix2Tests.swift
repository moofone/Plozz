import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// Final fix 2: colour logos preferred over black/white ones, the wrong Wikidata brand, and the DEBUG seam line.
@MainActor
final class LiveTVFinalFix2Tests: XCTestCase {
    // MARK: Colour preference

    private let tmdb = URL(string: "https://image.tmdb.org/t/p/original/a.png")!
    private let commons = URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/A.svg")!

    private func candidates() -> [LiveTVLogoCandidate] {
        [LiveTVLogoCandidate(source: .tmdb, url: tmdb, size: .raster(width: 2_000, height: 700)),
         LiveTVLogoCandidate(source: .wikidata, url: commons, size: .vector)]
    }

    func testAColourLogoBeatsAMonochromeOneOfTheSameQuality() {
        let colourCommons = LiveTVLogoQuality.choose(candidates()) { $0 == self.tmdb ? true : false }
        XCTAssertEqual(colourCommons?.source, .wikidata, "TMDB is black/white; Commons is colour")
        let colourTMDB = LiveTVLogoQuality.choose(candidates()) { $0 == self.tmdb ? false : true }
        XCTAssertEqual(colourTMDB?.source, .tmdb)
    }

    func testUnmeasuredLogosKeepSourceOrderAndMonochromeLosesToAnUnmeasuredOne() {
        XCTAssertEqual(LiveTVLogoQuality.choose(candidates())?.source, .tmdb)
        XCTAssertEqual(LiveTVLogoQuality.choose(candidates()) { $0 == self.tmdb ? true : nil }?.source, .wikidata)
        XCTAssertEqual(LiveTVLogoQuality.choose(candidates()) { _ in true }?.source, .tmdb, "both monochrome: source order")
    }

    func testColourNeverOutranksQualityOrAnOverride() {
        let soft = [
            LiveTVLogoCandidate(source: .tmdb, url: tmdb, size: .raster(width: 80, height: 30)),
            LiveTVLogoCandidate(source: .wikidata, url: commons, size: .vector)]
        XCTAssertEqual(LiveTVLogoQuality.choose(soft) { $0 == self.commons ? true : false }?.source, .wikidata, "crisp Wikidata is mono, soft TMDB colour: crisp wins")
        let override = LiveTVLogoCandidate(source: .override, url: tmdb, size: nil)
        XCTAssertEqual(LiveTVLogoQuality.choose(candidates() + [override]) { _ in true }?.source, .override)
    }

    // MARK: Service

    private final class Access: @unchecked Sendable {
        let value: TMDbAccess
        init(_ value: TMDbAccess) { self.value = value }
    }

    private func channel(_ id: String, _ name: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 1, name: name, category: "News", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            playlistSourceID: "server-1")
    }

    func testAMonochromeTMDBLogoGivesWayToAColourCommonsLogo() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let service = LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: tmp.appendingPathComponent("ff2-\(UUID().uuidString).json")),
            directory: .init(fileURL: tmp.appendingPathComponent("n-\(UUID().uuidString).json"), fetch: { _ in Data() }),
            wikidata: .init(fileURL: tmp.appendingPathComponent("w-\(UUID().uuidString).json"), fetch: { _ in (Data(), 500) }),
            accessProvider: { .directToken("test") },
            measureGuideIcon: { _ in nil },
            measureLogoColour: { url in url.host == "image.tmdb.org" })
        let amc = channel("amc", "AMC")
        let identity = LiveTVChannelLogoIdentity(channel: amc)
        service.store.recordNetwork(TMDbNetworkLogo(networkID: 174, name: "AMC", originCountry: "US", filePath: "/amc.png", pixelWidth: 2_000, pixelHeight: 700))
        service.store.recordMatches([identity: .network(id: 174, filePath: "/amc.png")])
        service.store.recordWikidataMatches([identity: .logo(qid: "Q1", file: "AMC logo.svg")])
        XCTAssertEqual(service.displayedLogoURL(for: amc)?.host, "image.tmdb.org", "nothing measured yet: source order")

        let published = PublishedURLs()
        await service.preferColourLogos([LiveTVLogoRequest(channel: amc)]) { await published.add($0) }
        XCTAssertEqual(service.displayedLogoURL(for: amc)?.host, "commons.wikimedia.org")
        let urls = await published.urls
        XCTAssertEqual(urls[LiveTVChannelLogoKey(channel: amc)]?.host, "commons.wikimedia.org")
    }

    private actor PublishedURLs {
        var urls: [LiveTVChannelLogoKey: URL] = [:]
        func add(_ new: [LiveTVChannelLogoKey: URL]) { urls.merge(new) { $1 } }
    }

    // MARK: Wikidata brand

    func testAnAliasThatNamesAnotherBrandsLogoFileIsRejected() {
        let entries = [
            WikidataLogoEntry(qid: "Q4764866", label: "CTV Wild Channel",
                              altLabels: ["Animal Planet", "CTV Wild Channel"], file: "CTV Wild Channel Logo.png"),
            WikidataLogoEntry(qid: "Q1", label: "Adult Swim Canada",
                              altLabels: ["Adult Swim", "Adult Swim Canada"], file: "Adult Swim 2003 logo.svg"),
            WikidataLogoEntry(qid: "Q2", label: "CBC Television", altLabels: ["CBC"], file: "CBC Television.svg")]
        let matcher = LiveTVWikidataLogoMatcher(entries: entries)
        XCTAssertNil(matcher.match(.init(name: "CA: Animal Planet", groups: [], country: "CA"), country: "CA"))
        XCTAssertEqual(matcher.match(.init(name: "CTV Wild Channel", groups: [], country: "CA"), country: "CA")?.qid, "Q4764866")
        XCTAssertEqual(matcher.match(.init(name: "Adult Swim", groups: [], country: "CA"), country: "CA")?.qid, "Q1")
    }

    func testFileBrandRule() {
        XCTAssertTrue(LiveTVWikidataLogoMatcher.fileNamesAnotherBrand(
            file: "CTV Wild Channel Logo.png", label: "CTV Wild Channel", matchedName: "Animal Planet"))
        XCTAssertFalse(LiveTVWikidataLogoMatcher.fileNamesAnotherBrand(
            file: "Animal Planet 2018.svg", label: "CTV Wild Channel", matchedName: "Animal Planet"), "the file names the asked brand")
        XCTAssertFalse(LiveTVWikidataLogoMatcher.fileNamesAnotherBrand(
            file: "CBC Television.svg", label: "CBC Television", matchedName: "CBC"), "the alias is part of the label")
        XCTAssertFalse(LiveTVWikidataLogoMatcher.fileNamesAnotherBrand(
            file: "Whatever.svg", label: "Other Name", matchedName: "Alias"), "a file naming neither is kept")
        XCTAssertFalse(LiveTVWikidataLogoMatcher.fileNamesAnotherBrand(
            file: "CTV Wild Channel Logo.png", label: "CTV Wild Channel", matchedName: "CTV Wild Channel"))
    }

    // MARK: Seam line

    func testTheSeamSummaryIsEmittedOnceWithoutHandoffDiagnostics() async throws {
        let lines = Lines()
        let previous = LiveTVLogoSeamLog.sink
        LiveTVLogoSeamLog.sink = { lines.append($0) }
        defer { LiveTVLogoSeamLog.sink = previous }
        let tmp = FileManager.default.temporaryDirectory
        let service = LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: tmp.appendingPathComponent("ff2s-\(UUID().uuidString).json")),
            directory: .init(fileURL: tmp.appendingPathComponent("n-\(UUID().uuidString).json"), fetch: { _ in Data() }),
            wikidata: .init(fileURL: tmp.appendingPathComponent("w-\(UUID().uuidString).json"), fetch: { _ in (Data(), 500) }),
            accessProvider: { .disabled }, measureGuideIcon: { _ in nil })
        let model = LiveTVPrototypeModel(channels: [channel("a", "Alpha")], logoService: service)
        model.resolveLogos()
        for _ in 0..<200 where lines.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #if DEBUG
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all.first?.hasPrefix("LIVE_TV event=logoSeam ") == true)
        #endif
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.withLock { storage.append(line) } }
        var all: [String] { lock.withLock { storage } }
    }
}
