#if canImport(UIKit)
import UIKit
#endif
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVSportsEventParserTests: XCTestCase {
    func testMLSMatchWithDateSuffix() {
        let event = LiveTVSportsEventParser.parse("(Apple) (MLS) 004 |  Seattle vs. Salt Lake  (2026-11-19 21:25:00)")
        XCTAssertEqual(event, LiveTVSportsEvent(league: .mls, teams: ["Seattle", "Salt Lake"]))
    }

    func testSpanishVariantDropsTheLanguageTag() {
        let event = LiveTVSportsEventParser.parse("(Apple) (MLS) 007 |  Seattle vs. Salt Lake (Spanish) (2026-11-19 21:25:00)")
        XCTAssertEqual(event?.teams, ["Seattle", "Salt Lake"])
        XCTAssertEqual(event?.league, .mls)
    }

    func testAtSeparatorAndOtherLeagues() {
        XCTAssertEqual(
            LiveTVSportsEventParser.parse("(ESPN+) (NBA) 12 | Boston @ Miami (2026-11-19 19:00:00)"),
            LiveTVSportsEvent(league: .nba, teams: ["Boston", "Miami"], teamsAreAwayThenHome: true))
        XCTAssertEqual(LiveTVSportsEventParser.parse("(WNBA) 3 | Las Vegas vs. Seattle (2026-05-01 20:00:00)")?.league, .wnba)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(NFL) 1 | Chiefs vs. Bills (2026-11-19 20:15:00)")?.league, .nfl)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(NHL) 2 | Rangers vs. Bruins (2026-11-19 19:00:00)")?.league, .nhl)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(MLB) 2 | Mets vs. Braves (2026-07-01 19:00:00)")?.league, .mlb)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(UEFA) 9 | Inter vs. Ajax (2026-11-19 21:00:00)")?.league, .uefaChampionsLeague)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(UCL) 9 | Inter vs. Ajax")?.league, .uefaChampionsLeague)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(UEL) 9 | Roma vs. Lyon")?.league, .uefaEuropaLeague)
    }

    func testCountdownAndWrapUpShowsHaveALeagueButNoTeams() {
        XCTAssertEqual(
            LiveTVSportsEventParser.parse("(Apple) (MLS) 001 | MLS Countdown (2026-11-19 20:00:00)"),
            LiveTVSportsEvent(league: .mls, teams: []))
        XCTAssertEqual(LiveTVSportsEventParser.parse("(NBA) 5 | Postgame Wrap-Up")?.teams, [])
    }

    func testNoTagNoLeagueAndNoGuessing() {
        XCTAssertNil(LiveTVSportsEventParser.parse("CA EN: CBC CALGARY HD"))
        XCTAssertNil(LiveTVSportsEventParser.parse("Seattle vs. Salt Lake"))
        XCTAssertNil(LiveTVSportsEventParser.parse("(Apple) (Soccer) 004 | Seattle vs. Salt Lake"))
        XCTAssertNil(LiveTVSportsEventParser.parse("NBA TV HD"))
    }

    func testGlyphsAreAvailableSystemSymbols() {
        #if canImport(UIKit)
        for league in LiveTVSportsLeague.allCases {
            XCTAssertNotNil(UIImage(systemName: league.glyphSymbolName), league.glyphSymbolName)
        }
        #endif
    }

    func testOnlyAtNamesAnAwayTeam() {
        XCTAssertEqual(LiveTVSportsEventParser.parse("(NBA) 1 | Boston @ Miami")?.teamsAreAwayThenHome, true)
        XCTAssertEqual(LiveTVSportsEventParser.parse("(NBA) 1 | Boston vs. Miami")?.teamsAreAwayThenHome, false)
    }
}
