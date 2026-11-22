import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// The guide works the same for every kept country: matching by tvg-id, then by name and country, and the 24/7 loops that never
/// have a guide. Names are as a real provider list writes them (`US| 24/7 COMEDY`, `UK: 24/7 30 ROCK 4K`, `NOW: ALIBI`); the CA loops
/// follow the same pattern with a `CA| 24/7` group, as this list has none of its own.
@MainActor
final class LiveTVGuideAllCountriesTests: XCTestCase {
    private func channel(
        _ id: String, _ name: String, group: String, guideID: String? = nil, country: String? = nil
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: guideID, country: country, groups: [group])
    }

    // MARK: Station index

    private let stations: [String: [String]] = [
        "AMC.us": ["AMC"], "AMC.us2": [], "AMC.ca": ["AMC Canada"], "BBC2.uk": ["BBC Two"], "BBCAmerica.us": ["BBC America"],
        "CTVToronto.ca": ["CTV Toronto"], "Alibi.uk": ["Alibi"], "ESPN.us": ["ESPN"], "ESPN.br": ["ESPN Brasil"],
        "Dave.uk": ["Dave"], "Dave": []
    ]

    func testRowsAreReadByNameAndTheirOwnCountry() {
        let index = LiveTVGuideStationIndex(guideChannels: stations)
        XCTAssertEqual(index.resolve(name: "US: AMC HD", country: "US"), "AMC.us", "the plain id wins over AMC.us2")
        XCTAssertEqual(index.resolve(name: "CA EN: AMC HD", country: "CA"), "AMC.ca")
        XCTAssertEqual(index.resolve(name: "UK: BBC Two HD", country: "GB"), "BBC2.uk", "UK is the .uk suffix and the display name")
        XCTAssertEqual(index.resolve(name: "NOW: ALIBI ᴴᴰ", country: "GB"), "Alibi.uk")
        XCTAssertEqual(index.resolve(name: "US| BBC America 4K", country: "US"), "BBCAmerica.us")
        XCTAssertEqual(index.resolve(name: "CA EN: CTV TORONTO HD", country: "CA"), "CTVToronto.ca")
    }

    func testARowNeverTakesAStationOfAnotherCountry() {
        let index = LiveTVGuideStationIndex(guideChannels: stations)
        XCTAssertEqual(index.resolution(name: "CA EN: BBC AMERICA", country: "CA")?.method, .foreignFeed,
                       "Canada shares US feeds, in English: the one sanctioned exception")
        XCTAssertNil(index.resolve(name: "CA FR: BBC AMERICA", country: "CA"), "the US feed is not French")
        XCTAssertNil(index.resolve(name: "US: CTV TORONTO", country: "US"))
        XCTAssertNil(index.resolve(name: "UK: ESPN", country: "GB"), "ESPN.us and ESPN.br are not UK stations")
        XCTAssertEqual(index.resolve(name: "US: ESPN", country: "US"), "ESPN.us")
    }

    func testARowWithoutACountryNeedsAnUnambiguousStation() {
        let index = LiveTVGuideStationIndex(guideChannels: stations)
        XCTAssertNil(index.resolve(name: "ESPN", country: nil), "US and Brazil both claim it")
        XCTAssertEqual(index.resolve(name: "BBC America", country: nil), "BBCAmerica.us")
        XCTAssertEqual(index.resolve(name: "Dave", country: "GB"), "Dave.uk", "a station with no suffix is a candidate for any country")
        XCTAssertNil(index.resolve(name: "Nothing On Here", country: "US"))
    }

    // MARK: Matcher

    func testTrustedMatchingGivesRowsWithoutAGuideIDTheirStationByNameAndCountry() {
        let us = channel("us", "US: AMC HD", group: "US| ENTERTAINMENT")
        let uk = channel("uk", "NOW: ALIBI ᴴᴰ", group: "UK| NOW TV ENTERTAINMENT ᴴᴰ/ᴿᴬᵂ")
        let ca = channel("ca", "CA EN: CTV TORONTO HD", group: "CA| CANADA")
        let own = channel("own", "UK: BBC Two HD", group: "UK| ENTERTAINMENT", guideID: "BBC2.uk")
        let staleID = channel("stale", "US: ESPN", group: "US| SPORTS", guideID: "ESPN.removed")
        let none = channel("none", "US: Some Local Channel", group: "US| LOCAL")
        let result = LiveTVGuideMatcher().matching(
            channels: [us, uk, ca, own, staleID, none], guideChannels: stations, trustsGuideIDs: true)
        XCTAssertEqual(result.assignments["us"]?.guideChannelID, "AMC.us")
        XCTAssertEqual(result.assignments["uk"]?.guideChannelID, "Alibi.uk")
        XCTAssertEqual(result.assignments["ca"]?.guideChannelID, "CTVToronto.ca")
        XCTAssertEqual(result.assignments["own"]?.guideChannelID, "BBC2.uk")
        XCTAssertEqual(result.assignments["own"]?.method, .exactID, "a tvg-id that names a station is read first")
        XCTAssertEqual(result.assignments["stale"]?.guideChannelID, "ESPN.us", "a tvg-id with no station falls back to the name")
        XCTAssertEqual(result.assignments["stale"]?.method, .displayName)
        XCTAssertNil(result.assignments["none"])
    }

    func testAnOverrideStillWinsOverTheNameRule() {
        let row = channel("us", "US: AMC HD", group: "US| ENTERTAINMENT")
        let result = LiveTVGuideMatcher().matching(
            channels: [row], guideChannels: stations, overrides: ["us": "ESPN.us"], trustsGuideIDs: true)
        XCTAssertEqual(result.assignments["us"]?.guideChannelID, "ESPN.us")
        XCTAssertEqual(result.assignments["us"]?.method, .userConfirmed)
    }

    // MARK: 24/7 loops

    func testLoopTitlesReadTheShowForEveryCountry() {
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "24/7: 30 ROCK", groups: ["US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]), "30 ROCK")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "24/7: A TOUCH OF CLOTH", groups: ["US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]), "A TOUCH OF CLOTH")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "UK: 24/7 30 ROCK 4K", groups: ["UK| 24/7 ᴴᴰ/ᴿᴬᵂ"]), "30 ROCK")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "UK: 24/7 24/7 LAW AND ORDER 4K", groups: ["UK| 24/7 ᴴᴰ/ᴿᴬᵂ"]), "LAW AND ORDER")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "CA EN: 24/7 SEINFELD HD", groups: ["CA| 24/7 COMEDY"]), "SEINFELD")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "24/7: 24", groups: ["US| 24/7 ACTION/ADVENTURE ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]), "24")
    }

    func testASectionHeaderIsNotALoop() {
        let group = "US| 24/7 ACTION/ADVENTURE ᴿᴬᵂ ⁶⁰ᶠᵖˢ"
        let header = "## 24/7 ACTION/ADVENTURE ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##"
        XCTAssertNil(LiveTVChannelKind.showLoopTitle(name: header, groups: [group]))
        XCTAssertEqual(LiveTVChannelKind.classify(name: header, groups: [group]), .sectionMarker)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "24/7: 24", groups: [group]), .showLoop)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "## DISNEY+ ORIGINAL ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", groups: ["US| DISNEY+ NETWORK ᴿᴬᵂ ⁶⁰ᶠᵖˢ"]),
                       .sectionMarker, "a header that opens with its group's own word labels the run")
        XCTAssertEqual(LiveTVChannelKind.classify(name: "## UK|BBC One H D ##", groups: ["UK| ENTERTAINMENT"]), .linear,
                       "a decorated name that carries its own country tag is a channel (rule C)")
    }

    func testEveryCountryLoopShowsOneCellTitledWithItsShow() throws {
        let rows = [
            channel("us", "24/7: 30 ROCK", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            channel("uk", "UK: 24/7 30 ROCK 4K", group: "UK| 24/7 ᴴᴰ/ᴿᴬᵂ"),
            channel("ca", "CA EN: 24/7 SEINFELD HD", group: "CA| 24/7 COMEDY"),
            channel("plain", "US: ESPN", group: "US| SPORTS")
        ]
        let model = LiveTVPrototypeModel(channels: rows)
        let now = model.now
        for (id, title) in [("us", "30 ROCK"), ("uk", "30 ROCK"), ("ca", "SEINFELD")] {
            let programs = model.programs(for: id, from: now.addingTimeInterval(-3_600), hours: 6)
            XCTAssertEqual(programs.count, 1, id)
            let cell = try XCTUnwrap(programs.first)
            XCTAssertEqual(cell.title, title, id)
            XCTAssertTrue(cell.isContinuousLoop, id)
            XCTAssertLessThanOrEqual(cell.start, now.addingTimeInterval(-3_600), "the cell spans the whole window: \(id)")
            XCTAssertGreaterThanOrEqual(cell.end, now.addingTimeInterval(5 * 3_600), id)
            XCTAssertEqual(model.currentProgram(for: id)?.title, title, "the hero reads the show as on now: \(id)")
        }
        XCTAssertFalse(model.programs(for: "plain", from: now, hours: 3).contains { $0.isContinuousLoop })
        XCTAssertTrue(LiveTVPrototypeProgram.loopTag == "24/7")
    }

    func testALoopWatchesAndCountsAsHavingAGuide() {
        let model = LiveTVPrototypeModel(channels: [channel("us", "24/7: 30 ROCK", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ")])
        model.tune("us")
        XCTAssertEqual(model.playingChannelID, "us")
        model.guideOnly = true
        XCTAssertEqual(model.visibleChannels.map(\.id), ["us"], "a loop is not hidden by the Guide filter")
    }

    func testASectionHeaderIsNeverACatalogChannelOrALoopCell() {
        let model = LiveTVPrototypeModel(channels: [
            channel("header", "## 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            channel("show", "24/7: 30 ROCK", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ")
        ])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["show"])
    }

    // MARK: Prefixes

    func testSurinameIsACountryAndMonacoRadioIsNot() {
        var classifier = LiveTVLineupClassifier()
        let suriname = ServerLiveTVChannel(id: "1", name: "SU: PREMIUM+ AAN DE POORT BIJ 4K", groups: ["SU| SURINAME 4K"])
        XCTAssertEqual(classifier.placement(of: suriname), .country("SR"))
        let radio = ServerLiveTVChannel(id: "2", name: "MC: 2000S R&B", groups: ["MC| RADIO LIVE"])
        if case .country(let code) = classifier.placement(of: radio) { XCTFail("MC| RADIO LIVE is a package, not \(code)") }
        let serbia = ServerLiveTVChannel(id: "3", name: "SR: AGRO TV", groups: [])
        XCTAssertEqual(classifier.placement(of: serbia), .country("RS"), "the SR name prefix stays Serbia")
    }

    // MARK: Coverage

    func testCoverageCountsLinearRowsByCountryAndKeepsLoopsAndHeadersApart() {
        let rows = [
            channel("us1", "US: AMC HD", group: "US| ENTERTAINMENT"),
            channel("us2", "US: Unknown Local", group: "US| LOCAL"),
            channel("uk1", "NOW: ALIBI ᴴᴰ", group: "UK| NOW TV ENTERTAINMENT ᴴᴰ/ᴿᴬᵂ"),
            channel("ca1", "CA EN: CTV TORONTO HD", group: "CA| CANADA"),
            channel("loop", "24/7: 30 ROCK", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            channel("header", "## 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ")
        ]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: stations, stationsWithListings: ["AMC.us", "Alibi.uk"])
        XCTAssertEqual(coverage.kept, 5, "the header is not a channel")
        XCTAssertEqual(coverage.linear, 4)
        XCTAssertEqual(coverage.matched, 2, "CTV Toronto has a station but no listings in the window")
        XCTAssertEqual(coverage.loops, 1)
        XCTAssertEqual(coverage.byCountry["US"], .init(matched: 1, total: 2))
        XCTAssertEqual(coverage.byCountry["GB"], .init(matched: 1, total: 1))
        XCTAssertEqual(coverage.byCountry["CA"], .init(matched: 0, total: 1))
        XCTAssertEqual(
            coverage.logLine,
            "LIVE_TV event=guideCoverage kept=5 linear=4 matched=2 byCountry=CA:0/1,US:1/2,GB:1/1 loops=1 placeholders=0 radio=0 replay=0 foreign=0 sources=id:0,id-case:0,name:2,name-foreign-feed:0 channels=2/4 channelsByCountry=CA:0/1,US:1/2,GB:1/1")
    }

    /// Skipped unless `PLOZZ_COVERAGE_CHANNELS` (the lineup snapshot's `channels.jsonl`) and `PLOZZ_COVERAGE_STATIONS` (one XMLTV
    /// station id per line) are set; the report goes to `PLOZZ_COVERAGE_REPORT`. Names only: nothing here reads a URL.
    func testRealListCoverageReport() throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard let channelsPath = value("PLOZZ_COVERAGE_CHANNELS"), let stationsPath = value("PLOZZ_COVERAGE_STATIONS") else {
            throw XCTSkip("Set PLOZZ_COVERAGE_CHANNELS and PLOZZ_COVERAGE_STATIONS to measure a real list.")
        }
        var rows: [LiveTVPrototypeChannel] = []
        for line in try String(contentsOfFile: channelsPath, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["stableID"] as? String, let name = object["name"] as? String else { continue }
            let groups = object["groups"] as? [String] ?? []
            rows.append(LiveTVPrototypeChannel(
                id: id, number: 0, name: name, category: groups.first ?? "", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                guideID: object["epgID"] as? String, groups: groups))
        }
        var stations: [String: [String]] = [:]
        for id in try String(contentsOfFile: stationsPath, encoding: .utf8).split(separator: "\n") { stations[String(id)] = [] }
        let allRows = LiveTVLineupFilter.apply(
            LiveTVLineup(placeIDs: [], includesAdult: true, keepsLiveEvents: false), to: rows)
        let cut = LiveTVLineupFilter.apply(.standard, to: rows)
        let kept = cut.kept
        let coverage = LiveTVGuideCoverage.measure(channels: kept, stations: stations)
        var report = [coverage.logLine, "placeholdersDroppedAtCut\t\(cut.summary.placeholders)\tread\t\(rows.count)\tkept\t\(kept.count)",
                      "placeholdersWholeList\t\(allRows.summary.placeholders)"]
        var classifier = LiveTVLineupClassifier()
        for channel in coverage.unmatched {
            guard case .country(let code) = classifier.placement(of: channel), code == "US" || code == "GB" else { continue }
            report.append("unmatched\t\(code)\t\(channel.name)\t\(channel.guideID ?? "-")")
        }
        if let out = value("PLOZZ_COVERAGE_REPORT") { try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertGreaterThan(coverage.linear, 0)
    }

    // MARK: Placeholders

    private func serverRow(_ id: String, _ name: String, group: String) -> ServerLiveTVChannel {
        ServerLiveTVChannel(id: id, name: name, groups: [group])
    }

    func testPlaceholdersAreDroppedAtTheLineupCut() {
        let rows = [
            serverRow("real", "US: AMC HD", group: "US| ENTERTAINMENT"),
            serverRow("disney", "## DISNEY+ ORIGINAL ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| DISNEY+ NETWORK ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            serverRow("spectrum", "## SPECTRUM NETWORK ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| SPECTRUM NETWORK ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            serverRow("paramount", "## PARAMOUNT+ ORIGINAL ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| PARAMOUNT+ ORIGINAL ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            serverRow("header", "##### CANADA NEWS ENGLISH #####", group: "CA| NEWS EN"),
            serverRow("idle", "- NO EVENT STREAMING - | 8K EXCLUSIVE | ARG: FANATIZ PPV 10", group: "US| FANATIZ PPV"),
            serverRow("ended", "(A 001) | Old Game (2020-01-02 19:00:00)", group: "US| VICTORY+ PPV"),
            serverRow("loop", "24/7: 30 ROCK", group: "US| 24/7 COMEDY ᴿᴬᵂ ⁶⁰ᶠᵖˢ")
        ]
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(result.kept.map(\.id), ["real", "loop"])
        XCTAssertEqual(result.summary.placeholders, 6)
        XCTAssertEqual(result.inventory.total, 2, "placeholders are in no count")
        XCTAssertEqual(result.inventory.codeCounts["US"], 2)
    }

    func testAnUpcomingOrLiveEventSlotIsNotAPlaceholder() {
        let soon = DateFormatter()
        soon.locale = Locale(identifier: "en_US_POSIX")
        soon.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = soon.string(from: Date().addingTimeInterval(3_600))
        let rows = [serverRow("soon", "(A 001) | Soon Game (\(stamp))", group: "US| VICTORY+ PPV")]
        XCTAssertEqual(LiveTVLineupFilter.apply(.standard, to: rows).kept.map(\.id), ["soon"])
    }

    func testPlaceholdersAreNeverInTheCatalogEvenWhenFavouritedOrInEvents() {
        let model = LiveTVPrototypeModel(channels: [
            channel("real", "US: AMC HD", group: "US| ENTERTAINMENT"),
            channel("disney", "## DISNEY+ ORIGINAL ᴿᴬᵂ ⁶⁰ᶠᵖˢ ##", group: "US| DISNEY+ NETWORK ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            channel("idle", "- NO EVENT STREAMING - | 8K EXCLUSIVE | ARG: FANATIZ PPV 10", group: "AR| FANATIZ PPV"),
            channel("ended", "(A 001) | Old Game (2020-01-02 19:00:00)", group: "US| VICTORY+ PPV")
        ])
        XCTAssertEqual(model.channels.map(\.id), ["real"])
        XCTAssertEqual(model.browseSummary.totalCount, 1)
        model.category = LiveTVEventSlotClassifier.filterName
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(model.activeEventCount, 0)
        model.category = nil
        XCTAssertEqual(model.guideChannels.count, 1)
        model.query = "disney"
        XCTAssertTrue(model.visibleChannels.isEmpty)
    }
}
