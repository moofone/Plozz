import FeatureLiveTVCore
import XCTest
@testable import FeatureLiveTV

final class LiveTVGlassLineupLogicTests: XCTestCase {
    func testPageGeometryIsTheTagPickersWithASubtitleLine() {
        typealias Picker = LiveTVGlassTagPickerMetrics
        XCTAssertEqual(LiveTVGlassLineupMetrics.fixedRowTop, 40 + 52 + 14 + 34 + 22, "the mockup's topY")
        XCTAssertEqual(LiveTVGlassLineupMetrics.fixedRowTop - Picker.fixedRowTop, 48)
        XCTAssertEqual(LiveTVGlassLineupMetrics.fixedHeight, LiveTVGlassLineupMetrics.fixedRowTop + 56 + 18)
    }

    func testCopyMatchesTheMockup() {
        XCTAssertEqual(LiveTVGlassLineupText.title, "My Channels")
        XCTAssertEqual(LiveTVGlassLineupText.subtitle, "Only these channels are loaded, given guides and searched.")
        XCTAssertEqual(LiveTVGlassLineupText.findCountry, "Find a country")
        XCTAssertEqual(LiveTVGlassLineupText.apply, "Apply")
        XCTAssertEqual(LiveTVGlassLineupText.noMatch("zz"), "No countries match “zz”")
        XCTAssertEqual(LiveTVGlassLineupText.withoutCountryNote, "Kept unless you remove them — the 4K groups are here.")
        XCTAssertEqual(LiveTVGlassLineupText.adultNote, "Off unless turned on with the Parental PIN. Never on Kids profiles.")
        XCTAssertEqual(LiveTVGlassLineupText.alwaysKeep, "Always Keep")
        XCTAssertTrue(LiveTVGlassLineupText.count(kept: 14_835, total: 31_330).hasSuffix("channels"))
        XCTAssertTrue(LiveTVGlassLineupText.count(kept: 3, total: 9).hasPrefix("3 of 9"))
    }

    func testAlwaysKeepRowsAreTheMockupsThree() {
        let rows = LiveTVGlassLineupText.keepRows
        XCTAssertEqual(rows.map(\.keep), [.favouritesAndRecents, .liveEvents, .searchLeftOut])
        XCTAssertEqual(rows.map(\.title), ["Favourites and Recently Watched", "All Live Events", "Left-out Channels in Search"])
        XCTAssertEqual(rows.map(\.height), [60, 76, 76])
        XCTAssertEqual(rows.map(\.note), [nil, "From every country", "By name only, without guide"])
    }
}

#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit

/// A hosted render of Set Up My Channels (the real sheet, 1080p units) measured against the mockup's `lineupLayout`: title at the panel
/// padding, the count at its right edge, the search row at 162, Apply after the 520 field, the first chip row below the section label.
@MainActor
final class LiveTVGlassLineupScreenHostedTests: XCTestCase {
    func testSheetRendersAtTheMockupsGeometry() throws {
        let state = LiveTVLineupState(store: nil)
        state.record(
            inventory: LiveTVLineupInventory(
                total: 31_330, codeCounts: ["US": 3_545, "GB": 1_317, "IN": 1_157, "DE": 979, "FR": 888, "CA": 495],
                groups: [.init(id: "Ultra HD", title: "Ultra HD", count: 45), .init(id: "", title: "Everything Else", count: 20_000)],
                adultCount: 14),
            leftOut: [])
        let size = CGSize(width: 1_180, height: 920)
        let view = ZStack(alignment: .topLeading) {
            Color.black
            LiveTVGlassLineupSheet(state: state, size: size, onApply: {}, onBack: {})
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading).ignoresSafeArea())
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in window.layer.render(in: context.cgContext) }
        let directory = ProcessInfo.processInfo.environment["PLOZZ_LIVETV_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? image.pngData()?.write(to: directory.appendingPathComponent("lineup-sheet-1080.png"))
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func ink(_ rect: CGRect, above threshold: Int = 150) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in Int(rect.minY)..<min(height, Int(rect.maxY)) {
                for x in Int(rect.minX)..<min(width, Int(rect.maxX)) {
                    let i = (y * width + x) * 4
                    if (Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1_000 > threshold {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        let title = try XCTUnwrap(ink(CGRect(x: 20, y: 30, width: 500, height: 70)), "title")
        XCTAssertEqual(title.minX, 40, accuracy: 6, "title left = the panel padding")
        XCTAssertEqual(title.midY, 40 + 26, accuracy: 10, "title centre y")
        let count = try XCTUnwrap(ink(CGRect(x: 700, y: 30, width: 460, height: 70), above: 90), "count")
        XCTAssertEqual(count.maxX, 1_180 - 40, accuracy: 8, "count right edge = padding from the right")
        let field = try XCTUnwrap(ink(CGRect(x: 30, y: 150, width: 545, height: 80), above: 15), "search field capsule")
        XCTAssertEqual(field.minY, 162, accuracy: 6, "search row top")
        XCTAssertEqual(field.width, 520, accuracy: 8, "the field is 520 wide")
        let chips = try XCTUnwrap(ink(CGRect(x: 30, y: 270, width: 1_000, height: 120), above: 200), "the selected chips (white)")
        XCTAssertGreaterThan(chips.minY, 240, "chips start below the section label")
    }
}
#endif
