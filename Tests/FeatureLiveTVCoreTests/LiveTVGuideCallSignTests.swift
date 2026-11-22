import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Matching a US local row to a guide's station by call sign and subchannel: the readers, the station table and the rules between them.
@MainActor
final class LiveTVGuideCallSignTests: XCTestCase {
    private func row(_ name: String, id: String = "row", guideID: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: "US| LOCAL", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: guideID, groups: ["US| LOCAL"])
    }

    /// The station ids a row is read from, or nil when it takes none.
    private func reads(_ name: String, in guide: [String: [String]]) -> [String]? {
        let matcher = LiveTVGuideMatcher()
        let result = matcher.match(channels: [row(name)], guideChannels: guide, trustsGuideIDs: true)
        let ids = result.filter { !$0.value.isEmpty }.keys.sorted()
        return ids.isEmpty ? nil : ids
    }

    private let raleigh: [String: [String]] = [
        "WTVD111.us@HD": ["ABC (WTVD) Raleigh, NC HD"],
        "WTVD111.us@SD": ["ABC (WTVD) Raleigh, NC"],
        "WTVD112.us@HD": ["Localish (WTVD-DT2) Raleigh, NC HD"],
        "WTVD114.us@SD": ["HSN (WTVD4) Raleigh, NC"],
        "WRAL51.us@HD": ["NBC (WRAL) Raleigh-Durham, NC HD"],
        "WRAL51.us@Plus1": ["NBC (WRAL) Raleigh-Durham, NC +1"],
        "WRAL51.us@West": ["NBC (WRAL) Raleigh-Durham, NC West"]
    ]

    // MARK: Readers

    func testRowTokensReadCallSignAndSubchannel() {
        let cases: [(String, String?, String?)] = [
            ("US: NBC 4 (WDIV) DETROIT (A) ᴿᴬᵂ", "wdiv", "wdiv"),
            ("TV: A3 NEW YORK 02 WCBS CBS ᴿᴬᵂ", "wcbs", "wcbs"),
            ("US: FOX (KRQEDT2) ALBUQUERQUE NEW MEXICO", "krqe", "krqedt2"),
            ("TV: WHEELING, WV  WTOV-D2 FOX 10 A3 HD CLEVELAND", "wtov", "wtovdt2"),
            ("US: CBS 7 (KHQA-DT) QUINCY HD", "khqa", "khqa"),
            ("US: ABC 13 LYNCHBURG VA (WSET)", "wset", "wset"),
            ("US: ABC 11 (WTVD-DT2)", "wtvd", "wtvddt2"),
            ("US: ABC 11 (WTVD.3)", "wtvd", "wtvddt3"),
            ("US: METV (KJCX-LD) HELENA", "kjcxld", "kjcxld"),
            ("US: PBS (K44JPD) TRANSLATOR", "k44jpd", "k44jpd"),
            ("US: HSN (WTVD4)", "wtvd", "wtvddt4"),
            ("US: WORLD NEWS ABC", nil, nil),
            ("US: ABC WORLD2", nil, nil),
            ("US: ABC WEST HD", nil, nil),
            ("US: KIDS (WEST) NBC", nil, nil)
        ]
        for (name, base, full) in cases {
            let sign = LiveTVGuideStationIndex.callSign(in: name)
            XCTAssertEqual(sign?.base, base, name)
            XCTAssertEqual(sign?.full, full, name)
        }
    }

    func testStationNamesAndIDsReadCallSigns() {
        XCTAssertEqual(LiveTVCallSignData.callSign(inDisplayName: "FOX (WTXF) Philadelphia, PA HD")?.full, "wtxf")
        XCTAssertEqual(LiveTVCallSignData.callSign(inDisplayName: "Localish (WTVD-DT2) Raleigh, NC HD")?.full, "wtvddt2")
        XCTAssertEqual(LiveTVCallSignData.callSign(inDisplayName: "Charge! (WTVD3) Raleigh, NC")?.full, "wtvddt3")
        XCTAssertEqual(LiveTVCallSignData.callSign(inDisplayName: "MeTV (KJCX-LD) Helena, MT")?.full, "kjcxld")
        XCTAssertNil(LiveTVCallSignData.callSign(inDisplayName: "WE (Women's Entertainment) - Eastern"))
        XCTAssertNil(LiveTVCallSignData.callSign(inDisplayName: "HBO (West)"))
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WTXFTV291.us")?.full, "wtxf")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WTVD112.us")?.full, "wtvddt2")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "K44JPD1.us")?.full, "k44jp", "A translator id adds a D")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WIRPLD271.us")?.full, "wirpld")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WZTVDT2.us")?.full, "wztvdt2")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "KCWCDT41.us")?.full, "kcwc", "Channel 4, subchannel 1")
        XCTAssertNil(LiveTVCallSignData.callSign(ofStationID: "Film4.uk"))
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WTVD.us")?.full, "wtvd", "An id that is the call sign alone")
        XCTAssertEqual(LiveTVCallSignData.callSign(ofStationID: "WZTVDT2.us")?.full, "wztvdt2")
    }

    // MARK: Matching

    func testMainRowTakesTheMainStationAndBothFeedsAreOffered() {
        XCTAssertEqual(reads("US: ABC 11 RALEIGH (WTVD)", in: raleigh), ["WTVD111.us@HD", "WTVD111.us@SD"])
    }

    func testSubchannelMustAgree() {
        XCTAssertEqual(reads("US: LOCALISH (WTVD-DT2) RALEIGH", in: raleigh), ["WTVD112.us@HD"])
        XCTAssertEqual(reads("US: HSN (WTVD4)", in: raleigh), ["WTVD114.us@SD"])
        XCTAssertNil(reads("US: ABC (WTVD-DT5)", in: raleigh), "A subchannel the guide lacks is refused, not read as the main one")
        let onlySub = ["WTVD112.us@HD": ["Localish (WTVD-DT2) Raleigh, NC HD"]]
        XCTAssertNil(reads("US: ABC 11 (WTVD)", in: onlySub), "A main row never takes a station that exists only as a subchannel")
        let onlyMain = ["WTVD111.us@HD": ["ABC (WTVD) Raleigh, NC HD"]]
        XCTAssertNil(reads("US: LOCALISH (WTVD-DT2)", in: onlyMain), "A subchannel row never takes the main station")
    }

    func testNetworkTheRowNamesMustBeTheStationsOwn() {
        let guide = ["WWSI621.us@HD": ["Telemundo (WWSI) Philadelphia, PA HD"], "WTXF291.us@HD": ["FOX (WTXF) Philadelphia, PA HD"]]
        XCTAssertEqual(reads("US: NBC 10 (WWSI) TELEMUNDO", in: guide), ["WWSI621.us@HD"],
                       "A row naming two networks is judged by the station: it is Telemundo's")
        XCTAssertNil(reads("US: ABC (WWSI) PHILADELPHIA", in: guide), "The station is Telemundo, the row says ABC")
        XCTAssertNil(reads("US: ABC (WTXF) PHILADELPHIA", in: guide), "A FOX station is not an ABC row's")
        XCTAssertEqual(reads("US: PHILADELPHIA (WTXF)", in: guide), ["WTXF291.us@HD"], "A row that names no network takes the station")
    }

    func testPlusOneWestAndOtherFeedsAreNeverTheBase() {
        XCTAssertEqual(reads("US: NBC 5 (WRAL)", in: raleigh), ["WRAL51.us@HD"])
        XCTAssertNil(reads("US: NBC 5 (WRAL) +1", in: raleigh))
        XCTAssertNil(reads("US: NBC 5 (WRAL) WEST", in: raleigh))
        let onlyWest = ["WXYZ71.us@West": ["ABC (WXYZ) Detroit, MI West"]]
        XCTAssertNil(reads("US: ABC 7 (WXYZ) DETROIT", in: onlyWest), "A West feed is not the base station")
    }

    func testEastFeedServesARowWithoutAMarker() {
        let guide = ["WXYZ71.us@East": ["ABC (WXYZ) Detroit, MI East"], "WXYZ71.us@West": ["ABC (WXYZ) Detroit, MI West"]]
        XCTAssertEqual(reads("US: ABC 7 (WXYZ) DETROIT", in: guide), ["WXYZ71.us@East"])
    }

    func testTwoStationsClaimingOneCallSignServeNeither() {
        let guide = ["WABC71.us@HD": ["ABC (WABC) New York, NY HD"], "WABC.us": ["ABC (WABC) New York, NY"]]
        // Two ids that each name the call sign: which is the station?
        XCTAssertEqual(LiveTVGuideCallSignTable(guideChannels: guide).ambiguousStemCount, 2)
        XCTAssertNil(reads("US: ABC 7 (WABC) NEW YORK", in: guide))
    }

    func testTheStationWhoseOwnIDNamesTheCallSignBeatsAMislabelledID() {
        let guide = ["KHON.us": ["US: FOX HARTFORD (WTIC)"], "WTIC.us": ["US: FOX 61 HARTFORD (WTIC) HD"]]
        XCTAssertEqual(reads("US: FOX 61 (WTIC) HARTFORD HD", in: guide), ["WTIC.us"])
    }

    func testAnIDThatIsTheCallSignNeedsNoNetworkFromItsUnrelatedName() {
        let guide = ["WTVA.us": ["US: ABC GOOD MORNING AMERICA"]]
        XCTAssertEqual(reads("US: NBC 9 (WTVA) TUPELO (D)", in: guide), ["WTVA.us"])
        XCTAssertNil(reads("US: NBC 9 (WTVA-DT2) TUPELO", in: guide))
    }

    func testNameBeatsAnIDThatCarriesAnotherCallSign() {
        let guide = ["WXYZ71.us@HD": ["ABC (WXYQ) Detroit, MI HD"]]
        XCTAssertEqual(reads("US: ABC 7 (WXYQ) DETROIT", in: guide), ["WXYZ71.us@HD"], "The name's bracket is the station's call sign")
        XCTAssertNil(reads("US: ABC 7 (WXYZ) DETROIT", in: guide), "The id's old call sign is not the station's")
    }

    func testStationNameIsItsCallSignWhenTheIDCarriesAnotherLicence() {
        let guide = [
            "WAGTCD261.us@HD": ["NBC (WAGT) Augusta, GA HD"],
            "K44JPD1.us@SD": ["FOX (K44JP) Cottage Grove, OR"],
            "WJLP338.us@SD": ["MeTV (WJLP) New Jersey/New York HD"]
        ]
        XCTAssertEqual(reads("US: NBC 16 (WAGT) AUGUSTA (H) ᴿᴬᵂ", in: guide), ["WAGTCD261.us@HD"])
        XCTAssertEqual(reads("US: FOX (K44JP) COTTAGE GROVE", in: guide), ["K44JPD1.us@SD"])
        XCTAssertNil(reads("US: METV (WJLP)", in: guide), "The name says main, the id says subchannel 8: unknown service, refused")
    }

    func testAFreeWordBeforeACommaIsAPlaceNotACallSign() {
        XCTAssertEqual(LiveTVGuideStationIndex.callSign(in: "TV: WACO, TX KCEN NBC 6 A3 HD")?.base, "kcen")
        XCTAssertNil(LiveTVGuideStationIndex.callSign(in: "US: WACO, TX NBC"))
        XCTAssertEqual(LiveTVGuideStationIndex.callSign(in: "US: NBC (WACO) TEXAS")?.base, "waco", "In brackets a call sign is a call sign")
    }

    func testBareCallSignTheGuideHasFillsOnlyALocalRow() {
        let guide = [
            "KIROTV71.us@HD": ["CBS (KIRO) Seattle, WA HD"], "WGNDT1.us@SD": ["WGN TV 9"], "WNBC471.us@HD": ["NBC (WNBC) New York, NY HD"],
            "WGNAmerica.us": ["WGN America"]
        ]
        XCTAssertEqual(reads("US: KIRO 7 NEWS", in: guide), ["KIROTV71.us@HD"])
        XCTAssertEqual(reads("US: WNBC", in: guide), ["WNBC471.us@HD"])
        XCTAssertNil(reads("US: ABC 7 KIRO", in: guide), "A network the station does not carry")
        XCTAssertEqual(reads("US: WGN AMERICA", in: ["WGNDT1.us@SD": ["WGN TV 9"]]), nil, "The national channel is not the Chicago local")
        XCTAssertEqual(reads("US: WGN AMERICA", in: guide), ["WGNAmerica.us"])
    }

    func testStationNamedLikeALineupRowIsReadForItsNetworkWord() {
        let guide = ["KALB.us": ["US: NBC 5 ALEXANDRIA LA (KALB) HD"], "WEDW491.us@SD": ["Connecticut Public Television (WEDW) Bridgeport"]]
        XCTAssertEqual(reads("US: NBC 5 (KALB) ALEXANDRIA", in: guide), ["KALB.us"])
        XCTAssertNil(reads("US: CBS 5 (KALB) ALEXANDRIA", in: guide))
        XCTAssertEqual(reads("US: PBS 49 (WEDW) NEW YORK", in: guide), ["WEDW491.us@SD"], "A licensee name carries no network to contradict the row")
        XCTAssertNil(reads("US: ABC (KOKI) TULSA", in: ["KOKI231.us@HD": ["ROAR (KOKI) Tulsa, OK"]]), "ROAR is not the row's ABC")
    }

    func testStationNamedByCallSignAndServiceIsNotTheMainService() {
        let guide = ["WCBSTV21.us@HD": ["CBS (WCBS) New York, NY HD"], "WCBSTV23.us@SD": ["WCBS DABL"], "WGRZ22.us@SD": ["WGRZ Antenna TV"]]
        XCTAssertEqual(reads("US: CBS 2 (WCBS) NEW YORK", in: guide), ["WCBSTV21.us@HD"])
        XCTAssertNil(reads("US: ANTENNA (WGRZ)", in: ["WGRZ22.us@SD": ["WGRZ Antenna TV"]]), "Subchannel 2 only: a main row is refused")
    }

    func testLowPowerStationIsNotTheFullPowerOne() {
        let guide = ["KJCXLD11.us@SD": ["MeTV (KJCX-LD) Helena, MT"]]
        XCTAssertEqual(reads("US: METV (KJCX-LD) HELENA", in: guide), ["KJCXLD11.us@SD"])
        XCTAssertNil(reads("US: METV (KJCX) HELENA", in: guide))
    }

    func testRefusedCallSignDoesNotFallBackToTheName() {
        // The name rule would key `abc` + the city; a refused call sign must stay refused.
        let guide = ["WTVD111.us@HD": ["ABC (WTVD) Raleigh, NC HD"], "ABC.us": ["ABC"]]
        XCTAssertNil(reads("US: ABC (WTVD-DT3)", in: guide))
    }

    func testStationsTheRowNeedsAreRetainedWithEveryFeed() {
        let index = LiveTVGuideStationIndex(guideChannels: raleigh)
        XCTAssertEqual(index.retainedStationIDs(name: "US: ABC 11 RALEIGH (WTVD)", country: "US"), ["WTVD111.us@HD", "WTVD111.us@SD"])
        XCTAssertEqual(index.retainedStationIDs(name: "US: ABC 11 (WTVD) +1", country: "US"), [])
    }

    func testRowWhoseProviderIDIsTheSameStationStillReadsIt() {
        let guide = ["WTVD111.us@HD": ["ABC (WTVD) Raleigh, NC HD"]]
        let result = LiveTVGuideMatcher().matching(
            channels: [row("US: ABC 11 (WTVD)", guideID: "WTVD111.us@HD")], guideChannels: guide, trustsGuideIDs: true)
        XCTAssertEqual(result.assignments["row"]?.guideChannelID, "WTVD111.us@HD")
        XCTAssertNotNil(result.channelsByGuideID["WTVD111.us@HD"])
    }

    /// Skipped unless `PLOZZ_EXTRA_GUIDE_STATIONS`, `PLOZZ_EXTRA_GUIDE_LISTINGS` and `PLOZZ_CALLSIGN_FIXTURES` (a tab-separated list of
    /// `row_name, expected_station_id (or NONE), confidence, lane, class, …`, judged by hand) are set. Every SURE call-sign row must read
    /// its expected station (any feed of it) or, when NONE is expected, nothing. The others are reported to `PLOZZ_EXTRA_GUIDE_REPORT`.
    func testHandJudgedFixtureRowsReadTheirStations() throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard let stationsPath = value("PLOZZ_EXTRA_GUIDE_STATIONS"), let listingsPath = value("PLOZZ_EXTRA_GUIDE_LISTINGS"),
              let fixturesPath = value("PLOZZ_CALLSIGN_FIXTURES") else {
            throw XCTSkip("Set PLOZZ_EXTRA_GUIDE_STATIONS, PLOZZ_EXTRA_GUIDE_LISTINGS and PLOZZ_CALLSIGN_FIXTURES.")
        }
        let listed = Set(try String(contentsOfFile: listingsPath, encoding: .utf8).split(separator: "\n").map(String.init))
        var guide: [String: [String]] = [:]
        for line in try String(contentsOfFile: stationsPath, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "channel", let id = object["id"] as? String, listed.contains(id) else { continue }
            guide[id] = object["displayNames"] as? [String] ?? []
        }
        var failures: [String] = [], report: [String] = [], checked = 0
        let lines = try String(contentsOfFile: fixturesPath, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        // Columns are read by header name, so a file with other columns is never read at the wrong offsets.
        let header = (lines.first ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let nameColumn = header.firstIndex(of: "row_name"), let expectedColumn = header.firstIndex(of: "expected_station_id"),
              let confidenceColumn = header.firstIndex(of: "confidence"), let laneColumn = header.firstIndex(of: "lane") else {
            return XCTFail("\((fixturesPath as NSString).lastPathComponent) is not a call-sign fixture: it needs row_name, "
                + "expected_station_id, confidence and lane columns; found \(header)")
        }
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == header.count, fields[laneColumn] == "callsign" else { continue }
            let (name, expected) = (fields[nameColumn], fields[expectedColumn])
            let found = reads(name, in: guide)
            let agrees = expected == "NONE" ? found == nil : found?.contains(expected) == true
            if Self.fixtureRowsWhereTheGuideIsRight.contains(name) { continue }
            if fields[confidenceColumn] == "SURE" {
                checked += 1
                if !agrees { failures.append("\(name) expected \(expected) read \(found ?? [])") }
            } else {
                report.append("unsure\t\(agrees ? "agrees" : "differs")\t\(name)\t\(expected)\t\(found ?? [])")
            }
        }
        if let out = value("PLOZZ_EXTRA_GUIDE_REPORT") {
            try (["fixtureRowsChecked\t\(checked)\tfailures\t\(failures.count)"] + failures + report)
                .joined(separator: "\n").write(toFile: out + ".fixtures", atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Fixture rows whose hand judgement the guide contradicts: `KCVU` is in the guide (`FOX (KCVU) Chico, CA HD`, with listings).
    private static let fixtureRowsWhereTheGuideIsRight: Set<String> = ["US: FOX 20 (KCVU) CHICO / REDDING"]

    // MARK: A real list

    /// Skipped unless the lineup snapshot and the extra guide copy are given (the same `PLOZZ_EXTRA_GUIDE_*` files as
    /// `LiveTVExtraGuideCoverageTests.testRealListFillFromAnExtraGuide`). Writes counts per country, the pass time (median of 5)
    /// and every row filled by call sign (names and station ids only) to `PLOZZ_EXTRA_GUIDE_REPORT`.
    func testRealListCallSignFill() throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard let channelsPath = value("PLOZZ_EXTRA_GUIDE_CHANNELS"), let providerPath = value("PLOZZ_EXTRA_GUIDE_PROVIDER"),
              let providerListings = value("PLOZZ_EXTRA_GUIDE_PROVIDER_LISTINGS"), let extraPath = value("PLOZZ_EXTRA_GUIDE_STATIONS"),
              let extraListings = value("PLOZZ_EXTRA_GUIDE_LISTINGS") else {
            throw XCTSkip("Set the PLOZZ_EXTRA_GUIDE_* files to measure a real list.")
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
        func stations(_ path: String) throws -> [String: [String]] {
            var result: [String: [String]] = [:]
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "channel", let id = object["id"] as? String else { continue }
                result[id] = object["displayNames"] as? [String] ?? []
            }
            return result
        }
        func ids(_ path: String) throws -> Set<String> {
            Set(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init))
        }
        let kept = LiveTVLineupFilter.apply(.standard, to: rows).kept
        let provider = try stations(providerPath), providerWith = try ids(providerListings)
        let extra = try stations(extraPath), extraWith = try ids(extraListings)
        func measure() -> LiveTVGuideCoverage {
            LiveTVGuideCoverage.measure(
                channels: kept, stations: provider, stationsWithListings: providerWith,
                extraStations: extra, extraStationsWithListings: extraWith)
        }
        let merged = measure()
        // The provider's own guide is read first and alone: an extra guide never moves one of its matches (item a in the report).
        let alone = LiveTVGuideCoverage.measure(channels: kept, stations: provider, stationsWithListings: providerWith)
        XCTAssertEqual(alone.sources, merged.sources.filter { $0.key != "extra" })
        XCTAssertEqual(alone.sources["id"], merged.sources["id"])
        var times: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = measure()
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        times.sort()
        var report = ["with extra guide\t" + merged.logLine, "extraFilled\t\(merged.extraGuideRows ?? 0)",
                      "measurePassMs\tmedian=\(Int(times[2])) all=\(times.map { Int($0) })"]
        report.append("providerOnly\t" + alone.logLine)
        for channel in alone.unmatched { report.append("providerUnmatched\t\(channel.name)") }
        let providerMatches = LiveTVGuideMatcher().matching(
            channels: alone.linearRows, guideChannels: provider.filter { providerWith.contains($0.key) }, trustsGuideIDs: true).assignments
        for channel in alone.linearRows {
            if let match = providerMatches[channel.id], LiveTVGuideStationIndex.callSign(in: channel.name) != nil {
                report.append("providerCallSign\t\(channel.name)\t\(match.guideChannelID)\t\(match.method)")
            }
        }
        let readable = extra.filter { extraWith.contains($0.key) }
        var buildTimes: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = LiveTVGuideCallSignTable(guideChannels: readable)
            buildTimes.append(Date().timeIntervalSince(start) * 1000)
        }
        buildTimes.sort()
        report.append("signTableBuildMs\tmedian=\(String(format: "%.1f", buildTimes[2])) all=\(buildTimes.map { String(format: "%.1f", $0) })")
        let table = LiveTVGuideCallSignTable(guideChannels: readable)
        report.append("signTable\tstations=\(table.stationCount) ambiguousStems=\(table.ambiguousStemCount)")
        // Rows the extra guide filled by call sign: the row, the station.
        let index = LiveTVGuideStationIndex(guideChannels: readable)
        var classifier = LiveTVLineupClassifier()
        var filled = 0
        for channel in merged.linearRows {
            guard case .country(let code) = classifier.placement(of: channel), code == "US" else { continue }
            let facts = LiveTVGuideStationIndex.RowFacts(name: channel.guideName ?? channel.name)
            guard facts.callSign != nil, !facts.shifted,
                  case .station(let found) = index.callSignAnswer(facts: facts, country: code) else { continue }
            filled += 1
            report.append("callSignFill\t\(channel.name)\t\(found.first ?? "")")
        }
        report.append("callSignRows\t\(filled)")
        if let out = value("PLOZZ_EXTRA_GUIDE_REPORT") { try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertGreaterThan(merged.linear, 0)
    }
}
