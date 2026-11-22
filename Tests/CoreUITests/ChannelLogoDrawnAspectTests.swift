#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

final class ChannelLogoDrawnAspectTests: XCTestCase {
    private func image(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testDrawnLogoKeepsTheSourceAspectForWideSquareAndTallLogos() {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        for (width, height) in [(300.0, 100.0), (100.0, 100.0), (50.0, 100.0)] {
            let source = image(width, height)
            // A stale trim aspect must not win over the image that is drawn.
            let aspect = BareChannelLogo.drawnAspect(of: source, fallback: 1)
            for hasBadge in [false, true] {
                let size = geometry.logoSize(aspect: aspect, hasBadge: hasBadge)
                XCTAssertEqual(size.width / size.height, width / height, accuracy: width / height * 0.005)
            }
        }
    }
}
#endif
