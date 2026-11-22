#if canImport(UIKit)
import CoreModels
import UIKit
import XCTest
@testable import CoreUI

/// The guide plate's only badge is the 4K word, placed as in the mockup: just outside the logo's top-right corner,
/// its top 22% of its own height above the logo's top, never over the logo.
final class ChannelLogoBadgeFitTests: XCTestCase {
    private let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))

    func testOnlyUltraHighDefinitionChannelsGetAPlateBadge() {
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.uhd]), .k4)
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.k4, .hdr, .fps(60)]), .k4)
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.k8]), .k8)
        for tags: [IPTVChannelTag] in [
            [.country("CA"), .language("EN"), .hd], [.fhd], [.hdr], [.fps(60)], [.raw, .backup], []
        ] {
            XCTAssertNil(IPTVChannelTag.ultraHighDefinitionBadge(in: tags), "\(tags)")
        }
    }

    func testBadgeSitsAtTheLogosTopRightCornerWithoutOverlap() {
        for aspect in [3.0, 1.0, 0.5] {
            for text in ["4K", "8K"] {
                let layout = geometry.layout(aspect: aspect, badge: text)
                let context = "\(aspect) \(text)"
                guard let rect = layout.badge else { XCTFail(context); continue }
                XCTAssertEqual(rect.minX, layout.logo.maxX, accuracy: 0.001, context)
                XCTAssertEqual(rect.minY, layout.logo.minY - geometry.badgeHeight * 0.22, accuracy: 0.001, context)
                XCTAssertEqual(rect.height, geometry.badgeHeight, accuracy: 0.001, context)
                XCTAssertFalse(rect.intersects(layout.logo), context)
                XCTAssertGreaterThanOrEqual(layout.logo.minX, -0.001, context)
                XCTAssertLessThanOrEqual(rect.maxX, ChannelLogoExtraction.GuideGeometry.referenceCellSize.width, context)
                XCTAssertEqual(layout.logo.width / layout.logo.height, aspect, accuracy: aspect * 0.005, context)
            }
        }
    }

    func testBadgeReservesTheMockupsTwoAndAHalfFontSizesFromTheLogoWidth() {
        let wide = geometry.layout(aspect: 8, badge: "4K").logo
        XCTAssertLessThanOrEqual(wide.width, geometry.box.width - geometry.badgeWidth + 0.001)
        let unbadged = geometry.layout(aspect: 8, badge: nil).logo
        XCTAssertGreaterThan(unbadged.width, wide.width, "A wide logo gives up the badge's width")
    }

    func testNoBadgeLeavesTheLogoCentredAndUnchanged() {
        let layout = geometry.layout(aspect: 4, badge: nil)
        XCTAssertEqual(layout.logo.size, ChannelLogoExtraction.fittedSize(aspect: 4, in: geometry.box))
        XCTAssertEqual(layout.logo.midX, geometry.box.width / 2, accuracy: 0.001)
        XCTAssertEqual(layout.logo.midY, geometry.box.height / 2, accuracy: 0.001)
        XCTAssertNil(layout.badge)
    }

    func testScalesWithTheCell() {
        let large = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 504, height: 164))
        let small = geometry.layout(aspect: 2, badge: "4K"), big = large.layout(aspect: 2, badge: "4K")
        XCTAssertEqual(big.logo.width, small.logo.width * 2, accuracy: 0.5)
        XCTAssertEqual(big.badge?.height ?? 0, (small.badge?.height ?? 0) * 2, accuracy: 0.5)
    }
}
#endif
