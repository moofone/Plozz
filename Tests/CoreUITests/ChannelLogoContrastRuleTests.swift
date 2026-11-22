#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// The deterministic contrast rule over every real logo file kept as a fixture (provider files, cached files the app fetched, plus
/// synthetics): after recolouring, and the flat plate if needed, each logo passes on both themes.
final class ChannelLogoContrastRuleTests: XCTestCase {
    private func fixtures() throws -> [(name: String, data: Data)] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "LogoRule", withExtension: nil, subdirectory: "Fixtures"))
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    /// Quality icons (transparent, wide enough, sane shape) are recoloured and must pass the rule on both themes; everything else
    /// (provider tiles, low resolution, boxed logos) is shown as text. No plate exists.
    func testQualityIconsPassAfterRecolourAndTheRestFallToText() throws {
        let quality: Set<String> = ["CBC_16644.png", "GLOBAL_16702.png", "GLOBAL_NEWS_16704.png", "CTV_NEWS_CHANNEL_navy.png", "SPORTSNET.png", "BBC_RED_BUTTON.png"]
        let tiles: [String] = ["PROV_CA_EN__CTV_ATLENTIC__ATV_MONCTON_.jpg", "PROV_CA_EN__CTV_CALARY_NEWS.jpg", "PROV_CA_EN__GLOBAL_CALAGRY_SD.jpg", "PROV_CA_EN__GLOBAL_MONTREAL.jpg", "PROV_CA_EN__CBC_CALGARY_HD.jpg", "FOX_NEWS_colour.png", "ADULT_SWIM.jpg"]
        var failures: [String] = []
        for (name, data) in try fixtures() {
            for theme in [ChannelLogoExtraction.Theme.dark, .light] {
                let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme), name)
                if quality.contains(name), prepared.needsTextFallback { failures.append("\(name)/\(theme.rawValue) fell to text at \(Int(prepared.readableShare * 100))%") }
                if tiles.contains(name), !prepared.needsTextFallback { failures.append("\(name)/\(theme.rawValue) tile kept as a logo") }
            }
        }
        XCTAssertEqual(failures, [])
    }

    /// A quality colour icon that already reads is returned exactly as it was: no recolour, no text.
    func testAlreadyGoodQualityIconIsUnchangedByteForByte() throws {
        // SYNTHETIC: a 300 x 100 transparent icon with a red disc and a mid-blue bar.
        var bytes = [UInt8]()
        for y in 0..<100 { for x in 0..<300 {
            let disc = (x - 50) * (x - 50) + (y - 50) * (y - 50) < 1600
            bytes += disc ? [225, 40, 50, 255] : (x > 110 && x < 280 && y > 30 && y < 70) ? [60, 130, 230, 255] : [0, 0, 0, 0]
        } }
        let icon = try XCTUnwrap(ChannelLogoPixels(width: 300, height: 100, bytes: bytes))
        let data = try XCTUnwrap(ChannelLogoExtraction.makeImage(icon).flatMap { UIImage(cgImage: $0).pngData() })
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let treated = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme))
            let untouched = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, whitensMixedInk: false, theme: theme))
            XCTAssertFalse(treated.needsTextFallback, "\(theme)")
            XCTAssertEqual(
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(treated.image.cgImage)),
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(untouched.image.cgImage)))
        }
    }

    /// A tile with a baked box (the 1024 x 967 boxed logo) is not an icon even though its box strips cleanly.
    func testBoxedTileIsRejectedByTheOriginalImagesOpaqueShare() throws {
        let fox = try XCTUnwrap(try fixtures().first { $0.name == "FOX_NEWS_colour.png" })
        let stripped = try XCTUnwrap(ChannelLogoExtraction.strippingBackground(fox.data))
        XCTAssertLessThan(stripped.originalSeeThrough, ChannelLogoExtraction.minimumOriginalSeeThroughShare)
        XCTAssertTrue(ChannelLogoExtraction.isQualityIcon(stripped.pixels), "the stripped box alone would have passed")
        XCTAssertTrue(try XCTUnwrap(ChannelLogoExtraction.prepare(data: fox.data, providerRequestsDarkBackground: false)).needsTextFallback)
    }

    /// The real 314 x 204 TMDB CTV News Channel logo: the CTV mark (red C disc, blue T tile, green V) keeps its exact colours on both themes
    /// and only the navy NEWS CHANNEL wordmark is recoloured. Writes before/after PNGs to /tmp/ctv-fix for viewing.
    func testCTVNewsChannelMarkIsUntouchedAndOnlyTheWordmarkIsRecoloured() throws {
        let data = try XCTUnwrap(try fixtures().first { $0.name == "CTV_NEWS_CHANNEL_tmdb_314x204.png" }).data
        let original = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(ChannelLogoExtraction.decode(data))))
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme))
            XCTAssertFalse(prepared.isDark, "a mixed logo is recoloured in place, never drawn as one white silhouette (\(theme))")
            let after = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared.image.cgImage)))
            XCTAssertEqual(after.width, original.width)
            XCTAssertEqual(after.height, original.height)
            var markChanged = 0, markTotal = 0, wordChanged = 0
            for y in 0..<original.height {
                for x in 0..<original.width {
                    let i = (y * original.width + x) * 4
                    guard original.bytes[i + 3] > 200 else { continue }
                    let same = (0..<3).allSatisfy { abs(Int(original.bytes[i + $0]) - Int(after.bytes[i + $0])) <= 2 }
                    let inMark = y < original.height * 33 / 100 && x > original.width * 40 / 100
                    if inMark { markTotal += 1; if !same { markChanged += 1 } } else if !same { wordChanged += 1 }
                }
            }
            XCTAssertEqual(markChanged, 0, "mark pixels must be untouched (\(theme))")
            XCTAssertGreaterThan(markTotal, 1000)
            if theme == .dark { XCTAssertGreaterThan(wordChanged, 2000, "the navy wordmark is whitened on dark") }
            try? FileManager.default.createDirectory(atPath: "/tmp/ctv-fix", withIntermediateDirectories: true)
            let back: UIColor = theme == .dark ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.94, alpha: 1)
            let size = CGSize(width: 314 * 2 + 20, height: 204 + 20)
            let sheet = UIGraphicsImageRenderer(size: size).image { _ in
                back.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
                UIImage(data: data)?.draw(at: CGPoint(x: 10, y: 10))
                prepared.image.draw(at: CGPoint(x: 324, y: 10))
            }
            try? sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ctv-fix/\(theme)-before-after.png"))
        }
    }

    /// Name text: one line if it fits, else two balanced lines at a word boundary, shrink to the floor, ellipsis only on line 2.
    func testNameTextBreaksAtWordsAndNeverMidWord() {
        let measure: (String) -> Double = { Double($0.count) * 10 }
        func layout(_ name: String, _ width: Double) -> ChannelLogoExtraction.NameLayout { ChannelLogoExtraction.nameLayout(name, maxWidth: width, width: measure) }
        XCTAssertEqual(layout("TV5", 164).lines, ["TV5"])
        XCTAssertEqual(layout("CTV News Channel", 164).lines, ["CTV News Channel"], "fits on one line")
        XCTAssertEqual(layout("CTV News Channel", 120).lines, ["CTV News", "Channel"])
        XCTAssertEqual(layout("Global Calgary SD", 120).lines, ["Global", "Calgary SD"])
        XCTAssertEqual(layout("CTV Calgary News", 100).lines, ["CTV Calgary", "News"], "the break that minimises the longer line")
        XCTAssertEqual(layout("AB CD EF GH", 60).lines, ["AB CD", "EF GH"], "equal splits keep the leading words on line 1")
        XCTAssertEqual(layout("Ici Télé Ottawa-Gatineau", 150).lines, ["Ici Télé", "Ottawa-Gatineau"])
        let long = layout("Supercalifragilisticexpialidocious", 100)
        XCTAssertEqual(long.lines, ["Supercalifragilisticexpialidocious"])
        XCTAssertEqual(long.scale, ChannelLogoExtraction.minimumNameScale, accuracy: 0.0001)
        XCTAssertTrue(long.truncatesLastLine)
        XCTAssertFalse(layout("CTV News Channel", 120).truncatesLastLine)
    }

    /// The logo is centred in its one box, scaled uniformly and never stretched, for any aspect.
    func testLogoIsCentredInItsBoxAtItsOwnAspect() {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        for aspect in [0.5, 1, 2.6, 5.5] {
            let logo = geometry.layout(aspect: aspect, badge: nil).logo
            XCTAssertEqual(logo.midX, geometry.box.width / 2, accuracy: 0.5)
            XCTAssertEqual(logo.midY, geometry.box.height / 2, accuracy: 0.5)
            XCTAssertEqual(logo.width / logo.height, aspect, accuracy: aspect * 0.01)
            XCTAssertLessThanOrEqual(logo.width, geometry.box.width + 0.5)
            XCTAssertLessThanOrEqual(logo.height, geometry.box.height + 0.5)
        }
    }

    /// The real 96 x 96 provider tiles (a wide logo squashed into a square with a baked box) are never logos.
    func testSquareProviderTilesFallToText() throws {
        for (name, data) in try fixtures() where name.hasPrefix("PROV_") {
            let decoded = try XCTUnwrap(ChannelLogoExtraction.decode(data))
            XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 128, name)
            for theme in [ChannelLogoExtraction.Theme.dark, .light] {
                XCTAssertTrue(try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme)).needsTextFallback, "\(name) \(theme)")
            }
        }
    }

    /// The treatment is generic: nothing in the extraction code names a channel, network, provider or logo source.
    func testExtractionCodeNamesNoChannelOrProvider() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CoreUI/ChannelLogoExtraction.swift")
        let code = try String(contentsOf: path, encoding: .utf8).lowercased()
        for word in ["cbc", "global", "ctv", "bbc", "fox", "sportsnet", "tmdb", "xmltv", "wikidata", "plex", "jellyfin", "emby", "iptv", "adult swim", "bnn"] {
            XCTAssertFalse(code.contains(word), "extraction code mentions \(word)")
        }
    }
}
#endif
