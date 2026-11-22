import XCTest
@testable import FeatureLiveTVCore
#if canImport(UIKit)
import UIKit
#endif

final class LiveTVSportsArtPlanTests: XCTestCase {
    func testLeagueComesFromTheGroupWhenTheNameHasNoTag() {
        let cases: [(String, [String], LiveTVSportsLeague?)] = [
            ("US: NBA 12", ["US| NBA PPV"], .nba),
            ("CA: CFL 3", ["CA| CFL PPV"], .cfl),
            ("US: GAME", ["US| NCAAB PPV"], .ncaab),
            ("US: GAME", ["US| NCAAF PPV"], .ncaaf),
            ("US: GAME", ["US| UEFA PPV"], .uefaChampionsLeague),
            ("US: GAME", ["US| WTA PPV ⱽᴵᴾ"], .wta),
            ("US: GAME", ["US| NHLX PPV"], nil),
            ("US: GAME", ["US| WHL PPV"], nil),
            ("US: GAME", ["US| ATP PPV"], nil),
            ("US: GAME", ["US| RUGBY PPV"], nil)
        ]
        for (name, groups, expected) in cases {
            XCTAssertEqual(LiveTVSportsEventParser.parse(name, groups: groups)?.league, expected, groups.joined())
        }
        XCTAssertEqual(LiveTVSportsEventParser.parse("(Apple) (MLS) 004 | Seattle vs. Salt Lake", groups: ["US| ESPN+ PPV"])?.league, .mls, "a tag beats the group")
    }

    func testEveryLeagueBadgeHasAWikidataItem() {
        let items = LiveTVSportsLeague.allCases.map(\.wikidataItem)
        XCTAssertEqual(Set(items).count, items.count, "each league has its own badge item")
        for item in items { XCTAssertTrue(item.hasPrefix("Q"), item) }
    }

    func testSportGlyphComesFromTitleThenGroup() {
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "Basketball (W): Columbia at #20 Maryland", groups: []), .basketball)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "flohockey: 2026 Caledon Admirals vs Oakville Blades", groups: ["US| FLO VIP PPV"]), .hockey)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "florugby: 2026 Lyon vs Toulouse", groups: []), .rugby)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "flowrestling: Lucha Open (Mat 11)", groups: []), .wrestling)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "2026 ATP Finals: Final", groups: []), .tennis)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "US: GAME 4", groups: ["US| RUGBY PPV"]), .rugby)
        XCTAssertEqual(LiveTVSportGlyph.glyph(name: "Volleyball (W): A at B", groups: ["US| NCAAB PPV"]), .volleyball, "the title is read before the group")
        XCTAssertNil(LiveTVSportGlyph.glyph(name: "AU (STAN 04) | Jeonbuk v Seoul", groups: ["US| STAN PPV"]))
    }

    func testBroadcasterComesFromGroupOrTag() {
        let cases: [(String, [String], String?)] = [
            ("x", ["US| FLO VIP PPV"], "FloSports"), ("x", ["CA| TSN+ PPV"], "TSN"), ("x", ["CA| SPORTSNET+ PPV"], "Sportsnet"),
            ("x", ["US| PEACOCK PPV ⱽᴵᴾ"], "Peacock"), ("x", ["US| DAZN PPV"], "DAZN"), ("US (ESPN+ 316) | ESPN+: A vs. B", [], "ESPN+"),
            ("x", ["US| SOCCER PPV"], nil)
        ]
        for (name, groups, expected) in cases {
            XCTAssertEqual(LiveTVSportsBroadcaster.broadcaster(name: name, groups: groups)?.displayName, expected, groups.joined())
        }
    }

    func testCompositionOrder() {
        typealias C = LiveTVSportsComposition
        XCTAssertEqual(C.compose(name: "(MLS) 004 | Seattle vs. Salt Lake", groups: [], crestCount: 2), .twoCrests(league: .mls))
        XCTAssertEqual(C.compose(name: "(MLS) 004 | Seattle vs. Salt Lake", groups: [], crestCount: 1), .oneCrest(league: .mls))
        XCTAssertEqual(C.compose(name: "x", groups: ["US| NBA PPV"]), .leagueBadge(.nba))
        XCTAssertEqual(C.compose(name: "flohockey: A vs B", groups: ["US| FLO VIP PPV"], broadcasterLogoAvailable: true), .broadcaster(name: "FloSports", glyph: .hockey))
        XCTAssertEqual(C.compose(name: "flohockey: A vs B", groups: ["US| FLO VIP PPV"]), .glyph(.hockey), "no broadcaster logo resolved")
        XCTAssertEqual(C.compose(name: "A v B", groups: ["US| ESPN+ PPV"]), .text)
        XCTAssertEqual(C.compose(name: "A vs B", groups: []), .text)
    }

    func testEverySportSymbolExistsOnThisPlatform() throws {
        #if canImport(UIKit)
        for glyph in LiveTVSportGlyph.allCases {
            XCTAssertNotNil(UIImage(systemName: glyph.symbolName), "\(glyph) → \(glyph.symbolName)")
        }
        for league in LiveTVSportsLeague.allCases {
            XCTAssertNotNil(UIImage(systemName: league.glyphSymbolName), "\(league) → \(league.glyphSymbolName)")
        }
        #else
        throw XCTSkip("SF Symbols are checked on tvOS and iOS.")
        #endif
    }
}
