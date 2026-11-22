#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

final class ChannelLogoDarkInkRealLogoTests: XCTestCase {
    private func data(_ file: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: file, withExtension: "png", subdirectory: "Fixtures/ProviderLogos"))
        return try Data(contentsOf: url)
    }

    private func darkPixelCount(_ p: ChannelLogoPixels) -> Int {
        var n = 0, i = 0
        while i < p.bytes.count {
            if p.bytes[i + 3] > ChannelLogoExtraction.trimAlphaThreshold,
               max(p.bytes[i], p.bytes[i + 1], p.bytes[i + 2]) <= UInt8(ChannelLogoExtraction.darkInkMaxChannel) { n += 1 }
            i += 4
        }
        return n
    }

    /// The real provider logos the owner reported (CBC, Global, Global News: black wordmark, red mark, on transparent). Their raw
    /// pixels are mostly dark ink; `prepare` must leave no dark-ink pixel (anti-aliased edges and the thin "NEWS" line included)
    /// and must keep the red mark red.
    func testRealCbcAndGlobalLogosLeaveNoBlackInkAndKeepTheRedMark() throws {
        for name in ["cbc-dark-wordmark", "global", "global-news"] {
            let source = try data(name)
            let raw = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(ChannelLogoExtraction.decode(source))), name)
            XCTAssertEqual(ChannelLogoExtraction.inkTreatment(raw), .inkOnly, name)
            XCTAssertGreaterThan(darkPixelCount(raw), 50_000, "\(name) really has black ink")
            let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: source, providerRequestsDarkBackground: false), name)
            XCTAssertFalse(prepared.isDark, name)
            let out = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared.image.cgImage)), name)
            XCTAssertEqual(darkPixelCount(out), 0, "\(name) still has black ink")
            var red = 0, i = 0
            while i < out.bytes.count {
                if out.bytes[i + 3] > 200, out.bytes[i] > 180, out.bytes[i + 1] < 90, out.bytes[i + 2] < 90 { red += 1 }
                i += 4
            }
            XCTAssertGreaterThan(red, 2_000, "\(name) keeps its red mark")
        }
    }

    /// A black wordmark logo that is already all dark (BBC Red Button's black text, red dot): the whole-silhouette path, as before for
    /// the dark share, with the provider's real pixels.
    func testRealBbcRedButtonStillTakesAnInkTreatment() throws {
        let raw = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(ChannelLogoExtraction.decode(try data("bbc-red-button")))))
        XCTAssertNotEqual(ChannelLogoExtraction.inkTreatment(raw), .unchanged)
    }

    /// CBC-like and Global News-like synthetic logos: a red mark, a wordmark and a thin one-pixel line of small text with partly
    /// transparent (anti-aliased) edges. Everything near-black is whitened with its alpha, even where the black is only a small part.
    func testThinAntiAliasedBlackTextBesideARedMarkIsWhitened() throws {
        let w = 120, h = 60
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
            let o = (y * w + x) * 4; bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b; bytes[o + 3] = a
        }
        for y in 4..<44 { for x in 4..<44 { put(x, y, 230, 30, 40, 255) } }                  // the red mark: the bulk of the ink
        for y in 10..<30 { for x in 50..<90 { put(x, y, 8, 8, 10, 255) } }                  // a small black wordmark
        for x in 50..<110 { put(x, 40, 10, 10, 12, 255); put(x, 39, 10, 10, 12, 90); put(x, 41, 10, 10, 12, 60) }   // thin "NEWS" line + AA edges
        let pixels = try XCTUnwrap(ChannelLogoPixels(width: w, height: h, bytes: bytes))
        XCTAssertEqual(ChannelLogoExtraction.inkTreatment(pixels), .inkOnly)
        let out = ChannelLogoExtraction.whiteningDarkInk(pixels)
        XCTAssertEqual(darkPixelCount(out), 0)
        let edge = (39 * w + 80) * 4
        XCTAssertEqual(Array(out.bytes[edge..<(edge + 4)]), [255, 255, 255, 90], "an anti-aliased edge keeps its alpha")
        XCTAssertEqual(Array(out.bytes[((10 * w + 10) * 4)..<((10 * w + 10) * 4 + 4)]), [230, 30, 40, 255])
    }
}
#endif
