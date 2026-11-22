import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Guide matching, round 2: the general signals (id case, loose names, aliases from the guide's own ids, feeds shared between
/// countries, radio, event slots) with names a provider really writes plus other providers' styles. Nothing here is keyed to a
/// provider; the data tables are `LiveTVGuideStationData`.
@MainActor
final class LiveTVGuideMatchRound2Tests: XCTestCase {
    private func channel(_ id: String, _ name: String, group: String = "CA| CANADA", guideID: String? = nil, country: String? = nil, language: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: guideID, language: language, country: country, groups: [group])
    }

    /// Station ids as a standard XMLTV carries them; display names only where noted.
    private let guide: [String: [String]] = [
        "CTVCalgary.ca": [], "ctvcalgary.ca": [], "CTVNC.ca": ["CTV News Channel"], "GlobalBC.ca": ["Global BC"],
        "CookingChannel.ca": [], "GlobalCalgary.ca": [], "CBC.ca": [], "TheWeatherNetwork.ca": [], "CasaTV.ca": [], "HBO2.ca": [], "RDS.ca": [], "RDINews.ca": [],
        "ICITeleMontreal.ca": [], "Explora.ca": [], "CBCNews.ca": [], "CityTVToronto.ca": [],
        "CNN.us": [], "cnn.ar": [], "cnn.il": [], "FoxNews.us": [], "TCM.es": [], "TCM.fr": [], "BET.us": [],
        "TVO.ch": [], "ONE.mt": [], "MAVTV.us": [], "CNBC.us": [], "CNBC.uk": [], "AMC.us": [], "AMC.ca": [],
        "TVOne.us": [], "BBCOne.uk": ["BBC One"], "Dave.uk": []
    ]

    private func index() -> LiveTVGuideStationIndex { LiveTVGuideStationIndex(guideChannels: guide) }

    // MARK: Names

    func testNamesAreReadWithAccentsHyphensSpacesAndBracketTagsFolded() {
        let index = index()
        XCTAssertEqual(index.resolve(name: "CA FR: ICI RADIO-CANADA TÉLÉ MONTREAL HD", country: "CA"), "ICITeleMontreal.ca")
        XCTAssertEqual(index.resolve(name: "CA FR: ICI  RADIO CANADA TELE  MONTREAL", country: "CA"), "ICITeleMontreal.ca")
        XCTAssertEqual(index.resolve(name: "CA EN: HBO 2 (R)", country: "CA"), "HBO2.ca")
        XCTAssertEqual(index.resolve(name: "CA EN: HBO2 (CA)", country: "CA"), "HBO2.ca")
        XCTAssertEqual(index.resolve(name: "CA: HBO 2 [FR]", country: "CA"), "HBO2.ca")
        XCTAssertEqual(index.resolve(name: "CA FR: ICI EXPLORA HD", country: "CA"), "Explora.ca", "the brand word ici is generic")
    }

    func testOtherSeparatorStylesGiveTheSameStation() {
        let index = index()
        for name in ["CA| THE COOKING CHANNEL HD", "CA - Cooking Channel", "[CA] COOKING CHANNEL ᴴᴰ", "Cooking Channel FHD", "CA|EN| COOKING CHANNEL"] {
            XCTAssertEqual(index.resolve(name: name, country: "CA"), "CookingChannel.ca", name)
        }
        XCTAssertEqual(index.resolve(name: "CA EN: WEATHER NETWORK", country: "CA"), "TheWeatherNetwork.ca", "camel-case id read as words")
        XCTAssertEqual(index.resolve(name: "CA FR: CASA", country: "CA"), "CasaTV.ca", "tv is a generic word")
        XCTAssertEqual(index.resolve(name: "CA EN: GLOBAL NEWS CALGARY HD", country: "CA"), "GlobalCalgary.ca", "an alias from the guide's own ids")
        XCTAssertNil(index.resolve(name: "CA: ONE", country: "CA"), "a loose key of three letters is not read")
        XCTAssertNil(LiveTVGuideStationIndex(guideChannels: ["SkySportsNews.uk": [], "SkySports.us": []]).resolve(name: "UK: SKY SPORTS +", country: "GB"), "news is not a generic word")
        XCTAssertEqual(index.resolve(name: "CA EN: CBC NEWS NETWORK", country: "CA"), "CBCNews.ca", "the exact key wins over the loose one")
    }

    func testAliasesComeFromTheGuidesOwnIDs() {
        let index = index()
        XCTAssertEqual(index.resolve(name: "CA EN: GLOBAL VANCOUVER", country: "CA"), "GlobalBC.ca")
        XCTAssertEqual(index.resolve(name: "CA EN: CTV NEWS CHANNEL HD", country: "CA"), "CTVNC.ca")
        XCTAssertEqual(index.resolve(name: "CA: RDS 1", country: "CA"), "RDS.ca")
        XCTAssertEqual(index.resolve(name: "CA FR: ICI RDI HD", country: "CA"), "RDINews.ca")
        XCTAssertEqual(index.resolve(name: "CA EN: CTV CALGARY", country: "CA"), "CTVCalgary.ca", "same stem in two spellings: the plain id wins")
    }

    func testADisplayNameOnlyGuideIsMatchedByItsNames() {
        let index = LiveTVGuideStationIndex(guideChannels: ["ch-17": ["Comedy Central", "Comedy Central HD"], "ch-18": ["Paramount Network"]])
        XCTAssertEqual(index.resolve(name: "US| COMEDY CENTRAL 4K", country: nil), "ch-17")
        XCTAssertEqual(index.resolve(name: "PARAMOUNT NETWORK", country: nil), "ch-18")
    }

    // MARK: Shared feeds

    func testACanadianRowUsesTheUSFeedOfAnInternationalNetworkInItsLanguage() {
        let index = index()
        for name in ["CA EN: CNN HD", "CA: CNN", "CA EN: FOX NEWS HD", "CA EN: MAV TV HD", "CA: BET"] {
            XCTAssertEqual(index.resolution(name: name, country: "CA")?.method, .foreignFeed, name)
        }
        XCTAssertEqual(index.resolve(name: "CA EN: CNN HD", country: "CA"), "CNN.us", "not Argentina's or Israel's CNN")
        XCTAssertEqual(index.resolve(name: "CA: CNBC", country: "CA"), "CNBC.us", "the country's own order, US before UK")
    }

    func testAForeignFeedIsDeclinedWhenItsLanguageOrCountryIsNotShared() {
        let index = index()
        XCTAssertNil(index.resolve(name: "CA FR: BET", country: "CA"), "US feed is English")
        XCTAssertNil(index.resolve(name: "CA EN: TCM", country: "CA"), "only Spanish and French feeds exist")
        XCTAssertNil(index.resolve(name: "CA: TVO", country: "CA"), "TVO.ch is Swiss")
        XCTAssertNil(index.resolve(name: "CA: ONE", country: "CA"), "ONE.mt is Maltese, TVOne.us is not ONE")
        XCTAssertNil(index.resolve(name: "UK: CNN", country: "GB"), "the UK shares no feeds")
        XCTAssertEqual(index.resolution(name: "CA EN: AMC HD", country: "CA")?.method, .displayName, "its own feed wins over the shared one")
        XCTAssertEqual(index.resolve(name: "CA EN: AMC HD", country: "CA"), "AMC.ca")
    }

    func testARowLanguageFromTheProviderFieldDecidesWhenTheNameHasNone() {
        let index = index()
        XCTAssertEqual(index.resolve(name: "CA: BET", country: "CA", language: "EN"), "BET.us")
        XCTAssertNil(index.resolve(name: "CA: BET", country: "CA", language: "FR"))
    }

    func testAnAmbiguousNameGivesNoStation() {
        let ambiguous = LiveTVGuideStationIndex(guideChannels: ["Sport1.ca": ["Sport"], "Sport2.ca": ["Sport"], "Sport.us": []])
        XCTAssertNil(ambiguous.resolve(name: "CA: SPORT", country: "CA"), "two different Canadian stations claim it")
        XCTAssertEqual(ambiguous.resolve(name: "US: SPORT", country: "US"), "Sport.us")
    }

    // MARK: Matcher sources

    func testTheMatchSourceIsRecorded() {
        let rows = [
            channel("exact", "CA EN: CTV CALGARY", guideID: "CTVCalgary.ca"),
            channel("case", "CA EN: CTV HALIFAX", guideID: "CTVHALIFAX.CA"),
            channel("name", "CA EN: THE COOKING CHANNEL"),
            channel("foreign", "CA EN: CNN HD")
        ]
        var stations = guide
        stations["ctvhalifax.ca"] = []
        let result = LiveTVGuideMatcher().matching(channels: rows, guideChannels: stations, trustsGuideIDs: true)
        XCTAssertEqual(result.assignments["exact"]?.method, .exactID)
        XCTAssertEqual(result.assignments["case"]?.method, .idCase)
        XCTAssertEqual(result.assignments["case"]?.guideChannelID, "ctvhalifax.ca")
        XCTAssertEqual(result.assignments["name"]?.method, .displayName)
        XCTAssertEqual(result.assignments["foreign"]?.method, .foreignFeed)
        XCTAssertLessThan(LiveTVGuideMatchMethod.foreignFeed, .displayName)
        XCTAssertLessThan(LiveTVGuideMatchMethod.idCase, .exactID)
        XCTAssertGreaterThan(LiveTVGuideMatchMethod.idCase, .nativeID)
    }

    func testAnIDWithNoListingsFallsThroughToTheNameInCoverage() {
        let rows = [channel("a", "CA EN: THE COOKING CHANNEL", guideID: "Missing.ca"), channel("b", "CA EN: CASA", guideID: "CasaTV.ca")]
        let coverage = LiveTVGuideCoverage.measure(
            channels: rows, stations: ["CookingChannel.ca": [], "CasaTV.ca": [], "Missing.ca": []], stationsWithListings: ["CookingChannel.ca"])
        XCTAssertEqual(coverage.matched, 1)
        XCTAssertEqual(coverage.sources["name"], 1)
        XCTAssertEqual(coverage.unmatched.map(\.id), ["b"])
        XCTAssertEqual(coverage.providerGaps.map(\.id), ["b"], "its own station has no listings: the provider's gap")
    }

    func testCoverageSeparatesProviderGapsFromMatcherMisses() {
        let rows = [
            channel("gap", "CA EN: GLOBAL NEWS KINGSTON HD"),
            channel("miss", "CA FR: BET"),
            channel("ok", "CA EN: CNN")
        ]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: guide)
        XCTAssertEqual(coverage.matched, 1)
        XCTAssertEqual(coverage.sources["name-foreign-feed"], 1)
        XCTAssertEqual(Set(coverage.unmatched.map(\.id)), ["gap", "miss"])
        XCTAssertEqual(coverage.providerGaps.map(\.id), ["gap"], "BET.us exists, a rule declined it")
        XCTAssertTrue(coverage.logLine.contains("radio=0 replay=0 foreign=0 sources=id:0,id-case:0,name:0,name-foreign-feed:1 channels="))
        XCTAssertFalse(coverage.logLine.contains("UK:"), "countries are ISO codes")
    }

    // MARK: GB rules (provider ids, time shifts, regions)

    private let gbGuide: [String: [String]] = [
        "bbc1.uk": [], "BBCTwoWales.uk": [], "BBCOneNorthernIreland.uk": [], "BBCOneWales.uk": [], "BBCOneNorthWest.uk": [], "BBCOneOxford.uk": [], "BBC2.uk": [], "ITV2.uk": [], "E4.uk": [],
        "E4plus1.uk": [], "More4.uk": [], "tntsports1.uk": [], "SkySports2.uk": [], "NatGeo.uk": [], "DiscoveryChannel.uk": [], "TS": []
    ]

    private func gb(_ id: String, _ name: String, guideID: String? = nil) -> LiveTVPrototypeChannel {
        channel(id, name, group: "UK| GENERAL", guideID: guideID)
    }

    private func gbMatch(_ rows: [LiveTVPrototypeChannel]) -> [String: LiveTVGuideMatch] {
        LiveTVGuideMatcher().matching(channels: rows, guideChannels: gbGuide, trustsGuideIDs: true).assignments
    }

    func testAProviderIDOfAnotherRegionIsVetoedAndTheNameIsRead() {
        let result = gbMatch([
            gb("wales", "UK: BBC ONE WALES 4K ◉", guideID: "BBCOneNorthWest.uk"),
            gb("london", "UK: BBC ONE LONDON 4K ◉", guideID: "BBCOneOxford.uk"),
            gb("ok", "UK: BBC ONE NORTH WEST", guideID: "BBCOneNorthWest.uk"),
            gb("two", "UK: BBC TWO HD ◉", guideID: "BBCTwoWales.uk"),
            gb("ni", "UK: BBC ONE NI HD ◉", guideID: "bbc1.uk")
        ])
        XCTAssertEqual(result["two"]?.guideChannelID, "BBC2.uk", "the id names a region the row does not")
        XCTAssertEqual(result["ni"]?.guideChannelID, "BBCOneNorthernIreland.uk", "NI is northern ireland; the national id is not its feed")
        XCTAssertEqual(result["wales"]?.guideChannelID, "BBCOneWales.uk")
        XCTAssertEqual(result["wales"]?.method, .displayName)
        XCTAssertEqual(result["london"]?.guideChannelID, "bbc1.uk", "London is the default region; Oxford is another")
        XCTAssertEqual(result["ok"]?.method, .exactID, "the id agrees with the name")
    }

    func testAProviderIDOfAnotherChannelNumberIsVetoed() {
        let result = gbMatch([gb("n", "UK: SKY SPORTS 1", guideID: "SkySports2.uk"), gb("same", "UK: SKY SPORTS 2", guideID: "SkySports2.uk")])
        XCTAssertNil(result["n"], "SkySports2 is not Sky Sports 1, and the guide has no other")
        XCTAssertEqual(result["same"]?.guideChannelID, "SkySports2.uk")
    }

    func testAPlaceholderIDIsNoID() {
        XCTAssertTrue(LiveTVGuideStationIndex.isPlaceholderID("TS"))
        XCTAssertTrue(LiveTVGuideStationIndex.isPlaceholderID(" tbd "))
        XCTAssertFalse(LiveTVGuideStationIndex.isPlaceholderID("E4.uk"))
        let result = gbMatch([gb("more4", "UK: MORE4 ◉", guideID: "TS"), gb("e4", "UK: E4", guideID: "TS")])
        XCTAssertEqual(result["more4"]?.guideChannelID, "More4.uk", "TS is not read as a station even when the guide has one")
        XCTAssertEqual(result["more4"]?.method, .displayName)
        XCTAssertEqual(result["e4"]?.guideChannelID, "E4.uk")
    }

    func testTimeShiftedRowsAreLeftUnmatched() {
        for name in ["UK: E4 +1 ◉", "UK: ITV 2+1 ◉", "UK: NATIONAL GEOGRAPHIC +1 ◉", "UK: DISCOVERY +6H"] {
            XCTAssertTrue(LiveTVGuideStationIndex.isTimeShifted(name), name)
        }
        for name in ["UK: SKY SPORTS +", "UK: AMC+ 4K", "US: ESPN+ 2", "UK: E4", "CA: HBO2"] {
            XCTAssertFalse(LiveTVGuideStationIndex.isTimeShifted(name), name)
        }
        let result = gbMatch([
            gb("e4", "UK: E4 +1 ◉", guideID: "E4.uk"), gb("itv2", "UK: ITV 2+1", guideID: "ITV2.uk"),
            gb("geo", "UK: NATIONAL GEOGRAPHIC +1", guideID: "TS"), gb("own", "UK: E4 +1", guideID: "E4plus1.uk")
        ])
        XCTAssertEqual(result["e4"]?.guideChannelID, "E4plus1.uk", "the guide has its own +1 feed, found by name"); XCTAssertNil(result["itv2"]); XCTAssertNil(result["geo"])
        XCTAssertEqual(result["own"]?.guideChannelID, "E4plus1.uk", "a station of its own shift serves it")
    }

    func testNameVariantsForUKNamesAndNoFuzzyFallback() {
        let result = gbMatch([
            gb("one", "UK: BBC ONE"), gb("two", "UK: BBC TWO HD"), gb("tnt", "UK: TNT SPORT 1 HEVC 4K"), gb("tnt5", "UK: TNT SPORT 5"),
            gb("geo", "UK: NATIONAL GEOGRAPHIC ᴿᴬᵂ"), gb("disc", "UK: DISCOVERY HEVC HD"), gb("typo", "UK: ITV TWOO")
        ])
        XCTAssertEqual(result["one"]?.guideChannelID, "bbc1.uk", "number word and digit")
        XCTAssertEqual(result["two"]?.guideChannelID, "BBC2.uk")
        XCTAssertEqual(result["tnt"]?.guideChannelID, "tntsports1.uk", "sport/sports")
        XCTAssertNil(result["tnt5"], "a near name is not a match")
        XCTAssertEqual(result["geo"]?.guideChannelID, "NatGeo.uk")
        XCTAssertEqual(result["disc"]?.guideChannelID, "DiscoveryChannel.uk")
        XCTAssertNil(result["typo"])
    }

    func testForeignPrefixesAndReplaySlotsAreNotInTheLinearDenominator() {
        let rows = [
            gb("uk", "UK: E4"), gb("ua", "UA: MEGA"), gb("replay", "UK: SKY CINEMA RED BUTTON 1"), gb("us", "TV: ESPN"),
            channel("vod", "UK: SERIES WORLD", group: "UK| REPLAY SERIES")
        ]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: gbGuide)
        XCTAssertEqual(coverage.foreign, 1)
        XCTAssertEqual(coverage.replay, 2)
        XCTAssertEqual(coverage.linear, 2, "E4 and the TV: package row")
        XCTAssertEqual(coverage.matched, 1)
    }

    // MARK: US rules (call signs, feed markers, local stations)

    private let usGuide: [String: [String]] = [
        "KPIX.us": [], "WBZ.us": [], "WTIC.us": [], "KHON.us": [], "WZTVDT2.us": [], "WTVD.us": [], "abc11wtvd.us": [], "WCBS.us": [],
        "HBO.us": [], "HBOWest.us": [], "CartoonNetwork.us": [], "BET.us": [], "SkyKids.us": [], "CBeebies.us": [], "FOXNews.us": [],
        "WestPalmBeach.us": [], "IndependentFilmChannel.us": [], "ESPNNews.us": [], "EEntertainment.us": [], "KIDS.us": []
    ]

    private func us(_ id: String, _ name: String, guideID: String? = nil) -> LiveTVPrototypeChannel {
        channel(id, name, group: "US| GENERAL", guideID: guideID)
    }

    private func usMatch(_ rows: [LiveTVPrototypeChannel]) -> [String: LiveTVGuideMatch] {
        LiveTVGuideMatcher().matching(channels: rows, guideChannels: usGuide, trustsGuideIDs: true).assignments
    }

    func testCallSignsAreReadFromNames() {
        let cases: [(String, String?)] = [
            ("US: CBS (WSBK) BOSTON HD", "wsbk"), ("US: FOX HARTFORD (WTIC)", "wtic"), ("TV: DENVER, CO KMGH ABC 7 A3 HD (D11)", "kmgh"),
            ("US: NBC 4 (KARK-DT2) LITTLE ROCK", "kark"), ("US: CBS WCBS-TV NEW YORK", "wcbs"), ("US: FOX WEST HD", nil),
            ("US: KIDS CHANNEL", nil), ("US: WWE NETWORK", nil), ("US: HBO WEST", nil)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(LiveTVGuideStationIndex.callSign(in: name)?.base, expected, name)
        }
        XCTAssertEqual(LiveTVGuideStationIndex.callSign(in: "US: CBS (WZTV-DT2)")?.full, "wztvdt2")
        XCTAssertEqual(LiveTVGuideStationIndex.callSign(ofStem: "abc11wtvd")?.base, "wtvd")
        XCTAssertEqual(LiveTVGuideStationIndex.callSign(ofStem: "wztvdt2")?.full, "wztvdt2")
        XCTAssertNil(LiveTVGuideStationIndex.callSign(ofStem: "espn"))
    }

    func testACallSignMatchesItsStationAndRefusesAnotherMarketsID() {
        let result = usMatch([
            us("sign", "US: CBS (WBZ) BOSTON HD"), us("dt", "US: CW (WZTV-DT2) NASHVILLE"), us("net", "US: ABC 11 (WTVD) RALEIGH HD"),
            us("conflict", "US: FOX HARTFORD (WTIC)", guideID: "KHON.us"), us("wrong", "US: CBS 5 (KENS) SAN ANTONIO HD", guideID: "KPIX.us"),
            us("gap", "US: CBS (WGCL) ATLANTA", guideID: "WBZ.us"), us("agree", "US: FOX 2 (KHON) HONOLULU", guideID: "KHON.us")
        ])
        XCTAssertEqual(result["sign"]?.guideChannelID, "WBZ.us")
        XCTAssertEqual(result["dt"]?.guideChannelID, "WZTVDT2.us")
        XCTAssertEqual(result["net"]?.guideChannelID, "WTVD.us")
        XCTAssertEqual(result["conflict"]?.guideChannelID, "WTIC.us", "the call sign wins over another market's id")
        XCTAssertNil(result["wrong"], "KENS has no station and KPIX is another market")
        XCTAssertNil(result["gap"])
        XCTAssertEqual(result["agree"]?.method, .exactID)
    }

    func testLocalStationsWithoutACallSignStayUnmatched() {
        XCTAssertTrue(LiveTVGuideStationIndex.isLocalWithoutCallSign("US: ABC 7 HD [BUFFALO]"))
        XCTAssertTrue(LiveTVGuideStationIndex.isLocalWithoutCallSign("US: FOX NET [WAUSAU]"))
        XCTAssertFalse(LiveTVGuideStationIndex.isLocalWithoutCallSign("US: FOX NEWS"))
        XCTAssertFalse(LiveTVGuideStationIndex.isLocalWithoutCallSign("US: NBC 6 (WTVJ) MIAMI"))
        XCTAssertNil(usMatch([us("fox", "US: FOX NET [WAUSAU]")])["fox"])
        XCTAssertEqual(usMatch([us("news", "US: FOX NEWS HD")])["news"]?.guideChannelID, "FOXNews.us")
    }

    func testEastIsTheBaseFeedAndWestOrPlusNeedTheirOwnStation() {
        let result = usMatch([
            us("east", "US: CARTOON NETWORK EAST HD"), us("west", "US: HBO WEST HD", guideID: "HBO.us"),
            us("westNoID", "US: BET WEST"), us("place", "US: WEST PALM BEACH"), us("plus", "US: HBO +3"),
            us("pacific", "US: CARTOON NETWORK PACIFIC", guideID: "CartoonNetwork.us")
        ])
        XCTAssertEqual(result["east"]?.guideChannelID, "CartoonNetwork.us")
        XCTAssertEqual(result["west"]?.guideChannelID, "HBOWest.us", "the guide has its own west feed")
        XCTAssertNil(result["westNoID"], "BET West is not BET")
        XCTAssertEqual(result["place"]?.guideChannelID, "WestPalmBeach.us", "west as a first word is no feed marker")
        XCTAssertNil(result["plus"])
        XCTAssertNil(result["pacific"])
        XCTAssertTrue(LiveTVGuideStationIndex.isTimeShifted("US: TRUTV WEST 4K"))
        XCTAssertFalse(LiveTVGuideStationIndex.isTimeShifted("US: WEST PALM BEACH"))
    }

    func testAnExactNameBeatsAnUnrelatedProviderID() {
        let result = usMatch([
            us("kids", "US: SKY KIDS HD", guideID: "CBeebies.us"), us("keep", "US: BET HD", guideID: "BET.us"),
            us("acronym", "US: IFC", guideID: "IndependentFilmChannel.us"), us("unknown", "US: SOME SHOW", guideID: "CBeebies.us")
        ])
        XCTAssertEqual(result["kids"]?.guideChannelID, "SkyKids.us")
        XCTAssertEqual(result["kids"]?.method, .displayName)
        XCTAssertEqual(result["keep"]?.method, .exactID)
        XCTAssertEqual(result["acronym"]?.guideChannelID, "IndependentFilmChannel.us")
        XCTAssertEqual(result["unknown"]?.guideChannelID, "CBeebies.us", "no exact name to overrule it")
    }

    func testOnePrefixParserReadsEveryProviderStyle() {
        let styles = ["US: BET", "US:BET", "US | BET", "US|BET", "[US] BET", "(US) BET", "US - BET", "US-BET", "TV: BET", "US EN: BET HD", "US: US BET", "BET HD"]
        for name in styles {
            XCTAssertEqual(usMatch([us("r", name)])["r"]?.guideChannelID, "BET.us", name)
        }
    }

    // MARK: Radio and event slots

    func testRadioIsRecognisedBySignalAndTVBrandsAreKept() {
        for name in ["CA: Best Hits Radio 80's", "CA: CJWV Oldies 96.7 FM", "CA FR: CANAL M FM", "US: KISS 1010 AM", "FM 101.1 Rock", "NL: Sky Radio"] {
            XCTAssertTrue(LiveTVChannelKind.isRadio(name: name), name)
            XCTAssertEqual(LiveTVChannelKind.classify(name: name, groups: ["CA| GENERAL EN"]), .radio, name)
        }
        for name in ["CA FR: ICI RADIO-CANADA TÉLÉ TORONTO", "CA FR: ICI RADIO CANADA TELE VANCOUVER HD", "CA FR: ICI RADIO TELE TORONTO HD",
                     "CA EN: CTV NEWS", "US: AMC HD", "CA EN: CANAL FAMILY", "CA: FAMILY JR"] {
            XCTAssertFalse(LiveTVChannelKind.isRadio(name: name), name)
        }
    }

    func testRadioIsNotInTheLinearCountsOrTheDenominator() {
        let rows = [channel("radio", "CA: CJWV Oldies 96.7 FM"), channel("tv", "CA EN: THE COOKING CHANNEL")]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: guide)
        XCTAssertEqual(coverage.radio, 1)
        XCTAssertEqual(coverage.linear, 1)
        XCTAssertEqual(coverage.byCountry["CA"], .init(matched: 1, total: 1))
        XCTAssertTrue(coverage.logLine.contains(" radio=1 "))
    }

    func testNumberedLiveEventSlotsAreEventsNotLinearAndIdleOnesArePlaceholders() {
        for number in 1...6 {
            let name = "CA EN: CTV NEWS LIVE EVENTS \(number) HD"
            XCTAssertEqual(LiveTVChannelKind.classify(name: name, groups: ["CA| NEWS EN"]), .event, name)
            XCTAssertTrue(LiveTVPlaceholder.isPlaceholder(name: name, groups: ["CA| NEWS EN"], eventGroups: ["CA| NEWS EN"]), "idle: nothing shows")
        }
        XCTAssertEqual(LiveTVChannelKind.classify(name: "CA EN: CTV NEWS CHANNEL HD", groups: ["CA| NEWS EN"]), .linear)
        XCTAssertFalse(LiveTVChannelKind.isEventForLogos(name: "CA EN: CTV NEWS LIVE EVENTS 2 HD", groups: ["CA| NEWS EN"]), "the brand still names it")
        XCTAssertTrue(LiveTVChannelKind.isEventForLogos(name: "CA EN: ROGERS SUPER SPORTS PACK 12 ᴴᴰ", groups: ["CA| ROGERS SUPER SPORTS PACK EN"]))
        let coverage = LiveTVGuideCoverage.measure(
            channels: [channel("event", "CA EN: CTV NEWS LIVE EVENTS 1 HD", group: "CA| NEWS EN")], stations: guide)
        XCTAssertEqual(coverage.linear, 0, "not in the linear denominator")
    }

    // MARK: Real list (env-gated)

    private func value(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[key] ?? env["TEST_RUNNER_" + key]
    }

    /// The provider list, the country-level match report and the match-pass time. Skipped unless `PLOZZ_COVERAGE_CHANNELS` (the
    /// snapshot's `channels.jsonl`) and `PLOZZ_COVERAGE_STATIONS` (one station id per line) are set; `PLOZZ_COVERAGE_REPORT` receives it.
    func testRealListMatchReport() throws {
        guard let channelsPath = value("PLOZZ_COVERAGE_CHANNELS"),
              value("PLOZZ_COVERAGE_STATIONS") != nil || value("PLOZZ_GUIDE_JSONL") != nil else {
            throw XCTSkip("Set PLOZZ_COVERAGE_CHANNELS and PLOZZ_COVERAGE_STATIONS (or PLOZZ_GUIDE_JSONL) to measure a real list.")
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
        // Either the ids with listings (names unknown), or the whole saved guide: every station with its display names, and the
        // stations that have programmes.
        var stations: [String: [String]] = [:]
        var listed = Set<String>()
        if let guidePath = value("PLOZZ_GUIDE_JSONL") {
            for line in try String(contentsOfFile: guidePath, encoding: .utf8).split(separator: "\n") {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if object["type"] as? String == "channel", let id = object["id"] as? String { stations[id] = object["displayNames"] as? [String] ?? [] }
                if object["type"] as? String == "programme", let id = object["channel"] as? String { listed.insert(id) }
            }
        } else if let stationsPath = value("PLOZZ_COVERAGE_STATIONS") {
            for id in try String(contentsOfFile: stationsPath, encoding: .utf8).split(separator: "\n") { stations[String(id)] = [] }
            listed = Set(stations.keys)
        }
        let kept = LiveTVLineupFilter.apply(.standard, to: rows).kept
        let coverage = LiveTVGuideCoverage.measure(channels: kept, stations: stations, stationsWithListings: listed)
        var report = [coverage.logLine]
        report.append("providerGaps\t\(coverage.providerGaps.count)\tmatcherMisses\t\(coverage.unmatched.count - coverage.providerGaps.count)")
        // The match pass alone, over the whole list and over the rows the lineup keeps: median of five.
        func passMedian(_ channels: [LiveTVPrototypeChannel]) -> Int {
            var timings: [Double] = []
            for _ in 0..<5 {
                let start = Date()
                _ = LiveTVGuideMatcher().matching(channels: channels, guideChannels: stations, trustsGuideIDs: true)
                timings.append(Date().timeIntervalSince(start) * 1000)
            }
            return Int(timings.sorted()[2])
        }
        report.append("matchPassMs\tallRows=\(rows.count):\(passMedian(rows))\tkeptRows=\(kept.count):\(passMedian(kept))")
        // By country: matched, the sources, and the misses split into provider gaps and matcher declines.
        for code in ["CA", "US", "GB"] {
            var classifier = LiveTVLineupClassifier()
            let own = kept.filter { if case .country(code) = classifier.placement(of: $0) { true } else { false } }
            let part = LiveTVGuideCoverage.measure(channels: own, stations: stations, stationsWithListings: listed)
            report.append("country\t\(code)\tmatched=\(part.matched)\tlinear=\(part.linear)\tradio=\(part.radio)\tsources=\(part.sources.sorted { $0.key < $1.key })\tproviderGap=\(part.providerGaps.count)\tmatcherMiss=\(part.unmatched.count - part.providerGaps.count)\tchannels=\(part.channelsMatched)/\(part.channelsTotal)")
            // The gap by what the provider could still give: a row whose own id names a station with no listings in the window
            // (the provider could supply those listings), against a row for which the guide has no station at all.
            let noListings = part.providerGaps.filter { $0.guideID.map { stations[$0] != nil } ?? false }
            report.append("gapDetail\t\(code)\tidNamesStationWithoutListings=\(noListings.count)\tnoStationAtAll=\(part.providerGaps.count - noListings.count)")
            // Unmatched time-shifted rows (`+1`, `WEST`) whose base station has listings: what a proven shift could add.
            let listedStations = stations.filter { listed.contains($0.key) }
            let baseIndex = LiveTVGuideStationIndex(guideChannels: listedStations)
            var shiftedWithBase = 0, shiftedTotal = 0
            for row in part.unmatched where LiveTVGuideStationIndex.isTimeShifted(row.guideName ?? row.name) {
                shiftedTotal += 1
                let base = (row.guideName ?? row.name).replacingOccurrences(of: #"(?i)\s*\+\s*\d+\s*h?\b|\s+(west|pacific)\b"#, with: "", options: .regularExpression)
                if baseIndex.resolve(name: base, country: code) != nil { shiftedWithBase += 1 }
            }
            report.append("timeshiftCandidates\t\(code)\tunmatchedShiftedRows=\(shiftedTotal)\twhoseBaseHasListings=\(shiftedWithBase)")
            // The linear rows (the denominator), to reconcile against another count.
            for row in part.linearRows { report.append("linearRow\t\(code)\t\(row.name)\t\(row.categories.first ?? "")") }
            // The provider ids the sibling-tail rule refuses.
            for row in own {
                guard let id = row.guideID, stations[id] != nil else { continue }
                if LiveTVGuideStationIndex.idIsSiblingOfName(id: id, facts: .init(name: row.guideName ?? row.name)) {
                    report.append("siblingVeto\t\(code)\t\(row.name)\t\(id)\t\(listed.contains(id))")
                }
            }
            let assigned = LiveTVGuideMatcher().matching(channels: own, guideChannels: stations, trustsGuideIDs: true).assignments
            for row in own {
                if let match = assigned[row.id], match.method == .displayName || match.method == .foreignFeed || match.method == .idCase {
                    report.append("\(match.method.sourceLabel)\t\(code)\t\(row.name)\t\(match.guideChannelID)")
                }
            }
        }
        // Where the pass spends its time: the lineup classifier and the name split are shared with the old rule, the index is
        // built once, and the name lookups are the new part.
        func median(_ body: () -> Void) -> Double {
            var values: [Double] = []
            for _ in 0..<5 { let start = Date(); body(); values.append(Date().timeIntervalSince(start) * 1000) }
            return values.sorted()[2]
        }
        var placed = LiveTVLineupClassifier()
        let classifierMs = median { var classifier = LiveTVLineupClassifier(); for row in rows { _ = classifier.placement(of: row) }; placed = classifier }
        _ = placed
        let splitMs = median { for row in rows { _ = IPTVChannelName.split(row.guideName ?? row.name) } }
        var built: LiveTVGuideStationIndex?
        let indexMs = median { built = LiveTVGuideStationIndex(guideChannels: stations) }
        let lookups = rows.map { $0.guideName ?? $0.name }
        let lookupMs = median { for name in lookups { _ = built?.resolution(name: name, country: "CA") } }
        report.append("components(ms, median of 5, \(rows.count) rows)\tclassifier=\(Int(classifierMs))\tsplit=\(Int(splitMs))\tindexBuild=\(Int(indexMs))\tnameLookups=\(Int(lookupMs))")
        let gaps = Set(coverage.providerGaps.map(\.id))
        var classifier = LiveTVLineupClassifier()
        for channel in coverage.unmatched {
            guard case .country(let code) = classifier.placement(of: channel) else { continue }
            report.append("\(gaps.contains(channel.id) ? "gap" : "miss")\t\(code)\t\(channel.name)\t\(channel.guideID ?? "-")")
        }
        if let out = value("PLOZZ_COVERAGE_REPORT") { try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertGreaterThan(coverage.matched, 0)
    }

    /// The US and GB analysis fixtures (`name, groups, epgID, expected, …`, tab separated; expected is a station id or `none`) run
    /// through the matcher: `PLOZZ_MATCH_FIXTURES` is a comma-separated list of files, `PLOZZ_COVERAGE_STATIONS` the station ids.
    /// Reports agreement, wrong guides (a different station than expected: the costly case) and rows left unmatched.
    func testAnalysisFixturesAgreement() throws {
        guard let list = value("PLOZZ_MATCH_FIXTURES"), let stationsPath = value("PLOZZ_COVERAGE_STATIONS") else {
            throw XCTSkip("Set PLOZZ_MATCH_FIXTURES and PLOZZ_COVERAGE_STATIONS to run the analysis fixtures.")
        }
        var stations: [String: [String]] = [:]
        for id in try String(contentsOfFile: stationsPath, encoding: .utf8).split(separator: "\n") { stations[String(id)] = [] }
        var lines: [String] = []
        for path in list.split(separator: ",").map(String.init) {
            var agree = 0, wrong: [String] = [], missed: [String] = [], total = 0
            for (offset, line) in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard offset > 0, cells.count >= 4 else { continue }
                total += 1
                let row = channel("fx\(offset)", cells[0], group: cells[1], guideID: cells[2].isEmpty ? nil : cells[2])
                let got = LiveTVGuideMatcher().matching(channels: [row], guideChannels: stations, trustsGuideIDs: true)
                    .assignments[row.id]?.guideChannelID
                let expected = cells[3] == "none" ? nil : cells[3]
                if got?.lowercased() == expected?.lowercased() { agree += 1 }
                else if let got, expected != nil { wrong.append("\(cells[0])\tgot=\(got)\texpected=\(expected ?? "")\t\(cells.count > 4 ? cells[cells.count - 2] : "")") }
                else if let got { wrong.append("\(cells[0])\tgot=\(got)\texpected=none") }
                else { missed.append("\(cells[0])\texpected=\(expected ?? "")") }
            }
            lines.append("fixtures\t\((path as NSString).lastPathComponent)\trows=\(total)\tagree=\(agree)\twrong=\(wrong.count)\tunmatched-but-expected=\(missed.count)")
            lines += wrong.map { "wrong\t" + $0 } + missed.map { "missed\t" + $0 }
        }
        if let out = value("PLOZZ_COVERAGE_REPORT") { try lines.joined(separator: "\n").write(toFile: out + ".fixtures", atomically: true, encoding: .utf8) }
        XCTAssertFalse(lines.isEmpty)
    }

    /// Hides every tvg-id of the iptv-org playlist (its ids are authoritative) and measures the name matcher against them:
    /// `PLOZZ_IPTVORG_M3U` is the snapshot's `index.nourl.m3u`.
    func testIPTVOrgNameMatcherPrecisionWithTheIDHidden() throws {
        guard let path = value("PLOZZ_IPTVORG_M3U") else { throw XCTSkip("Set PLOZZ_IPTVORG_M3U to measure the name matcher.") }
        var stations: [String: [String]] = [:]
        var rows: [(expected: String, name: String, country: String?)] = []
        var pendingID: String?
        var pendingName: String?
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("#EXTINF") {
                guard let idRange = line.range(of: #"tvg-id="([^"]*)""#, options: .regularExpression),
                      let comma = line.lastIndex(of: ",") else { pendingID = nil; continue }
                pendingID = String(line[idRange].dropFirst(8).dropLast())
                pendingName = String(line[line.index(after: comma)...])
            } else if let id = pendingID, let name = pendingName, !id.isEmpty {
                let base = id.split(separator: "@").first.map(String.init) ?? id
                let suffix = base.split(separator: ".").last.map { String($0.prefix(2)).uppercased() }
                stations[id, default: []].append(name)
                rows.append((id, name, suffix == "UK" ? "GB" : suffix))
                pendingID = nil
            }
        }
        let index = LiveTVGuideStationIndex(guideChannels: stations)
        var matched = 0, correct = 0
        let start = Date()
        for row in rows {
            guard let found = index.resolve(name: row.name, country: row.country) else { continue }
            matched += 1
            let expectedBase = row.expected.split(separator: "@").first.map(String.init)
            if found == row.expected || found.split(separator: "@").first.map(String.init) == expectedBase { correct += 1 }
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        let line = "iptvOrgNameMatcher rows=\(rows.count) matched=\(matched) correct=\(correct) precision=\(Double(correct) / Double(max(matched, 1))) recall=\(Double(correct) / Double(max(rows.count, 1))) passMs=\(elapsed)"
        if let out = value("PLOZZ_COVERAGE_REPORT") { try line.write(toFile: out + ".iptvorg", atomically: true, encoding: .utf8) }
        XCTAssertGreaterThan(Double(correct) / Double(max(matched, 1)), 0.9, line)
    }
}
