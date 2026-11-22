import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// The package prefix (`PRIME:` in `CA| PRIME`) and the Canadian parse corpus: real channel names and group labels of a provider's
/// Canadian rows (no URLs, ids or credentials), with every expected value written by hand from the names and the reviewed
/// region corpus (`expected-regions.tsv`), never generated from the parser's output.
@MainActor
final class LiveTVCanadianParseCorpusTests: XCTestCase {
    /// Stations named like a real guide's display names (`Global (CIHF) Dartmouth`); the second name of CIHF is the server's alias.
    private let guide: [String: [String]] = [
        "CIHFDT.ca@SD": ["Global (CIHF) Dartmouth", "Global Maritimes"],
        "GlobalBC.ca": ["Global BC"], "CityTVCalgary.ca": ["Citytv Calgary"], "CityTVEdmonton.ca": ["Citytv Edmonton"],
        "YTV.ca": ["YTV"], "HGTV.ca": ["HGTV Canada"], "TVA.ca": ["TVA"], "RDINews.ca": [], "CTVNC.ca": ["CTV News Channel"],
        "CP24.ca": ["CP24"]
    ]

    private func channel(_ name: String, _ group: String, id: String = "row") -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
    }

    private func station(of channels: [LiveTVPrototypeChannel]) -> [String: String] {
        let assignments = LiveTVGuideMatcher().matching(channels: channels, guideChannels: guide, trustsGuideIDs: true).assignments
        return assignments.mapValues(\.guideChannelID)
    }

    // MARK: Package prefix

    func testPackagePrefixLeavesTheNameAndBecomesATag() {
        let split = IPTVChannelName.split("PRIME: GLOBAL MARITIMES ᴿᴬᵂ", groups: ["CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertEqual(split.name, "GLOBAL MARITIMES")
        XCTAssertEqual(split.tags, [.package("PRIME"), .raw])
        let prefix = IPTVChannelName.packagePrefix(in: "AT&T: 123 GO! ᴿᴬᵂ", groups: ["US| AT&T ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertEqual(prefix?.label, "AT&T")
        XCTAssertEqual(prefix?.rest, "123 GO! ᴿᴬᵂ")
    }

    func testAPrefixThatIsNotTheGroupsOwnWordStaysInTheName() {
        XCTAssertEqual(IPTVChannelName.split("NOW: ALIBI", groups: ["CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]).name, "NOW: ALIBI")
        XCTAssertEqual(IPTVChannelName.split("RK: 48 HOURS ᴿᴬᵂ", groups: ["US| ROKU ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]).name, "RK: 48 HOURS")
        XCTAssertNil(IPTVChannelName.packagePrefix(in: "PRIME: X", groups: []))
        XCTAssertNil(IPTVChannelName.packagePrefix(in: "PRIME:", groups: ["CA| PRIME"]), "nothing after the label")
        XCTAssertNil(IPTVChannelName.packagePrefix(in: "24/7: NCIS", groups: ["US| 24/7 SHOWS"]), "a word starts with a letter")
    }

    func testCountryAndLanguagePrefixesKeepTheirOwnRule() {
        let canadian = IPTVChannelName.split("CA EN: GLOBAL MARITIMES HD", groups: ["CA| NEWS EN"])
        XCTAssertEqual(canadian.name, "GLOBAL MARITIMES")
        XCTAssertEqual(canadian.tags, [.country("CA"), .language("EN"), .hd])
        XCTAssertEqual(canadian.tags, IPTVChannelName.split("CA EN: GLOBAL MARITIMES HD").tags)
        // `FR:` is a country code even where the group's first word is `FR`.
        let french = IPTVChannelName.split("FR: TF1 HD", groups: ["FR| FR HD"])
        XCTAssertEqual(french.name, "TF1")
        XCTAssertEqual(french.tags, [.country("FR"), .hd])
        XCTAssertNil(IPTVChannelName.packagePrefix(in: "EN: NEWS", groups: ["CA| EN NEWS"]), "a language code")
    }

    func testAPackageTagIsNeverABadge() {
        let tags: [IPTVChannelTag] = [.package("PRIME"), .raw]
        XCTAssertEqual(IPTVChannelTag.displayTexts(for: tags, measured: nil), ["RAW"])
        XCTAssertFalse(IPTVChannelTag.displayTexts(for: tags, measured: LiveChannelResolutionLabel(height: 1_080)).contains("PRIME"))
        XCTAssertTrue(IPTVChannelTag.displayTexts(for: tags, measured: LiveChannelResolutionLabel(height: 1_080)).contains("RAW"))
    }

    // MARK: The same station, two rows

    func testBothGlobalMaritimesRowsAreTheSameStationAndIdentity() {
        let hd = channel("CA EN: GLOBAL MARITIMES HD", "CA| NEWS EN", id: "hd")
        let prime = channel("PRIME: GLOBAL MARITIMES ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", id: "prime")
        let stations = station(of: [hd, prime])
        XCTAssertEqual(stations["hd"], "CIHFDT.ca@SD")
        XCTAssertEqual(stations["prime"], "CIHFDT.ca@SD")
        let facts = { (row: LiveTVPrototypeChannel) in LiveTVGuideStationIndex.RowFacts(name: row.name, groups: row.categories) }
        XCTAssertEqual(facts(hd).words, facts(prime).words)
        XCTAssertEqual(LiveTVChannelRegion.region(for: hd), LiveTVChannelRegion.region(for: prime))
        let model = LiveTVPrototypeModel(channels: [hd, prime])
        XCTAssertEqual(model.channel(id: "prime")?.name, model.channel(id: "hd")?.name)
        // The matcher also reads a row the model already cleaned.
        let cleaned = channel(model.channel(id: "prime")?.name ?? "", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", id: "cleaned")
        XCTAssertEqual(station(of: [cleaned])["cleaned"], "CIHFDT.ca@SD")
    }

    func testWithoutAGroupTheMatcherReadsTheRowAsBefore() {
        let facts = LiveTVGuideStationIndex.RowFacts(name: "PRIME: GLOBAL MARITIMES ᴿᴬᵂ")
        XCTAssertEqual(facts.raw, "PRIME: GLOBAL MARITIMES ᴿᴬᵂ")
        let corroborated = LiveTVGuideStationIndex.RowFacts(name: "PRIME: GLOBAL MARITIMES ᴿᴬᵂ", groups: ["CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ"])
        XCTAssertEqual(corroborated.words, ["global", "maritimes"])
    }

    // MARK: Kind

    func testAPackageRowOfAKnownStationIsLinearAndAnyOtherStaysFast() {
        let index = LiveTVGuideStationIndex(guideChannels: guide)
        let group = ["CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]
        XCTAssertEqual(LiveTVChannelKind.classify(name: "PRIME: GLOBAL MARITIMES ᴿᴬᵂ", groups: group, stations: index, country: "CA"), .linear)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "PRIME: HOLLYWOOD SUITE 2000S ᴿᴬᵂ", groups: group, stations: index, country: "CA"), .fast)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "PRIME: GLOBAL MARITIMES ᴿᴬᵂ", groups: group), .fast, "no guide: today's rule")
        XCTAssertEqual(LiveTVChannelKind.classify(name: "AT&T: STINGRAY HITS", groups: []), .fast)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "CA EN: GLOBAL MARITIMES HD", groups: ["CA| NEWS EN"], stations: index, country: "CA"), .linear)
        XCTAssertEqual(
            LiveTVChannelKind.classify(name: "PRIME: HULU ORIGINALS 3 ᴿᴬᵂ", groups: group, stations: index, country: "CA"), .fast, "a shelf stays FAST")
    }

    func testCoverageCountsAKnownPackageStationAsALinearChannel() {
        let rows = [
            channel("CA EN: GLOBAL MARITIMES HD", "CA| NEWS EN", id: "hd"),
            channel("PRIME: GLOBAL MARITIMES ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", id: "prime"),
            channel("PRIME: HOLLYWOOD SUITE 2000S ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", id: "fast")
        ]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: guide)
        XCTAssertEqual(coverage.linear, 2)
        XCTAssertEqual(coverage.matched, 2)
        XCTAssertEqual(coverage.placeholders, 1)
    }

    // MARK: Corpus

    private struct Entry {
        let name: String, group: String, display: String, country: String, language: String, region: String
        let network: String, tags: String, kind: String, station: String, open: Set<String>
    }

    private func corpus() throws -> [Entry] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ca-parse-corpus.tsv")
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map { line in
            var columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            while columns.count < 11 { columns.append("") }
            return Entry(
                name: columns[0], group: columns[1], display: columns[2], country: columns[3], language: columns[4], region: columns[5],
                network: columns[6], tags: columns[7], kind: columns[8], station: columns[9],
                open: Set(columns[10].split(separator: ",").map(String.init)))
        }
    }

    /// Rows whose expected display name or tags are what a viewer should see but the parser does not yet give (a feed mark that is
    /// not the last word: `(R)`, `(CA)`, a glued `HD`). Their other columns are still checked; the open columns are printed.
    func testCanadianCorpusMatchesEveryExpectedValue() throws {
        let entries = try corpus()
        let index = LiveTVGuideStationIndex(guideChannels: guide)
        let networkIDs = Set(LiveTVFilterTagCatalog.tags(in: .network).map(\.id))
        var mismatches: [String] = []
        var openReports: [String] = []
        for (offset, entry) in entries.enumerated() {
            let row = channel(entry.name, entry.group, id: "row\(offset)")
            let named = try XCTUnwrap(LiveTVPrototypeModel(channels: [row]).channel(id: row.id), entry.name)
            var classifier = LiveTVLineupClassifier()
            let country = LiveTVGuideStationIndex.country(of: row, classifier: &classifier) ?? ""
            let region = LiveTVChannelRegion.region(for: row) ?? ""
            let network = LiveTVChannelTagIndex.storedTagIDs(of: named).filter(networkIDs.contains).sorted().joined(separator: " ")
            let kind = LiveTVChannelKind.classify(name: row.name, groups: row.categories, stations: index, country: country).rawValue
            let station = self.station(of: [row])[row.id] ?? ""
            let got: [(String, String, String)] = [
                ("display", entry.display, named.name), ("country", entry.country, country), ("language", entry.language, named.language ?? ""),
                ("region", entry.region, region), ("network", entry.network, network),
                ("tags", entry.tags, named.tags.map(\.badgeText).joined(separator: " ")), ("kind", entry.kind, kind),
                ("station", entry.station, station)
            ]
            for (column, expected, actual) in got where expected != actual {
                let line = "\(entry.name) [\(entry.group)] \(column): expected '\(expected)' got '\(actual)'"
                if entry.open.contains(column) { openReports.append(line) } else { mismatches.append(line) }
            }
        }
        print("CA-PARSE-CORPUS rows=\(entries.count) open (known gaps, not asserted):\n" + openReports.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(entries.count, 30)
        XCTAssertEqual(mismatches.count, 0, "\(mismatches.count) wrong values in \(entries.count) rows\n" + mismatches.joined(separator: "\n"))
    }
}
