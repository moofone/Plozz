import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVSportsCrestTests: XCTestCase {
    private func entry(_ qid: String, _ label: String, alts: [String] = [], file: String = "x.svg") -> WikidataLogoEntry {
        WikidataLogoEntry(qid: qid, label: label, altLabels: alts, file: file)
    }

    func testTeamMatchesByExactNameAliasAndLeagueAliasTable() {
        let matcher = LiveTVSportsCrestMatcher(league: .nba, entries: [
            entry("Q1", "Seattle Supersonics", alts: ["SuperSonics"]), entry("Q2", "Boston Celtics", alts: ["Celtics"]),
            entry("Q3", "Los Angeles Lakers")
        ])
        XCTAssertEqual(matcher.team(named: "Boston Celtics")?.qid, "Q2")
        XCTAssertEqual(matcher.team(named: "celtics")?.qid, "Q2", "an English alias matches exactly")
        XCTAssertEqual(matcher.team(named: "Boston")?.qid, "Q2", "the league's city alias resolves to the full name")
        XCTAssertEqual(matcher.team(named: "Lakers")?.qid, "Q3")
        XCTAssertNil(matcher.team(named: "Bost"), "no fuzzy matching")
        XCTAssertNil(matcher.team(named: "Chicago"), "a team with no Wikidata logo stays unmatched")
    }

    func testTiesStayUnmatched() {
        let matcher = LiveTVSportsCrestMatcher(league: .mls, entries: [
            entry("Q1", "Austin FC", alts: ["Austin"]), entry("Q2", "Austin Bold", alts: ["Austin"])
        ])
        XCTAssertNil(matcher.team(named: "Austin"))
        XCTAssertEqual(matcher.team(named: "Austin FC")?.qid, "Q1")
    }

    func testLicenceAllowList() {
        for allowed in ["Public domain", "PD-textlogo", "PD-ineligible", "CC0", "CC0 1.0", "CC BY 4.0", "CC BY-SA 3.0", "CC BY-SA 2.5 CA", "CC BY 3.0 DE"] {
            XCTAssertTrue(WikidataLogoDirectory.isAllowed(licence: allowed), allowed)
        }
        for denied in ["", "CC BY-NC 4.0", "CC BY-ND 4.0", "CC BY-NC-SA 3.0", "GFDL", "Fair use", "Copyrighted free use", "All rights reserved"] {
            XCTAssertFalse(WikidataLogoDirectory.isAllowed(licence: denied), denied)
        }
        XCTAssertTrue(WikidataLogoDirectory.requiresCredit(licence: "CC BY-SA 4.0"))
        XCTAssertTrue(WikidataLogoDirectory.requiresCredit(licence: "CC BY 2.0"))
        XCTAssertFalse(WikidataLogoDirectory.requiresCredit(licence: "CC0"))
        XCTAssertFalse(WikidataLogoDirectory.requiresCredit(licence: "Public domain"))
    }

    func testTeamQueryAsksForTeamsOfTheLeagueWithALogo() {
        let query = WikidataLogoDirectory.teamQuery(league: "Q155223")
        XCTAssertTrue(query.contains("wdt:P31/wdt:P279* ?type"))
        XCTAssertTrue(query.contains("wd:Q12973014") && query.contains("wd:Q847017"))
        XCTAssertTrue(query.contains("wdt:P118 wd:Q155223") && query.contains("wdt:P154 ?logo"))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ url: String) { lock.withLock { urls.append(url) } }
        var all: [String] { lock.withLock { urls } }
    }

    private final class Published: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [LiveTVChannelLogoKey: [URL?]] = [:]
        func merge(_ more: [LiveTVChannelLogoKey: [URL?]]) { lock.withLock { value.merge(more) { $0 + $1 } } }
        var all: [LiveTVChannelLogoKey: [URL?]] { lock.withLock { value } }
    }

    func testCrestsAreDrawnOnlyForAllowedLicencesAndAreRequestedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let teams = #"""
        {"results":{"bindings":[
         {"item":{"value":"http://www.wikidata.org/entity/Q1"},"itemLabel":{"value":"Seattle Sounders FC"},"logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/Sounders.svg"},"alts":{"value":""}},
         {"item":{"value":"http://www.wikidata.org/entity/Q2"},"itemLabel":{"value":"Portland Timbers"},"logoFile":{"value":"http://commons.wikimedia.org/wiki/Special:FilePath/Timbers.svg"},"alts":{"value":""}}
        ]}}
        """#
        func licence(_ name: String) -> String {
            #"{"query":{"pages":{"1":{"imageinfo":[{"extmetadata":{"LicenseShortName":{"value":"\#(name)"},"Artist":{"value":"<a href=\"x\">Jane Doe</a>"}}}]}}}}"#
        }
        let wikidata = WikidataLogoDirectory(
            fileURL: directory.appendingPathComponent("wikidata.json"),
            fetch: { request in
                let url = request.url!.absoluteString
                counter.add(url)
                if url.contains("sparql") { return (Data(teams.utf8), 200) }
                return (Data((url.contains("Sounders") ? licence("CC BY-SA 4.0") : licence("Fair use")).utf8), 200)
            },
            now: { Date(timeIntervalSince1970: 1_794_050_400) }, sleep: { _ in })
        let service = LiveTVChannelLogoService(
            store: LiveTVChannelLogoStore(fileURL: directory.appendingPathComponent("store.json")),
            directory: TMDbNetworkDirectory(fileURL: directory.appendingPathComponent("n.json"), fetch: { _ in Data() }, now: { Date(timeIntervalSince1970: 1_794_050_400) }),
            wikidata: wikidata, accessProvider: { .disabled })
        let key = LiveTVChannelLogoKey(sourceID: "s", channelID: "1")
        let event = LiveTVSportsEvent(league: .mls, teams: ["Seattle", "Portland"])
        let published = Published()
        await service.resolveCrests([(key, event), (LiveTVChannelLogoKey(sourceID: "s", channelID: "2"), event)]) { published.merge($0) }
        let crests = try XCTUnwrap(published.all[key])
        XCTAssertEqual(crests.count, 2)
        XCTAssertEqual(crests[0], WikidataLogoDirectory.imageURL(file: "Sounders.svg"))
        XCTAssertNil(crests[1], "a logo whose Commons licence is not allowed is never drawn")
        XCTAssertEqual(counter.all.filter { $0.contains("sparql") }.count, 1, "one team query per league")
        XCTAssertEqual(counter.all.filter { $0.contains("Sounders") }.count, 1, "each file's licence is read once")
        let credit = await wikidata.credit(forFile: "Sounders.svg")
        XCTAssertEqual(credit, "Logo: Sounders.svg by Jane Doe, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Sounders.svg")
        let none = await wikidata.credit(forFile: "Timbers.svg")
        XCTAssertNil(none)
    }

    func testTheSportsDBIsGone() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" || url.pathExtension == "md" || url.pathExtension == "xcstrings" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            if lower.contains("thesportsdb") || lower.contains("plozzlivetvsportsart") || lower.contains("livetvsportsartservice") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
