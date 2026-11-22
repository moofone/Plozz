import XCTest
@testable import CoreModels

final class LogoColourProfileTests: XCTestCase {
    private func pixels(_ count: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) -> [UInt8] {
        (0..<count).flatMap { _ in [r, g, b, alpha] }
    }

    func testBlackWhiteAndGreyLogosAreMonochrome() throws {
        for value in [UInt8(0), 128, 255] {
            let profile = try XCTUnwrap(LogoColourProfile(straightRGBA: pixels(64, value, value, value)))
            XCTAssertTrue(profile.isMonochrome, "\(value)")
        }
    }

    func testColourLogosAreNotMonochromeEvenWhenDark() throws {
        XCTAssertFalse(try XCTUnwrap(LogoColourProfile(straightRGBA: pixels(64, 10, 20, 80))).isMonochrome)
        XCTAssertFalse(try XCTUnwrap(LogoColourProfile(straightRGBA: pixels(64, 230, 30, 30))).isMonochrome)
    }

    func testAFewColouredPixelsDoNotMakeAMonochromeLogoColour() throws {
        let bytes = pixels(95, 0, 0, 0) + pixels(5, 230, 30, 30)
        // 100 pixels, every 4th sampled: 25 samples. 5 coloured out of 100 would be 5%; sampling keeps it below 10%.
        let profile = try XCTUnwrap(LogoColourProfile(straightRGBA: bytes))
        XCTAssertLessThan(profile.colouredShare, 0.1)
    }

    func testTransparentPixelsDoNotCount() throws {
        XCTAssertNil(LogoColourProfile(straightRGBA: pixels(64, 255, 0, 0, alpha: 0)))
        let mixed = pixels(32, 255, 0, 0, alpha: 10) + pixels(32, 0, 0, 0)
        XCTAssertTrue(try XCTUnwrap(LogoColourProfile(straightRGBA: mixed)).isMonochrome)
    }
}
