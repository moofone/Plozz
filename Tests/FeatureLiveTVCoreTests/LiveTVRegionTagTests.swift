import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// First acceptance test for region parsing: the five real provider rows (snapshot provider-2026-11-17b) containing "halifax".
/// The four Canadian feeds are Halifax; the football event naming FC Halifax Town is not a region.
final class LiveTVRegionTagTests: XCTestCase {
    private func row(_ id: String, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
    }

    func testHalifaxCorpus() {
        let rows: [(channel: LiveTVPrototypeChannel, expected: String?)] = [
            (row("cbc", "CA EN: CBC HALIFAX HD", "CA| KIDS EN"), "Halifax"),
            (row("ctv", "CA EN: CTV HALIFAX", "CA| GENERAL EN"), "Halifax"),
            (row("global", "CA EN: GLOBAL HALIFAX SD", "CA| GENERAL EN"), "Halifax"),
            (row("news", "CA EN: GLOBAL NEWS HALIFAX HD", "CA| NEWS EN"), "Halifax"),
            (row("event", "National League 4 | Kidderminster vs FC Halifax Town // UK Sat 14 Nov 3:00pm // ET Sat 14 Nov 10:00am",
                 "UK| NATIONAL LEAGUE PPV"), nil)
        ]
        for (channel, expected) in rows {
            XCTAssertEqual(LiveTVChannelRegion.region(for: channel), expected, channel.name)
        }
        XCTAssertEqual(rows.compactMap { LiveTVChannelRegion.region(for: $0.channel) }.filter { $0 == "Halifax" }.count, 4)
    }

    func testProviderNamesNameTheirPlaceWhateverTheSpelling() {
        let cases: [(String, String, String?)] = [
            ("CA EN: CBC MONTREALHD", "CA| GENERAL EN", "Montréal"),
            ("CA EN: CBC REGINA(HD)", "CA| GENERAL EN", "Regina"),
            ("CA FR: ICI TELE OTTAWA-GATINEAU HD", "CA| GENERAL FR", "Ottawa-Gatineau"),
            ("CA EN: CTV NEWS CHANNEL", "CA| NEWS EN", nil),
            ("CA EN: CBC NEWS NETWORK", "CA| NEWS EN", nil)
        ]
        for (name, group, expected) in cases {
            XCTAssertEqual(LiveTVChannelRegion.region(for: row(name, name, group)), expected, name)
        }
    }

    // MARK: Corpus

    /// One reviewed row of `Fixtures/expected-regions.tsv` (identified by raw name and group; provider channel numbers are not stable, so none is kept), built independently of the parser (public market and city lists,
    /// every hit read by hand). `expected` holds the canonical places joined by `|`.
    private struct CorpusRow {
        let name: String, group: String, classification: String, expected: String
    }

    private func corpus() throws -> [CorpusRow] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/expected-regions.tsv")
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 6 else { return nil }
            return CorpusRow(name: columns[1], group: columns[2], classification: columns[4], expected: columns[5])
        }
    }

    /// Two reviewed rows put a state after the city ("ALBUQUERQUE NEW MEXICO", "EL PASO TEXAS") while thirteen other rows that
    /// spell the state the same way ("SAN FRANCISCO CALIFORNIA") expect the city alone. The parser follows the thirteen; the owner decides.
    private static let stateAfterCityDisagreements: Set<String> = [
        "US: FOX (KRQEDT2) ALBUQUERQUE NEW MEXICO", "US: SPECTRUM NEWS 1 - EL PASO TEXAS ᴴᴰ"
    ]

    func testReviewedCorpusRegionsAndNonRegionsPassCompletely() throws {
        var checked = 0
        var failures: [String] = []
        for entry in try corpus() where ["REGION", "NOT_REGION", "NO_REGION"].contains(entry.classification) {
            let expected = entry.classification == "REGION" ? entry.expected : ""
            let channel = row(entry.name, entry.name, entry.group)
            let got = LiveTVChannelRegion.places(for: channel).joined(separator: "|")
            checked += 1
            if got != expected, !Self.stateAfterCityDisagreements.contains(entry.name) {
                failures.append("\(entry.classification) \(entry.name) [\(entry.group)] expected '\(expected)' got '\(got)'")
            }
        }
        XCTAssertGreaterThan(checked, 3000)
        XCTAssertEqual(failures.count, 0, "\(failures.count) of \(checked) rows\n" + failures.prefix(60).joined(separator: "\n"))
    }

    func testStateAfterCityDisagreementsAreStillTheOwnersToDecide() throws {
        let rows = try corpus().filter { Self.stateAfterCityDisagreements.contains($0.name) }
        XCTAssertEqual(rows.count, 2)
        for entry in rows {
            XCTAssertNotEqual(LiveTVChannelRegion.places(for: row(entry.name, entry.name, entry.group)).joined(separator: "|"), entry.expected)
        }
    }

    /// Provider misspellings and rows the reviewer could not decide are reported, not asserted: the owner has not decided how they count.
    func testTypoAndAmbiguousCorpusRowsAreReported() throws {
        var summary: [String: (matching: Int, total: Int)] = [:]
        for entry in try corpus() where ["TYPO", "AMBIGUOUS"].contains(entry.classification) {
            let got = LiveTVChannelRegion.places(for: row(entry.name, entry.name, entry.group)).joined(separator: "|")
            var value = summary[entry.classification] ?? (0, 0)
            value.total += 1
            if got == entry.expected { value.matching += 1 }
            summary[entry.classification] = value
        }
        print("REGION-CORPUS typo/ambiguous (parser equals reviewer's place): \(summary)")
        XCTAssertEqual(summary.keys.sorted(), ["AMBIGUOUS", "TYPO"])
    }
}

/// The label under a shared network logo is decided once per lineup by the model.
@MainActor
final class LiveTVRegionLabelModelTests: XCTestCase {
    private func row(_ id: String, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
    }

    func testOnlyRegionalChannelsOfASharedLogoGetTheirPlace() async throws {
        let channels = [
            row("a", "CA EN: CBC CALGARY HD", "CA| GENERAL EN"),
            row("b", "CA EN: CBC HALIFAX HD", "CA| GENERAL EN"),
            row("c", "CA EN: CBC NEWS NETWORK", "CA| NEWS EN"),
            row("d", "CA EN: CTV CALGARY", "CA| GENERAL EN"),
            row("e", "US: ABC (WSET) LYNCHBURG VA", "US| ABC")
        ]
        let model = LiveTVPrototypeModel(channels: channels)
        let override = URL(string: "https://logos.example.test/cbc.png")!
        let other = URL(string: "https://logos.example.test/ctv.png")!
        model.setLogoURLs([
            LiveTVChannelLogoKey(channel: channels[0]): override, LiveTVChannelLogoKey(channel: channels[1]): override,
            LiveTVChannelLogoKey(channel: channels[2]): override, LiveTVChannelLogoKey(channel: channels[3]): other,
            LiveTVChannelLogoKey(channel: channels[4]): other
        ])
        // The counts are computed in the background once the logos settle; a row reads them in O(1).
        for _ in 0..<200 where model.regionLabel(for: channels[0]) == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(model.regionLabel(for: channels[0]), "Calgary")
        XCTAssertEqual(model.regionLabel(for: channels[1]), "Halifax")
        XCTAssertNil(model.regionLabel(for: channels[2]), "a national row has no region")
        XCTAssertEqual(model.regionLabel(for: channels[3]), "Calgary", "shared by two regional rows")
        XCTAssertEqual(model.regionLabel(for: channels[4]), "Lynchburg")
    }

    func testALogoOfOneRegionalChannelAndAChannelWithoutALogoShowNoLabel() {
        let channels = [row("a", "CA EN: CBC CALGARY HD", "CA| GENERAL EN"), row("b", "CA EN: CBC HALIFAX HD", "CA| GENERAL EN")]
        let model = LiveTVPrototypeModel(channels: channels)
        model.setLogoURLs([LiveTVChannelLogoKey(channel: channels[0]): URL(string: "https://logos.example.test/one.png")!])
        XCTAssertNil(model.regionLabel(for: channels[0]), "alone with its logo")
        XCTAssertNil(model.regionLabel(for: channels[1]), "no logo drawn: the name is drawn")
    }
}

/// Region tags for favourite filters: the canonical places of the region parser, offered only when the lineup carries them.
@MainActor
final class LiveTVRegionFilterTagTests: XCTestCase {
    private func row(_ id: String, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
    }

    private func tagID(_ place: String) -> String { LiveTVFilterTagCatalog.regionTagID(place) }

    func testARegionalRowCarriesItsPlaceTagAndNationalRowsCarryNone() {
        let halifax = Set(LiveTVChannelTagIndex.storedTagIDs(of: row("a", "CA EN: CBC HALIFAX HD", "CA| GENERAL EN")))
        XCTAssertTrue(halifax.contains(tagID("Halifax")))
        XCTAssertEqual(halifax.filter { $0.hasPrefix("region-") }.count, 1)
        let national = Set(LiveTVChannelTagIndex.storedTagIDs(of: row("b", "CA EN: CBC NEWS NETWORK", "CA| NEWS EN")))
        XCTAssertTrue(national.filter { $0.hasPrefix("region-") }.isEmpty)
        let both = Set(LiveTVChannelTagIndex.storedTagIDs(of: row("c", "CA FR: ICI TELE OTTAWA-GATINEAU", "CA| GENERAL FR")))
        let places = LiveTVChannelRegion.places(for: row("c", "CA FR: ICI TELE OTTAWA-GATINEAU", "CA| GENERAL FR"))
        XCTAssertFalse(places.isEmpty)
        XCTAssertTrue(both.isSuperset(of: places.map(tagID)), "one tag per place of the row")
    }

    func testEventsAndShowLoopsCarryNoRegionTag() {
        let event = Set(LiveTVChannelTagIndex.storedTagIDs(of: row("d", "US: NHL 01: Calgary Flames vs Halifax Mooseheads", "US| NHL")))
        XCTAssertTrue(event.filter { $0.hasPrefix("region-") }.isEmpty)
    }

    private func regionTitles(_ model: LiveTVPrototypeModel, selected: [String] = []) -> [String: Int] {
        let section = model.filterTagSections(selectedTagIDs: selected).first { $0.id == LiveTVFilterTag.Section.region.rawValue }
        return Dictionary(uniqueKeysWithValues: (section?.tags ?? []).map { ($0.tag.title, $0.count) })
    }

    private var northAmericaModel: LiveTVPrototypeModel {
        LiveTVPrototypeModel(channels: [
            row("a", "CA EN: CBC HALIFAX HD", "CA| GENERAL EN"), row("b", "CA EN: CTV HALIFAX", "CA| GENERAL EN"),
            row("c", "CA EN: CBC CALGARY HD", "CA| GENERAL EN"), row("d", "CA EN: CBC NEWS NETWORK", "CA| NEWS EN"),
            row("e", "CA EN: CTV MONCTON", "CA| GENERAL EN"),
            row("f", "US EN: ABC ABILENE HD", "US| GENERAL EN"), row("g", "US EN: NBC AKRON", "US| GENERAL EN")
        ])
    }

    func testNoRegionSectionUntilACountryIsPicked() {
        XCTAssertTrue(regionTitles(northAmericaModel).isEmpty)
        XCTAssertTrue(regionTitles(northAmericaModel, selected: ["news", "sports"]).isEmpty, "non-country tags do not open it")
    }

    func testRegionsFollowThePickedCountries() {
        let model = northAmericaModel
        let canada = regionTitles(model, selected: ["canada"])
        XCTAssertEqual(canada["Halifax"], 2)
        XCTAssertEqual(canada["Calgary"], 1)
        XCTAssertNotNil(canada["Moncton"])
        XCTAssertNil(canada["Abilene"])
        XCTAssertNil(canada["Akron"])
        let us = regionTitles(model, selected: ["united-states"])
        XCTAssertNotNil(us["Abilene"])
        XCTAssertNotNil(us["Akron"])
        XCTAssertNil(us["Calgary"])
        XCTAssertNil(us["Halifax"])
        XCTAssertNil(us["Toronto"], "no channel of the lineup carries it")
        let both = regionTitles(model, selected: ["canada", "united-states"])
        XCTAssertEqual(Set(both.keys), ["Halifax", "Calgary", "Moncton", "Abilene", "Akron"])
    }

    func testASelectedRegionStaysOfferedWhenItsCountryIsNotPicked() {
        let model = northAmericaModel
        let kept = regionTitles(model, selected: ["united-states", LiveTVFilterTagCatalog.regionTagID("Halifax")])
        XCTAssertNotNil(kept["Halifax"], "a picked region is never dropped")
        XCTAssertNil(kept["Calgary"])
        XCTAssertNotNil(kept["Abilene"])
        XCTAssertEqual(Set(regionTitles(model, selected: [LiveTVFilterTagCatalog.regionTagID("Halifax")]).keys), ["Halifax"],
                       "with no country only the picked region shows")
        XCTAssertEqual(regionTitles(model, selected: [LiveTVFilterTagCatalog.regionTagID("Toronto")])["Toronto"], 0,
                       "even a region the lineup no longer carries")
    }

    func testRegionScopeIsPureOverTheCarriedPlaces() {
        let carried = ["Calgary", "Abilene", "Halifax"].map { LiveTVFilterTagCatalog.regionTagID($0) }
            .compactMap(LiveTVFilterTagCatalog.tag(id:))
        let carriedByCountry = ["canada": Set([LiveTVFilterTagCatalog.regionTagID("Calgary"), LiveTVFilterTagCatalog.regionTagID("Halifax")]),
                                "united-states": Set([LiveTVFilterTagCatalog.regionTagID("Abilene")])]
        func offered(_ selected: [String]) -> [String] {
            LiveTVRegionTagScope.offeredRegionTags(carriedRegionTags: carried, selectedTagIDs: selected) { carriedByCountry[$0] ?? [] }.map(\.title)
        }
        XCTAssertEqual(offered([]), [])
        XCTAssertEqual(Set(offered(["canada"])), ["Calgary", "Halifax"])
        XCTAssertEqual(offered(["united-states"]), ["Abilene"])
        XCTAssertEqual(Set(offered(["canada", "united-states"])), ["Calgary", "Halifax", "Abilene"])
    }

    func testCatalogHasNoDuplicateRegionIDsAndKeepsEarlierTagsFirst() {
        let regional = LiveTVFilterTagCatalog.tags(in: .region)
        XCTAssertGreaterThan(regional.count, 900)
        XCTAssertEqual(Set(regional.map(\.id)).count, regional.count)
        XCTAssertEqual(LiveTVFilterTagCatalog.all.prefix(while: { $0.section != .region }).count, LiveTVFilterTagCatalog.all.firstIndex { $0.section == .region })
        XCTAssertEqual(LiveTVFilterTagCatalog.tag(id: "united-kingdom")?.section, .countryRegion)
    }

    /// Reported per country (the corpus' own country column): rows that carry a region tag and distinct place tags.
    func testReportsRegionTagCountsPerCountryOverTheCorpus() throws {
        var rows: [String: Int] = [:], places: [String: Set<String>] = [:], total: [String: Int] = [:]
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/expected-regions.tsv")
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 6 else { continue }
            let tags = LiveTVChannelTagIndex.storedTagIDs(of: row(columns[1], columns[1], columns[2])).filter { $0.hasPrefix("region-") }
            total[columns[0], default: 0] += 1
            if !tags.isEmpty { rows[columns[0], default: 0] += 1; places[columns[0], default: []].formUnion(tags) }
        }
        let report = total.keys.sorted().map { "\($0): \(rows[$0] ?? 0)/\(total[$0] ?? 0) rows tagged, \(places[$0]?.count ?? 0) distinct places" }
        print("REGION-TAG-COUNTS \(report.joined(separator: "; "))")
        XCTAssertFalse(total.isEmpty)
        XCTAssertGreaterThan(rows.values.reduce(0, +), 1500)
    }
}
