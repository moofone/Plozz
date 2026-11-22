import CoreUI
import SwiftUI
import XCTest
@testable import FeatureLiveTV
#if os(tvOS)
import UIKit
#endif

/// Token values are the mockup's `LAYOUT["4k"]` and `AL(true)` × 0.75 (a generated table below), not copies of the production literals.
final class LiveTVGlassLayoutTests: XCTestCase {
    private let u: CGFloat = 0.75
    /// The mockup's `AL(K).z`: round(n × 1.2) in the 2560 space.
    private func z(_ n: CGFloat) -> CGFloat { (n * 1.2).rounded() }

    func testGuideTokensAreTheMockupFourKValuesTimesThreeQuarters() {
        let l = LiveTVGlassLayout.uhd4K
        let table: [(String, CGFloat, CGFloat)] = [
            ("rowH", l.rowHeight, 74), ("rowGap", l.rowGap, 10), ("cg", l.cellGap, 10), ("cellR", l.cellRadius, 22),
            ("rulerH", l.rulerHeight, 50), ("ruler to first row", l.rulerRowGap, 14), ("plateW (+8, as appleScreen)", l.plateWidth, 202 + 8),
            ("fsCell", l.cellFontSize, 25), ("fsRuler", l.rulerFontSize, 22)]
        for (name, value, mockup) in table { XCTAssertEqual(value, mockup * u, accuracy: 0.001, name) }
        // The plate scales its parts by rowHeight / 82, so the reference values give numW 49, pPad 8 and logoPad 22 once scaled.
        let scale = l.rowHeight / 82
        XCTAssertEqual(l.plateNumberWidth * scale, 49 * u, accuracy: 0.001)
        XCTAssertEqual(l.plateLeadingInset * scale, 8 * u, accuracy: 0.001)
        XCTAssertEqual(l.plateLogoTrailingInset * scale, 22 * u, accuracy: 0.001)
        XCTAssertEqual(l.windowMinutes, 180)
        XCTAssertEqual(LiveTVGlassLayout.hd1080.windowMinutes, 120)
    }

    func testScreenFrameHeroPanelAndTrayTokensAreTheMockupValuesTimesThreeQuarters() {
        let l = LiveTVGlassLayout.uhd4K
        XCTAssertEqual(l.leadingInset, z(144) * u, accuracy: 0.001, "LX")
        XCTAssertEqual(l.trailingInset, 96 * u, accuracy: 0.001, "PX")
        XCTAssertEqual(l.heroBlockBottom, z(330) * u, accuracy: 0.001, "hb")
        XCTAssertEqual(l.guideTop, (z(330) + z(28)) * u, accuracy: 0.001, "gy")
        XCTAssertEqual(l.headingLeadingX, (z(144) + 8 - z(22)) * u, accuracy: 0.001, "heading")
        XCTAssertEqual(l.panelWidth, 760 * u, accuracy: 0.001)
        XCTAssertEqual(l.panelMargin, 40 * u, accuracy: 0.001)
        XCTAssertEqual(l.uiScale, 1.2 * u, accuracy: 0.0001)
        XCTAssertEqual(l.ui(680), z(680) * u, accuracy: 0.5, "hero text column")
        XCTAssertEqual(l.ui(60), z(60) * u, accuracy: 0.5, "button height")
        XCTAssertEqual(l.ui(52), z(52) * u, accuracy: 0.5, "hero title")
        let hd = LiveTVGlassLayout.hd1080
        XCTAssertEqual([hd.leadingInset, hd.trailingInset, hd.guideTop, hd.headingLeadingX, hd.panelWidth, hd.panelMargin, hd.uiScale],
                       [144, 80, 358, 130, 600, 40, 1])
    }

    func testChooserPicksUHDFromThe3840By2160Mode() {
        XCTAssertEqual(LiveTVGlassLayout.chooser(pixelWidth: 3_840, pixelHeight: 2_160), .uhd4K)
        XCTAssertEqual(LiveTVGlassLayout.chooser(pixelWidth: 1_920, pixelHeight: 1_080), .hd1080)
        XCTAssertEqual(LiveTVGlassLayout.chooser(pixelWidth: 2_560, pixelHeight: 1_440), .hd1080)
    }

    func testFourKShowsAtLeastNineRowsAndThreeHours() {
        let layout = LiveTVGlassLayout.uhd4K
        let guideHeight: CGFloat = 1080 - layout.guideTop - layout.rulerHeight - 14
        XCTAssertGreaterThanOrEqual(Int(guideHeight / (layout.rowHeight + layout.rowGap)), 9)
        XCTAssertEqual(layout.windowSeconds, 3 * 3_600)
        let hd = LiveTVGlassLayout.hd1080
        let hdHeight: CGFloat = 1080 - hd.guideTop - hd.rulerHeight - 14
        XCTAssertGreaterThan(Int(guideHeight / (layout.rowHeight + layout.rowGap)), Int(hdHeight / (hd.rowHeight + hd.rowGap)))
    }

    func testTheEnvironmentDefaultsTo1080pAndAnOverrideWins() {
        XCTAssertEqual(EnvironmentValues().liveTVGlassLayout, .hd1080)
        var values = EnvironmentValues()
        values.liveTVGlassLayout = .uhd4K
        XCTAssertEqual(values.liveTVGlassLayout, .uhd4K)
    }

    #if os(tvOS)
    /// A display-mode change recomputes the published tokens without rebuilding the host.
    @MainActor func testTrackingRecomputesTheEnvironmentOnAScreenModeChange() async throws {
        defer { LiveTVGlassLayout.override = nil }
        final class Box { var seen: [LiveTVGlassLayout] = [] }
        struct Probe: View {
            let box: Box
            @Environment(\.liveTVGlassLayout) private var layout
            var body: some View { box.seen.append(layout); return Color.clear }
        }
        LiveTVGlassLayout.override = .hd1080
        let box = Box()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = UIHostingController(rootView: Probe(box: box).liveTVGlassLayoutTracking())
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.seen.last, .hd1080)
        LiveTVGlassLayout.override = .uhd4K
        NotificationCenter.default.post(name: UIScreen.modeDidChangeNotification, object: UIScreen.main)
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        XCTAssertEqual(box.seen.last, .uhd4K)
        window.isHidden = true
    }
    #endif
}
