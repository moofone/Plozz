@testable import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

/// Draws the right channel panel at 1920×1080 over a guide stand-in with the mockup's content (`#v=browse&r=1080&s=right`) and for
/// the other states a channel can be in, and writes each to `/tmp/panel-exact/<name>.png` to be compared with the mockup's render.
@MainActor
final class LiveTVGlassChannelPanelRenderTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/panel-exact", isDirectory: true)

    private typealias Content = LiveTVGlassChannelPanelContent

    private func upcoming(_ rows: [(String, String)]) -> [LiveTVGlassUpcomingProgram] {
        rows.enumerated().map { LiveTVGlassUpcomingProgram(id: "u\($0.offset)", title: $0.element.0, timeText: $0.element.1, startsTomorrow: false) }
    }

    private func states(logo: URL, wideLogo: URL) -> [(String, Content)] {
        let mockupUpcoming = upcoming([("Hockey Night in Canada", "7:00"), ("The National", "10:00"), ("CBC News: Toronto", "11:00"), ("Still Standing", "11:30")])
        return [
            ("1-linear-with-listings", Content(
                channelName: "CBC Toronto", logoURL: logo, numberText: "301", sourceNames: ["cf.q-19.com"],
                now: .init(title: "CBC News: Toronto", meta: "8 min left", progress: 0.7,
                           description: "Saturday's stories from across the city and the GTA."),
                isFavorite: false, watchTitle: "Watch", upcoming: mockupUpcoming)),
            ("2-linear-no-listings", Content(
                channelName: "Global Toronto", logoURL: wideLogo, numberText: "303", now: nil, isFavorite: false, watchTitle: "Watch", upcoming: [])),
            ("3-event", Content(
                channelName: "TSN+ 29", isEvent: true, numberText: "",
                now: .init(title: "2025 STIHL Timbersports: Men's Singles Championship Final", meta: "58 min left", progress: 0.35, description: nil),
                isFavorite: false, watchTitle: "Watch", upcoming: [])),
            ("4-24-7-loop", Content(
                channelName: "24/7 NCIS", logoURL: logo, numberText: "7102",
                now: .init(title: "NCIS", meta: "24/7", progress: nil, description: nil),
                isFavorite: true, watchTitle: "Resume", upcoming: [])),
            ("5-4k-channel", Content(
                channelName: "SN 4K Toronto", logoURL: wideLogo, qualityBadge: "4K", numberText: "306",
                now: .init(title: "NHL: Edmonton at Calgary", meta: "1 hr 20 min left", progress: 0.4, description: nil),
                isFavorite: false, watchTitle: "Watch", upcoming: upcoming([("Hockey Night in Canada", "10:00"), ("Sportsnet Central", "11:00")]))),
            ("7-nothing-airing-next-programme", Content(
                channelName: "CBC Toronto", logoURL: logo, numberText: "301",
                now: .init(title: "Hockey Night in Canada", meta: "Starts 7:00", progress: nil, description: "Tonight's game from Toronto."),
                isFavorite: false, watchTitle: "Watch", upcoming: upcoming([("The National", "10:00"), ("CBC News: Toronto", "11:00")]))),
            ("6-long-names", Content(
                channelName: "The Extraordinarily Long Channel Name Network Canada East HD", logoURL: logo, numberText: "12045",
                now: .init(title: "A Remarkably Long Programme Title That Needs Two Lines to Read",
                           meta: "42 min left", progress: 0.5,
                           description: "An unusually long synopsis that runs past the third line so the panel has to clamp it instead of growing past the screen, with more words after that."),
                isFavorite: false, watchTitle: "Watch",
                upcoming: upcoming([("Another Remarkably Long Programme Title in the Upcoming List", "7:00"), ("News", "8:00"), ("Weather", "8:30"), ("Sports", "9:00"), ("Late Show", "10:00")])))
        ]
    }

    /// A 4K display lays out in 1920×1080 pt: the panel is the mockup's 760 × 0.75 = 570 wide, 30 from the edges, at 0.9 of its 1080p type.
    func testFourKLayoutKeepsThePanelInProportion() async throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let logo = try makeLogo(text: "CBC", size: CGSize(width: 520, height: 200), name: "cbc", color: UIColor(red: 0.89, green: 0.13, blue: 0.16, alpha: 1))
        let (name, content) = try XCTUnwrap(states(logo: logo, wideLogo: logo).first)
        let (window, previous) = try await makeWindow()
        let host = UIHostingController(rootView: PanelFixture(content: content, layout: .uhd4K, margin: LiveTVGlassLayout.uhd4K.panelMargin))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(800))
        let image = DetailTransitionSnapshot.image(of: window)
        try XCTUnwrap(image.pngData()).write(to: Self.outputDirectory.appendingPathComponent("\(name)-4k.png"))
        XCTAssertEqual(LiveTVGlassLayout.uhd4K.panelWidth, 570)
        XCTAssertEqual(LiveTVGlassLayout.uhd4K.panelMargin, 30)
        XCTAssertEqual(LiveTVGlassLayout.uhd4K.uiScale, 0.9, accuracy: 0.0001)
    }

    func testRendersEveryChannelPanelState() async throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let logo = try makeLogo(text: "CBC", size: CGSize(width: 520, height: 200), name: "cbc", color: UIColor(red: 0.89, green: 0.13, blue: 0.16, alpha: 1))
        let wide = try makeLogo(text: "Global", size: CGSize(width: 620, height: 180), name: "global", color: .white)
        for (name, content) in states(logo: logo, wideLogo: wide) {
            let (window, previous) = try await makeWindow()
            let host = UIHostingController(rootView: PanelFixture(content: content))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            for _ in 0..<40 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(800))
            let image = DetailTransitionSnapshot.image(of: window)
            try XCTUnwrap(image.pngData()).write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
            if name == "1-linear-with-listings" {
                // The mockup's panel at 1080p is 600 wide, its right edge 40 in from the screen's, 917 tall for this content, and
                // centred; measured as the extent of pixels that differ from the fixture's plain background.
                let frame = try XCTUnwrap(Self.panelFrame(in: image))
                XCTAssertEqual(frame.width, 600, accuracy: 3, "panel width")
                XCTAssertEqual(frame.maxX, 1880, accuracy: 3, "panel right edge")
                XCTAssertEqual(frame.midY, 540, accuracy: 6, "panel is vertically centred")
                XCTAssertEqual(frame.height, 917 - 12, accuracy: 14, "panel height (mockup 917 with its 78-pt logo; this fixture's logo is 12 shorter)")
                XCTAssertLessThanOrEqual(frame.height, 1000, "never taller than the screen less its margins")
                add(XCTAttachment(string: "panel frame \(frame)"))
            }
        }
    }

    /// The bounding box of the panel: pixels in x ≥ 1200 that are not the fixture's background and not the guide rows behind it.
    private static func panelFrame(in image: UIImage) -> CGRect? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = CGFloat(w) / 1920
        func lum(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) }
        // The panel's right edge and vertical extent along its centre column; its left edge along its centre row.
        let cx = Int(1860 * scale), cy = Int(540 * scale)
        var top = h, bottom = 0
        for y in 0..<h where lum(cx, y) > 60 { top = min(top, y); bottom = max(bottom, y) }
        var left = w, right = 0
        for x in Int(1200 * scale)..<w where lum(x, cy) > 60 && lum(x, cy) != 0 { left = min(left, x); right = max(right, x) }
        guard top < bottom, left < right else { return nil }
        return CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale, width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    private func makeLogo(text: String, size: CGSize, name: String, color: UIColor) throws -> URL {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let font = UIFont.systemFont(ofSize: size.height * 0.7, weight: .black)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let measured = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2), withAttributes: attributes)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("panel-logo-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    private func makeWindow() async throws -> (UIWindow, UIWindow?) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return (window, previous)
    }
}

private struct PanelFixture: View {
    let content: LiveTVGlassChannelPanelContent
    var layout = LiveTVGlassLayout.hd1080
    var margin: CGFloat = 40

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 8 / 255, green: 9 / 255, blue: 12 / 255)
            Text("Canada  7").font(.system(size: 31, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).offset(x: 160, y: 548)
            ForEach(Array(["CBC News: Toronto", "Big Money Quiz", "Cottage Country", "News Now", "CFL Eastern Final", "NHL: Edmonton at Calgary"].enumerated()), id: \.offset) { index, title in
                let y = 640 + CGFloat(index) * 86
                Text(verbatim: "\(301 + index)").font(.system(size: 27)).foregroundStyle(.white.opacity(0.5)).offset(x: 160, y: y + 20)
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.08))
                    .frame(width: 1400, height: 78)
                    .overlay(alignment: .leading) { Text(title).font(.system(size: 27)).foregroundStyle(.white.opacity(0.92)).padding(.leading, 22) }
                    .offset(x: 400, y: y)
            }
            LiveTVGlassChannelPanel(
                content: content, canvasHeight: 1080,
                onWatch: {}, onMultiview: {}, onToggleFavorite: {}, onClose: {})
                .environment(\.liveTVGlassLayout, layout)
                .padding(.trailing, margin)
                .frame(width: 1920, height: 1080, alignment: .trailing)
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }
}
