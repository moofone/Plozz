#if canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CoreUI

final class ChannelLogoExtractionTests: XCTestCase {
    // MARK: Synthetic buffers

    private func buffer(
        width: Int, height: Int, fill: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    ) throws -> ChannelLogoPixels {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = fill(x, y)
                bytes += [pixel.r, pixel.g, pixel.b, pixel.a]
            }
        }
        return try XCTUnwrap(ChannelLogoPixels(width: width, height: height, bytes: bytes))
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 16, height: Int = 16) throws -> ChannelLogoPixels {
        try buffer(width: width, height: height) { _, _ in (r, g, b, 255) }
    }

    func testTrimFindsInkInsideTransparentPadding() throws {
        let pixels = try buffer(width: 20, height: 10) { x, y in
            (3..<9).contains(x) && (2..<5).contains(y) ? (200, 0, 0, 255) : (0, 0, 0, 0)
        }
        XCTAssertEqual(
            ChannelLogoExtraction.trimRect(pixels),
            ChannelLogoPixelRect(x: 3, y: 2, width: 6, height: 3)
        )
    }

    func testTrimIgnoresFaintHaloAtOrBelowThreshold() throws {
        let pixels = try buffer(width: 10, height: 10) { x, y in
            if (4..<6).contains(x), (4..<6).contains(y) { return (10, 10, 10, 255) }
            return (10, 10, 10, 12)
        }
        XCTAssertEqual(
            ChannelLogoExtraction.trimRect(pixels),
            ChannelLogoPixelRect(x: 4, y: 4, width: 2, height: 2)
        )
    }

    func testFullyTransparentImageHasNoTrimAndIsNotDark() throws {
        let pixels = try buffer(width: 8, height: 8) { _, _ in (0, 0, 0, 0) }
        XCTAssertNil(ChannelLogoExtraction.trimRect(pixels))
        XCTAssertNil(ChannelLogoExtraction.colourProfile(pixels))
        XCTAssertFalse(ChannelLogoExtraction.isDark(pixels, providerRequestsDarkBackground: false))
    }

    /// Dark ink of any hue (black, dark grey, navy) is drawn as a white silhouette; brand colours and light logos are left alone.
    func testDarkInkIsRedrawnLightAndBrandColoursAreNot() throws {
        func treatment(_ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> ChannelLogoExtraction.InkTreatment {
            ChannelLogoExtraction.inkTreatment(try solid(r, g, b))
        }
        XCTAssertEqual(try treatment(0, 0, 0), .whole, "black")
        XCTAssertEqual(try treatment(40, 42, 44), .whole, "dark grey")
        XCTAssertEqual(try treatment(10, 20, 80), .whole, "navy (CTV News Channel)")
        XCTAssertEqual(try treatment(110, 20, 30), .unchanged, "maroon is a colour")
        XCTAssertEqual(try treatment(240, 70, 60), .unchanged, "red")
        XCTAssertEqual(try treatment(255, 255, 255), .unchanged, "white is already light")
        XCTAssertTrue(ChannelLogoExtraction.isDark(try solid(10, 20, 80), providerRequestsDarkBackground: false))
    }

    /// CBC and Global: a black wordmark beside a red mark. The wordmark turns white, the red stays exactly as it was.
    func testDarkWordmarkBesideAColourMarkIsWhitenedAndTheMarkKept() throws {
        let pixels = try buffer(width: 20, height: 10) { x, _ in
            x < 6 ? (230, 30, 40, 255) : x < 18 ? (12, 12, 14, 255) : (0, 0, 0, 0)
        }
        XCTAssertEqual(ChannelLogoExtraction.inkTreatment(pixels), .inkOnly, "12 of 18 columns are dark ink")
        XCTAssertFalse(ChannelLogoExtraction.isDark(pixels, providerRequestsDarkBackground: false))
        let out = ChannelLogoExtraction.whiteningDarkInk(pixels)
        func rgba(_ x: Int) -> [UInt8] { Array(out.bytes[(x * 4)..<(x * 4 + 4)]) }
        XCTAssertEqual(rgba(2), [230, 30, 40, 255], "the red mark is untouched")
        XCTAssertEqual(rgba(10), [255, 255, 255, 255], "the wordmark is white")
        XCTAssertEqual(rgba(19), [255, 255, 255, 0], "transparent stays transparent")
    }

    func testDarkLetteringOnAColourPlateIsLeftAlone() throws {
        let pixels = try buffer(width: 20, height: 10) { x, _ in x < 15 ? (250, 200, 0, 255) : (10, 10, 10, 255) }
        XCTAssertEqual(ChannelLogoExtraction.inkTreatment(pixels), .unchanged, "it reads on its own plate")
    }

    /// The analysis is one pass over the pixels at preparation (off the main thread, once per logo): record what it costs at the largest
    /// size a logo is decoded at; drawing and scrolling do no extra work.
    func testInkAnalysisCostIsOneCheapPassAtTheLargestLogoSize() throws {
        let size = ChannelLogoExtraction.maximumPixelSize
        let pixels = try buffer(width: size, height: size) { x, _ in x < size / 4 ? (230, 30, 40, 255) : (12, 12, 14, 255) }
        let start = ContinuousClock.now
        _ = ChannelLogoExtraction.inkTreatment(pixels)
        _ = ChannelLogoExtraction.whiteningDarkInk(pixels)
        let elapsed = ContinuousClock.now - start
        add({ let a = XCTAttachment(string: "ink analysis + whitening at \(size)x\(size): \(elapsed)"); a.lifetime = .keepAlways; return a }())
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testLightLogoAndTransparentImageAreUnchanged() throws {
        XCTAssertEqual(ChannelLogoExtraction.inkTreatment(try solid(240, 240, 240)), .unchanged)
        let clear = try buffer(width: 8, height: 8) { _, _ in (0, 0, 0, 0) }
        XCTAssertEqual(ChannelLogoExtraction.inkTreatment(clear), .unchanged)
    }

    /// The whole decision is made once, in `prepare` (off the main thread, cached by the loader): the drawn image is already final.
    func testPrepareWhitensTheWordmarkOnceAndKeepsTheFlag() throws {
        let pixels = try buffer(width: 40, height: 20) { x, _ in
            x < 10 ? (230, 30, 40, 255) : x < 36 ? (10, 10, 12, 255) : (0, 0, 0, 0)
        }
        let png = try pngData(pixels)
        let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: png, providerRequestsDarkBackground: false))
        XCTAssertFalse(prepared.isDark, "mixed logos are recoloured in the image, not tinted at draw time")
        let drawn = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared.image.cgImage)))
        let wordmark = Array(drawn.bytes[((10 * drawn.width + 20) * 4)..<((10 * drawn.width + 20) * 4 + 3)])
        XCTAssertEqual(wordmark, [255, 255, 255])
        let mark = Array(drawn.bytes[((10 * drawn.width + 2) * 4)..<((10 * drawn.width + 2) * 4 + 3)])
        XCTAssertEqual(mark, [230, 30, 40])
    }

    func testAWhiteLogoWithAColourAccentStaysInColour() throws {
        let pixels = try buffer(width: 16, height: 16) { x, _ in x < 12 ? (20, 20, 20, 255) : (230, 30, 30, 255) }
        XCTAssertFalse(ChannelLogoExtraction.isDark(pixels, providerRequestsDarkBackground: false), "a quarter of the ink is red")
    }

    func testProviderFlagForcesDarkTreatment() throws {
        let red = try solid(240, 70, 60)
        XCTAssertFalse(ChannelLogoExtraction.isDark(red, providerRequestsDarkBackground: false))
        XCTAssertTrue(ChannelLogoExtraction.isDark(red, providerRequestsDarkBackground: true))
    }

    func testDarkTestIgnoresMostlyTransparentPixels() throws {
        // Dark pixels at alpha 100 are skipped; the opaque light pixels decide.
        let pixels = try buffer(width: 16, height: 4) { x, _ in x < 8 ? (0, 0, 0, 100) : (250, 250, 250, 255) }
        XCTAssertFalse(ChannelLogoExtraction.isDark(pixels, providerRequestsDarkBackground: false))
    }

    func testWideAndSquareLogosCoverEqualAreaWithinTheBox() throws {
        let box = CGSize(width: 164, height: 52)
        let wide = ChannelLogoExtraction.fittedSize(aspect: 2, in: box)
        let tall = ChannelLogoExtraction.fittedSize(aspect: 1.5, in: box)
        XCTAssertEqual(wide.width * wide.height, tall.width * tall.height, accuracy: 0.01)
        XCTAssertEqual(wide.width * wide.height, 0.42 * 164 * 52, accuracy: 0.01)
    }

    func testExtremeAspectIsClampedToTheBox() {
        let box = CGSize(width: 164, height: 52)
        let ribbon = ChannelLogoExtraction.fittedSize(aspect: 12, in: box)
        XCTAssertLessThanOrEqual(ribbon.width, box.width + 0.001)
        XCTAssertLessThanOrEqual(ribbon.height, box.height + 0.001)
        XCTAssertEqual(ribbon.width / ribbon.height, 12, accuracy: 0.001)
        let column = ChannelLogoExtraction.fittedSize(aspect: 1.0 / 12, in: box)
        XCTAssertLessThanOrEqual(column.height, box.height + 0.001)
    }

    /// E! trims to a 0.31 aspect: a tall mark is fitted by height to the whole logo box, scaled uniformly.
    func testATallNarrowMarkUsesTheFullBoxHeight() {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        for aspect in [0.31, 0.2, 0.5] {
            let size = geometry.logoSize(aspect: aspect, hasBadge: false)
            XCTAssertEqual(size.height, geometry.box.height, accuracy: 0.001, "aspect \(aspect)")
            XCTAssertEqual(size.width / size.height, aspect, accuracy: 0.005, "aspect \(aspect)")
        }
        let badged = geometry.logoSize(aspect: 0.31, hasBadge: true)
        XCTAssertEqual(badged.height, geometry.box.height, accuracy: 0.001, "a narrow mark keeps its height beside the 4K badge")
    }

    func testDegenerateAspectHasNoSize() {
        XCTAssertEqual(ChannelLogoExtraction.fittedSize(aspect: 0, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testGuideGeometryMatchesReferenceRow() {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        XCTAssertEqual(geometry.box, CGSize(width: 164, height: 52))
        XCTAssertEqual(geometry.badgeWidth, 46)
    }

    func testBadgeRoomShrinksOnlyLogosThatNeedIt() {
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        let plain = geometry.logoSize(aspect: 4, hasBadge: false)
        let badged = geometry.logoSize(aspect: 4, hasBadge: true)
        XCTAssertGreaterThan(plain.width, 118)
        XCTAssertEqual(badged.width, 118, accuracy: 0.001)
        XCTAssertEqual(badged.width / badged.height, 4, accuracy: 0.001)
        let narrow = geometry.logoSize(aspect: 1, hasBadge: true)
        XCTAssertEqual(narrow, geometry.logoSize(aspect: 1, hasBadge: false))
    }

    func testPrepareTrimsPaddedImageAndReportsTrimmedAspect() throws {
        let pixels = try buffer(width: 40, height: 20) { x, y in
            (10..<30).contains(x) && (5..<15).contains(y) ? (240, 70, 60, 255) : (0, 0, 0, 0)
        }
        let png = try pngData(pixels)
        let prepared = try XCTUnwrap(
            ChannelLogoExtraction.prepare(data: png, providerRequestsDarkBackground: false)
        )
        XCTAssertEqual(prepared.aspect, 2, accuracy: 0.0001)
        XCTAssertEqual(prepared.image.cgImage?.width, 20)
        XCTAssertEqual(prepared.image.cgImage?.height, 10)
        XCTAssertFalse(prepared.isDark)
    }

    /// Whatever `prepare` returns, `aspect` must be the returned image's own width / height,
    /// for wide, square and tall logos, trimmed or not.
    func testPrepareReportsTheAspectOfTheReturnedImage() throws {
        let shapes: [(width: Int, height: Int, aspect: Double)] = [(60, 20, 3), (24, 24, 1), (12, 24, 0.5)]
        for shape in shapes {
            let inked = try buffer(width: shape.width, height: shape.height) { _, _ in (240, 70, 60, 255) }
            let padded = try buffer(width: shape.width + 8, height: shape.height + 8) { x, y in
                (4..<(4 + shape.width)).contains(x) && (4..<(4 + shape.height)).contains(y)
                    ? (240, 70, 60, 255) : (0, 0, 0, 0)
            }
            for pixels in [inked, padded] {
                let prepared = try XCTUnwrap(
                    ChannelLogoExtraction.prepare(data: try pngData(pixels), providerRequestsDarkBackground: false)
                )
                let image = try XCTUnwrap(prepared.image.cgImage)
                XCTAssertEqual(prepared.aspect, Double(image.width) / Double(image.height), accuracy: 0.0001)
                XCTAssertEqual(prepared.aspect, shape.aspect, accuracy: 0.0001)
            }
        }
    }

    func testPrepareRejectsUndecodableData() {
        XCTAssertNil(ChannelLogoExtraction.prepare(data: Data([1, 2, 3]), providerRequestsDarkBackground: false))
    }

    // MARK: Fixtures from the reference design

    private struct Expected: Decodable {
        struct Trim: Decodable { let x: Int; let y: Int; let w: Int; let h: Int }
        struct Size: Decodable { let w: Double; let h: Double }
        let naturalW: Int
        let naturalH: Int
        let trim: Trim
        let dark: Bool
        let guideSize: Size
        let guideSizeWithBadge: Size
    }

    private struct Reference: Decodable {
        let logos: [String: Expected]
    }

    private var fixtureDirectory: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "ChannelLogos", withExtension: nil, subdirectory: "Fixtures"))
        }
    }

    /// Unmanaged RGBA, straight alpha, straight from the PNG.
    private func fixturePixels(_ url: URL) throws -> ChannelLogoPixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(image))
    }

    func testEveryReferenceLogoMatchesTheDesignOracle() throws {
        let directory = try fixtureDirectory
        let reference = try JSONDecoder().decode(
            Reference.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json"))
        )
        XCTAssertEqual(reference.logos.count, 25)
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: CGSize(width: 252, height: 82))
        for (key, expected) in reference.logos.sorted(by: { $0.key < $1.key }) {
            let pixels = try fixturePixels(directory.appendingPathComponent("\(key).png"))
            XCTAssertEqual(pixels.width, expected.naturalW, key)
            XCTAssertEqual(pixels.height, expected.naturalH, key)
            let trim = try XCTUnwrap(ChannelLogoExtraction.trimRect(pixels), key)
            XCTAssertEqual(
                trim,
                ChannelLogoPixelRect(x: expected.trim.x, y: expected.trim.y, width: expected.trim.w, height: expected.trim.h),
                key
            )
            // The design's LIGHTEN set maps to the provider's dark-background flag.
            let providerFlag = key == "paramount-plus-us"
            XCTAssertEqual(
                ChannelLogoExtraction.isDark(pixels, providerRequestsDarkBackground: providerFlag),
                expected.dark, key
            )
            let aspect = Double(trim.width) / Double(trim.height)
            let plain = geometry.logoSize(aspect: aspect, hasBadge: false)
            XCTAssertEqual(plain.width, expected.guideSize.w, accuracy: 0.01, key)
            XCTAssertEqual(plain.height, expected.guideSize.h, accuracy: 0.01, key)
            let badged = geometry.logoSize(aspect: aspect, hasBadge: true)
            XCTAssertEqual(badged.width, expected.guideSizeWithBadge.w, accuracy: 0.01, key)
            XCTAssertEqual(badged.height, expected.guideSizeWithBadge.h, accuracy: 0.01, key)
        }
    }

    // MARK: Helpers

    private func pngData(_ pixels: ChannelLogoPixels) throws -> Data {
        var bytes = pixels.bytes
        // Premultiply for CoreGraphics; the test inks are opaque or fully transparent.
        let image: CGImage = try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
