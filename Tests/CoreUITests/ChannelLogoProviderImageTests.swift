#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// Real provider images for the channels reported as distorted in the guide (adult swim, AMC, Disney Channel,
/// E!, A&E, ABC Spark, AMI télé). Whatever the source looks like, Plozz must draw the trimmed content at its own aspect.
final class ChannelLogoProviderImageTests: XCTestCase {
    private static let fixtures: [(name: String, file: String, ext: String, requestsDark: Bool)] = [
        ("adult swim", "adult-swim", "jpg", false), ("AMC", "amc", "png", false),
        ("Disney Channel", "disney-channel", "jpg", false), ("E!", "e", "jpg", false),
        ("A&E", "a-and-e", "jpg", false), ("ABC Spark", "abc-spark", "jpg", false),
        ("AMI télé", "ami-tele", "jpg", false)
    ]

    private func data(_ file: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: file, withExtension: ext, subdirectory: "Fixtures/ProviderLogos"))
        return try Data(contentsOf: url)
    }

    func testDrawnLogoKeepsTheTrimmedContentAspectForEveryProviderImage() throws {
        let cell = CGSize(width: 252, height: 82)
        let geometry = ChannelLogoExtraction.GuideGeometry(cellSize: cell)
        var table = ["channel | source px | trimmed px | trimmed aspect | view aspect | drawn w×h (no badge) | drawn w×h (4K) | low quality"]
        for fixture in Self.fixtures {
            let source = try data(fixture.file, fixture.ext)
            let decoded = try XCTUnwrap(ChannelLogoExtraction.decode(source), fixture.name)
            let prepared = try XCTUnwrap(
                ChannelLogoExtraction.prepare(data: source, providerRequestsDarkBackground: fixture.requestsDark),
                fixture.name)
            let cg = try XCTUnwrap(prepared.image.cgImage, fixture.name)
            let contentAspect = Double(cg.width) / Double(cg.height)
            XCTAssertEqual(prepared.aspect, contentAspect, accuracy: contentAspect * 0.001, fixture.name)
            let viewAspect = BareChannelLogo.drawnAspect(of: prepared.image, fallback: prepared.aspect)
            XCTAssertEqual(viewAspect, contentAspect, accuracy: contentAspect * 0.001, fixture.name)
            var drawn: [CGSize] = []
            for badge in [nil, "4K"] as [String?] {
                let logo = geometry.layout(aspect: viewAspect, badge: badge).logo
                XCTAssertEqual(logo.width / logo.height, contentAspect, accuracy: contentAspect * 0.01,
                               "\(fixture.name) badge \(badge ?? "none")")
                drawn.append(logo.size)
            }
            table.append(String(
                format: "%@ | %dx%d | %dx%d | %.3f | %.3f | %.1fx%.1f | %.1fx%.1f | %@",
                fixture.name, decoded.width, decoded.height, cg.width, cg.height, contentAspect, viewAspect,
                drawn[0].width, drawn[0].height, drawn[1].width, drawn[1].height,
                prepared.isLowQuality ? "yes" : "no"))
        }
        let attachment = XCTAttachment(string: table.joined(separator: "\n"))
        attachment.name = "provider-logo-drawn-aspects"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreparedImageAlwaysCarriesItsOwnAspectWhenTrimmingAndBackgroundRemovalApply() throws {
        for fixture in Self.fixtures {
            let source = try data(fixture.file, fixture.ext)
            let prepared = try XCTUnwrap(
                ChannelLogoExtraction.prepare(data: source, providerRequestsDarkBackground: false), fixture.name)
            let cg = try XCTUnwrap(prepared.image.cgImage, fixture.name)
            XCTAssertEqual(prepared.image.size.width / prepared.image.size.height,
                           CGFloat(cg.width) / CGFloat(cg.height), accuracy: 0.0001, fixture.name)
        }
    }

    /// The provider's flat background (white, or black for AMC) must be gone: a logo drawn on a see-through
    /// background, not a white square. The ring around the image is mostly see-through where the background was.
    func testFlatBackgroundBoxIsRemovedFromEveryProviderImage() throws {
        var lines: [String] = []
        for fixture in Self.fixtures {
            let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(
                data: data(fixture.file, fixture.ext), providerRequestsDarkBackground: false, whitensMixedInk: false), fixture.name)
            let pixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(XCTUnwrap(prepared.image.cgImage)), fixture.name)
            var transparent = 0
            var opaqueNearWhiteOnRing = 0, ring = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let i = (y * pixels.width + x) * 4
                    let alpha = Int(pixels.bytes[i + 3])
                    if alpha <= ChannelLogoExtraction.trimAlphaThreshold { transparent += 1 }
                    if x == 0 || y == 0 || x == pixels.width - 1 || y == pixels.height - 1 {
                        ring += 1
                        if alpha > 200, pixels.bytes[i] > 225, pixels.bytes[i + 1] > 225, pixels.bytes[i + 2] > 225 {
                            opaqueNearWhiteOnRing += 1
                        }
                    }
                }
            }
            let transparentShare = Double(transparent) / Double(pixels.width * pixels.height)
            lines.append("\(fixture.name): \(pixels.width)x\(pixels.height) transparent \(transparentShare) whiteRing \(opaqueNearWhiteOnRing)/\(ring)")
            XCTAssertFalse(ChannelLogoExtraction.isMostlyOpaque(pixels), "\(fixture.name) keeps a solid box")
            XCTAssertLessThanOrEqual(Double(opaqueNearWhiteOnRing) / Double(ring), 0.25, "\(fixture.name) keeps a white edge")
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "provider-logo-background-removal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Low quality

    private func transparentPNG(canvas: Int, content: CGSize) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(
                x: ((CGFloat(canvas) - content.width) / 2).rounded(.down),
                y: ((CGFloat(canvas) - content.height) / 2).rounded(.down),
                width: content.width, height: content.height))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testLogoWhoseTrimmedContentIsUnder48PixelsOnItsLongSideIsLowQuality() throws {
        for (content, expected) in [
            (CGSize(width: 47, height: 20), true), (CGSize(width: 20, height: 47), true),
            (CGSize(width: 48, height: 20), false), (CGSize(width: 20, height: 48), false),
            (CGSize(width: 90, height: 30), false)
        ] {
            let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(
                data: transparentPNG(canvas: 128, content: content), providerRequestsDarkBackground: false))
            XCTAssertEqual(prepared.isLowQuality, expected, "\(content)")
        }
    }
}
#endif
