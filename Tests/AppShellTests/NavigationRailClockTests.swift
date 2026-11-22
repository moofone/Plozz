#if os(tvOS)
import CoreText
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import AppShell

final class NavigationRailClockTests: XCTestCase {
    /// The width the time text needs: tabular digits (as `.monospacedDigit()` draws them) at the clock's font size, scaled for the canvas.
    private func width(of text: String, scale: CGFloat) -> CGFloat {
        let base = CTFontCreateUIFontForLanguage(.emphasizedSystem, NavigationRailClock.timeFontSize * scale, nil)!
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType, kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]]
        ] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, 0, nil, descriptor)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func testWidestTimesFitTheBoxAtFullSizeAt1080pAnd4K() {
        for scale in [CGFloat(1), 2] {
            for text in ["10:00", "11:11", "12:59", "23:59", "00:00"] {
                let needed = width(of: text, scale: scale)
                XCTAssertLessThanOrEqual(needed, NavigationRailClock.width * scale - 8 * scale, "\(text) at \(scale)x")
            }
        }
    }

    func testBoxStaysCentredOnTheMockupColumn() {
        XCTAssertEqual(NavigationRailClock.centerX, 60)
        XCTAssertEqual(NavigationRailClock.centerFromBottom, 81, "the mockup's H − railTop position, not POLISH-1's 40")
        XCTAssertGreaterThan(NavigationRailClock.width, NavigationRailClock.size)
    }

    /// 4K: the box, font and column centre are the 1080p values × 0.9 (the mockup's `AL(true).z`), and the widest time still fits.
    func testFourKClockScalesWithTheTokensAndStillFits() {
        let hd = NavigationRailClock.Metrics(layout: .hd1080)
        let uhd = NavigationRailClock.Metrics(layout: .uhd4K)
        XCTAssertEqual(hd.centerX, 60); XCTAssertEqual(hd.centerFromBottom, 81); XCTAssertEqual(uhd.centerFromBottom, 72.9, accuracy: 0.001); XCTAssertEqual(hd.timeFontSize, 31)
        XCTAssertEqual(uhd.timeFontSize, 31 * 0.9, accuracy: 0.001)
        XCTAssertEqual(uhd.centerX, 54, accuracy: 0.001)
        XCTAssertEqual(uhd.size, 84 * 0.9, accuracy: 0.001)
        for text in ["10:00", "12:59", "23:59", "00:00"] {
            let needed = width(of: text, scale: LiveTVGlassLayout.uhd4K.uiScale)
            XCTAssertLessThanOrEqual(needed, uhd.width - 8 * 0.9, "\(text) at 4K")
        }
    }

    func testTwoDigitHoursAreFormattedInFull() {
        let calendar = Calendar(identifier: .gregorian)
        func date(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hour, minute: minute))!
        }
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
        XCTAssertEqual(NavigationRailClock.parts(for: date(22, 5), locale: us).time, "10:05")
        XCTAssertEqual(NavigationRailClock.parts(for: date(12, 59), locale: us).time, "12:59")
        XCTAssertEqual(NavigationRailClock.parts(for: date(23, 59), locale: gb).time, "23:59")
        XCTAssertNil(NavigationRailClock.parts(for: date(23, 59), locale: gb).period)
    }

    /// The clock drawn on a 1920 × 1080 canvas where the rail overlay puts it (`Metrics`), at both sizes: the time's ink centre sits
    /// 0.9 × as far from the bottom edge at 4K, the box never clips, and the render is written next to the Live TV snapshots.
    @MainActor func testHostedClockScalesFromTheScreenEdgeAndNeverClips() throws {
        var centres: [CGFloat] = []
        for (layout, name) in [(LiveTVGlassLayout.hd1080, "1080"), (LiveTVGlassLayout.uhd4K, "4K")] {
            let metrics = NavigationRailClock.Metrics(layout: layout)
            let scene = ZStack(alignment: .topLeading) {
                Color.black
                NavigationRailClock()
                    .position(x: metrics.centerX, y: 1_080 - metrics.centerFromBottom)
            }
            .frame(width: 1_920, height: 1_080)
            .environment(\.liveTVGlassLayout, layout)
            .environment(\.locale, Locale(identifier: "en_US"))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var minY = Int.max, maxY = -1, minX = Int.max, maxX = -1
            for y in 0..<height { for x in 0..<width where rgba[(y * width + x) * 4] > 90 {
                minY = min(minY, y); maxY = max(maxY, y); minX = min(minX, x); maxX = max(maxX, x)
            } }
            XCTAssertGreaterThan(maxY, 0, "\(name) draws the clock")
            XCTAssertGreaterThanOrEqual(minX, Int(metrics.centerX - metrics.width / 2), "\(name) left")
            XCTAssertLessThanOrEqual(maxX, Int(metrics.centerX + metrics.width / 2), "\(name) right")
            XCTAssertLessThanOrEqual(maxY, 1_080 - 1, "\(name) bottom")
            centres.append(1_080 - CGFloat(minY + maxY) / 2)
            // The time and the period are two ink bands; the mockup's `.aclock b` / `i` rects (DOM, 1920 pt space) are the reference.
            var bands: [(Int, Int)] = []
            for y in minY...maxY where (0..<width).contains(where: { rgba[(y * width + $0) * 4] > 90 }) {
                if let last = bands.last, y - last.1 <= 3 { bands[bands.count - 1].1 = y } else { bands.append((y, y)) }
            }
            let mockup = layout == .uhd4K ? (time: CGFloat(997.05), period: CGFloat(1021.07), x: CGFloat(54))
                : (time: CGFloat(987.5), period: CGFloat(1014.27), x: CGFloat(60))
            let timeCentre = CGFloat(bands[0].0 + bands[0].1) / 2
            let periodCentre = bands.count > 1 ? CGFloat(bands[1].0 + bands[1].1) / 2 : 0
            let report = "| element | mockup (pt) | app (pt) | Δ |\n|---|---|---|---|\n"
                + "| \(name) clock x centre | \(mockup.x) | \(CGFloat(minX + maxX) / 2) | \(CGFloat(minX + maxX) / 2 - mockup.x) |\n"
                + "| \(name) time centre y | \(mockup.time) | \(timeCentre) | \(timeCentre - mockup.time) |\n"
                + "| \(name) period centre y | \(mockup.period) | \(periodCentre) | \(periodCentre - mockup.period) |\n"
            XCTAssertEqual(CGFloat(minX + maxX) / 2, mockup.x, accuracy: 4, "\(name) clock x")
            XCTAssertEqual(timeCentre, mockup.time, accuracy: 4, "\(name) time centre y")
            XCTAssertEqual(periodCentre, mockup.period, accuracy: 4, "\(name) period centre y")
            let reportBase = ProcessInfo.processInfo.environment["PLOZZ_LIVETV_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("PlozzLiveTVRes4K")
            try? FileManager.default.createDirectory(at: reportBase, withIntermediateDirectories: true)
            try? report.write(to: reportBase.appendingPathComponent("clock-\(name).md"), atomically: true, encoding: .utf8)
            let base = ProcessInfo.processInfo.environment["PLOZZ_LIVETV_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("PlozzLiveTVRes4K")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? UIImage(cgImage: image).pngData()?.write(to: base.appendingPathComponent("clock-\(name).png"))
            print("LIVETV-RES4K clock \(name): ink x \(minX)...\(maxX) y \(minY)...\(maxY) (top-left origin)")
        }
        XCTAssertEqual(centres[1] / centres[0], 0.9, accuracy: 0.03)
    }
    // MARK: Expanded menu clock

    /// The collapsed and the expanded clock's boxes share one vertical centre, so opening the menu never moves the clock; the
    /// expanded box is the sheet's width, centred in it (mockup `.aclock.wide`).
    func testExpandedClockKeepsTheCollapsedClocksVerticalCentreAndCentresInTheSheet() {
        for layout in [LiveTVGlassLayout.hd1080, .uhd4K] {
            let collapsed = NavigationRailClock.Placement(layout: layout, isExpanded: false)
            let expanded = NavigationRailClock.Placement(layout: layout, isExpanded: true)
            XCTAssertEqual(expanded.centerFromBottom, collapsed.centerFromBottom)
            XCTAssertEqual(expanded.height, collapsed.height)
            let sheetMinX = NavigationRailMetrics.expandedPanelLayoutInset
            let sheetMaxX = NavigationRailMetrics.expandedWidth - NavigationRailMetrics.expandedPanelLayoutInset
            XCTAssertEqual(expanded.centerX - expanded.width / 2, sheetMinX)
            XCTAssertEqual(expanded.centerX + expanded.width / 2, sheetMaxX)
            XCTAssertEqual(collapsed.centerX, layout.ui(NavigationRailClock.centerX))
        }
    }

    /// The mockup's `.aclock.wide` sizes (1080p: time 34, AM/PM 24, date 22, gap 4) × the layout's UI scale.
    func testExpandedClockSizesFollowTheMockup() {
        let hd = NavigationRailExpandedClock.Metrics(layout: .hd1080)
        XCTAssertEqual([hd.timeFontSize, hd.periodFontSize, hd.dateFontSize, hd.lineGap], [34, 24, 22, 4])
        let uhd = NavigationRailExpandedClock.Metrics(layout: .uhd4K)
        XCTAssertEqual(uhd.timeFontSize, 34 * 0.9, accuracy: 0.001)
        XCTAssertEqual(uhd.dateFontSize, 22 * 0.9, accuracy: 0.001)
    }

    func testExpandedClockDateFollowsTheLocale() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 18, minute: 52))!
        XCTAssertEqual(NavigationRailExpandedClock.dateText(for: date, locale: Locale(identifier: "en_US")), "Saturday, November 14")
        XCTAssertEqual(NavigationRailExpandedClock.dateText(for: date, locale: Locale(identifier: "fr_FR")), "samedi 14 novembre")
        XCTAssertEqual(NavigationRailClock.parts(for: date, locale: Locale(identifier: "en_US")).period, "PM")
    }

    /// The expanded clock drawn where the rail puts it at both sizes: two ink bands (the one-line time, then the date), centred on
    /// the sheet's axis, inside the sheet, and the pair's centre where the collapsed clock's was.
    @MainActor func testHostedExpandedClockIsCentredInTheSheetAtTheCollapsedCentre() throws {
        for (layout, name) in [(LiveTVGlassLayout.hd1080, "1080"), (LiveTVGlassLayout.uhd4K, "4K")] {
            let placement = NavigationRailClock.Placement(layout: layout, isExpanded: true)
            let scene = ZStack(alignment: .topLeading) {
                Color.black
                NavigationRailExpandedClock()
                    .frame(width: placement.width, height: placement.height)
                    .position(x: placement.centerX, y: 1_080 - placement.centerFromBottom)
            }
            .frame(width: 1_920, height: 1_080)
            .environment(\.liveTVGlassLayout, layout)
            .environment(\.locale, Locale(identifier: "en_US"))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            var bands: [(Int, Int)] = []
            for y in 0..<height {
                var rowHasInk = false
                for x in 0..<width where rgba[(y * width + x) * 4] > 60 {
                    rowHasInk = true
                    minX = min(minX, x); maxX = max(maxX, x)
                }
                guard rowHasInk else { continue }
                minY = min(minY, y); maxY = max(maxY, y)
                if let last = bands.last, y - last.1 <= 3 { bands[bands.count - 1].1 = y } else { bands.append((y, y)) }
            }
            XCTAssertEqual(bands.count, 2, "\(name): the time on one line, the date under it")
            XCTAssertGreaterThanOrEqual(CGFloat(minX), placement.centerX - placement.width / 2, "\(name) left")
            XCTAssertLessThanOrEqual(CGFloat(maxX), placement.centerX + placement.width / 2, "\(name) right")
            XCTAssertEqual(CGFloat(minX + maxX) / 2, placement.centerX, accuracy: 6, "\(name) centred on the sheet's axis")
            XCTAssertEqual(CGFloat(minY + maxY) / 2, 1_080 - placement.centerFromBottom, accuracy: 6, "\(name) vertical centre")
        }
    }
}
#endif
