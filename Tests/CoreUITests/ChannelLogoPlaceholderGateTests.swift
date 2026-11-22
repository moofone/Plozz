import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoreUI

final class ChannelLogoPlaceholderGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: Fixtures. Flags are drawn flat; logos are stand-ins for the real CBC/CTV/Global/TSN artwork.

    private func image(_ width: Int, _ height: Int, transparent: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if !transparent { fill(context, (1, 1, 1), 0, 0, width, height) }
        draw(context)
        return context.makeImage()!
    }

    private func fill(_ c: CGContext, _ rgb: (CGFloat, CGFloat, CGFloat), _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        c.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        c.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    private func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private let red: (CGFloat, CGFloat, CGFloat) = (0.85, 0.1, 0.1)

    private func canada(width: Int = 600) -> CGImage {
        let height = width / 2
        return image(width, height) { c in
            fill(c, red, 0, 0, width / 4, height); fill(c, red, width * 3 / 4, 0, width / 4, height)
            fill(c, red, width * 43 / 100, height * 3 / 10, width / 7, height * 2 / 5)
        }
    }

    private func unitedStates() -> CGImage {
        image(570, 300) { c in
            for stripe in 0..<13 where stripe % 2 == 0 { fill(c, (0.7, 0.13, 0.2), 0, stripe * 23, 570, 23) }
            fill(c, (0.24, 0.23, 0.43), 0, 139, 228, 161)
        }
    }

    private func britain() -> CGImage {
        image(600, 300) { c in
            fill(c, (0, 0.14, 0.4), 0, 0, 600, 300)
            c.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1); c.setLineWidth(50)
            c.move(to: .zero); c.addLine(to: CGPoint(x: 600, y: 300))
            c.move(to: CGPoint(x: 0, y: 300)); c.addLine(to: CGPoint(x: 600, y: 0)); c.strokePath()
            fill(c, (1, 1, 1), 0, 110, 600, 80); fill(c, (1, 1, 1), 260, 0, 80, 300)
            fill(c, (0.8, 0.07, 0.17), 0, 125, 600, 50); fill(c, (0.8, 0.07, 0.17), 275, 0, 50, 300)
        }
    }

    /// A red ball with a black bar on transparency.
    private func ballLogo() -> CGImage {
        image(400, 200, transparent: true) { c in
            c.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1); c.fillEllipse(in: CGRect(x: 20, y: 20, width: 160, height: 160))
            fill(c, (0, 0, 0), 220, 80, 160, 40)
        }
    }

    /// White lettering on a blue box, a boxed logo.
    private func boxedLogo() -> CGImage {
        image(400, 200) { c in fill(c, (0.05, 0.2, 0.5), 0, 0, 400, 200); fill(c, (1, 1, 1), 60, 60, 280, 80) }
    }

    /// A white ring on red, with a red tab: another boxed logo.
    private func ringLogo() -> CGImage {
        image(300, 200) { c in
            fill(c, red, 0, 0, 300, 200)
            c.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1); c.setLineWidth(18); c.strokeEllipse(in: CGRect(x: 80, y: 30, width: 140, height: 140))
        }
    }

    private func gate(_ images: [URL: Data]) -> ChannelLogoPlaceholderGate {
        ChannelLogoPlaceholderGate(indexURL: directory.appendingPathComponent("index.json"), data: { images[$0] })
    }

    // MARK: Flags

    func testFlatCanadianUSAndBritishFlagsAreRecognisedAtAnySize() {
        for flag in [canada(), canada(width: 240), unitedStates(), britain()] {
            let fingerprint = LogoPerceptualHash.fingerprint(of: flag)!
            XCTAssertTrue(ChannelLogoPlaceholderGate.isFlag(fingerprint))
        }
    }

    func testRealLogosAreNeverTakenForFlags() {
        for logo in [ballLogo(), boxedLogo(), ringLogo()] {
            let fingerprint = LogoPerceptualHash.fingerprint(of: logo)!
            XCTAssertFalse(ChannelLogoPlaceholderGate.isFlag(fingerprint))
            let nearest = LogoFlagHashes.table.map { LogoPerceptualHash.distance($0.hash, fingerprint.hash) }.min()!
            XCTAssertGreaterThan(nearest, ChannelLogoPlaceholderGate.flagDistance, "outside the flag tolerance")
        }
    }

    func testAFlagUnderAUniqueURLIsRejected() async {
        let url = URL(string: "https://cdn.example/unique-flag.png")!
        let gate = gate([url: png(canada())])
        let rejected = await gate.rejects(url: url, brandKey: "somestation")
        XCTAssertTrue(rejected)
        XCTAssertTrue(ChannelLogoPlaceholderGate.isKnownPlaceholder(url))
    }

    func testARealLogoIsKeptAndAnUnloadableImageIsNotJudged() async {
        let url = URL(string: "https://cdn.example/real.png")!
        let gate = gate([url: png(ballLogo())])
        let kept = await gate.rejects(url: url, brandKey: "cbc")
        XCTAssertFalse(kept)
        let missing = await gate.rejects(url: URL(string: "https://cdn.example/missing.png")!, brandKey: "x")
        XCTAssertFalse(missing)
    }

    // MARK: Shared content

    func testIdenticalContentUnderDifferentURLsForThreeBrandsIsRejected() async {
        let logo = png(ringLogo())
        let urls = (1...3).map { URL(string: "https://cdn.example/copy\($0).png")! }
        let gate = gate(Dictionary(uniqueKeysWithValues: urls.map { ($0, logo) }))
        let first = await gate.rejects(url: urls[0], brandKey: "alpha")
        let second = await gate.rejects(url: urls[1], brandKey: "beta")
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        let third = await gate.rejects(url: urls[2], brandKey: "gamma")
        XCTAssertTrue(third)
        let again = await gate.rejects(url: urls[0], brandKey: "alpha")
        XCTAssertTrue(again, "the decision covers every URL with that content")
    }

    func testOneBrandsRegionalVariantsKeepTheirLogo() async {
        let url = URL(string: "https://cdn.example/cbc.png")!
        let gate = gate([url: png(ringLogo())])
        for _ in 0..<5 {
            let rejected = await gate.rejects(url: url, brandKey: "cbc")
            XCTAssertFalse(rejected)
        }
    }

    func testDecisionsSurviveRelaunch() async throws {
        let url = URL(string: "https://cdn.example/flag.png")!
        let first = gate([url: png(canada())])
        _ = await first.rejects(url: url, brandKey: "a")
        try await Task.sleep(for: .seconds(2.5))
        let second = gate([:])
        let rejected = await second.rejects(url: url, brandKey: "b")
        XCTAssertTrue(rejected, "judged once, kept with the image entry")
    }
}
