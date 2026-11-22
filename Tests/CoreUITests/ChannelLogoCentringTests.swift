#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// Optical centring: whatever empty margin a logo's image carries, the ink ends up centred in the logo slot.
/// Every image is drawn here; no provider or third-party artwork is involved.
final class ChannelLogoCentringTests: XCTestCase {
    /// A solid red block of `ink` on a transparent canvas, off-centre by design.
    private func pngData(canvas: CGSize, ink: CGRect) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(ink)
        }
    }

    func testInkIsTrimmedAndCentredInTheSlotWhateverTheMargins() throws {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        let cases: [(canvas: CGSize, ink: CGRect)] = [
            (CGSize(width: 400, height: 300), CGRect(x: 10, y: 150, width: 240, height: 80)),
            (CGSize(width: 400, height: 300), CGRect(x: 300, y: 5, width: 90, height: 90)),
            (CGSize(width: 600, height: 200), CGRect(x: 0, y: 60, width: 150, height: 120)),
            (CGSize(width: 300, height: 600), CGRect(x: 120, y: 400, width: 60, height: 180))
        ]
        for item in cases {
            let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(
                data: pngData(canvas: item.canvas, ink: item.ink), providerRequestsDarkBackground: false))
            // The trimmed image is the ink's bounding box, to the pixel.
            XCTAssertEqual(Double(prepared.image.size.width), Double(item.ink.width), accuracy: 1, "\(item)")
            XCTAssertEqual(Double(prepared.image.size.height), Double(item.ink.height), accuracy: 1, "\(item)")
            // Drawn in the slot: uniform scale, ink centre within 1 px of the slot centre.
            let aspect = BareChannelLogo.drawnAspect(of: prepared.image, fallback: prepared.aspect)
            let logo = geometry.layout(aspect: aspect, badge: nil).logo
            XCTAssertEqual(logo.midX, geometry.box.width / 2, accuracy: 1, "\(item)")
            XCTAssertEqual(logo.midY, geometry.box.height / 2, accuracy: 1, "\(item)")
            XCTAssertEqual(logo.width / logo.height, item.ink.width / item.ink.height, accuracy: item.ink.width / item.ink.height * 0.01)
        }
    }
}
#endif
