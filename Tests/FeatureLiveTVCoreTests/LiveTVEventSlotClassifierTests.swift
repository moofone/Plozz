import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVEventSlotClassifierTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func classify(_ name: String, _ group: String = "CA| ROGERS PPV") -> LiveTVEventSlot? {
        LiveTVEventSlotClassifier.classify(name: name, groups: [group], timeZone: utc)
    }

    private func date(_ stamp: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: stamp)!
    }

    func testIdleShapes() {
        for name in [
            "- NO EVENT STREAMING - | 8K EXCLUSIVE | CA: SPORTSNET PPV 50",
            "NO EVENT STREAMING NOW - | 8K EXCLUSIVE | US: DAZN PPV 59",
            ":TSN+  109", ":Flo College  39", "Flo Racing 18 :", "CA: DAZN 8 PPV",
            "(Victory+ 025) |  (2098-12-31 08:00:24)", "(US) (BTN+ 107) |  (2098-12-31 08:00:18)",
            "US: 24/7 ALL TIME BEST 2", "NBA: WASHINGTON WIZARDS SD"
        ] {
            XCTAssertEqual(classify(name)?.state, .idle, name)
        }
    }

    func testActiveShapesWithTitleAndStart() {
        XCTAssertEqual(
            classify("(Apple) (MLS) 002 |  Orlando vs. Cincinnati  (2026-11-19 19:25:00)")?.state,
            .active(title: "Orlando vs. Cincinnati", start: date("2026-11-19 19:25:00")))
        XCTAssertEqual(
            classify("US (ESPN+ 316) | ESPN+: Tennessee vs. Belmont (Tennessee vs. Belmont) (2026-11-17 19:31:15)")?.state,
            .active(title: "Tennessee vs. Belmont", start: date("2026-11-17 19:31:15")))
        XCTAssertEqual(
            classify("(Victory+ 001) | THSCA Game of the Week : Frisco Lone Star at Melissa (2026-09-25 19:55:00)")?.state,
            .active(title: "THSCA Game of the Week : Frisco Lone Star at Melissa", start: date("2026-09-25 19:55:00")))
        XCTAssertEqual(
            classify("flohockey: 2026 Caledon Admirals vs Oakville Blades (Home) (2026-11-19 19:00:00)")?.title,
            "2026 Caledon Admirals vs Oakville Blades (Home)")
    }

    func testActiveSlotWithoutAStamp() {
        XCTAssertEqual(
            LiveTVEventSlotClassifier.classify(
                name: "Ottawa (AZ) vs Whittier @ Nov 16 10:00 PM :Flo College  07", groups: ["US| FLO COLLEGE PPV"],
                timeZone: utc, reference: date("2026-11-16 09:00:00"))?.state,
            .active(title: "Ottawa (AZ) vs Whittier", start: date("2026-11-16 22:00:00")))
        XCTAssertEqual(classify("Boxing  05  :  Canelo vs Mbilli UK 2:00pm")?.title, "Canelo vs Mbilli UK 2:00pm")
    }

    func testAtStartWithoutAYearTakesTheNearestYear() {
        let reference = date("2026-11-10 12:00:00")
        let slot = LiveTVEventSlotClassifier.classify(
            name: "2026 CFL Grey Cup: Alouettes vs. Elks A @ Nov 16 19:00 :TSN+  01", groups: ["CA| TSN+ PPV"],
            timeZone: utc, reference: reference)
        XCTAssertEqual(slot?.state, .active(title: "2026 CFL Grey Cup: Alouettes vs. Elks A", start: date("2026-11-16 19:00:00")))
        let afternoon = LiveTVEventSlotClassifier.classify(
            name: "Pre-Game Show @ Jan 3 7:30 PM :TSN+  02", groups: ["CA| TSN+ PPV"], timeZone: utc, reference: reference)
        XCTAssertEqual(afternoon?.state, .active(title: "Pre-Game Show", start: date("2027-01-03 19:30:00")))
    }

    func testThePlaceholderDateGivesNoStart() {
        XCTAssertNil(classify("(X 001) | Some Fight (2098-12-31 08:00:01)")?.start)
    }

    func testStampIsWallClockInTheGivenZone() {
        let tokyo = LiveTVEventSlotClassifier.classify(
            name: "(A 1) | Game (2026-11-19 19:25:00)", groups: ["PPV"], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(tokyo?.start, date("2026-11-19 10:25:00"))
    }

    func testGroupRules() {
        XCTAssertNotNil(classify("A | X (2026-01-01 10:00:00)", "US| ESPN+ PPV \u{2C7D}\u{1D35}\u{1D3E}"), "Superscripts fold")
        XCTAssertNotNil(classify("A | X (2026-01-01 10:00:00)", "ca| ppv event"))
        // Event-pack groups without a PPV token.
        XCTAssertNotNil(classify("CA EN: ROGERS SUPER SPORTS PACK 1 \u{1D34}\u{1D30}", "CA| ROGERS SUPER SPORTS PACK EN"))
        XCTAssertNotNil(classify("Match | X (2026-01-01 10:00:00)", "CA| LIVE EVENTS"))
        XCTAssertNotNil(classify("Match | X (2026-01-01 10:00:00)", "US| SPECIAL EVENT"))
        // The name alone is never enough, apart from the placeholder prefix.
        XCTAssertNil(classify("PPV Movies 1", "CA| MOVIES"))
        XCTAssertNil(classify("CBC CALGARY", "CA| ENTERTAINMENT"))
        XCTAssertNotNil(classify("- NO EVENT STREAMING - | x", "CA| MOVIES"))
    }

    func testPackSlotsAreIdleUntilTheyNameAnEvent() {
        XCTAssertEqual(classify("CA EN: ROGERS SUPER SPORTS PACK 1 \u{1D34}\u{1D30}", "CA| ROGERS SUPER SPORTS PACK EN")?.state, .idle)
    }

    /// The service is what the event streams on, so the panel can name it without repeating the title.
    func testServiceIsTheTrailingSlotOrTheLeadingParenthetical() {
        let atStart = "2025 STIHL Timbersports: Men's Singles @ Nov 17 13:30 :TSN+ 29"
        XCTAssertEqual(LiveTVEventSlotClassifier.service(in: atStart), "TSN+ 29")
        XCTAssertEqual(LiveTVEventSlotClassifier.service(in: "US (Victory+ 025) | Rangers vs Devils (2025-11-17 19:00:00)"), "Victory+ 025")
        XCTAssertNil(LiveTVEventSlotClassifier.service(in: "CA| ROGERS SUPER SPORTS PACK 1"))
        XCTAssertNil(LiveTVEventSlotClassifier.service(in: "A name with no slot"))
    }
}
