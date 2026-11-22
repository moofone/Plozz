#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

/// Hosted renders of the real hero, heading and right panel at both layout sizes, measured against the mockup's own DOM geometry
/// (headless Chrome, `#v=browse&r=1080|4k&q4t=1`, converted to 1920 pt space). The renders are written to
/// `$PLOZZ_LIVETV_SNAPSHOT_DIR` (default: the temporary directory) with the comparison table.
@MainActor
final class LiveTVGlassScreenHostedTests: XCTestCase {
    private let canvas = CGSize(width: 1_920, height: 1_080)
    private let tolerance: CGFloat = 4
    private var table: [String] = []

    override func tearDown() async throws {
        LiveTVGlassLayout.override = nil
        try await super.tearDown()
    }

    // MARK: Mockup geometry (1920 pt space)

    private struct Mockup {
        var headingLeft, headingCenterY: CGFloat
        var titleLeft, titleCenterY: CGFloat
        var watchX, watchY, watchHeight: CGFloat
        var panelX, panelWidth: CGFloat
    }

    /// From the mockup's DOM: `.ahead`, `.atitle`, the first `.abtn.pill`, `.lg.panel`.
    private static let mockup1080 = Mockup(
        headingLeft: 130 + 22, headingCenterY: 291 + 30, titleLeft: 1160, titleCenterY: 101.31 + 57.19 / 2,
        watchX: 1160, watchY: 270, watchHeight: 60, panelX: 1280, panelWidth: 600)
    private static let mockup4K = Mockup(
        headingLeft: 116.25 + 19.5, headingCenterY: 261.82 + 27, titleLeft: 1236, titleCenterY: 93.61 + 51.14 / 2,
        watchX: 1236, watchY: 243, watchHeight: 54, panelX: 1320, panelWidth: 570)

    // MARK: Fixtures

    private func hostedHero(
        _ glass: LiveTVGlassLayout, withProgram: Bool = true, playing: Bool = false, glassBacking: Bool = false,
        background: Color = .black
    ) -> some View {
        let layout = PrototypePreviewLayout(
            size: canvas, navigationInset: 64, hidesSidebar: true, glass: glass)
        let channel = LiveTVPrototypeModel().channels[0]
        let now = Date()
        let program = withProgram ? LiveTVPrototypeProgram(
            id: "p", channelID: channel.id, title: "CBC News: Toronto", subtitle: "News",
            start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1_800)) : nil
        let inputs = PrototypeGlassHeroInputs(
            headingTitle: "Canada", headingCount: "7", isHeadingOpen: false, openHeading: {}, focusScope: nil,
            isPlaying: playing, now: now, isFavorite: false, toggleFavorite: {}, multiview: {}, info: {},
            glassBacking: glassBacking)
        return ZStack(alignment: .topLeading) {
            background
            PrototypeGlassHero(channel: channel, program: program, layout: layout, inputs: inputs, watch: {})
                .frame(width: layout.heroWidth, height: layout.heroHeight, alignment: layout.heroAlignment)
                .offset(x: layout.contentFrame.minX - layout.bounds.minX, y: layout.contentFrame.minY - layout.bounds.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .environment(\.liveTVGlassLayout, glass)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    // MARK: Pixels

    private struct Pixels {
        let width: Int, height: Int
        let luma: [UInt8]
        let image: CGImage

        func ink(in rect: CGRect, above threshold: UInt8 = 150) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) where luma[y * width + x] > threshold {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        /// The rows holding a horizontal run of near-white of at least `minimumRun` points inside `rect`: a solid pill, never text.
        func solidWhiteBounds(in rect: CGRect, minimumRun: Int = 90) -> CGRect? {
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                var run = 0, runStart = 0
                for x in max(0, Int(rect.minX))...min(width - 1, Int(rect.maxX)) {
                    if luma[y * width + x] > 235 {
                        if run == 0 { runStart = x }
                        run += 1
                    } else {
                        if run >= minimumRun { minX = min(minX, runStart); maxX = max(maxX, x - 1); minY = min(minY, y); maxY = max(maxY, y) }
                        run = 0
                    }
                }
            }
            return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    private func render(_ view: some View, name: String) throws -> Pixels {
        let renderer = ImageRenderer(content: view)
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
        var luma = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let r = Int(rgba[index * 4]), g = Int(rgba[index * 4 + 1]), b = Int(rgba[index * 4 + 2])
            luma[index] = UInt8((r * 299 + g * 587 + b * 114) / 1_000)
        }
        if let data = UIImage(cgImage: image).pngData() {
            try? data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        }
        return Pixels(width: width, height: height, luma: luma, image: image)
    }

    private static var outputDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["PLOZZ_LIVETV_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PlozzLiveTVRes4K")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func row(_ element: String, mockup: CGFloat, app: CGFloat) {
        table.append("| \(element) | \(String(format: "%.1f", mockup)) | \(String(format: "%.1f", app)) | \(String(format: "%+.1f", app - mockup)) |")
        XCTAssertEqual(app, mockup, accuracy: tolerance, element)
    }

    private func writeTable(_ name: String) {
        let text = "| element | mockup (pt) | app (pt) | Δ |\n|---|---|---|---|\n" + table.joined(separator: "\n") + "\n"
        try? text.write(to: Self.outputDirectory.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        print("LIVETV-RES4K \(name)\n\(text)")
    }

    // MARK: Hero and heading

    private func checkHero(_ glass: LiveTVGlassLayout, _ mockup: Mockup, _ name: String) throws {
        LiveTVGlassLayout.override = glass
        let pixels = try render(hostedHero(glass), name: "hero-\(name)")
        let watch = try XCTUnwrap(pixels.solidWhiteBounds(in: CGRect(x: 960, y: 0, width: 960, height: 520)), "Watch pill")
        row("\(name) Watch pill x", mockup: mockup.watchX, app: watch.minX)
        row("\(name) Watch pill y", mockup: mockup.watchY, app: watch.minY)
        row("\(name) Watch pill height", mockup: mockup.watchHeight, app: watch.height)
        let title = try XCTUnwrap(pixels.ink(in: CGRect(x: 960, y: 0, width: 960, height: watch.minY - 4)), "hero title")
        row("\(name) hero text left", mockup: mockup.titleLeft, app: title.minX)
        let titleLine = try XCTUnwrap(pixels.ink(in: CGRect(x: 960, y: 0, width: 960, height: watch.minY - 4), above: 200))
        _ = titleLine
        let heading = try XCTUnwrap(pixels.ink(in: CGRect(x: 100, y: 200, width: 400, height: 140)), "heading")
        row("\(name) heading name left", mockup: mockup.headingLeft, app: heading.minX)
        row("\(name) heading centre y", mockup: mockup.headingCenterY, app: heading.midY)
        writeTable("hero-\(name)")
        table = []
    }

    func testHeroAndHeadingMatchTheMockupAt1080p() throws {
        try checkHero(.hd1080, Self.mockup1080, "1080")
    }

    func testHeroAndHeadingMatchTheMockupAt4K() throws {
        try checkHero(.uhd4K, Self.mockup4K, "4K")
    }

    /// Mockup `appleHero` without a programme, Plozz-like over a playing picture: one line, "No guide information", over the buttons —
    /// no channel-name title and no labels — on the free shade (`.herofree`), not a panel.
    func testAHeroWithoutAGuideIsOneLineOnTheFreeShade() throws {
        for (glass, name) in [(LiveTVGlassLayout.hd1080, "1080"), (.uhd4K, "4K")] {
            LiveTVGlassLayout.override = glass
            // Over black the shade is invisible: what is drawn is the text and the Resume pill.
            let dark = try render(hostedHero(glass, withProgram: false, playing: true, glassBacking: true), name: "hero-noguide-\(name)")
            let resume = try XCTUnwrap(dark.solidWhiteBounds(in: CGRect(x: 960, y: 0, width: 960, height: 520)), "Resume pill")
            let text = try XCTUnwrap(dark.ink(in: CGRect(x: 960, y: 0, width: 960, height: resume.minY - 4)), "\(name) text")
            XCTAssertLessThan(text.height, glass.ui(25) * 1.3, "\(name): one 25 pt line, no 52 pt channel-name title")
            XCTAssertEqual(resume.minY - text.maxY, glass.ui(26), accuracy: glass.ui(25) * 0.5, "\(name): the line sits right over the buttons")
            // Over white the shade shows beside the text, and nothing is drawn far from it.
            let light = try render(
                hostedHero(glass, withProgram: false, playing: true, glassBacking: true, background: .white), name: "hero-noguide-shade-\(name)")
            let besideText = Int(light.luma[Int(resume.midY) * light.width + Int(resume.minX - glass.ui(20))])
            XCTAssertLessThan(besideText, 200, "\(name): the soft shade reaches past the text")
            XCTAssertEqual(Int(light.luma[40 * light.width + 40]), 255, "\(name): no panel or shade far from the text")
        }
    }

    func testHeroIsSmallerAt4KThanAt1080p() throws {
        LiveTVGlassLayout.override = .hd1080
        let hd = try XCTUnwrap(render(hostedHero(.hd1080), name: "hero-compare-1080")
            .solidWhiteBounds(in: CGRect(x: 960, y: 0, width: 960, height: 520)))
        LiveTVGlassLayout.override = .uhd4K
        let uhd = try XCTUnwrap(render(hostedHero(.uhd4K), name: "hero-compare-4K")
            .solidWhiteBounds(in: CGRect(x: 960, y: 0, width: 960, height: 520)))
        XCTAssertEqual(uhd.height / hd.height, 0.9, accuracy: 0.03)
    }

    // MARK: Guide

    /// The guide's frame, from the real layout code (the screen-aligned preview frame and the guide metrics), against the mockup's
    /// DOM rects: ruler top, first-row top, row pitch, plate and first cell.
    func testGuideGeometryMatchesTheMockupAtBothSizes() {
        // [ruler top, row 0 top, pitch, plate x, plate width, row height, first cell x] from the mockup DOM.
        let expected: [(LiveTVGlassLayout, String, [CGFloat])] = [
            (.hd1080, "1080", [358, 424, 92, 144, 204, 82, 360]),
            (.uhd4K, "4K", [322.5, 370.5, 63, 129.75, 157.5, 55.5, 294.75])]
        for (glass, name, mockup) in expected {
            LiveTVGlassLayout.override = glass
            let layout = PrototypePreviewLayout(size: canvas, navigationInset: 64, hidesSidebar: true, glass: glass)
            let rulerTop = layout.contentFrame.minY - layout.bounds.minY + layout.heroHeight + PrototypeLayout.sectionGap
            let firstRow = rulerTop + PrototypeLayout.rulerHeight + PrototypeLayout.rulerGap + PrototypeLayout.smallGap
            let plateX = layout.contentFrame.minX - layout.bounds.minX
            row("\(name) ruler top", mockup: mockup[0], app: rulerTop)
            row("\(name) first row top", mockup: mockup[1], app: firstRow)
            row("\(name) row pitch", mockup: mockup[2], app: PrototypeLayout.rowHeight + PrototypeLayout.rowGap)
            row("\(name) plate x", mockup: mockup[3], app: plateX)
            row("\(name) plate width", mockup: mockup[4], app: PrototypeLayout.stationColumnWidth)
            row("\(name) row height", mockup: mockup[5], app: PrototypeLayout.rowHeight)
            row("\(name) first cell x", mockup: mockup[6], app: plateX + PrototypeLayout.stationColumnWidth + PrototypeLayout.columnGap)
            row("\(name) window minutes", mockup: CGFloat(glass.windowMinutes), app: PrototypeLayout.viewportSeconds(for: 1_696) / 60)
            writeTable("guide-\(name)")
            table = []
        }
    }

    // MARK: Right panel

    private func content(upcoming count: Int, description: String?) -> LiveTVGlassChannelPanelContent {
        LiveTVGlassChannelPanelContent(
            channelName: "CBC News: Toronto", logoURL: nil, numberText: "301",
            now: .init(title: "CBC News: Toronto", meta: "8m left", progress: 0.4, description: description),
            isFavorite: false, watchTitle: "Watch",
            upcoming: (0..<count).map {
                LiveTVGlassUpcomingProgram(id: "\($0)", title: "Upcoming programme \($0)", timeText: "\(7 + $0):00", startsTomorrow: $0 >= 5)
            })
    }

    private func hostedPanel(_ glass: LiveTVGlassLayout, content: LiveTVGlassChannelPanelContent) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            LiveTVGlassChannelPanel(
                content: content, canvasHeight: canvas.height, onWatch: {}, onMultiview: {}, onToggleFavorite: {}, onClose: {})
                .padding(.trailing, glass.panelMargin)
                .padding(.top, glass.panelMargin)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .environment(\.liveTVGlassLayout, glass)
        .environment(\.colorScheme, .dark)
    }

    /// The panel's drawn size comes from the real layout: the mockup's 760 × 0.75 = 570 wide at 4K, 600 at 1080p, 40 / 30 pt from the edges.
    func testPanelWidthAndEdgesFollowTheMockupAtBothSizes() {
        for (glass, mockup, name) in [(LiveTVGlassLayout.hd1080, Self.mockup1080, "1080"), (.uhd4K, Self.mockup4K, "4K")] {
            let host = UIHostingController(rootView: LiveTVGlassChannelPanel(
                content: content(upcoming: 4, description: "Saturday's stories from across the city."),
                canvasHeight: canvas.height, onWatch: {}, onMultiview: {}, onToggleFavorite: {}, onClose: {})
                .environment(\.liveTVGlassLayout, glass))
            let size = host.sizeThatFits(in: CGSize(width: 1_000, height: canvas.height))
            row("\(name) panel width", mockup: mockup.panelWidth, app: size.width)
            row("\(name) panel left edge", mockup: mockup.panelX, app: canvas.width - glass.panelMargin - size.width)
            XCTAssertLessThanOrEqual(size.height, canvas.height - 2 * glass.panelMargin + 0.5, "\(name) panel fits the canvas")
            writeTable("panel-\(name)")
            table = []
        }
    }

    func testPanelRendersAtBothSizesWithoutClipping() throws {
        for (glass, name) in [(LiveTVGlassLayout.hd1080, "1080"), (.uhd4K, "4K")] {
            LiveTVGlassLayout.override = glass
            let pixels = try render(
                hostedPanel(glass, content: content(upcoming: 6, description: "A long description of the programme that wraps.")),
                name: "panel-\(name)")
            let ink = try XCTUnwrap(pixels.ink(in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080), above: 120), "\(name) panel ink")
            XCTAssertGreaterThanOrEqual(ink.minX, canvas.width - glass.panelMargin - glass.panelWidth - 2, "\(name) left")
            XCTAssertLessThanOrEqual(ink.maxX, canvas.width - glass.panelMargin + 2, "\(name) right")
            XCTAssertGreaterThanOrEqual(ink.minY, glass.panelMargin - 2, "\(name) top")
            XCTAssertLessThanOrEqual(ink.maxY, canvas.height - glass.panelMargin + 2, "\(name) bottom")
        }
    }
}
#endif
