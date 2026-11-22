#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// Writes the real `ChannelLogoExtraction.prepare` output for the logo files in `_briefs/live-tv-glass/provider-logos` (both themes, and the
/// pre-fix rule for comparison) to `_briefs/live-tv-glass/logo-test/` for the HTML gallery. Skipped when that folder is not there.
final class ChannelLogoGalleryTests: XCTestCase {
    /// The briefs folder, from `PLOZZ_BRIEFS_DIR` (`TEST_RUNNER_PLOZZ_BRIEFS_DIR`); the test skips without it.
    private let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PLOZZ_BRIEFS_DIR"] ?? "/nonexistent")

    /// WCAG contrast of an sRGB colour against another.
    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { let v = c / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Share of the drawn ink (alpha-weighted) whose contrast against `row` is at least 3:1.
    private func readableShare(_ p: ChannelLogoPixels, row: (Double, Double, Double)) -> Double {
        let rowL = luminance(row.0, row.1, row.2)
        var good = 0.0, total = 0.0, i = 0
        while i < p.bytes.count {
            let a = Double(p.bytes[i + 3]) / 255
            if p.bytes[i + 3] > ChannelLogoExtraction.trimAlphaThreshold {
                // The ink over the row, as composited.
                let r = Double(p.bytes[i]) * a + row.0 * (1 - a), g = Double(p.bytes[i + 1]) * a + row.1 * (1 - a), b = Double(p.bytes[i + 2]) * a + row.2 * (1 - a)
                let l = luminance(r, g, b)
                let ratio = (max(l, rowL) + 0.05) / (min(l, rowL) + 0.05)
                total += a
                if ratio >= 3 { good += a }
            }
            i += 4
        }
        return total == 0 ? 1 : good / total
    }

    private func png(_ p: ChannelLogoPixels) -> Data? { ChannelLogoExtraction.makeImage(p).flatMap { UIImage(cgImage: $0).pngData() } }

    /// The image as the app draws it: a whole-silhouette logo is a template tinted white at 0.9.
    private func drawn(_ prepared: ChannelLogoExtraction.Prepared) throws -> ChannelLogoPixels {
        let px = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared.image.cgImage)))
        guard prepared.isDark else { return px }
        var bytes = px.bytes
        var i = 0
        while i < bytes.count { bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = UInt8(Double(bytes[i + 3]) * 0.9); i += 4 }
        return try XCTUnwrap(ChannelLogoPixels(width: px.width, height: px.height, bytes: bytes))
    }

    enum Mode: String, CaseIterable { case normal, reduceTransparency, increaseContrast }

    /// The logo slot as the app draws it for `prepared` on the theme's row: plate (opaque under Reduce Transparency; opaque with an edge
    /// under Increase Contrast), the image, or the channel name as text when the ink cannot read.
    func slot(_ prepared: ChannelLogoExtraction.Prepared, theme: ChannelLogoExtraction.Theme, mode: Mode, name: String) -> Data? {
        let rowRGB = theme == .dark ? ChannelLogoExtraction.darkRowRGB : ChannelLogoExtraction.lightRowRGB
        func colour(_ c: (Double, Double, Double), _ a: Double = 1) -> UIColor { UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: a) }
        let size = CGSize(width: 240, height: 80), box = CGRect(x: 20, y: 8, width: 200, height: 64)
        return UIGraphicsImageRenderer(size: size).pngData { ctx in
            colour(rowRGB).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            if prepared.needsTextFallback {
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let fg: UIColor = theme == .dark ? .white : UIColor(white: 0.1, alpha: 1)
                let font = UIFont.systemFont(ofSize: box.height * 0.4, weight: .semibold)
                (name as NSString).draw(in: box.insetBy(dx: 0, dy: 10), withAttributes: [.font: font, .foregroundColor: fg, .paragraphStyle: para])
                return
            }
            let aspect = prepared.image.size.width / prepared.image.size.height
            let pad: CGFloat = 0
            let inner = box.insetBy(dx: pad, dy: pad)
            var w = inner.width, h = w / aspect
            if h > inner.height { h = inner.height; w = h * aspect }
            let imgRect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
            if prepared.isDark {
                UIColor.white.withAlphaComponent(0.9).setFill()
                prepared.image.withRenderingMode(.alwaysTemplate).withTintColor(UIColor.white.withAlphaComponent(0.9)).draw(in: imgRect)
            } else {
                prepared.image.draw(in: imgRect)
            }
        }
    }

    func testWriteGalleryOutputs() throws {
        let source = root.appendingPathComponent("provider-logos"), out = root.appendingPathComponent("logo-test")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("no provider-logos folder") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let extra = out.appendingPathComponent("extra-sources")
        // SYNTHETIC near-white logo with a colour mark, for the light theme (no real example in the folder).
        let white = try XCTUnwrap(ChannelLogoPixels(width: 160, height: 60, bytes: (0..<(160 * 60)).flatMap { i -> [UInt8] in
            let x = i % 160, y = i / 160
            if (x - 30) * (x - 30) + (y - 30) * (y - 30) < 400 { return [230, 30, 40, 255] }
            if x > 62 && x < 150 && y > 18 && y < 42 && (x / 6 + y / 6) % 5 != 0 { return [248, 248, 248, 255] }
            return [0, 0, 0, 0]
        }))
        try XCTUnwrap(png(white)).write(to: extra.appendingPathComponent("SYNTHETIC_white_wordmark.png"))
        let darkRow = (25.0, 25.0, 27.0), lightRow = (240.0, 240.0, 240.0)
        let files = try (FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            + FileManager.default.contentsOfDirectory(at: extra, includingPropertiesForKeys: nil))
            .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seen = Set<Data>()
        var rows: [[String: Any]] = []
        for file in files {
            let data = try Data(contentsOf: file)
            guard seen.insert(data).inserted else { continue }   // the folder holds byte-identical copies under several names
            let base = file.deletingPathExtension().lastPathComponent
            let decoded = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(ChannelLogoExtraction.decode(data))))
            let raw = try XCTUnwrap(ChannelLogoExtraction.withoutBackgroundBox(data)).1   // what `prepare` analyses
            try XCTUnwrap(png(decoded)).write(to: out.appendingPathComponent("\(base)-orig.png"))
            var row: [String: Any] = ["file": file.lastPathComponent, "base": base]
            // The rule before this fix: a silhouette only for monochrome logos with a low mean luminance.
            let before = ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, whitensMixedInk: false)
            let profile = ChannelLogoExtraction.colourProfile(raw)
            let oldWhole = profile.map { $0.meanLuminance / 255 < ChannelLogoExtraction.darkLuminanceThreshold && $0.isMonochrome } ?? false
            if let before {
                var px = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(before.image.cgImage)))
                if oldWhole {
                    var b = px.bytes; var i = 0
                    while i < b.count { b[i] = 255; b[i + 1] = 255; b[i + 2] = 255; b[i + 3] = UInt8(Double(b[i + 3]) * 0.9); i += 4 }
                    px = try XCTUnwrap(ChannelLogoPixels(width: px.width, height: px.height, bytes: b))
                }
                try XCTUnwrap(png(px)).write(to: out.appendingPathComponent("\(base)-before.png"))
                row["before"] = ["treatment": oldWhole ? "whole silhouette" : "unchanged", "readable": readableShare(px, row: darkRow)]
            }
            for (theme, rowColour) in [(ChannelLogoExtraction.Theme.dark, darkRow), (.light, lightRow)] {
                var times: [Double] = []
                var prepared: ChannelLogoExtraction.Prepared?
                for _ in 0..<5 {
                    let start = ContinuousClock.now
                    prepared = ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme)
                    let d = ContinuousClock.now - start
                    times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                }
                let result = try XCTUnwrap(prepared)
                let px = try drawn(result)
                try XCTUnwrap(png(px)).write(to: out.appendingPathComponent("\(base)-\(theme.rawValue).png"))
                let share = ChannelLogoExtraction.inkShare(raw, theme: theme)?.share ?? 0
                let treatment = ChannelLogoExtraction.inkTreatment(raw, theme: theme)
                let displayName = base.replacingOccurrences(of: "CA_EN__", with: "").replacingOccurrences(of: "_", with: " ").capitalized
                var finals: [String: String] = [:]
                for mode in Mode.allCases {
                    let file = "\(base)-final-\(theme.rawValue)-\(mode.rawValue).png"
                    try XCTUnwrap(slot(result, theme: theme, mode: mode, name: displayName)).write(to: out.appendingPathComponent(file))
                    finals[mode.rawValue] = file
                }
                row[theme.rawValue] = [
                    "treatment": "\(treatment)", "clashingShare": share, "prepareMs": times.sorted()[2],
                    "readable": result.readableShare, "drawnAsSilhouette": result.isDark,
                    "text": result.needsTextFallback, "finals": finals]
            }
            // Without any recolouring: does the original already read on each row?
            var asIs: [String: Double] = [:]
            for (theme, rowColour) in [(ChannelLogoExtraction.Theme.dark, darkRow), (.light, lightRow)] {
                let plain = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, whitensMixedInk: false, theme: theme))
                _ = rowColour
                asIs[theme.rawValue] = ChannelLogoExtraction.readableInkShare(try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(plain.image.cgImage))), row: theme == .dark ? ChannelLogoExtraction.darkRowRGB : ChannelLogoExtraction.lightRowRGB)
            }
            row["asIs"] = asIs
            row["size"] = [decoded.width, decoded.height]
            row["source"] = file.deletingLastPathComponent().lastPathComponent
            rows.append(row)
        }
        let json = try JSONSerialization.data(withJSONObject: ["darkRow": [25, 25, 27], "lightRow": [240, 240, 240], "rule": ChannelLogoExtraction.minimumReadableInkShare, "logos": rows], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appendingPathComponent("results.json"))
    }
}
#endif
