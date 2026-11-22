import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Guide matching, round 3: ids that are a sibling of the row's name, the alias beside a same-name station of another country,
/// the `(D)` tag, a trailing `channel` in a lower-case id, `TV:` rows taking their group's country, per-channel coverage, and
/// the time-shift measurement (env-gated, with the table it produced).
@MainActor
final class LiveTVGuideMatchRound3Tests: XCTestCase {
    private func channel(_ id: String, _ name: String, group: String, guideID: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: guideID, groups: [group])
    }

    private func stations(_ ids: [String]) -> [String: [String]] { Dictionary(uniqueKeysWithValues: ids.map { ($0, []) }) }

    private func station(for row: LiveTVPrototypeChannel, in guide: [String: [String]]) -> String? {
        LiveTVGuideMatcher().matching(channels: [row], guideChannels: guide, trustsGuideIDs: true).assignments[row.id]?.guideChannelID
    }

    // MARK: Sibling tails

    func testAnIDWhoseTailDiffersFromTheRowsIsNotTrusted() {
        let guide = stations(["FuboSportsNetwork.us", "News12CT.us", "News12Bronx.us", "SkySportsF1.uk", "SkySportsNews.uk", "SkySportsMainEvent.uk"])
        XCTAssertNil(station(for: channel("a", "US: FUBO SPORTS 2 HD", group: "US| SPORT", guideID: "FuboSportsNetwork.us"), in: guide), "a number above one the id lacks")
        XCTAssertEqual(station(for: channel("b", "US: NEWS 12 BRONX", group: "US| NEWS", guideID: "News12CT.us"), in: guide), "News12Bronx.us", "the sibling id is refused and the name finds its own station")
        XCTAssertNil(station(for: channel("c", "UK: SKY SPORTS DARTS", group: "UK| SPORT", guideID: "SkySportsF1.uk"), in: guide))
    }

    func testAnIDThatContainsOrIsContainedByTheNameIsKept() {
        let guide = stations(["FuboSportsNetwork.us", "News12CT.us", "SkySportsMainEvent.uk", "CTVNC.ca"])
        XCTAssertEqual(station(for: channel("a", "US: FUBO SPORTS NETWORK HD", group: "US| SPORT", guideID: "FuboSportsNetwork.us"), in: guide), "FuboSportsNetwork.us")
        XCTAssertEqual(station(for: channel("b", "US: FUBO SPORTS", group: "US| SPORT", guideID: "FuboSportsNetwork.us"), in: guide), "FuboSportsNetwork.us")
        XCTAssertEqual(station(for: channel("c", "US: NEWS 12 CT", group: "US| NEWS", guideID: "News12CT.us"), in: guide), "News12CT.us")
        XCTAssertEqual(station(for: channel("d", "UK: SKY SPORTS MAIN EVENT HD", group: "UK| SPORT", guideID: "SkySportsMainEvent.uk"), in: guide), "SkySportsMainEvent.uk")
    }

    /// The fixtures called `NEWS 12 CONNECTICUT` / `News12CT` a sibling; CT is Connecticut, so it is one station and stays matched.
    func testAnAbbreviatedTailAndAnAmpersandAreTheSameStation() {
        let guide = stations(["News12CT.us", "DisneyJunior.us", "CrimeInvestigation.us", "NickJunior.uk"])
        XCTAssertEqual(station(for: channel("a", "US: NEWS 12 CONNECTICUT", group: "US| NEWS", guideID: "News12CT.us"), in: guide), "News12CT.us")
        XCTAssertEqual(station(for: channel("b", "US: DISNEY JR HD", group: "US| KIDS", guideID: "DisneyJunior.us"), in: guide), "DisneyJunior.us")
        XCTAssertEqual(station(for: channel("c", "US: CRIME & INVESTIGATION HD", group: "US| DOC", guideID: "CrimeInvestigation.us"), in: guide), "CrimeInvestigation.us")
        XCTAssertEqual(station(for: channel("d", "UK: NICK JR HD", group: "UK| KIDS", guideID: "NickJunior.uk"), in: guide), "NickJunior.uk")
    }

    func testASiblingIDStillLetsTheNameFindItsOwnStation() {
        let guide = stations(["SkySportsF1.uk", "SkySportsDarts.uk"])
        XCTAssertEqual(station(for: channel("a", "UK: SKY SPORTS DARTS", group: "UK| SPORT", guideID: "SkySportsF1.uk"), in: guide), "SkySportsDarts.uk")
    }

    func testTheSiblingRuleReadsWholeWordsAndIgnoresGenericOnes() {
        let facts = { LiveTVGuideStationIndex.RowFacts(name: $0) }
        XCTAssertTrue(LiveTVGuideStationIndex.idIsSiblingOfName(id: "SkySportsF1.uk", facts: facts("UK: SKY SPORTS DARTS")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "FoodNetwork.us", facts: facts("US: FOOD NETWORK HD")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "CFPL.ca", facts: facts("CA: CTV2 LONDON")), "no shared leading word")
        XCTAssertTrue(LiveTVGuideStationIndex.idIsSiblingOfName(id: "FuboSportsNetwork.us", facts: facts("US: FUBO SPORTS 2")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "HBO.ca", facts: facts("CA: HBO 1")), "1 is the base channel")
        XCTAssertTrue(LiveTVGuideStationIndex.idIsSiblingOfName(id: "HBO.ca", facts: facts("CA: HBO 2")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "DiscoveryChannel.ca", facts: facts("CA: DISCOVERY CANADA")), "generic words")
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "abc11wtvd.us", facts: facts("US: ABC 11 HD [RALEIGH]")), "a call-sign id")
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "GlobalCalgary.ca", facts: facts("CA EN: GLOBAL CALAGRY SD")), "a typo")
        XCTAssertTrue(LiveTVGuideStationIndex.idIsSiblingOfName(id: "GlobalNewsBC1.ca", facts: facts("CA EN: GLOBAL NEWS REGINA HD")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "DisneyJunior.us", facts: facts("US: DISNEY JR")))
        XCTAssertFalse(LiveTVGuideStationIndex.idIsSiblingOfName(id: "ESPNU.us", facts: facts("US: ESPN U")), "one key holds the other")
    }

    // MARK: Names

    func testTheDTagAndATrailingChannelAndAnAliasBesideSameNameStationsOfOtherCountries() {
        let guide = stations(["nbcsportsboston.us", "NBCSportsCalifornia.us", "reelzchannel.us", "NatGeo.us", "natgeo.ca", "NationalGeographic.es", "nationalgeographic.pt"])
        XCTAssertEqual(station(for: channel("a", "US: NBC SPORTS BOSTON (D) ᴿᴬᵂ", group: "US| NBC"), in: guide), "nbcsportsboston.us")
        XCTAssertEqual(station(for: channel("b", "US: NBC SPORTS CALIFORNIA (D) ᴿᴬᵂ", group: "US| NBC"), in: guide), "NBCSportsCalifornia.us")
        XCTAssertEqual(station(for: channel("c", "US: REELZ ᴿᴬᵂ", group: "US| PEACOCK"), in: guide), "reelzchannel.us")
        XCTAssertEqual(station(for: channel("d", "US: NATIONAL GEOGRAPHIC", group: "US| ENTERTAINMENT"), in: guide), "NatGeo.us")
    }

    func testASymbolDrawnInPlaceOfALetterIsThatLetter() {
        let guide = stations(["beINSports1En.qa"])
        XCTAssertEqual(station(for: channel("a", "UK: BEIN SP⚽RTS 1 ENGLISH SD", group: "UK| SPORT", guideID: "beINSports1En.qa"), in: guide), "beINSports1En.qa")
        XCTAssertEqual(LiveTVGuideStationIndex.withoutSymbols("UK: SKY ◉"), "UK: SKY")
    }

    func testARowNamedLikeAStationOfItsOwnIsNotTakenByAnAlias() {
        let guide = stations(["E.us", "EEntertainment.us", "E.ca"])
        XCTAssertEqual(station(for: channel("a", "US: E", group: "US| ENTERTAINMENT"), in: guide), "E.us")
    }

    // MARK: TV: rows

    func testATVPrefixRowTakesItsGroupsCountry() {
        let guide = stations(["NatGeo.us", "natgeo.ca", "CNN.us", "cnn.ar"])
        XCTAssertEqual(station(for: channel("a", "TV: NATIONAL GEOGRAPHIC ᴿᴬᵂ", group: "US| TV ᴿᴬᵂ ⁶⁰ᶠᵖˢ"), in: guide), "NatGeo.us")
        XCTAssertEqual(station(for: channel("b", "TV: NATIONAL GEOGRAPHIC ᴿᴬᵂ", group: "CA| TV"), in: guide), "natgeo.ca")
        XCTAssertEqual(station(for: channel("c", "TV: CNN", group: "US| TV"), in: guide), "CNN.us")
    }

    func testATVPrefixRowInAGroupWithNoCountryNeedsAnUnambiguousStation() {
        let guide = stations(["NatGeo.us", "natgeo.ca", "CNN.us", "cnn.ar", "OnlyHere.us"])
        XCTAssertNil(station(for: channel("a", "TV: NATIONAL GEOGRAPHIC", group: "PACKAGES"), in: guide), "two countries carry it")
        XCTAssertNil(station(for: channel("b", "TV: CNN", group: "PACKAGES"), in: guide))
        XCTAssertEqual(station(for: channel("c", "TV: ONLY HERE", group: "PACKAGES"), in: guide), "OnlyHere.us")
    }

    // MARK: Coverage by channel

    func testCoverageCountsQualityVariantsOfOneNameAsOneChannel() {
        let rows = [
            channel("1", "US: CNN HD", group: "US| NEWS", guideID: "CNN.us"), channel("2", "US: CNN RAW", group: "US| NEWS"),
            channel("3", "US: CNN 4K", group: "US| NEWS"), channel("4", "US: OBSCURE LOCAL", group: "US| NEWS"),
            channel("5", "US: OBSCURE LOCAL HD", group: "US| NEWS"), channel("6", "CA: CNN", group: "CA| NEWS")
        ]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: stations(["CNN.us"]), stationsWithListings: ["CNN.us"])
        XCTAssertEqual(coverage.linear, 6)
        XCTAssertEqual(coverage.byCountry["US"], .init(matched: 3, total: 5), "CNN RAW and 4K match by name")
        XCTAssertEqual(coverage.channelsByCountry["US"], .init(matched: 1, total: 2), "CNN is one channel, OBSCURE LOCAL the other")
        XCTAssertEqual(coverage.channelsTotal, 3)
        XCTAssertTrue(coverage.logLine.hasSuffix("channels=2/3 channelsByCountry=CA:1/1,US:1/2,GB:0/0"), coverage.logLine)
    }

    func testAChannelIsCoveredWhenOnlyOneVariantHasAStation() {
        let rows = [channel("1", "US: AMC HD", group: "US| MOVIES", guideID: "AMC.us"), channel("2", "US: AMC FHD", group: "US| MOVIES", guideID: "Missing.us")]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: stations(["AMC.us"]), stationsWithListings: ["AMC.us"])
        XCTAssertEqual(coverage.channelsByCountry["US"], .init(matched: 1, total: 1))
    }

    // MARK: Real guide (env-gated)

    private func value(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[key] ?? env["TEST_RUNNER_" + key]
    }

    /// `PLOZZ_GUIDE_JSONL` is the snapshot's `guide.jsonl`. For every station whose id carries a time-shift marker (`plus1`, `+1`,
    /// `West`, `Pacific`) and whose base station (the id without the marker, in the same country) also has listings, the share of the
    /// shifted station's programmes in the first 24 hours whose title equals the base's title N hours earlier. A family is proven
    /// when that is at least 95 %. Writes the table to `PLOZZ_COVERAGE_REPORT` + `.timeshift`.
    func testTimeShiftFamiliesMeasurement() throws {
        guard let path = value("PLOZZ_GUIDE_JSONL") else { throw XCTSkip("Set PLOZZ_GUIDE_JSONL to measure time-shift families.") }
        struct Programme { let start: Double, end: Double, title: String }
        var programmes: [String: [Programme]] = [:]
        var ids = Set<String>()
        let format = ISO8601DateFormatter()
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "channel", let id = object["id"] as? String { ids.insert(id) }
            if object["type"] as? String == "programme", let id = object["channel"] as? String, let start = (object["start"] as? String).flatMap({ format.date(from: $0) }),
               let end = (object["end"] as? String).flatMap({ format.date(from: $0) }), let title = object["title"] as? String {
                programmes[id, default: []].append(Programme(start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, title: title))
            }
        }
        let first = programmes.values.compactMap { $0.map(\.start).min() }.min() ?? 0
        var rows: [String] = []
        let pattern = try NSRegularExpression(pattern: #"^(.*?)(?:plus|\+)(\d+)$"#, options: [.caseInsensitive])
        for id in ids.sorted() {
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            let stem = parts[0]
            let suffix = parts.count > 1 ? "." + parts[1] : ""
            var baseStem: String?
            var hours: [Int] = []
            let range = NSRange(stem.startIndex..., in: stem)
            if let match = pattern.firstMatch(in: stem, range: range), let base = Range(match.range(at: 1), in: stem), let number = Range(match.range(at: 2), in: stem), let n = Int(stem[number]) {
                baseStem = String(stem[base]); hours = [n]
            } else if stem.lowercased().hasSuffix("west"), stem.count > 4 { baseStem = String(stem.dropLast(4)); hours = [3] }
            else if stem.lowercased().hasSuffix("pacific"), stem.count > 7 { baseStem = String(stem.dropLast(7)); hours = [3] }
            guard let baseStem, let shifted = programmes[id], !shifted.isEmpty else { continue }
            let candidates = ids.filter { $0.lowercased() == baseStem.lowercased() + suffix.lowercased() || ($0.lowercased() == (baseStem + "east" + suffix).lowercased()) }
            for base in candidates.sorted() {
                guard let baseProgrammes = programmes[base], !baseProgrammes.isEmpty else { continue }
                for n in hours {
                    var same = 0, total = 0
                    for programme in shifted where programme.start < first + 24 * 3600 {
                        let instant = programme.start - Double(n) * 3600
                        guard let covering = baseProgrammes.first(where: { $0.start <= instant && instant < $0.end }) else { continue }
                        total += 1
                        if covering.title == programme.title { same += 1 }
                    }
                    let share = total == 0 ? 0 : Double(same) / Double(total)
                    rows.append("\(id)\t\(base)\t+\(n)h\tagree=\(same)/\(total)\t\(String(format: "%.3f", share))\t\(total >= 10 && share >= 0.95 ? "proven" : "not-proven")")
                }
            }
        }
        if let out = value("PLOZZ_COVERAGE_REPORT") { try (["shifted\tbase\toffset\tagreement\tshare\tverdict"] + rows).joined(separator: "\n").write(toFile: out + ".timeshift", atomically: true, encoding: .utf8) }
    }

    // MARK: Feed-qualified ids and bracketed qualifiers

    func testAFeedQualifiedIDServesOnlyItsOwnCoast() {
        let guide = ["CBS.us@East": ["CBS - Eastern"], "CBS.us@West": ["CBS - Pacific"], "NBC.us@West": ["NBC - Network Pacific"]]
        XCTAssertEqual(station(for: channel("a", "CA: CBS WEST", group: "CA| CANADA"), in: guide), "CBS.us@West")
        XCTAssertEqual(station(for: channel("b", "CA: NBC WEST", group: "CA| CANADA"), in: guide), "NBC.us@West")
        XCTAssertEqual(station(for: channel("c", "CA: CBS EAST", group: "CA| CANADA"), in: guide), "CBS.us@East")
        XCTAssertEqual(station(for: channel("d", "US: CBS", group: "US| NETWORKS"), in: guide), "CBS.us@East")
    }

    func testAPacificFeedNeverAnswersTheBaseName() {
        let guide = ["CBS.us@West": ["CBS - Pacific"], "NBC.us@West": ["NBC - Network Pacific"]]
        XCTAssertNil(station(for: channel("a", "US: CBS", group: "US| NETWORKS"), in: guide), "the Pacific schedule is three hours late")
        XCTAssertNil(station(for: channel("b", "CA: CBS EAST", group: "CA| CANADA"), in: guide))
        XCTAssertNil(station(for: channel("c", "US: NBC HD", group: "US| NETWORKS"), in: guide))
        XCTAssertTrue(LiveTVGuideStationIndex.isTimeShiftedStation("CBS.us@West"))
        XCTAssertFalse(LiveTVGuideStationIndex.isTimeShiftedStation("CBS.us@East"))
        XCTAssertFalse(LiveTVGuideStationIndex.isTimeShiftedStation("CITVDT.ca@SD"))
    }

    func testAStationNameWithABracketedQualifierIsReadWithAndWithoutIt() {
        let guide = ["CICADT.ca@SD": ["TVO (TV Ontario)"], "TVO.ch": ["CH: TVO 4K"], "CFCMDT.ca@SD": ["CFCM TVA (Quebec)"], "TVA.ca": ["TVA"]]
        XCTAssertEqual(station(for: channel("a", "CA: TVO", group: "CA| CANADA"), in: guide), "CICADT.ca@SD")
        XCTAssertEqual(station(for: channel("b", "CA FR: TVA QUEBEC HD", group: "CA| GENERAL FR"), in: guide), "CFCMDT.ca@SD",
                       "the call sign before the network is the station's own id")
        XCTAssertEqual(station(for: channel("c", "CA FR: TVA HD", group: "CA| GENERAL FR"), in: guide), "TVA.ca", "the network is not the Quebec station")
    }

    func testABracketedQualifierNeverOverrulesOrStretchesAName() {
        XCTAssertNil(station(for: channel("a", "CA FR: TVA HD", group: "CA| GENERAL FR"), in: ["CFCMDT.ca@SD": ["CFCM TVA (Quebec)"]]),
                     "a market's station is not the network")
        XCTAssertNil(station(for: channel("b", "US: HBO", group: "US| MOVIES"), in: ["HBO2.us@SD": ["HBO (Pacific)"]]), "a qualifier naming a coast stays")
        XCTAssertEqual(station(for: channel("c", "CA: GLOBAL TORONTO", group: "CA| CANADA"),
                               in: ["globaltoronto.ca": ["Global Toronto"], "CIIIDT.ca@SD": ["Global Toronto (CIII)"]]), "globaltoronto.ca",
                       "an exact name still decides; the qualified one does not make it ambiguous")
        XCTAssertNil(station(for: channel("d", "CA: TVO", group: "CA| CANADA"), in: ["TVO.ch": ["CH: TVO 4K"], "CBCT.ca": ["CBC (Charlottetown)"]]))
        XCTAssertEqual(LiveTVGuideStationIndex.qualifiedKeys(of: "CFCM TVA (Quebec)", stemKey: "cfcmdt"), ["cfcmtva", "tvaquebec"])
        XCTAssertEqual(LiveTVGuideStationIndex.qualifiedKeys(of: "Global Edmonton", stemKey: "citvdt"), [])
    }

    // MARK: Global News

    /// Global's 24-hour news channels (snapshot 2026-11-17 names, groups and ids) beside their parent stations: a news channel with no
    /// guide of its own stays unmatched rather than reading its parent's schedule, which is news less than a third of the day. Global
    /// News BC keeps its own guide, and Global Vancouver is still Global BC (the same station, the guide's own abbreviation).
    func testAGlobalNewsChannelNeverReadsItsParentStation() {
        let guide: [String: [String]] = [
            "GlobalBC.ca": ["CA: GLOBAL BC"], "GlobalCalgary.ca": ["CA EN: GLOBAL CALAGRY SD"],
            "globaltoronto.ca": ["CA EN: GLOBAL TORONTO HD"], "globalnewsbc1.ca": ["CA: GLOBAL NEWS"],
            "GlobalNewsBC1.ca": ["CA EN: GLOBAL NEWS REGINA HD", "CA EN: GLOBAL NEWS PETERBOROUGH HD",
                                 "CA EN: GLOBAL NEWS NATIONAL HD", "CA EN: GLOBAL NEWS BC HD"]
        ]
        let rows: [(name: String, group: String, id: String?, expected: String?)] = [
            ("CA EN: GLOBAL NEWS TORONTO HD", "CA| NEWS EN", nil, nil),
            ("CA EN: GLOBAL NEWS CALGARY HD", "CA| NEWS EN", nil, nil),
            ("CA EN: GLOBAL NEWS VANCOUVER HD", "CA| NEWS EN", nil, nil),
            ("PRIME: GLOBAL NEWS BC ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", nil, nil),
            ("PRIME: GLOBAL NEWS CALGARY ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", nil, nil),
            ("PRIME: GLOBAL NEWS TORONTO ᴿᴬᵂ", "CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ", nil, nil),
            ("CA EN: GLOBAL NEWS BC HD", "CA| NEWS EN", "GlobalNewsBC1.ca", "GlobalNewsBC1.ca"),
            ("CA EN: GLOBAL VANCOUVER", "CA| GENERAL EN", nil, "GlobalBC.ca"),
            ("CA: GLOBAL BC", "CA| CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "GlobalBC.ca", "GlobalBC.ca"),
            ("CA EN: GLOBAL TORONTO HD", "CA| CANADA ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ", "globaltoronto.ca", "globaltoronto.ca")
        ]
        let channels = rows.enumerated().map { channel("g\($0.offset)", $0.element.name, group: $0.element.group, guideID: $0.element.id) }
        let result = LiveTVGuideMatcher().matching(channels: channels, guideChannels: guide, trustsGuideIDs: true)
        for (offset, row) in rows.enumerated() {
            XCTAssertEqual(result.assignments["g\(offset)"]?.guideChannelID, row.expected, row.name)
        }
    }

    // MARK: Halifax

    /// The provider's Halifax rows (snapshot 2026-11-17, names, groups and ids as exported) beside the other Atlantic and Global
    /// stations of the same guide. Every row with an id of its own reads that station; the two Global rows with no id stay
    /// unmatched rather than borrowing Global Halifax, whose schedule is a different channel's.
    func testEveryHalifaxRowReadsItsOwnStation() {
        let guide: [String: [String]] = [
            "CBHT.ca": ["CA EN: CBC HALIFAX HD"], "ctvhalifax.ca": ["CA EN: CTV HALIFAX"],
            "CJCH.ca": ["CA EN: CTV ATLENTIC (ATV MONCTON)"], "ASN.ca": ["CA EN: CTV2 ATLANTIC HD"],
            "CIHF.ca": ["CA EN: GLOBAL HALIFAX SD"], "CBAT.ca": ["CA EN: CBC FREDERICTON (HD)"],
            "CBCT.ca": ["CA EN: CBC CHARLOTTETOWN (HD)"], "CBNT.ca": ["CA EN: CBC ST JOHN'S (HD)"],
            "CIII.ca": ["CA EN: GLOBAL TORONTO HD"], "globaltoronto.ca": ["CA EN: GLOBAL TORONTO HD"],
            "GlobalBC.ca": ["CA: GLOBAL BC"], "globalnewsbc1.ca": ["CA: GLOBAL NEWS"], "CTVNC.ca": ["CA EN: CTV NEWS CHANNEL"]
        ]
        let rows: [(name: String, group: String, id: String?, expected: String?)] = [
            ("CA EN: CBC HALIFAX HD", "CA| KIDS EN", "CBHT.ca", "CBHT.ca"),
            ("CA EN: CTV HALIFAX", "CA| GENERAL EN", "ctvhalifax.ca", "ctvhalifax.ca"),
            ("CA EN: CTV ATLENTIC (ATV MONCTON)", "CA| GENERAL EN", "CJCH.ca", "CJCH.ca"),
            ("CA EN: CTV2 ATLANTIC HD", "CA| GENERAL EN", "ASN.ca", "ASN.ca"),
            ("CA EN: GLOBAL HALIFAX SD", "CA| GENERAL EN", "CIHF.ca", "CIHF.ca"),
            ("CA EN: GLOBAL MARITIMES HD", "CA| NEWS EN", nil, nil),
            ("CA EN: GLOBAL NEWS HALIFAX HD", "CA| NEWS EN", nil, nil)
        ]
        let channels = rows.enumerated().map { channel("h\($0.offset)", $0.element.name, group: $0.element.group, guideID: $0.element.id) }
        let result = LiveTVGuideMatcher().matching(channels: channels, guideChannels: guide, trustsGuideIDs: true)
        for (offset, row) in rows.enumerated() {
            XCTAssertEqual(result.assignments["h\(offset)"]?.guideChannelID, row.expected, row.name)
        }
        // The same rows when the provider omits its ids: the names alone still find the stations, and never another market's.
        let unnamed = rows.enumerated().map { channel("n\($0.offset)", $0.element.name, group: $0.element.group) }
        let byName = LiveTVGuideMatcher().matching(channels: unnamed, guideChannels: guide, trustsGuideIDs: true)
        for (offset, row) in rows.enumerated() {
            XCTAssertEqual(byName.assignments["n\(offset)"]?.guideChannelID, row.expected, "by name: \(row.name)")
        }
    }

    /// A provider guide lists, as an id's names, every row it pointed at that id: an id with several names is never read by those
    /// names (`TS` named after hundreds of channels, `HBO.us` also named `HBO WEST HD`), only an id with the one name.
    func testOnlyAStationWithOneProviderNameIsReadByIt() {
        let guide: [String: [String]] = [
            "TS": ["NL: Een ᴿᴬᵂ ◉", "CA EN: CNN HD", "US: NBC NEWS NOW", "UK: LFC TV"],
            "HBO.us": ["US: HBO HD", "US: HBO WEST HD", "US: HBO EAST"],
            "skyaction.uk": ["UK: SKY CINEMA ACTION HEVC 4K"]
        ]
        XCTAssertNil(station(for: channel("a", "CA EN: CNN HD", group: "CA| NEWS EN"), in: guide), "a catch-all id")
        XCTAssertNil(station(for: channel("b", "PRIME: NBC NEWS NOW ᴿᴬᵂ", group: "US| PRIME ᴿᴬᵂ"), in: guide))
        XCTAssertNil(station(for: channel("c", "AT&T: HBO WEST ᴿᴬᵂ", group: "US| AT&T ᴿᴬᵂ"), in: guide), "the Pacific row is not HBO East")
        XCTAssertEqual(station(for: channel("d", "UK: SKY CINEMA ACTION HD ◉", group: "UK| SKY CINEMA"), in: guide), "skyaction.uk")
    }

    /// The one name a provider gave an id is the row that carried it, so it passes the same checks as that row's id: a time-shifted
    /// name on a base id, another number, or a sibling channel is the provider's mistake and is never read.
    func testAProviderNameItsIDContradictsIsNotRead() {
        let guide: [String: [String]] = [
            "W.uk": ["UK: Quest Red +1 ◉"], "HistoryChannel.uk": ["UK: SKY HISTORY +1 ◉"],
            "SpectrumNews13.us": ["US: SPECTRUM NEWS 1 HD"], "CBHT.ca": ["CA EN: CBC HALIFAX HD"]
        ]
        XCTAssertNil(station(for: channel("a", "UK: QUEST RED +1", group: "UK| ENTERTAINMENT"), in: guide))
        XCTAssertNil(station(for: channel("b", "UK: SKY HISTORY +1", group: "UK| DOCUMENTARY"), in: guide), "the base schedule, an hour early")
        XCTAssertNil(station(for: channel("c", "US: SPECTRUM NEWS 1", group: "US| NEWS"), in: guide), "News 13 is one market of many")
        XCTAssertEqual(station(for: channel("d", "CA: CBC HALIFAX", group: "CA| GENERAL EN"), in: guide), "CBHT.ca", "a call-sign id agrees")
    }
}
