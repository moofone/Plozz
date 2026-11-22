import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGlassFormattingTests: XCTestCase {
    func testShortCountIsExactBelowAThousand() {
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(0), "0")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(7), "7")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(999), "999")
    }

    func testShortCountKeepsOneDecimalAndRoundsDown() {
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(1_000), "1.0k")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(4_000), "4.0k")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(14_835), "14.8k")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(99_999), "99.9k")
    }

    func testShortCountDropsTheDecimalFromOneHundredThousand() {
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(100_000), "100k")
        XCTAssertEqual(LiveTVGlassFormatting.shortCount(256_999), "256k")
    }

    func testLeftShort() {
        func text(_ seconds: TimeInterval) -> String? {
            LiveTVGlassFormatting.leftShort(remaining: seconds).map { String(localized: $0) }
        }
        XCTAssertEqual(text(8 * 60), "8m left")
        XCTAssertEqual(text(65 * 60), "1h 5m left")
        XCTAssertEqual(text(60 * 60), "1h left")
        XCTAssertNil(text(0))
        XCTAssertNil(text(-30))
        XCTAssertNil(text(59))
    }

    func testLeftLong() {
        func text(_ seconds: TimeInterval) -> String? {
            LiveTVGlassFormatting.leftLong(remaining: seconds).map { String(localized: $0) }
        }
        XCTAssertEqual(text(42 * 60), "42 min left")
        XCTAssertEqual(text(65 * 60), "1 hr 5 min left")
        XCTAssertEqual(text(120 * 60), "2 hr left")
        XCTAssertNil(text(10))
    }

    /// The panel's Upcoming times read `7:00`, as in the mockup: no AM/PM in a 12-hour locale, 24-hour form kept in others.
    func testClockDropsTheDayPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let evening = calendar.date(from: DateComponents(year: 2025, month: 11, day: 17, hour: 19, minute: 5))!
        let formatter = { (id: String) in LiveTVGlassFormatting.clock(evening, locale: Locale(identifier: id), timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(formatter("en_US"), "7:05")
        XCTAssertEqual(formatter("en_GB"), "19:05")
    }
}
