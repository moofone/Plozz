#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// The place printed under a network logo that several regional channels share (mock "Layered" column), and the owner's v2b logo size.
final class ChannelLogoRegionLabelTests: XCTestCase {
    private func layout(
        aspect: Double, inkFill: Double = 1, cell: CGSize, label: String = "Calgary"
    ) -> ChannelLogoExtraction.LabelledLogoLayout {
        let box = ChannelLogoExtraction.GuideGeometry(cellSize: cell).box
        return ChannelLogoExtraction.labelledLayout(aspect: aspect, inkFill: inkFill, box: box, cell: cell) {
            ChannelLogoExtraction.labelInk(label, font: $0)
        }
    }

    func testLabelIsAQuarterOfTheRowHeightAtThe1080AndThe4KRows() {
        XCTAssertEqual(layout(aspect: 2.6, cell: CGSize(width: 252, height: 74)).fontSize, 17.76, accuracy: 0.05)
        XCTAssertEqual(layout(aspect: 2.6, cell: CGSize(width: 252, height: 82)).fontSize, 19.68, accuracy: 0.05)
    }

    func testGapOnInkAndTheBlockIsCentredOnInkWithinHalfAPixel() {
        for cell in [CGSize(width: 252, height: 74), CGSize(width: 252, height: 82)] {
            for aspect in [1.0, 2.0, 2.6, 4.0, 6.0] {
                for label in ["Halifax", "Calgary", "Montréal", "St. John's"] {
                    let result = layout(aspect: aspect, cell: cell, label: label)
                    XCTAssertEqual(result.inkTop - result.logo.maxY, ChannelLogoExtraction.RegionLabelStyle.inkGap, accuracy: 0.001)
                    XCTAssertEqual((result.logo.minY + result.inkBottom) / 2, cell.height / 2, accuracy: 0.5, "\(label) \(aspect)")
                    XCTAssertEqual(result.logo.midX, cell.width / 2, accuracy: 0.5)
                    XCTAssertEqual(result.logo.width / result.logo.height, aspect, accuracy: aspect * 0.005)
                }
            }
        }
    }

    func testALongPlaceShrinksOnItsOwnLineToFitTheLogoBox() {
        let cell = CGSize(width: 252, height: 74)
        let box = ChannelLogoExtraction.GuideGeometry(cellSize: cell).box
        let text = "Newfoundland and Labrador and Nova Scotia"
        let result = layout(aspect: 3, cell: cell, label: text)
        let ink = ChannelLogoExtraction.labelInk(text, font: UIFont.systemFont(ofSize: result.fontSize, weight: .medium))
        XCTAssertLessThanOrEqual(ink.bounds.width, box.width + 0.5)
    }

    func testLabelContrastIsAtLeastFourPointFiveOnBothRows() {
        XCTAssertGreaterThanOrEqual(ChannelLogoExtraction.RegionLabelStyle.contrast(on: .dark), 4.5)
        XCTAssertGreaterThanOrEqual(ChannelLogoExtraction.RegionLabelStyle.contrast(on: .light), 4.5)
        XCTAssertEqual(ChannelLogoExtraction.RegionLabelStyle.darkOpacity, 0.8)
        XCTAssertEqual(ChannelLogoExtraction.RegionLabelStyle.lightOpacity, 0.72)
    }

    // MARK: v2b size

    private let reference = CGSize(width: 164, height: 52)

    func testSolidMarksKeepTheEqualAreaFit() {
        let base = ChannelLogoExtraction.fittedSize(aspect: 3, in: reference)
        XCTAssertEqual(ChannelLogoExtraction.v2bSize(aspect: 3, inkFill: 0.8, in: reference), base)
        XCTAssertEqual(ChannelLogoExtraction.v2bSize(aspect: 3, inkFill: 0.6, in: reference), base)
    }

    func testThinMarksScaleUpBySqrtOfTheFillShortfallUntilACapStopsIt() {
        // aspect 3 in 164 x 52: fit 103.5 x 34.5 (0.42 of the box area).
        let base = ChannelLogoExtraction.fittedSize(aspect: 3, in: reference)
        XCTAssertEqual(base.height, (0.42 * 164 * 52 / 3).squareRoot(), accuracy: 0.01)
        // fill 0.50: scale sqrt(1.2) = 1.0954; height 37.8 stays under the 44.2 cap.
        let mild = ChannelLogoExtraction.v2bSize(aspect: 3, inkFill: 0.5, in: reference)
        XCTAssertEqual(mild.height, base.height * 1.2.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(mild.width / mild.height, 3, accuracy: 0.01)
        // fill 0.20: sqrt(3) = 1.73 would be 59.8 high; the cap is 85% of 52 = 44.2.
        let capped = ChannelLogoExtraction.v2bSize(aspect: 3, inkFill: 0.2, in: reference)
        XCTAssertEqual(capped.height, 0.85 * 52, accuracy: 0.01)
        XCTAssertEqual(capped.width / capped.height, 3, accuracy: 0.01)
        // A wide mark is stopped by the box width instead.
        let wide = ChannelLogoExtraction.v2bSize(aspect: 7, inkFill: 0.3, in: reference)
        XCTAssertLessThanOrEqual(wide.width, 164.001)
        XCTAssertGreaterThanOrEqual(wide.width, ChannelLogoExtraction.fittedSize(aspect: 7, in: reference).width)
    }

    func testAFitAlreadyPastTheHeightCapIsNeverShrunk() {
        // Aspect 1.3: the equal-area fit is 52 high (the whole box height); v2b must not make it smaller.
        let base = ChannelLogoExtraction.fittedSize(aspect: 1.3, in: reference)
        let result = ChannelLogoExtraction.v2bSize(aspect: 1.3, inkFill: 0.2, in: reference)
        XCTAssertEqual(result.height, base.height, accuracy: 0.001)
        XCTAssertEqual(result.width, base.width, accuracy: 0.001)
    }

    func testInkFillIsMeasuredOnTheTrimmedBoundingBox() throws {
        // A 40 x 10 canvas with a 20 x 10 ink block and a 2 x 2 dot: bbox spans 38 x 10.
        var bytes = [UInt8](repeating: 0, count: 40 * 10 * 4)
        func ink(_ x: Int, _ y: Int) { let i = (y * 40 + x) * 4; bytes[i] = 255; bytes[i + 3] = 255 }
        for y in 0..<10 { for x in 0..<20 { ink(x, y) } }
        for y in 4..<6 { for x in 36..<38 { ink(x, y) } }
        let pixels = try XCTUnwrap(ChannelLogoPixels(width: 40, height: 10, bytes: bytes))
        XCTAssertEqual(ChannelLogoExtraction.inkFill(pixels), Double(200 + 4) / Double(38 * 10), accuracy: 0.0001)
    }
}
#endif
