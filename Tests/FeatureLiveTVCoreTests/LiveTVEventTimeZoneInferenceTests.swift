import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// A source's event stamps are read in the zone its own event names state (`6:00PM ET` next to `18:00:15`),
/// when at least 5 names say so and 80% of them agree; otherwise in the viewer's zone.
final class LiveTVEventTimeZoneInferenceTests: XCTestCase {
    private func name(_ index: Int, named: String, stamp: String) -> String {
        "(A 00\(index)) | Team \(index) vs Team \(index + 1) \(named) (2026-11-17 \(stamp))"
    }

    private func eastern(_ count: Int) -> [String] {
        (1...count).map { name($0, named: "6:00PM ET", stamp: "18:00:15") }
    }

    func testExportRowWithSixPMEasternAndStampEighteenHundredInfersEastern() throws {
        let names = eastern(5) + ["Plain title without a time (2026-11-17 20:00:00)"]
        let inferred = try XCTUnwrap(LiveTVEventTimeZoneInference.infer(from: names))
        XCTAssertEqual(inferred.timeZone.identifier, "America/New_York")
        XCTAssertEqual(inferred.samples, 5)
        XCTAssertEqual(inferred.matches, 5)
    }

    func testNamedZonesMapToTheirRegionsAndAcceptTwelveAndTwentyFourHourTimes() throws {
        let cases: [(String, String, String)] = [
            ("9:00PM PT", "21:00:00", "America/Los_Angeles"), ("8:30 PM CT", "20:30:10", "America/Chicago"),
            ("7:00 PM MST", "19:00:00", "America/Denver"), ("19:00 UTC", "19:00:00", "UTC"),
            ("12:05AM GMT", "00:05:00", "UTC"), ("7:00 PM AST", "19:00:00", "America/Halifax")
        ]
        for (named, stamp, identifier) in cases {
            let names = (1...5).map { name($0, named: named, stamp: stamp) }
            XCTAssertEqual(LiveTVEventTimeZoneInference.infer(from: names)?.timeZone, TimeZone(identifier: identifier), named)
        }
    }

    func testEightyPercentAgreementIsEnoughAndLessIsNot() {
        let mismatched = name(9, named: "6:00PM ET", stamp: "23:00:00")
        XCTAssertNotNil(LiveTVEventTimeZoneInference.infer(from: eastern(4) + [mismatched]), "4 of 5 is 80%")
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: eastern(3) + [mismatched, mismatched]), "3 of 5 is 60%")
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: eastern(5) + (6...10).map { name($0, named: "6:00PM ET", stamp: "23:00:00") }))
    }

    func testFewerThanFiveSamplesFallBackToTheViewersZone() {
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: eastern(4)))
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: []))
    }

    func testStampsThatEqualTheViewersZoneNotTheNamedZoneFallBack() {
        // `6:00PM ET` with the stamp at 23:00: the stamp is not Eastern wall-clock time.
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: (1...8).map { name($0, named: "6:00PM ET", stamp: "23:00:00") }))
    }

    func testPlaceholderStampsAndNamesWithoutAZoneAreNotSamples() {
        let names = (1...8).map { "(A \($0)) | Game \($0) 6:00PM (2026-11-17 18:00:00)" }
            + (1...8).map { "(B \($0)) | Game \($0) 6:00PM ET (2098-12-31 18:00:00)" }
        XCTAssertNil(LiveTVEventTimeZoneInference.infer(from: names))
    }
}
