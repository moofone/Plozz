#if canImport(UIKit)
import Foundation
import XCTest
@testable import CoreUI

/// Real provider logos are 96×96 JPEGs with no alpha: the solid background must go
/// before the trim, and the result must stay a uniform scale of the trimmed ink.
final class ChannelLogoOpaqueBackgroundTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle.module.url(
            forResource: "ChannelLogos", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func assertBackgroundRemoved(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try fixture(name)
        let source = try XCTUnwrap(ChannelLogoExtraction.decode(data), file: file, line: line)
        let sourcePixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(source), file: file, line: line)
        XCTAssertTrue(ChannelLogoExtraction.isOpaque(sourcePixels), "fixture must be opaque", file: file, line: line)

        let prepared = try XCTUnwrap(
            ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false), file: file, line: line)
        let image = try XCTUnwrap(prepared.image.cgImage, file: file, line: line)
        let pixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(image), file: file, line: line)

        // Aspect comes from the returned image, i.e. the trimmed ink.
        XCTAssertEqual(prepared.aspect, Double(image.width) / Double(image.height), accuracy: 1e-9, file: file, line: line)
        // The background is gone: part of the frame is now see-through, and the ink stays.
        let total = pixels.width * pixels.height
        let clear = stride(from: 3, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] <= 12 }.count
        let solid = stride(from: 3, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] > 200 }.count
        XCTAssertGreaterThan(clear, 0, "background not removed", file: file, line: line)
        XCTAssertGreaterThan(solid, total / 20, "ink lost", file: file, line: line)
        // Trimming only ever removes pixels.
        XCTAssertLessThanOrEqual(image.width, source.width, file: file, line: line)
        XCTAssertLessThanOrEqual(image.height, source.height, file: file, line: line)
        // The trim touches ink on every side: no padding of the old background left.
        let trim = try XCTUnwrap(ChannelLogoExtraction.trimRect(pixels), file: file, line: line)
        XCTAssertEqual(trim, ChannelLogoPixelRect(x: 0, y: 0, width: pixels.width, height: pixels.height),
                       file: file, line: line)
    }

    func testCTVCalgaryJPEGLosesItsBackground() throws {
        try assertBackgroundRemoved("CA_EN__CTV_CALGARY.jpg")
    }

    func testCBCCalgaryJPEGLosesItsBackground() throws {
        try assertBackgroundRemoved("CA_EN__CBC_CALGARY_HD.jpg")
    }

    /// The rest of the provider's CBC family: every opaque JPEG variant must be stripped the same way.
    func testEveryCBCProviderJPEGLosesItsBackground() throws {
        for name in [
            "CA_EN__CBC_CHARLOTTETOWN__HD_.jpg", "CA_EN__CBC_EDMONTON_HD.jpg", "CA_EN__CBC_FREDERICTON__HD_.jpg",
            "CA_EN__CBC_HALIFAX_HD.jpg", "CA_EN__CBC_MONTREALHD.jpg"
        ] {
            try assertBackgroundRemoved(name)
        }
    }

    /// A flattened logo on a white box with a few see-through pixels (rounded corners, an
    /// anti-aliased edge) and JPEG-style noise is still a boxed logo: it must lose the box.
    func testWhiteBoxWithNoisyEdgesAndAFewTransparentPixelsLosesItsBox() throws {
        let size = 96
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        var seed: UInt32 = 7
        func noise() -> Int { seed = seed &* 1_664_525 &+ 1_013_904_223; return Int(seed >> 29) - 3 }
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let inMark = (28..<68).contains(x) && (30..<66).contains(y)
                let base: (Int, Int, Int) = inMark ? (200, 20, 40) : (255, 255, 255)
                bytes[i] = UInt8(clamping: base.0 + noise())
                bytes[i + 1] = UInt8(clamping: base.1 + noise())
                bytes[i + 2] = UInt8(clamping: base.2 + noise())
                bytes[i + 3] = 255
            }
        }
        for (x, y) in [(0, 0), (95, 0), (0, 95), (95, 95)] { bytes[(y * size + x) * 4 + 3] = 0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try XCTUnwrap(UIImage(cgImage: cg).pngData())
        let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: png, providerRequestsDarkBackground: false))
        // The box is gone: the trim is the red mark (about 40 × 36), not the 96 × 96 frame.
        XCTAssertLessThan(prepared.image.size.width, 60)
        XCTAssertLessThan(prepared.image.size.height, 60)
    }
}
#endif
