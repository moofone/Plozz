import Foundation
@testable import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// One test per round-2 rule, on a small directory taken from the real TMDB export (ids and origin countries as TMDB reports them).
final class LiveTVLogoMatchingRound2Tests: XCTestCase {
    private static let directory: [(Int, String, String?)] = [
        (23, "CBC Television", "CA"), (201, "CBC", "JP"), (2548, "CBC", "EG"), (9101, "CBC Network", "EG"),
        (110, "CTV", "CA"), (403, "CTV", "TW"), (111, "CTV 2", "CA"), (218, "Global TV", "CA"), (8834, "Global News", "CA"),
        (1019, "Sportsnet", "CA"), (141, "ICI Radio-Canada Télé", "CA"), (783, "Super Channel", "CA"), (1344, "Crave", "CA"),
        (6, "NBC", "US"), (2462, "NBC", "JP"), (9, "CBS News", "US"), (16, "CBS", "US"), (193, "Telemundo", "US"),
        (175, "CNBC", "US"), (30, "USA Network", "US"), (49, "HBO", "US"), (318, "STARZ", "US"),
        (11, "FOX", "US"), (45, "Fox News Channel", "US"), (2636, "OMNI", "CA"), (641, "The Sports Network", "CA"), (121, "Rogers Cup", "CA"), (122, "Bell Media", "CA"), (123, "Sportsnet One", "CA"),
        (129, "A&E", "US"), (2639, "A&E", "BR"), (301, "NBA TV", "US"), (796, "MAVTV", "US"), (957, "Sportsman Channel", "US"),
        (408, "Turner Classic Movies", "US"), (28, "Univision", "US"), (2447, "Univision", "PR"), (237, "VisionTV", "CA"),
        (1430, "AHC", "US"), (5770, "BabyTV", "GB"), (6360, "CGTN", "CN"), (6726, "EWTN", "US"), (8148, "France 24", "FR"),
        (435, "Velocity", "US"), (2392, "Crime + Investigation", "GB"), (2393, "Crime + Investigation", "AU"),
        (1402, "Crime+Investigation", "IT"), (2798, "Savoir média", "CA"), (4161, "Noovo", "CA"), (1533, "TV5 Québec Canada", "CA"),
        (2922, "TV5Monde", "FR"), (42, "TV5", "PH"), (6736, "TV5", "FI"), (673, "CTV News Channel", "CA")
    ]
    private static let origins: [Int: String?] = Dictionary(uniqueKeysWithValues: directory.map { ($0.0, $0.2) })
    private let matcher = LiveTVTMDbLogoMatcher(networks: directory.map { TMDbNetworkEntry(id: $0.0, name: $0.1) })

    private func pick(_ name: String, groups: [String] = []) -> LiveTVTMDbCandidate? {
        let query = LiveTVTMDbChannelQuery(name: name, groups: groups)
        return LiveTVTMDbLogoMatcher.select(
            from: matcher.candidates(for: query), originCountries: Self.origins, channelCountry: LiveTVTMDbLogoMatcher.country(for: query)
        )
    }

    // MARK: Rule 1: collapsed generic suffixes

    func testCBCTieCollapsesGenericSuffixesAndPrefersTheChannelsCountry() {
        // "CBC Television" (CA), "CBC" (JP, EG) and "CBC Network" (EG) are one brand; the Canadian origin wins.
        XCTAssertEqual(pick("CA EN: CBC HD", groups: ["CA EN|News"])?.networkID, 23)
        XCTAssertEqual(LiveTVTMDbLogoMatcher.collapsedKey("CBC Television"), LiveTVTMDbLogoMatcher.collapsedKey("CBC"))
        XCTAssertEqual(LiveTVTMDbLogoMatcher.collapsedKey("Network"), "network", "a name of only generic words is kept")
    }

    func testBrandsThatDifferByMoreThanSuffixesStayTied() {
        // Two NBC networks with different origins and no country on the channel: not one brand, no decision.
        XCTAssertNil(pick("NBC"))
    }

    // MARK: Rule 2: brand family

    func testFamilyFallsBackToTheParentNetwork() {
        XCTAssertEqual(pick("CA EN: SPORTSNET WORLD HD", groups: ["CA EN|Sports"])?.networkID, 1019)
        XCTAssertEqual(pick("CA EN: GLOBAL NEWS TORONTO HD", groups: ["CA EN|News"])?.networkID, 8834)
        XCTAssertEqual(pick("US: CBS NEWS NEW YORK", groups: ["US|News"])?.networkID, 9)
        XCTAssertEqual(pick("US: FOX 10 LOCAL", groups: ["US|Local"])?.networkID, 11)
        XCTAssertEqual(pick("CA EN: CTV2 LONDON HD", groups: ["CA EN|Local"])?.networkID, 111)
    }

    func testExactEntryBeatsTheFamilyParent() {
        // "Sportsnet One" exists, so "SPORTSNET ONE" is an exact name and not the Sportsnet parent.
        XCTAssertEqual(pick("CA EN: SPORTSNET ONE HD", groups: ["CA EN|Sports"])?.networkID, 123)
        XCTAssertEqual(pick("CA EN: SPORTSNET ONE HD", groups: ["CA EN|Sports"])?.rule, .exactName)
    }

    func testFamilyDoesNotInventAParentWhenTheTailIsAnotherWord() {
        XCTAssertNil(pick("CA EN: CTV SPORTS BAR", groups: ["CA EN|Sports"]))
    }

    // MARK: Rule 3: carrier and owner prefixes

    func testCarrierPrefixIsDroppedOnlyWhenAnotherBrandFollows() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.removingCarrier("ROGERS SPORTSNET ONE"), "SPORTSNET ONE")
        XCTAssertNil(LiveTVTMDbLogoMatcher.removingCarrier("BELL"), "a lone carrier is its own brand")
        XCTAssertEqual(pick("CA EN: ROGERS SPORTSNET ONE HD", groups: ["CA EN|Sports"])?.networkID, 123)
    }

    // MARK: Rule 4 and the channel kind: events, shows, FAST

    func testBundlesAreEventSlotsNotChannels() {
        XCTAssertEqual(LiveTVChannelKind.classify(name: "ROGERS SUPER SPORTS PACK 12", groups: ["CA|Sports"]), .event)
        XCTAssertTrue(matcher.candidates(for: .init(name: "ROGERS SUPER SPORTS PACK 12")).isEmpty)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "US: UFC 300 PPV EVENT 4", groups: []), .event)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "US: GAME (2026-11-21 20:00)", groups: []), .event)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "US: ESPN", groups: ["US|PPV"]), .event)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "CA EN: CBC CALGARY HD", groups: ["CA EN|News"]), .linear)
    }

    func testSingleShowChannelsAreRecognisedByPrefixOrGroup() {
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "24/7: NCIS 4K", groups: []), "NCIS")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "US: COBRA KAI 4K", groups: ["US| CINEMA TV SHOWS"]), "COBRA KAI")
        XCTAssertEqual(LiveTVChannelKind.showLoopTitle(name: "ONEPLAY Paw Patrol", groups: ["US| 24/7 ONEPLAY"]), "Paw Patrol")
        XCTAssertNil(LiveTVChannelKind.showLoopTitle(name: "AL PACINO", groups: ["US| 24/7 MOVIES/ACTORS"]), "actors are not shows")
        XCTAssertNil(LiveTVChannelKind.showLoopTitle(name: "US: ESPN", groups: ["US|Sports"]))
        XCTAssertEqual(LiveTVChannelKind.classify(name: "AT&T: STINGRAY HITS", groups: []), .fast)
        XCTAssertEqual(LiveTVChannelKind.classify(name: "US: HULU ORIGINALS 3", groups: []), .fast)
    }

    func testShowTitleMatchIsExactYearAwareAndRefusesAmbiguity() {
        typealias C = TMDbShowTitleMatch.Candidate
        let office = [
            C(id: 1, name: "The Office", originalName: "The Office", firstAirYear: 2005, popularity: 90),
            C(id: 2, name: "The Office", originalName: "The Office", firstAirYear: 2001, popularity: 20)
        ]
        XCTAssertEqual(TMDbShowTitleMatch.select(title: "OFFICE", candidates: office), 1, "a leading The is ignored; 4.5x more popular wins")
        XCTAssertEqual(TMDbShowTitleMatch.select(title: "The Office 2001", candidates: office), 2)
        let tied = [C(id: 3, name: "Big Brother", originalName: "", firstAirYear: 2000, popularity: 30),
                    C(id: 4, name: "Big Brother", originalName: "", firstAirYear: 2010, popularity: 20)]
        XCTAssertNil(TMDbShowTitleMatch.select(title: "BIG BROTHER", candidates: tied))
        XCTAssertNil(TMDbShowTitleMatch.select(title: "BIG", candidates: tied), "a prefix of a title is not the title")
        XCTAssertEqual(TMDbShowTitleMatch.query(from: "TEENAGE MUTANT NINJA TURTLES 2003").year, 2003)
        XCTAssertEqual(TMDbShowTitleMatch.query(from: "1923").year, nil, "a title that is only a year keeps its name")
    }

    func testBestShowLogoIsHighestVotedEnglishOrLanguageless() {
        typealias L = TMDbNetworkLogoClient.ShowImagesResponse.Logo
        let logos = [L(file_path: "/de.png", iso_639_1: "de", vote_average: 9, width: 900),
                     L(file_path: "/a.png", iso_639_1: "en", vote_average: 5, width: 500),
                     L(file_path: "/b.png", iso_639_1: nil, vote_average: 7, width: 300),
                     L(file_path: nil, iso_639_1: "en", vote_average: 10, width: 1)]
        XCTAssertEqual(TMDbNetworkLogoClient.bestShowLogo(logos), "/b.png")
        XCTAssertNil(TMDbNetworkLogoClient.bestShowLogo([]))
    }

    // MARK: Affiliates, group brands, the curated table

    func testAffiliateCallSignsAndGroupBrands() {
        XCTAssertEqual(pick("US: NBC (KDEN) DENVER", groups: ["US|Locals"])?.networkID, 6)
        XCTAssertEqual(pick("US: KSL NBC 5 SALT LAKE CITY", groups: ["US|Locals"])?.networkID, 6)
        XCTAssertNil(pick("US: KSL 5 SALT LAKE CITY", groups: ["US|Locals"]), "no network name, no match")
        XCTAssertNotEqual(pick("US: NBC OXYGEN (WEST)", groups: ["US|Entertainment"])?.networkID, 6, "(WEST) is a feed, not a call sign")
    }

    func testCuratedEntryBeatsHeuristicsAndNeedsExactBrandOrAFamilyTail() {
        XCTAssertEqual(pick("CA EN: SUPER CHANNEL FUSE HD", groups: ["CA EN|Movies"])?.networkID, 783)
        XCTAssertEqual(pick("CA EN: CRAVE 2 / TMN 2 HD", groups: ["CA EN|Movies"])?.networkID, 1344)
        XCTAssertEqual(pick("US: NBC CNBC (EAST)", groups: ["US|News"])?.networkID, 175)
        XCTAssertEqual(pick("US: NBC TELEMUNDO (KDEN)", groups: ["US|Locals"])?.networkID, 193)
        XCTAssertEqual(pick("US: STARZ ENCORE BLACK", groups: ["US|Movies"])?.networkID, 318)
        XCTAssertEqual(pick("US: HBO HITS EAST", groups: ["US|Movies"])?.networkID, 49)
        XCTAssertEqual(pick("CA EN: ICI TELE OTTAWA-GATINEAU", groups: ["CA FR|Local"])?.networkID, 141)
    }

    func testEveryCuratedEntryIdentifiesItsLogoSource() {
        for row in LiveTVCuratedBrands.table {
            XCTAssertTrue(row.tmdb != nil || row.qid != nil, "\(row.name) has neither a TMDB ID nor a Wikidata item")
            if let qid = row.qid { XCTAssertTrue(qid.hasPrefix("Q"), row.name) }
        }
        XCTAssertEqual(LiveTVCuratedBrands.entries.count, LiveTVCuratedBrands.table.count, "keys are unique")
    }

    // MARK: Real-device misses (store from the user's simulator)

    func testTSNChannelsOneToFiveTakeTheSportsNetwork() {
        for number in 1...5 {
            XCTAssertEqual(pick("CA: TSN\(number) ⁽ᴮᴷ⁾ ᴿᴬᵂ", groups: ["CA| SPORTS"])?.networkID, 641, "TSN\(number)")
            XCTAssertEqual(pick("CA EN: TSN \(number) HD", groups: ["CA EN|Sports"])?.networkID, 641, "TSN \(number)")
        }
    }

    func testSportsnetOneAnd360TakeSportsnet() {
        XCTAssertEqual(pick("CA EN: SPORTSNET ONE HD", groups: ["CA EN|Sports"])?.networkID, 123)
        XCTAssertEqual(pick("CA EN: SPORTSNET 360 HD", groups: ["CA EN|Sports"])?.networkID, 1019)
        XCTAssertEqual(pick("CA EN: SPORTSNETONE HD", groups: ["CA EN|Sports"])?.networkID, 123, "glued names are split")
    }

    func testFoxNewsIsNeverFoxEvenWhenTMDBNamesItFoxNewsChannel() {
        XCTAssertEqual(pick("US: FOX NEWS HD", groups: ["US|News"])?.networkID, 45)
        XCTAssertEqual(pick("AT&T: FOX NEWS ᴿᴬᵂ")?.networkID, 45)
        XCTAssertEqual(pick("US: FOXNEWS", groups: ["US|News"])?.networkID, 45)
        XCTAssertEqual(pick("US: FOX 9 (KMSP) MINNEAPOLIS HD", groups: ["US|Locals"])?.networkID, 11, "a local FOX station keeps FOX")
        // Without the Fox News network in the directory FOX NEWS finds nothing, not FOX.
        let withoutFoxNews = LiveTVTMDbLogoMatcher(networks: Self.directory.filter { $0.0 != 45 }.map { TMDbNetworkEntry(id: $0.0, name: $0.1) })
        let candidates = withoutFoxNews.candidates(for: .init(name: "US: FOX NEWS HD", groups: ["US|News"]))
        XCTAssertFalse(candidates.contains { $0.networkID == 11 })
    }

    func testOmniChannelsTakeOmni() {
        for name in ["CA EN: OMNI 1", "CA EN: OMNI 2", "CA EN: OMNI TELEVISION", "CA EN: OMNITELEVISION HD"] {
            XCTAssertEqual(pick(name, groups: ["CA EN|Multicultural"])?.networkID, 2636, name)
        }
    }

    func testCraveOneToFourTakeCrave() {
        for number in 1...4 { XCTAssertEqual(pick("CA EN: CRAVE\(number) HD", groups: ["CA EN|Movies"])?.networkID, 1344, "CRAVE\(number)") }
    }

    func testCTV2CitiesTakeCTV2() {
        for city in ["ATLANTIC", "BARRIE", "LONDON", "WINDSOR", "OTTAWA", "TORONTO"] {
            XCTAssertEqual(pick("CA EN: CTV2 \(city) HD", groups: ["CA EN|Local"])?.networkID, 111, city)
        }
    }

    func testProviderTypoOfACityIsStrippedOnlyWhenTheCityIsUnique() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: CTV CALARY NEWS"), "CTV")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: CTV CALGARY NEWS"), "CTV")
        XCTAssertEqual(pick("CA EN: CTV CALARY NEWS", groups: ["CA EN|News"])?.networkID, 110)
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: GLOBAL NEWS"), "GLOBAL NEWS", "NEWS alone is part of the brand")
        XCTAssertFalse(LiveTVTMDbLogoMatcher.uniqueMisspelledPlace("CHANNEL"), "an ordinary word is not a typo of a place")
        XCTAssertTrue(LiveTVTMDbLogoMatcher.uniqueMisspelledPlace("WINIPEG"))
    }

    // MARK: CA unmatched queue (pass 1-4)

    func testSeparatorsBecomeSpaces() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("CA EN: MUCH_MUSIC"), "MUCH MUSIC")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("CA FR: TSN/RDS EXTRA 1"), "TSN RDS EXTRA 1")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("US: 24/7 MOVIES"), "24/7 MOVIES")
        XCTAssertEqual(pick("CA FR: TSN/RDS EXTRA 3")?.networkID, 641)
    }

    func testSpellingFixOnlyForAUniqueNeighbourOfSixOrMoreLetters() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.correctingSpelling("CRIME + INVERSTIGATION"), "CRIME + INVESTIGATION")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.correctingSpelling("CRIME + INVESTIGATION"), "CRIME + INVESTIGATION")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.correctingSpelling("MOVIES"), "MOVIES", "short words are never corrected")
    }

    func testRogersSuperSportsPackIsAnEventSlotNotAChannel() {
        XCTAssertEqual(LiveTVChannelKind.classify(name: "CA EN: ROGERS SUPER SPORTS PACK 12 ᴴᴰ", groups: ["CA| ROGERS SUPER SPORTS PACK EN"]), .event)
    }

    func testCTVNewsLiveEventsTakeCTVNews() {
        for number in 1...6 { XCTAssertEqual(pick("CA EN: CTV NEWS LIVE EVENTS \(number) HD", groups: ["CA EN|News"])?.networkID, 673) }
    }

    func testBrandsTMDBListsUnderAForeignOriginAreCuratedForCanadianChannels() {
        let cases: [(String, Int)] = [
            ("CA EN: A&E CANADA HD", 129), ("CA EN: NBA TV HD", 301), ("CA EN: MAV TV HD", 796), ("CA EN: SPORTSMAN HD", 957),
            ("CA EN: TCM", 408), ("CA EN: UNIVISION HD", 28), ("CA EN: VISION HD", 237), ("CA FR: AHC", 1430),
            ("CA FR: CGTN", 6360), ("CA FR: EWTN", 6726), ("CA FR: FRANCE 24", 8148), ("CA EN: DISCOVERY VELOCITY HD", 435),
            ("CA EN: CRIME + INVERSTIGATION", 2392), ("CA FR: CANAL SAVOIR", 2798), ("CA FR: ICI MONTREAL", 141),
            ("CA FR: ICI VANCOUVER", 141), ("CA FR: ICI TELEVISION HD", 141), ("CA FR: ICI RADIO TELE TORONTO HD", 141),
            ("CA FR: NOOVO V-TELE HD", 4161), ("CA FR: TV5 HD", 1533), ("CA FR: TV 5 QUÉBEC  HD", 1533), ("CA FR: TV5 MONDE INFO", 2922),
            ("CA FR: TV5 MONDE STYLE", 2922), ("CA FR: BABY TV", 5770)
        ]
        for (name, id) in cases { XCTAssertEqual(pick(name, groups: [])?.networkID, id, name) }
    }

    func testCountryBoundCuratedEntryDoesNotTakeOtherCountries() {
        XCTAssertNil(LiveTVTMDbLogoMatcher.curatedEntry(for: .init(name: "PH: TV5 HD", groups: [])), "TV5 is Québec's only for a Canadian channel")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.curatedEntry(for: .init(name: "CA FR: TV5 HD", groups: []))?.tmdbNetworkID, 1533)
    }

    func testWikidataOnlyCuratedBrands() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.curatedEntry(for: .init(name: "CA EN: CITY NEWS TORONTO ON HD", groups: []))?.wikidataQID, "Q5122969")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.curatedEntry(for: .init(name: "CA FR: TRACE URBAN", groups: []))?.wikidataQID, "Q1755296")
        XCTAssertNil(LiveTVTMDbLogoMatcher.curatedEntry(for: .init(name: "CA FR: TRACE AFRICA", groups: [])), "no Wikidata item for the other Trace channels")
    }

    // MARK: Found by the iptv-org evaluation

    func testWikidataItemsAreNeverResolvedThroughCuratedTMDBIDs() {
        // Pseudo-network 227 is an unrelated item; the curated MSG row names TMDB network 227.
        var entries = (0..<300).map { WikidataLogoEntry(qid: "Q\($0)", label: "Unrelated \($0)", altLabels: [], file: "A.svg") }
        entries[227] = WikidataLogoEntry(qid: "Q9999", label: "WKOF", altLabels: [], file: "WKOF.svg")
        let matcher = LiveTVWikidataLogoMatcher(entries: entries)
        XCTAssertNil(matcher.match(.init(name: "MSG (720p)", groups: []), country: "US"))
        XCTAssertEqual(matcher.match(.init(name: "WKOF", groups: []), country: "US")?.qid, "Q9999")
    }

    func testACuratedUSBrandDoesNotApplyToAChannelOfAnotherCountry() {
        let big10 = LiveTVTMDbCandidate(networkID: 917, networkName: "Big Ten Network", confidence: 1, rule: .curated)
        let origins: [Int: String?] = [917: "US"]
        XCTAssertEqual(LiveTVTMDbLogoMatcher.select(from: [big10], originCountries: origins, channelCountry: "RW"), nil)
        XCTAssertEqual(LiveTVTMDbLogoMatcher.select(from: [big10], originCountries: origins, channelCountry: "US")?.networkID, 917)
        XCTAssertEqual(LiveTVTMDbLogoMatcher.select(from: [big10], originCountries: origins, channelCountry: "CA")?.networkID, 917, "Canadian lineups carry US brands")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.select(from: [big10], originCountries: origins, channelCountry: nil)?.networkID, 917)
        XCTAssertEqual(LiveTVTMDbLogoMatcher.select(from: [big10], originCountries: [917: String?.none], channelCountry: "RW")?.networkID, 917, "unknown origin stays")
    }
}
