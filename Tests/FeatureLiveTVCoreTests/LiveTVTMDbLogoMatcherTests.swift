import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVTMDbLogoMatcherTests: XCTestCase {
    /// TMDB networks (id, name) from the daily export that share names with Canadian channels.
    private static let networks: [TMDbNetworkEntry] = [
        (23, "CBC Television"), (201, "CBC"), (2548, "CBC"),
        (110, "CTV"), (403, "CTV"), (2909, "CTV"), (9284, "CTV"),
        (673, "CTV News Channel"), (218, "Global TV"), (8834, "Global News"),
        (2, "ABC"), (6, "NBC"), (2462, "NBC"), (9603, "NBC"), (71, "The CW"), (8795, "tv"), (1567, "Prime")
    ].map { TMDbNetworkEntry(id: $0.0, name: $0.1) }

    /// Origin countries TMDB reported for those networks (`nil` when it has none).
    private static let originCountries: [Int: String?] = [
        23: "CA", 201: "JP", 2548: "EG", 110: "CA", 403: "TW", 2909: "BY", 9284: nil, 673: "CA", 218: "CA",
        8834: "CA", 2: "US", 6: "US", 2462: "JP", 9603: "NA", 71: "US", 8795: nil, 1567: "NZ"
    ]

    private let matcher = LiveTVTMDbLogoMatcher(networks: networks)

    private func match(_ name: String, groups: [String] = [], country: String? = nil) -> Int? {
        let query = LiveTVTMDbChannelQuery(name: name, groups: groups, country: country)
        return LiveTVTMDbLogoMatcher.select(
            from: matcher.candidates(for: query), originCountries: Self.originCountries,
            channelCountry: LiveTVTMDbLogoMatcher.country(for: query)
        )?.networkID
    }

    /// The 18 Canadian provider channel names from the logo exploration, with the network IDs it found.
    func testTheEighteenCanadianProviderChannels() {
        let expected: [(String, Int?)] = [
            ("CA EN: CBC CALGARY HD", 23), ("CA EN: CBC CHARLOTTETOWN (HD)", 23), ("CA EN: CBC EDMONTON HD", 23),
            ("CA EN: CBC FREDERICTON (HD)", 23), ("CA EN: CBC HALIFAX HD", 23), ("CA EN: CBC MONTREALHD", 23),
            ("CA EN: CTV ATLENTIC (ATV MONCTON)", 110), ("CA EN: CTV CALARY NEWS", 110), ("CA EN: CTV CALGARY", 110),
            ("CA EN: CTV HALIFAX", 110), ("CA EN: CTV KITCHENER HD", 110), ("CA EN: CTV NEWS CHANNEL", 673),
            ("CA EN: GLOBAL CALAGRY SD", 218), ("CA EN: GLOBAL HALIFAX SD", 218), ("CA EN: GLOBAL MARITIMES HD", 218),
            ("CA EN: GLOBAL MONTREAL", 218), ("CA EN: GLOBAL NEWS BC HD", 8834), ("CA EN: GLOBAL NEWS CALGARY HD", 8834)
        ]
        XCTAssertEqual(expected.count, 18)
        for (name, id) in expected {
            XCTAssertEqual(match(name), id, name)
        }
    }

    func testNormalisationStripsPrefixDecorationsQualityMarksAndSuperscripts() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("CA EN: CBC CALGARY HD"), "CBC CALGARY")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("US| ABC FHD"), "ABC")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("##### ABC ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ #####"), "ABC")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.primaryKey("CA EN: CBC CHARLOTTETOWN (HD)"), "CBC CHARLOTTETOWN")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.normalized("Fox & Friends+"), "foxandfriendsplus")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.normalized("Télé-Québec"), "telequebec")
    }

    func testBrandKeyDropsProviderPrefixesCallSignsAffiliateNumbersAndPlaces() {
        let cases: [(String, String)] = [
            ("US: NBC 10 (WJAR) RHODE ISLAND (A) ᴿᴬᵂ", "NBC"),
            ("US: FOX 9 (KMSP) MINNEAPOLIS HD", "FOX"),
            ("US: CW 53 HD [COLUMBUS]", "CW"),
            ("US: ABC 11 LOUISVILLE KY (WHAS) HD", "ABC"),
            ("RK: PBS FOOD ᴿᴬᵂ", "PBS FOOD"),
            ("AT&T: STINGRAY GREATEST HITS ᴿᴬᵂ", "STINGRAY GREATEST HITS"),
            ("CA EN: CBC ST JOHN'S (HD)", "CBC"),
            ("CA EN: CBC MONTREALHD", "CBC"),
            ("CA EN: CTV2 LONDON HD(R)", "CTV2"),
            ("CA EN: GLOBAL NEWS NATIONAL HD", "GLOBAL NEWS"),
            ("CA EN: CTV Sudbury HD", "CTV"),
            ("US: TELEMUNDO 42 (KGLA-DT) NEW ORLEANS ᴴᴰ", "TELEMUNDO")
        ]
        for (name, expected) in cases {
            XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey(name), expected, name)
        }
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("Toronto"), "Toronto", "a name that is only a place stays")
    }

    func testEventListingsAreNotChannels() {
        XCTAssertTrue(LiveTVTMDbLogoMatcher.isEventListing("flowrestling: Lucha Open (Mat 11) (2026-11-21 08:00:00)"))
        XCTAssertTrue(LiveTVTMDbLogoMatcher.isEventListing("PPV EVENT 36"))
        XCTAssertFalse(LiveTVTMDbLogoMatcher.isEventListing("CA EN: CBC CALGARY HD"))
    }

    func testAlternateKeyStripsCityFeedWordsAndProviderTypos() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: CTV ATLENTIC (ATV MONCTON)"), "CTV")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: GLOBAL CALAGRY SD"), "GLOBAL")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("CA EN: GLOBAL NEWS BC HD"), "GLOBAL NEWS")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.alternateKey("Toronto"), "Toronto")
    }

    func testCandidateRulesAndConfidence() {
        let exact = matcher.candidates(for: .init(name: "US| NBC HD"))
        XCTAssertEqual(exact.first?.rule, .exactName)
        XCTAssertEqual(exact.first?.confidence, LiveTVTMDbLogoMatcher.exactConfidence)
        let alias = matcher.candidates(for: .init(name: "CA EN: CBC CALGARY HD"))
        XCTAssertEqual(alias.first?.networkID, 23)
        XCTAssertEqual(alias.first?.rule, .alias)
        let alternate = matcher.candidates(for: .init(name: "Global News Calgary"))
        XCTAssertEqual(alternate.first(where: { $0.networkID == 8834 })?.rule, .alias)
        XCTAssertTrue(matcher.candidates(for: .init(name: "No Such Channel")).isEmpty)
        XCTAssertTrue(matcher.candidates(for: .init(name: "###")).isEmpty)
    }

    func testAliasMapsCWToTheCW() {
        XCTAssertEqual(match("##### CW ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ #####", groups: ["US|Entertainment"]), 71)
    }

    func testCountryComesFromGroupThenNamePrefixThenChannelCountry() {
        XCTAssertEqual(LiveTVTMDbLogoMatcher.country(for: .init(name: "ABC", groups: ["CA|News"])), "CA")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.country(for: .init(name: "US| ABC", groups: ["Sports"])), "US")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.country(for: .init(name: "ABC", groups: [], country: "ca")), "CA")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.country(for: .init(name: "ABC", country: "United States")), "US")
        XCTAssertEqual(LiveTVTMDbLogoMatcher.country(for: .init(name: "CA EN: CBC", groups: ["US|x"])), "US")
        XCTAssertNil(LiveTVTMDbLogoMatcher.country(for: .init(name: "ABC")))
    }

    func testCountryFilterKeepsOnlyMatchingOrUnknownNetworks() {
        XCTAssertEqual(match("NBC", country: "US"), 6)
        XCTAssertEqual(match("NBC", country: "JP"), 2462)
        XCTAssertNil(match("NBC", country: "FR"), "no NBC network is French")
    }

    func testTiesAndBelowThresholdStayUnmatched() {
        // Without a country two NBC networks (US and JP) score identically.
        XCTAssertNil(match("NBC"))
        let query = LiveTVTMDbChannelQuery(name: "ABC")
        let candidate = matcher.candidates(for: query)[0]
        let weak = LiveTVTMDbCandidate(networkID: 1, networkName: "x", confidence: 0.4, rule: .alternateName)
        XCTAssertNil(LiveTVTMDbLogoMatcher.select(from: [weak], originCountries: [1: "CA"], channelCountry: "CA"))
        XCTAssertEqual(
            LiveTVTMDbLogoMatcher.select(from: [candidate], originCountries: [2: "US"], channelCountry: "US")?.networkID, 2
        )
    }

    func testUnknownCountryLosesToAKnownMatchAndCannotPassOnAnAlternateKey() {
        let known = LiveTVTMDbCandidate(networkID: 1, networkName: "A", confidence: 0.5, rule: .alternateName)
        let unknown = LiveTVTMDbCandidate(networkID: 2, networkName: "A", confidence: 0.5, rule: .alternateName)
        XCTAssertEqual(
            LiveTVTMDbLogoMatcher.select(
                from: [unknown, known], originCountries: [1: "CA", 2: nil], channelCountry: "CA"
            )?.networkID, 1
        )
        XCTAssertNil(LiveTVTMDbLogoMatcher.select(from: [unknown], originCountries: [2: nil], channelCountry: "CA"))
        let exactUnknown = LiveTVTMDbCandidate(networkID: 3, networkName: "A", confidence: 0.9, rule: .exactName)
        XCTAssertEqual(
            LiveTVTMDbLogoMatcher.select(from: [exactUnknown], originCountries: [3: nil], channelCountry: "CA")?.networkID, 3
        )
    }

    func testResultIsDeterministicRegardlessOfCandidateOrder() {
        let query = LiveTVTMDbChannelQuery(name: "CA EN: CTV CALGARY", groups: ["CA|Local"])
        let candidates = matcher.candidates(for: query)
        let forward = LiveTVTMDbLogoMatcher.select(from: candidates, originCountries: Self.originCountries, channelCountry: "CA")
        let reverse = LiveTVTMDbLogoMatcher.select(
            from: candidates.reversed(), originCountries: Self.originCountries, channelCountry: "CA"
        )
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward?.networkID, 110)
    }

    /// Regional feeds of a network resolve to the network, a national news channel to its own network, and a brand with no
    /// regional variants to itself. Names are the provider's own (misspellings kept).
    func testRegionalFeedsResolveToTheirNetworkNotAnotherOne() {
        let adultSwim = TMDbNetworkEntry(id: 80, name: "Adult Swim")
        let regionalMatcher = LiveTVTMDbLogoMatcher(networks: Self.networks + [adultSwim])
        var countries = Self.originCountries
        countries[80] = "US"
        let rows: [(name: String, group: String, expected: Int)] = [
            ("CA| CTV CALGARY ᴴᴰ", "CA| CANADA", 110),
            ("CA| CTV ATLENTIC (ATV MONCTON)", "CA| CANADA", 110),
            ("CA| CTV KITCHENER HD", "CA| CANADA", 110),
            ("CA| CTV NEWS CHANNEL ᴴᴰ", "CA| CANADA", 673),
            ("CA| GLOBAL CALAGRY SD", "CA| CANADA", 218),
            ("CA| GLOBAL MONTREAL", "CA| CANADA", 218),
            ("CA| GLOBAL MARITIMES HD", "CA| CANADA", 218),
            ("CA| CBC CALGARY HD", "CA| CANADA", 23),
            ("CA| ADULT SWIM HD", "CA| CANADA", 80)
        ]
        for row in rows {
            let query = LiveTVTMDbChannelQuery(name: row.name, groups: [row.group])
            let chosen = LiveTVTMDbLogoMatcher.select(
                from: regionalMatcher.candidates(for: query), originCountries: countries,
                channelCountry: LiveTVTMDbLogoMatcher.country(for: query)
            )
            print("G4 \(row.name) -> network \(chosen?.networkID.description ?? "none") (\(chosen?.rule.rawValue ?? "-"))")
            XCTAssertEqual(chosen?.networkID, row.expected, row.name)
        }
    }
}
