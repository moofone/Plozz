#if os(tvOS)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

/// Hosted renders of the real Favourite Filters page, its hold menu and the tag picker at 1080p and 4K tokens, measured against the
/// reference renders `mockup-ff-favs.png`, `mockup-ff-tags.png` and `mockup-ff-menu.png` (1 reference pixel = 1 pt, measured from the panel's
/// top-left). The renders are written to `$PLOZZ_LIVETV_SNAPSHOT_DIR` (default: the temporary directory) with the comparison table.
@MainActor
final class LiveTVGlassFilterScreenHostedTests: XCTestCase {
    private let canvas = CGSize(width: 1_920, height: 1_080)
    private let tolerance: CGFloat = 6
    private var table: [String] = []
    private var model: LiveTVPrototypeModel!

    override func setUp() async throws {
        try await super.setUp()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiveTVGlassFilterScreenHostedTests.\(UUID().uuidString)"))
        model = LiveTVPrototypeModel(channels: Self.channels(), favoriteFilterStore: LiveTVFavoriteFilterStore(defaults: defaults, namespace: "ff"))
        XCTAssertNotNil(model.createFavoriteFilter(tagIDs: ["canada"]))
        XCTAssertNotNil(model.createFavoriteFilter(tagIDs: ["sports", "4k"]))
    }

    override func tearDown() async throws {
        LiveTVGlassLayout.override = nil
        try await super.tearDown()
    }

    /// Seven Canadian channels, five of them sports in 4K (the reference's Canada 7 and Sports · 4K 5), a UK lineup with the
    /// reference's suggested tags, and a live event.
    private static func channels() -> [LiveTVPrototypeChannel] {
        func channel(_ id: Int, _ name: String, _ group: String) -> LiveTVPrototypeChannel {
            .init(id: "\(id)", number: id, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: [group])
        }
        let canada = [
            channel(1, "CA EN: CBC News", "CA| NEWS"), channel(2, "CA EN: CTV 4K", "CA| GENERAL"),
            channel(3, "CA EN: TSN 4K", "CA| SPORT"), channel(4, "CA EN: Sportsnet 4K", "CA| SPORT"),
            channel(5, "CA EN: TSN2 4K", "CA| SPORT"), channel(6, "CA EN: Sportsnet One 4K", "CA| SPORT"),
            channel(7, "CA EN: CFL Network 4K", "CA| SPORT")]
        let rest = [
            channel(8, "UK EN: BBC News", "UK| NEWS"), channel(9, "UK EN: Sky Cinema", "UK| MOVIES"),
            channel(10, "UK EN: Sky Sports Football", "UK| FOOTBALL"), channel(11, "UK EN: Sky Sports F1", "UK| SPORT"),
            channel(12, "UK EN: Disney Channel", "UK| FAMILY"), channel(13, "UK EN: CBeebies", "UK| KIDS"),
            channel(14, "TSN+ 01 | Leafs vs. Bruins (2026-11-19 21:25:00)", "CA| TSN+ PPV")]
        return canada + rest
    }

    // MARK: Pixels

    private struct Pixels {
        let width: Int, height: Int
        let luma: [UInt8]

        /// The bounds of the pixels brighter than `threshold` inside `rect`.
        func ink(in rect: CGRect, above threshold: UInt8 = 150) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) where luma[y * width + x] > threshold {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    /// Renders through a real window: `ImageRenderer` cannot draw the picker's text field or scroll view.
    private func render(_ view: some View, size: CGSize, name: String) throws -> Pixels {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading).ignoresSafeArea())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            guard let context = UIGraphicsGetCurrentContext() else { return }
            window.layer.render(in: context)
        }.cgImage)
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
        return Pixels(width: width, height: height, luma: luma)
    }

    private static var outputDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["PLOZZ_LIVETV_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PlozzLiveTVRes4K")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func row(_ element: String, reference: CGFloat, app: CGFloat, tolerance: CGFloat? = nil) {
        table.append("| \(element) | \(String(format: "%.1f", reference)) | \(String(format: "%.1f", app)) | \(String(format: "%+.1f", app - reference)) |")
        XCTAssertEqual(app, reference, accuracy: tolerance ?? self.tolerance, element)
    }

    private func writeTable(_ name: String) {
        let text = "| element | reference (pt) | app (pt) | Δ |\n|---|---|---|---|\n" + table.joined(separator: "\n") + "\n"
        try? text.write(to: Self.outputDirectory.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        print("LIVETV-FILTERS \(name)\n\(text)")
        table = []
    }

    // MARK: Favourite Filters page (reference: mockup-ff-favs.png, panel at 133,466)

    /// The reference page is 560 wide; the page is as wide as the tray, so its right-hand parts sit this far left.
    private var panelShift: CGFloat { LiveTVGlassQuickMenuLayout.minWidth - 560 }

    /// Luma above the glass panel's own tone (a chip's or field's fill sits just over it).
    private let fillThreshold: UInt8 = 75
    /// Save is dimmed (40%) until the draft can be saved.
    private let dimmedFillThreshold: UInt8 = 67

    private func pageSize(_ scale: CGFloat) -> CGSize {
        let size = LiveTVGlassFavouriteFiltersPlan.size(rowCount: model.favoriteFilterList.count, maxHeight: 900)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func hostedPage(scale: CGFloat) -> some View {
        let size = LiveTVGlassFavouriteFiltersPlan.size(rowCount: model.favoriteFilterList.count, maxHeight: 900)
        return ZStack(alignment: .topLeading) {
            Color.black
            LiveTVGlassUnitScale(scale: scale) {
                LiveTVGlassFavouriteFiltersPage(
                    model: model, top: 0, canvasHeight: 900, preferredFocusID: nil, onNew: {}, onEdit: { _ in }, onBack: {})
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    /// The reference's rows, measured from the panel's top-left: text left 39, row centres 108 / 196 / 258, the hold hint at 315,
    /// the count's right edge 80 and the chevron's centre 51 from the panel's right edge (the panel itself is 560 wide, as the tray).
    func testFavouriteFiltersPageMatchesTheReferenceRowByRow() throws {
        for (glass, name) in [(LiveTVGlassLayout.hd1080, "1080"), (.uhd4K, "4K")] {
            LiveTVGlassLayout.override = glass
            let scale = glass.uiScale
            let pixels = try render(hostedPage(scale: scale), size: pageSize(scale), name: "ff-page-\(name)")
            func band(_ centre: CGFloat, left: CGFloat = 20, right: CGFloat = 480, threshold: UInt8 = 150) -> CGRect? {
                pixels.ink(in: CGRect(x: left * scale, y: (centre - 24) * scale, width: (right - left) * scale, height: 48 * scale), above: threshold)
            }
            let new = try XCTUnwrap(band(108), "New Favourite Filter row")
            row("\(name) New Favourite Filter text left", reference: 39 * scale, app: new.minX, tolerance: 6 * scale)
            row("\(name) New Favourite Filter centre y", reference: 108 * scale, app: new.midY, tolerance: 8 * scale)
            let canada = try XCTUnwrap(band(196), "Canada row")
            row("\(name) Canada text left", reference: 39 * scale, app: canada.minX, tolerance: 6 * scale)
            row("\(name) Canada centre y", reference: 196 * scale, app: canada.midY, tolerance: 8 * scale)
            let sports = try XCTUnwrap(band(258), "Sports · 4K row")
            row("\(name) Sports · 4K centre y", reference: 258 * scale, app: sports.midY, tolerance: 8 * scale)
            let hint = try XCTUnwrap(band(315, threshold: 100), "hold hint")
            row("\(name) hold hint left", reference: 39 * scale, app: hint.minX, tolerance: 6 * scale)
            row("\(name) hold hint centre y", reference: 315 * scale, app: hint.midY, tolerance: 8 * scale)
            let count = try XCTUnwrap(band(196, left: 380 + panelShift, right: 488 + panelShift, threshold: 90), "count")
            row("\(name) count right edge from panel right", reference: 80 * scale, app: LiveTVGlassQuickMenuLayout.minWidth * scale - count.maxX, tolerance: 6 * scale)
            let chevron = try XCTUnwrap(band(196, left: 494 + panelShift, right: 540 + panelShift, threshold: 90), "chevron")
            row("\(name) chevron centre from panel right", reference: 51 * scale, app: LiveTVGlassQuickMenuLayout.minWidth * scale - chevron.midX, tolerance: 6 * scale)
            writeTable("ff-page-\(name)")
        }
    }

    func testPageSizeFollowsTheListMetrics() throws {
        let page = LiveTVGlassFavouriteFiltersPage(
            model: model, top: 0, canvasHeight: 900, preferredFocusID: nil, onNew: {}, onEdit: { _ in }, onBack: {})
        let host = UIHostingController(rootView: page)
        let size = host.sizeThatFits(in: CGSize(width: 1_920, height: 1_080))
        let plan = LiveTVGlassFavouriteFiltersPlan.size(rowCount: 2, maxHeight: 900)
        XCTAssertEqual(size.width, plan.width, accuracy: 1)
        XCTAssertEqual(size.height, plan.height, accuracy: 1)
        XCTAssertEqual(plan.height, 14 + 62 + 62 + 25 + 124 + 52 + 14, "the reference's panel without Kids' Channels")
    }

    // MARK: Hold menu (reference: the mockup's fx menu: Edit, Move Up, Move Down, Delete)

    func testHoldMenuRendersItsRowsAndTheRedDelete() throws {
        let content = LiveTVGlassFilterHoldMenu.content(index: 1, count: 3)
        let menu = LiveTVGlassContextMenu(
            entries: content.entries, metrics: LiveTVGlassFilterHoldMenu.metrics, initialFocusID: nil, onSelect: { _ in }, onClose: {})
            .fixedSize()
        let view = ZStack(alignment: .topLeading) { Color.black; menu }
            .frame(width: 380, height: LiveTVGlassFilterHoldMenu.height(of: content), alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        let pixels = try render(view, size: CGSize(width: 380, height: LiveTVGlassFilterHoldMenu.height(of: content)), name: "ff-hold-menu")
        XCTAssertEqual(content.entries.count, 4)
        for index in 0..<4 {
            let centre = 14 + CGFloat(index) * 62 + 31
            XCTAssertNotNil(pixels.ink(in: CGRect(x: 20, y: centre - 24, width: 300, height: 48), above: 110), "row \(index)")
        }
        let confirm = LiveTVGlassFilterHoldMenu.confirmation(name: "Sports · 4K")
        let confirmView = ZStack(alignment: .topLeading) {
            Color.black
            LiveTVGlassContextMenu(
                entries: confirm.entries, title: confirm.title, metrics: LiveTVGlassFilterHoldMenu.metrics,
                initialFocusID: confirm.initialFocusID, onSelect: { _ in }, onClose: {}).fixedSize()
        }
        .frame(width: 380, height: LiveTVGlassFilterHoldMenu.height(of: confirm), alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        let confirmPixels = try render(confirmView, size: CGSize(width: 380, height: LiveTVGlassFilterHoldMenu.height(of: confirm)), name: "ff-hold-confirm")
        XCTAssertNotNil(confirmPixels.ink(in: CGRect(x: 20, y: 14, width: 340, height: 40), above: 100), "the confirmation's title")
    }

    // MARK: Tag picker (reference: mockup-ff-tags-picked.png, panel at 135,240)

    private func hostedPicker(scale: CGFloat, size: CGSize, editing: String? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            LiveTVGlassUnitScale(scale: scale) {
                LiveTVGlassTagPicker(model: model, size: size, editingID: editing, onSave: { _, _ in true }, onDelete: editing == nil ? nil : {}, onBack: {})
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    /// The mockup's Plozz-like sheet (`tagLayout`), measured from the panel's top-left: the title at 48, the name box 48…668 at 122…178,
    /// the section name column at 48 and the first section's first word at 48 + 250.
    func testTagSheetMatchesTheMockupAtBothSizes() throws {
        for (glass, name) in [(LiveTVGlassLayout.hd1080, "1080"), (.uhd4K, "4K")] {
            LiveTVGlassLayout.override = glass
            let scale = glass.uiScale
            let size = LiveTVGlassTagSheetMetrics.size(canvas: canvas, scale: scale)
            XCTAssertEqual(size.width * scale, canvas.width - 80, accuracy: 0.001, "\(name) 40 pt margin left and right")
            XCTAssertEqual(size.height * scale, canvas.height - 80, accuracy: 0.001, "\(name) 40 pt margin top and bottom")
            let pixels = try render(hostedPicker(scale: scale, size: size), size: CGSize(width: size.width * scale, height: size.height * scale), name: "ff-tags-\(name)")
            func ink(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, above: UInt8 = 150) -> CGRect? {
                pixels.ink(in: CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale), above: above)
            }
            let title = try XCTUnwrap(ink(20, 30, 560, 90), "title")
            row("\(name) title left", reference: 48 * scale, app: title.minX, tolerance: 5 * scale)
            let nameBox = try XCTUnwrap(ink(20, 112, 700, 80, above: 25), "name box")
            row("\(name) name box left", reference: 48 * scale, app: nameBox.minX, tolerance: 4 * scale)
            row("\(name) name box top", reference: 122 * scale, app: nameBox.minY, tolerance: 5 * scale)
            row("\(name) name box height", reference: 56 * scale, app: nameBox.height, tolerance: 5 * scale)
            row("\(name) name box width", reference: 620 * scale, app: nameBox.width, tolerance: 8 * scale)
            let label = try XCTUnwrap(ink(30, 200, 240, 70, above: 100), "first section's name")
            row("\(name) section name left", reference: 48 * scale, app: label.minX, tolerance: 6 * scale)
            let word = try XCTUnwrap(ink(280, 200, 200, 70, above: 100), "first section's first tag")
            row("\(name) first tag word left", reference: 298 * scale, app: word.minX, tolerance: 6 * scale)
            writeTable("ff-tags-\(name)")
        }
    }

    /// An edited filter's picked tags carry the accent checkmark and no capsule.
    func testPickerShowsTheEditedFilterNameAndItsTagsAsPicked() throws {
        let filter = try XCTUnwrap(model.favoriteFilterList.last)
        let size = LiveTVGlassTagSheetMetrics.size(canvas: canvas, scale: 1)
        let pixels = try render(hostedPicker(scale: 1, size: size, editing: filter.id), size: size, name: "ff-tags-edit")
        let title = try XCTUnwrap(pixels.ink(in: CGRect(x: 20, y: 30, width: 600, height: 80)), "title")
        XCTAssertGreaterThan(title.width, 150, "the title names what you are doing")
        let sections = model.filterTagSections(selectedTagIDs: filter.tagIDs)
        XCTAssertTrue(sections.flatMap(\.tags).contains { filter.tagIDs.contains($0.tag.id) })
        var accent = 0
        for y in 190..<700 { for x in 40..<1_200 {
            let index = (y * pixels.width + x)
            if pixels.luma[index] > 110, pixels.luma[index] < 200 { accent += 1 }
        } }
        XCTAssertGreaterThan(accent, 50, "a picked tag is drawn with its checkmark")
    }

    // MARK: Flow layout

    func testFlowLayoutWrapsAtTheWidthAndKeepsTheGapsOfTheMockup() {
        let chip = CGSize(width: 300, height: 56)
        let result = LiveTVGlassFlowLayout.frames(for: [chip, chip, chip, chip], width: 1_100, spacing: 14)
        XCTAssertEqual(result.frames.map(\.origin), [
            CGPoint(x: 0, y: 0), CGPoint(x: 314, y: 0), CGPoint(x: 628, y: 0), CGPoint(x: 0, y: 70)])
        XCTAssertEqual(result.height, 126)
        XCTAssertEqual(LiveTVGlassFlowLayout.frames(for: [], width: 100, spacing: 14).height, 0)
        let wide = LiveTVGlassFlowLayout.frames(for: [CGSize(width: 2_000, height: 56)], width: 1_100, spacing: 14)
        XCTAssertEqual(wide.frames.first?.origin, .zero, "a chip wider than the line still starts one")
    }
}
#endif
