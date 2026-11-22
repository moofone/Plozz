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
}
