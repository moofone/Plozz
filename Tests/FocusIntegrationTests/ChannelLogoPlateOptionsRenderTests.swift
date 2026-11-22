@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

/// Renders the logo-plate options A-F for the logos that still fail the contrast rule, over three backdrops and three accessibility
/// modes, as real SwiftUI (including the real `glassEffect`), into `_briefs/live-tv-glass/logo-test/options/` with a results.json of
/// contrast scores measured on the rendered pixels behind each logo. Run on the 1080p simulator only.
@MainActor
final class ChannelLogoPlateOptionsRenderTests: XCTestCase {
    /// Under `PLOZZ_BRIEFS_DIR` (`TEST_RUNNER_PLOZZ_BRIEFS_DIR`); the test skips without it.
    private let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PLOZZ_BRIEFS_DIR"] ?? "/nonexistent").appendingPathComponent("logo-test/options")
    typealias Theme = ChannelLogoExtraction.Theme

    enum Option: String, CaseIterable { case A, B, C, D, E, F }
    enum Backdrop: String, CaseIterable { case darkRow, brightFrame, lightRow
        var theme: Theme { self == .lightRow ? .light : .dark }
    }
    enum Mode: String, CaseIterable { case normal, reduceTransparency, increaseContrast }

    struct Logo { let id: String; let name: String; let data: Data }

    static let slot = CGSize(width: 228, height: 74)
    static let cell = CGSize(width: 260, height: 110)
    static let gridOrigin = CGPoint(x: 300, y: 130)

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CoreUITests/Fixtures/LogoRule")
    }

    private func logos() throws -> [Logo] {
        let dir = fixtureDirectory()
        func file(_ n: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(n)) }
        // SYNTHETIC: black text bars on a yellow shape (dark text on colour).
        var bytes = [UInt8]()
        for y in 0..<60 { for x in 0..<160 {
            let inShape = x > 8 && x < 152 && y > 6 && y < 54
            let inText = inShape && x > 30 && x < 130 && ((y > 20 && y < 28) || (y > 34 && y < 42))
            bytes += inText ? [10, 10, 10, 255] : inShape ? [245, 200, 30, 255] : [0, 0, 0, 0]
        } }
        let synthetic = try XCTUnwrap(ChannelLogoPixels(width: 160, height: 60, bytes: bytes))
        let png = try XCTUnwrap(ChannelLogoExtraction.makeImage(synthetic).flatMap { UIImage(cgImage: $0).pngData() })
        return [
            Logo(id: "global-calgary-sd", name: "Global Calgary", data: try file("PROV_CA_EN__GLOBAL_CALAGRY_SD.jpg")),
            Logo(id: "ctv-calgary-news", name: "CTV Calgary News", data: try file("PROV_CA_EN__CTV_CALARY_NEWS.jpg")),
            Logo(id: "global-montreal", name: "Global Montreal", data: try file("PROV_CA_EN__GLOBAL_MONTREAL.jpg")),
            Logo(id: "synthetic-dark-on-colour", name: "Sample Channel", data: png)
        ]
    }

    // MARK: Cells

    struct Cell: View {
        let option: Option, logo: Logo, theme: Theme, mode: Mode, backingOnly: Bool
        let prepared: ChannelLogoExtraction.Prepared
        let original: UIImage

        private var plateIsLight: Bool { theme == .dark }
        private var opaque: Bool { mode != .normal }

        var body: some View {
            ZStack {
                switch option {
                case .A: plate(flat: true) { image }
                case .B: plate(flat: false) { image }
                case .C: glassPlate { image }
                case .D: image   // the column's single glass layer is drawn behind the whole column
                case .E: Image(uiImage: original).resizable().scaledToFit().opacity(backingOnly ? 0 : 1).padding(2)
                case .F:
                    Text(logo.name)
                        .font(.system(size: ChannelLogoPlateOptionsRenderTests.slot.height * 0.4, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4).lineLimit(2).multilineTextAlignment(.center)
                        .foregroundStyle(theme == .dark ? Color.white : Color(white: 0.1))
                        .opacity(backingOnly ? 0 : 1)
                }
            }
            .frame(width: ChannelLogoPlateOptionsRenderTests.slot.width, height: ChannelLogoPlateOptionsRenderTests.slot.height)
            .frame(width: ChannelLogoPlateOptionsRenderTests.cell.width, height: ChannelLogoPlateOptionsRenderTests.cell.height)
        }

        private var image: some View {
            Group {
                if prepared.isDark {
                    Image(uiImage: prepared.image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(.white.opacity(0.9))
                } else {
                    Image(uiImage: prepared.image).renderingMode(.original).resizable().scaledToFit()
                }
            }
            .opacity(backingOnly ? 0 : 1)
        }

        private var fill: Color { (plateIsLight ? Color.white : Color(white: 28.0 / 255)).opacity(opaque ? 1 : 0.9) }
        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

        private func plate(flat: Bool, @ViewBuilder _ content: () -> some View) -> some View {
            content().padding(7).background {
                shape.fill(fill).overlay {
                    if !flat {   // B: a 1 px edge and a slight inner highlight, no live effect
                        shape.strokeBorder(plateIsLight ? Color.black.opacity(0.25) : Color.white.opacity(0.35), lineWidth: 1)
                        shape.fill(LinearGradient(colors: [.white.opacity(plateIsLight ? 0.35 : 0.14), .clear], startPoint: .top, endPoint: .center))
                    }
                    if mode == .increaseContrast {
                        shape.strokeBorder(plateIsLight ? Color.black.opacity(0.6) : Color.white.opacity(0.7), lineWidth: 1.5)
                    }
                }
            }
        }

        @ViewBuilder private func glassPlate(@ViewBuilder _ content: () -> some View) -> some View {
            if opaque {
                plate(flat: true) { content() }   // Reduce Transparency / Increase Contrast: flat and opaque
            } else if #available(iOS 26.0, tvOS 26.0, *) {
                content().padding(7).glassEffect(.regular.tint(plateIsLight ? Color.white.opacity(0.35) : Color.black.opacity(0.3)), in: shape)
            } else {
                plate(flat: true) { content() }
            }
        }
    }

    struct Sheet: View {
        let backdrop: Backdrop, mode: Mode, backingOnly: Bool
        let logos: [Logo]
        let prepared: [String: ChannelLogoExtraction.Prepared]
        let originals: [String: UIImage]
        let frame: UIImage?

        var body: some View {
            ZStack(alignment: .topLeading) {
                switch backdrop {
                case .darkRow: Color(red: 25 / 255, green: 25 / 255, blue: 27 / 255)
                case .lightRow: Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
                case .brightFrame:
                    if let frame { Image(uiImage: frame).resizable().scaledToFill().frame(width: 1920, height: 1080).clipped() } else { Color.gray }
                }
                // D: one glass layer behind the whole logo column.
                if #available(iOS 26.0, tvOS 26.0, *), mode == .normal {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.clear)
                        .glassEffect(.regular.tint(backdrop == .lightRow ? Color.black.opacity(0.3) : Color.white.opacity(0.35)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .frame(width: ChannelLogoPlateOptionsRenderTests.cell.width + 20, height: ChannelLogoPlateOptionsRenderTests.cell.height * CGFloat(logos.count) + 20)
                        .offset(x: ChannelLogoPlateOptionsRenderTests.gridOrigin.x + ChannelLogoPlateOptionsRenderTests.cell.width * 3 - 10, y: ChannelLogoPlateOptionsRenderTests.gridOrigin.y - 10)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(backdrop == .lightRow ? Color(white: 28.0 / 255) : Color.white).opacity(0.9)
                        .frame(width: ChannelLogoPlateOptionsRenderTests.cell.width + 20, height: ChannelLogoPlateOptionsRenderTests.cell.height * CGFloat(logos.count) + 20)
                        .offset(x: ChannelLogoPlateOptionsRenderTests.gridOrigin.x + ChannelLogoPlateOptionsRenderTests.cell.width * 3 - 10, y: ChannelLogoPlateOptionsRenderTests.gridOrigin.y - 10)
                }
                ForEach(Array(logos.enumerated()), id: \.offset) { row, logo in
                    ForEach(Array(Option.allCases.enumerated()), id: \.offset) { col, option in
                        Cell(option: option, logo: logo, theme: backdrop.theme, mode: mode, backingOnly: backingOnly,
                             prepared: prepared[logo.id]!, original: originals[logo.id]!)
                            .offset(x: ChannelLogoPlateOptionsRenderTests.gridOrigin.x + CGFloat(col) * ChannelLogoPlateOptionsRenderTests.cell.width,
                                    y: ChannelLogoPlateOptionsRenderTests.gridOrigin.y + CGFloat(row) * ChannelLogoPlateOptionsRenderTests.cell.height)
                    }
                }
            }
            .frame(width: 1920, height: 1080, alignment: .topLeading)
        }
    }

    // MARK: Test

    func testRenderPlateOptions() async throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_BRIEFS_DIR"] != nil else { throw XCTSkip("PLOZZ_BRIEFS_DIR not set") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logos = try logos()
        let frame = UIImage(contentsOfFile: "/tmp/lg9.png")
        let (window, previous) = try await makeWindow()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var results: [[String: Any]] = []
        for backdrop in Backdrop.allCases {
            let theme = backdrop.theme
            var prepared: [String: ChannelLogoExtraction.Prepared] = [:], originals: [String: UIImage] = [:]
            for logo in logos {
                prepared[logo.id] = try XCTUnwrap(ChannelLogoExtraction.prepare(data: logo.data, providerRequestsDarkBackground: false, theme: theme))
                originals[logo.id] = try XCTUnwrap(UIImage(cgImage: try XCTUnwrap(ChannelLogoExtraction.decode(logo.data))))
            }
            for mode in Mode.allCases {
                var shots: [Bool: UIImage] = [:]
                for backing in [false, true] {
                    let view = Sheet(backdrop: backdrop, mode: mode, backingOnly: backing, logos: logos, prepared: prepared, originals: originals, frame: frame)
                        .environment(\.colorScheme, theme == .light ? .light : .dark)
                    window.rootViewController = UIHostingController(rootView: view)
                    window.makeKeyAndVisible()
                    for _ in 0..<12 { window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                    try await Task.sleep(for: .milliseconds(500))
                    shots[backing] = DetailTransitionSnapshot.image(of: window)
                }
                let name = "\(backdrop.rawValue)-\(mode.rawValue)"
                try XCTUnwrap(shots[false]?.pngData()).write(to: root.appendingPathComponent("\(name).png"))
                // Score each option from the pixels rendered behind the logo.
                let backing = try XCTUnwrap(shots[true]?.cgImage)
                let backingPixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(backing))
                let scale = Double(backing.width) / 1920
                for (row, logo) in logos.enumerated() {
                    let inkPixels = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared[logo.id]?.image.cgImage)))
                    for (col, option) in Option.allCases.enumerated() {
                        let rect = CGRect(x: Self.gridOrigin.x + CGFloat(col) * Self.cell.width + (Self.cell.width - Self.slot.width) / 2,
                                          y: Self.gridOrigin.y + CGFloat(row) * Self.cell.height + (Self.cell.height - Self.slot.height) / 2,
                                          width: Self.slot.width, height: Self.slot.height)
                        // The backing under the logo: the middle of the slot, where every logo's ink sits (the slot's edges are bare row).
                        let mean = meanColour(backingPixels, rect: rect.insetBy(dx: (rect.width - 44) / 2, dy: (rect.height - 30) / 2), scale: scale)
                        var score: Double
                        switch option {
                        case .F:
                            let fg: Double = theme == .dark ? 255 : 26
                            let one = try XCTUnwrap(ChannelLogoPixels(width: 1, height: 1, bytes: [UInt8(fg), UInt8(fg), UInt8(fg), 255]))
                            score = ChannelLogoExtraction.readableInkShare(one, row: mean)
                        case .E:
                            let box = try XCTUnwrap(ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(originals[logo.id]?.cgImage)))
                            let corner = (Double(box.bytes[0]), Double(box.bytes[1]), Double(box.bytes[2]))
                            score = ChannelLogoExtraction.readableInkShare(inkPixels, row: corner)
                        default:
                            let silhouette = prepared[logo.id]?.isDark == true
                            score = ChannelLogoExtraction.readableInkShare(inkPixels, row: mean, inkOverride: silhouette ? (255, 255, 255) : nil, inkAlpha: silhouette ? 0.9 : 1)
                        }
                        results.append(["backdrop": backdrop.rawValue, "mode": mode.rawValue, "logo": logo.id, "option": option.rawValue,
                                        "score": score, "pass": score >= ChannelLogoExtraction.minimumReadableInkShare,
                                        "backing": [mean.0, mean.1, mean.2]])
                    }
                }
            }
        }
        // Cost: layout + snapshot of a 24-row column per option (dark row, normal), median of 3.
        var cost: [String: Double] = [:]
        for option in Option.allCases {
            var times: [Double] = []
            for _ in 0..<3 {
                let logo = logos[0]
                let prepared = try XCTUnwrap(ChannelLogoExtraction.prepare(data: logo.data, providerRequestsDarkBackground: false, theme: .dark))
                let original = UIImage(cgImage: try XCTUnwrap(ChannelLogoExtraction.decode(logo.data)))
                let column = ScrollView { VStack(spacing: 0) { ForEach(0..<9, id: \.self) { _ in
                    Cell(option: option, logo: logo, theme: .dark, mode: .normal, backingOnly: false, prepared: prepared, original: original) } } }
                    .background(Color.black).frame(width: 1920, height: 1080)
                window.rootViewController = UIHostingController(rootView: column)
                window.makeKeyAndVisible()
                let start = ContinuousClock.now
                for _ in 0..<3 { window.layoutIfNeeded() }
                _ = DetailTransitionSnapshot.image(of: window)
                let d = ContinuousClock.now - start
                times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            }
            cost[option.rawValue] = times.sorted()[1]
        }
        let json = try JSONSerialization.data(withJSONObject: ["rule": ChannelLogoExtraction.minimumReadableInkShare, "results": results, "costMs9Rows": cost], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: root.appendingPathComponent("results.json"))
        XCTAssertEqual(results.count, Backdrop.allCases.count * Mode.allCases.count * logos.count * Option.allCases.count)
    }

    private func meanColour(_ p: ChannelLogoPixels, rect: CGRect, scale: Double) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        let x0 = Int(rect.minX * scale), x1 = min(p.width, Int(rect.maxX * scale)), y0 = Int(rect.minY * scale), y1 = min(p.height, Int(rect.maxY * scale))
        for y in stride(from: y0, to: y1, by: 2) { for x in stride(from: x0, to: x1, by: 2) {
            let i = (y * p.width + x) * 4
            r += Double(p.bytes[i]); g += Double(p.bytes[i + 1]); b += Double(p.bytes[i + 2]); n += 1
        } }
        return n == 0 ? (0, 0, 0) : (r / n, g / n, b / n)
    }

    private func makeWindow() async throws -> (UIWindow, UIWindow?) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }), ContinuousClock.now < deadline {
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
