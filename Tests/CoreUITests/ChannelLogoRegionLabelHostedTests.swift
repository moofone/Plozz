#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

/// Renders the real `BareChannelLogo` view (logo + region label) at the 1080 and 4K guide cells on both themes and measures the block on
/// the rendered pixels: edges detected in the image, offsets from the visible cell's centre. Alignment gate: every offset <= 0.5 pt.
/// Logos are drawn in code (no provider or third-party artwork); the sheets are saved next to the mock's sheets when that folder exists.
@MainActor
final class ChannelLogoRegionLabelHostedTests: XCTestCase {
    /// Under `PLOZZ_BRIEFS_DIR` (`TEST_RUNNER_PLOZZ_BRIEFS_DIR`); nothing is written without it.
    private let shots = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PLOZZ_BRIEFS_DIR"] ?? "/nonexistent").appendingPathComponent("logo-test/shots")
    private let scale: CGFloat = 4
    private static let ink = UIColor(red: 230 / 255, green: 20 / 255, blue: 20 / 255, alpha: 1)

    private struct Mark { let name: String; let draw: (CGSize) -> Void; let size: CGSize }

    /// Stand-ins for a wide wordmark, a thin wordmark, an asymmetric chevron and a small mark above a wide bar.
    private var marks: [Mark] {
        let red = Self.ink
        return [
            Mark(name: "wide", draw: { s in red.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: s.height, height: s.height)).fill()
                UIBezierPath(rect: CGRect(x: s.height * 1.2, y: s.height * 0.15, width: s.width - s.height * 1.2, height: s.height * 0.7)).fill() }, size: CGSize(width: 390, height: 100)),
            Mark(name: "thin", draw: { s in red.setFill()
                for i in 0..<6 { UIBezierPath(rect: CGRect(x: CGFloat(i) * s.width / 6, y: 0, width: s.width / 14, height: s.height)).fill() } }, size: CGSize(width: 300, height: 100)),
            Mark(name: "chevron", draw: { s in red.setFill(); let p = UIBezierPath()
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: s.width * 0.45, y: s.height / 2)); p.addLine(to: CGPoint(x: 0, y: s.height)); p.close(); p.fill()
                UIBezierPath(rect: CGRect(x: s.width * 0.55, y: s.height * 0.3, width: s.width * 0.45, height: s.height * 0.4)).fill() }, size: CGSize(width: 260, height: 100)),
            Mark(name: "small-above-bar", draw: { s in red.setFill()
                UIBezierPath(rect: CGRect(x: 0, y: 0, width: s.width * 0.3, height: s.height * 0.3)).fill()
                UIBezierPath(rect: CGRect(x: 0, y: s.height * 0.4, width: s.width, height: s.height * 0.6)).fill() }, size: CGSize(width: 300, height: 120))
        ]
    }

    private let labels = ["Halifax", "Calgary", "Montréal", "St. John's", "Charlottetown", "Windsor"]

    private func prepared(_ mark: Mark, theme: ChannelLogoExtraction.Theme) throws -> ChannelLogoExtraction.Prepared {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let data = UIGraphicsImageRenderer(size: mark.size, format: format).pngData { _ in mark.draw(mark.size) }
        return try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme))
    }

    private struct Measurement { var topGap = 0.0, bottomGap = 0.0, blockOffsetY = 0.0, logoOffsetX = 0.0, labelOffsetX = 0.0, inkCentreDelta = 0.0 }

    private func measure(_ image: UIImage, row: (Double, Double, Double), cell: CGSize) throws -> Measurement {
        let pixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(image.cgImage)))
        var logo = (minX: Int.max, maxX: -1, minY: Int.max, maxY: -1)
        var label = (minX: Int.max, maxX: -1, minY: Int.max, maxY: -1)
        // The cell's fractional edge pixels (the 4K cell is 170.6 pt wide) are partly outside the background; they are not ink.
        for y in 0..<(pixels.height - 1) {
            for x in 0..<(pixels.width - 1) {
                let i = (y * pixels.width + x) * 4
                let r = Double(pixels.bytes[i]), g = Double(pixels.bytes[i + 1]), b = Double(pixels.bytes[i + 2])
                let redness = (r - g) / (230 - 20)
                if redness >= 0.5 {
                    logo = (min(logo.minX, x), max(logo.maxX, x), min(logo.minY, y), max(logo.maxY, y))
                } else if redness < 0.08, (abs(r - row.0) + abs(g - row.1) + abs(b - row.2)) / 3 >= 0.4 * 160 * 0.6 {
                    label = (min(label.minX, x), max(label.maxX, x), min(label.minY, y), max(label.maxY, y))
                }
            }
        }
        XCTAssertGreaterThan(logo.maxX, 0, "no logo ink found")
        XCTAssertGreaterThan(label.maxX, 0, "no label ink found")
        let s = Double(scale)
        let top = Double(logo.minY) / s, bottom = Double(label.maxY + 1) / s
        var m = Measurement()
        m.topGap = top
        m.bottomGap = Double(cell.height) - bottom
        m.blockOffsetY = (top + bottom) / 2 - Double(cell.height) / 2
        m.logoOffsetX = (Double(logo.minX) + Double(logo.maxX + 1)) / 2 / s - Double(cell.width) / 2
        m.labelOffsetX = (Double(label.minX) + Double(label.maxX + 1)) / 2 / s - Double(cell.width) / 2
        m.inkCentreDelta = m.logoOffsetX - m.labelOffsetX
        return m
    }

    func testBlockIsInkCentredInTheVisibleCellOnBothLayoutsAndThemes() throws {
        let cells: [(String, CGSize)] = [
            ("1080", CGSize(width: 252, height: 82)),
            ("4k", CGSize(width: 252 * (74 * 0.75 / 82), height: 74 * 0.75))
        ]
        var table = "| layout | theme | mark | label | top gap | bottom gap | block dy | logo dx | label dx | logo-label dx |\n|---|---|---|---|---|---|---|---|---|---|\n"
        var worst = 0.0
        for (layoutName, cell) in cells {
            for theme in [ChannelLogoExtraction.Theme.dark, .light] {
                var tiles: [UIImage] = []
                for (index, mark) in marks.enumerated() {
                    let label = labels[index % labels.count]
                    let preparedLogo = try prepared(mark, theme: theme)
                    XCTAssertFalse(preparedLogo.needsTextFallback, "\(mark.name) \(theme)")
                    let url = URL(string: "https://logos.example.test/hosted/\(layoutName)-\(theme.rawValue)-\(mark.name).png")!
                    ChannelLogoExtractionLoader.seed(preparedLogo, url: url, providerRequestsDarkBackground: false, theme: theme)
                    let row = theme == .dark ? ChannelLogoExtraction.darkRowRGB : ChannelLogoExtraction.lightRowRGB
                    let view = BareChannelLogo(
                        name: "", logoURL: url, size: cell, cornerRadius: 0, artworkInset: 0, qualityBadge: nil,
                        providerRequestsDarkBackground: false, regionLabel: label)
                        .environment(\.themePalette, theme == .dark ? .dark : .light)
                        .frame(width: cell.width, height: cell.height)
                        .background(Color(red: row.0 / 255, green: row.1 / 255, blue: row.2 / 255))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = scale
                    let image = try XCTUnwrap(renderer.uiImage)
                    let m = try measure(image, row: row, cell: cell)
                    let offsets = [abs(m.blockOffsetY), abs(m.logoOffsetX), abs(m.labelOffsetX), abs(m.inkCentreDelta)]
                    worst = max(worst, offsets.max() ?? 0)
                    table += String(format: "| %@ | %@ | %@ | %@ | %.2f | %.2f | %+.2f | %+.2f | %+.2f | %+.2f |\n", layoutName, theme.rawValue, mark.name, label,
                                    m.topGap, m.bottomGap, m.blockOffsetY, m.logoOffsetX, m.labelOffsetX, m.inkCentreDelta)
                    for value in offsets { XCTAssertLessThanOrEqual(value, 0.5, "\(layoutName) \(theme) \(mark.name) \(label) offsets \(offsets)") }
                    tiles.append(image)
                }
                guard FileManager.default.fileExists(atPath: shots.path) else { continue }
                let width = tiles.map { $0.size.width }.reduce(8) { $0 + $1 + 8 }
                let sheet = UIGraphicsImageRenderer(size: CGSize(width: width, height: cell.height + 16)).image { context in
                    UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: cell.height + 16))
                    var x: CGFloat = 8
                    for tile in tiles { tile.draw(in: CGRect(x: x, y: 8, width: tile.size.width, height: tile.size.height)); x += tile.size.width + 8 }
                }
                try sheet.pngData()?.write(to: shots.appendingPathComponent("app-align-\(layoutName)-\(theme.rawValue).png"))
            }
        }
        if FileManager.default.fileExists(atPath: shots.path) {
            try table.write(to: shots.appendingPathComponent("app-align-offsets.md"), atomically: true, encoding: .utf8)
        }
        print("HOSTED-ALIGN worst offset \(worst) pt\n\(table)")
    }
}
#endif
