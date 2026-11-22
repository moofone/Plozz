import CoreUI
import SwiftUI
import XCTest
@testable import FeatureLiveTV

final class LiveTVPrototypeGlassLayoutTests: XCTestCase {
    #if os(tvOS)
    override func setUp() { super.setUp(); LiveTVGlassLayout.override = .hd1080 }
    override func tearDown() { LiveTVGlassLayout.override = nil; super.tearDown() }

    func testGuideStartsAtTheMockupTopWhateverTheSafeArea() {
        for insets in [
            EdgeInsets(),
            EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        ] {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1_920, height: 1_080), safeAreaInsets: insets, hidesSidebar: true)
            let guideTop = layout.contentFrame.minY - layout.bounds.minY
                + layout.heroHeight + PrototypeLayout.sectionGap
            XCTAssertEqual(guideTop, layout.guideScreenTop, accuracy: 0.01)
            XCTAssertEqual(layout.sidebarWidth, 0)
        }
    }

    func testGuideSitsAtTheMockupLeftAndRightEdgesBesideTheShellRail() {
        for insets in [EdgeInsets(), EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)] {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1_920 - insets.leading - insets.trailing, height: 1_080 - insets.top - insets.bottom),
                safeAreaInsets: insets, navigationInset: 64, hidesSidebar: true)
            XCTAssertEqual(layout.contentFrame.minX - layout.bounds.minX, 144, accuracy: 0.01)
            XCTAssertEqual(layout.contentFrame.width, 1_696, accuracy: 0.01)
            XCTAssertEqual(layout.bounds.maxX - layout.contentFrame.maxX, 80, accuracy: 0.01)
            XCTAssertEqual(layout.guideTrailingExtension, 0)
        }
    }

    func testSearchingKeepsTheShortHero() {
        let browsing = PrototypePreviewLayout(size: CGSize(width: 1_920, height: 1_080), hidesSidebar: true)
        let searching = PrototypePreviewLayout(
            size: CGSize(width: 1_920, height: 1_080), isSearching: true, hidesSidebar: true)
        XCTAssertLessThan(searching.heroHeight, browsing.heroHeight)
    }

    func testHeadingAndHeroEdgesFollowTheScreenNotTheContentFrame() {
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1_920, height: 1_080),
            safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            navigationInset: 88, hidesSidebar: true)
        XCTAssertEqual(
            layout.contentFrame.minX - layout.bounds.minX + layout.glassHeadingLeadingInset,
            layout.glassHeadingScreenX, accuracy: 0.01)
        XCTAssertEqual(
            layout.contentFrame.maxX - layout.glassHeroTrailingInset,
            layout.bounds.maxX - layout.glassHeroScreenMaxXInset, accuracy: 0.01)
    }
    #endif
}
