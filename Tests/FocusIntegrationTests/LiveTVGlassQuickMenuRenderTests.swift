@testable import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

/// Draws the quick menu over a guide stand-in in a 1920×1080 hosted window, with the mockup's content
/// (`#v=browse&r=1080&m=filter`), and writes each state to `/tmp/menu-exact/<name>.png` to be compared with the mockup's render.
/// The checks are on the rendered pixels: the focused row is the near-white pill, and nothing above My Channels is drawn.
@MainActor
final class LiveTVGlassQuickMenuRenderTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/menu-exact", isDirectory: true)
    /// The heading pill's centre on screen (1080p): the hero block ends at 330 and the pill hangs 19.5 below the button line.
    private static let headingCenter: CGFloat = 330 - 10.5
    private static let menuLeading: CGFloat = 114

    fileprivate struct State {
        var name: String
        var entries: [LiveTVGlassQuickMenuEntry]
        var focusID: String?
        var headingTitle = "Canada"
        var headingCount = "7"
    }

    private var states: [State] {
        let tools = LiveTVGlassQuickMenuFixture.tools
        return [
            State(name: "1-mockup-canada-focused", entries: LiveTVGlassQuickMenuFixture.mockup, focusID: "filter:canada"),
            State(name: "2-no-favourites", entries: [
                .init(id: "all", kind: .myChannels, title: "My Channels", count: "16.3k", focusedTotal: "34.5k", isSelected: true),
                .init(id: "newFilter", kind: .newFilter, title: "New Favourite Filter", glyph: .plus)
            ] + tools, focusID: "all", headingTitle: "My Channels", headingCount: "16.3k"),
            State(name: "3-toolbar-focused", entries: LiveTVGlassQuickMenuFixture.mockup, focusID: "multiview"),
            State(name: "4-kids-profile", entries: [
                .init(id: "all", kind: .myChannels, title: "Kids' Channels", count: "412", isSelected: true),
                tools[0], tools[1]
            ], focusID: "all", headingTitle: "Kids' Channels", headingCount: "412"),
            State(name: "5-long-filter-name", entries: [
                .init(id: "all", kind: .myChannels, title: "My Channels", count: "16.3k"),
                .init(id: "filter:long", kind: .favoriteFilter, title: "Premier League · Football · English · 4K · Live Events",
                      count: "1.2k", isSelected: true),
                .init(id: "filter:sports", kind: .favoriteFilter, title: "Sports · 4K", count: "5"),
                .init(id: "editFilters", kind: .facet, title: "Edit Favourite Filters", glyph: .pencil)
            ] + tools, focusID: "filter:long", headingTitle: "Premier League · Football · English · 4K · Live Events", headingCount: "1.2k"),
            State(name: "6-my-channels-total-focused", entries: [
                .myChannels(id: "all", title: "My Channels", count: 16_300, mergedTotal: 34_500, showsTotal: true, isSelected: true),
                .init(id: "filter:canada", kind: .favoriteFilter, title: "Canada", count: "7"),
                .init(id: "filter:sports", kind: .favoriteFilter, title: "Sports · 4K", count: "5"),
                .init(id: "editFilters", kind: .facet, title: "Edit Favourite Filters", glyph: .pencil)
            ] + tools, focusID: "all", headingTitle: "My Channels", headingCount: "16.3k")
        ]
    }

    func testRendersEveryStateAndTheFocusedRowIsTheWhitePill() async throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        for state in states {
            let (window, previous) = try await makeWindow()
            let layout = LiveTVGlassQuickMenuLayout(
                entries: state.entries, headingWidth: LiveTVGlassQuickMenuLayout.headingWidth(title: state.headingTitle, count: state.headingCount),
                caption: "Updated 6:41 PM")
            let top = layout.top(headingCenter: Self.headingCenter)
            let host = UIHostingController(rootView: RenderFixture(state: state, layout: layout, top: top))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            for _ in 0..<60 {
                window.layoutIfNeeded()
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                if system.focusedItem != nil { break }
            }
            // Let the focus fill and the glass settle.
            try await Task.sleep(for: .milliseconds(600))
            let image = DetailTransitionSnapshot.image(of: window)
            try XCTUnwrap(image.pngData()).write(to: Self.outputDirectory.appendingPathComponent("\(state.name).png"))

            let sheetOrigin = CGPoint(x: Self.menuLeading, y: top)
            let focusedID = try XCTUnwrap(state.focusID)
            let focused = try XCTUnwrap(layout.frames[focusedID])
            let isRow = focused.width > focused.height * 2
            let sample = CGPoint(x: sheetOrigin.x + (isRow ? focused.maxX - 70 : focused.midX + 22), y: sheetOrigin.y + focused.midY)
            XCTAssertGreaterThan(luminance(of: image, at: sample) ?? 0, 0.85,
                                 "\(state.name): the focused entry is drawn as the near-white pill")
            if isRow {
                // A focused row's fill spans its width; an unfocused neighbour is not filled.
                if let other = layout.entries.first(where: { $0.id != focusedID && $0.kind != .tool && layout.frames[$0.id] != nil }) {
                    let frame = layout.frames[other.id]!
                    let probe = CGPoint(x: sheetOrigin.x + frame.maxX - 70, y: sheetOrigin.y + frame.midY)
                    XCTAssertLessThan(luminance(of: image, at: probe) ?? 1, 0.7, "\(state.name): \(other.id) is not highlighted")
                }
            }
            // The first row sits at the sheet's top inset: nothing is drawn above it (no heading line).
            let firstRow = try XCTUnwrap(layout.frames[layout.entries[0].id])
            XCTAssertEqual(firstRow.minY, LiveTVGlassQuickMenuLayout.padding)
            XCTAssertEqual(window.bounds.size, CGSize(width: 1920, height: 1080))
        }
    }

    /// Relative luminance (0...1) of the pixel at a point of the 1920×1080 snapshot.
    private func luminance(of image: UIImage, at point: CGPoint) -> CGFloat? {
        guard let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / 1920
        let rect = CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)
        guard let crop = cg.cropping(to: rect) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
    }

    private func makeWindow() async throws -> (UIWindow, UIWindow?) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return (window, previous)
    }
}

/// A guide stand-in drawn like the mockup's (dark page, hero text on the right, plate numbers, programme cells) so the menu's glass
/// has something to blur, plus the menu at the position the screen gives it.
private struct RenderFixture: View {
    let state: LiveTVGlassQuickMenuRenderTests.State
    let layout: LiveTVGlassQuickMenuLayout
    let top: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 8 / 255, green: 9 / 255, blue: 12 / 255)
            VStack(alignment: .leading, spacing: 0) {
                Text("CBC News: Toronto").font(.system(size: 52, weight: .bold))
                Text("News").font(.system(size: 25)).padding(.top, 12)
                Text("Saturday's stories from across the city and the GTA.")
                    .font(.system(size: 25)).foregroundStyle(.white.opacity(0.55)).padding(.top, 12)
            }
            .foregroundStyle(.white)
            .frame(width: 680, alignment: .leading)
            .offset(x: 1920 - 80 - 680 - 8, y: 180)
            ForEach(Array(["Hockey Night in Canada", "Northern Bake-Off", "Cottage Country", "News Now", "CFL Eastern Final"].enumerated()), id: \.offset) { index, title in
                let y = 358 + 52 + 14 + CGFloat(index) * 92
                Text(verbatim: "\(300 + index)").font(.system(size: 27)).foregroundStyle(.white.opacity(0.5))
                    .offset(x: 152, y: y + 26)
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.08))
                    .frame(width: 1920 - 80 - 436, height: 82)
                    .overlay(alignment: .leading) {
                        Text(title).font(.system(size: 27)).foregroundStyle(.white.opacity(0.92)).padding(.leading, 18)
                    }
                    .offset(x: 436, y: y)
            }
            LiveTVGlassQuickMenu(
                entries: state.entries,
                headingWidth: LiveTVGlassQuickMenuLayout.headingWidth(title: state.headingTitle, count: state.headingCount),
                caption: "Updated 6:41 PM",
                initialFocusID: state.focusID,
                onSelect: { _ in },
                onClose: {})
                .offset(x: 114, y: top)
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }
}
