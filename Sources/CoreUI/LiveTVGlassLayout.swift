import CoreGraphics
import Foundation
import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// The Liquid Glass Live TV screen's metrics for one display class. The mockup draws its 4K layout at 2560×1440 pt (UI scale 1.5×)
/// with the Apple-style hero, panels and rail at 1.2× (`AL(K)`); tvOS always lays out in 1920×1080 pt, so every 4K value here is the
/// mockup's × `uhdScale` (0.75), and the hero/panel/tray/clock sizes are their 1080p value × `uiScale` (1.2 × 0.75 = 0.9).
///
/// Read it from the SwiftUI environment (`\.liveTVGlassLayout`, kept current by `liveTVGlassLayoutTracking()`); the static `active`
/// is the same choice for code that has no view, and tests pin a layout with `override`.
public struct LiveTVGlassLayout: Equatable, Sendable {
    public static let uhdScale: CGFloat = 1920.0 / 2560.0
    /// The mockup's `AL(K).k` for 4K.
    public static let uhdUIFactor: CGFloat = 1.2

    // MARK: Guide (mockup `LAYOUT`)
    public var rowHeight: CGFloat
    public var rowGap: CGFloat
    public var cellGap: CGFloat
    public var cellRadius: CGFloat
    public var rulerHeight: CGFloat
    /// The gap between the ruler and the first row (mockup: 14).
    public var rulerRowGap: CGFloat
    public var rulerFontSize: CGFloat
    /// The station column: 48 pt narrower than the mockup's plate (1080: 252, 4K: 250 + 8). Channel logos have a median
    /// visible aspect of about 2.6:1 and draw near 97 × 37 pt, so the mockup's width left about 60 pt empty either side;
    /// the logo zone still fits the 164 pt logo box.
    public var plateWidth: CGFloat
    /// The plate's own parts are drawn in a 82 pt reference cell and scaled by `rowHeight / 82`, so these three are in reference units:
    /// scaled by the row they give the mockup's `numW`, `pPad` and `logoPad`.
    public var plateNumberWidth: CGFloat
    public var plateLeadingInset: CGFloat
    public var plateLogoTrailingInset: CGFloat
    public var cellFontSize: CGFloat
    /// The timeline window in minutes: 120 at 1080p, 180 at 4K.
    public var windowMinutes: Int

    // MARK: Screen frame (mockup `LX`, `PX`, `hb`, `gy`)
    /// Screen x of the guide's channel plates (`AL.LX`).
    public var leadingInset: CGFloat
    /// Gap from the guide's trailing edge to the screen edge (`PX`).
    public var trailingInset: CGFloat
    /// Where the hero block ends (`hb`).
    public var heroBlockBottom: CGFloat
    /// The gap between the hero block and the guide's ruler (`gy - hb`).
    public var heroBottomGap: CGFloat
    /// Screen x of the heading capsule's left edge: the name lines up with the plate numbers.
    public var headingLeadingX: CGFloat

    // MARK: Hero, panels, tray, clock
    /// Multiplies every 1080p hero, panel, menu-tray and clock size (`AL(K).k` × `uhdScale`).
    public var uiScale: CGFloat
    /// The right channel panel's width and its distance from the top and trailing screen edges.
    public var panelWidth: CGFloat
    public var panelMargin: CGFloat

    // MARK: Plozz-like sheet
    /// One mockup pixel (the design's plain, unscaled px values): 1 at 1080p, `uhdScale` at 4K, where the mockup lays out in 2560 × 1440.
    public var pixelScale: CGFloat = 1
    /// How far the guide's ruler is pushed below `guideTop` while the guide sits on its one glass sheet (see `withGuideSheet()`).
    public var guideSheetDrop: CGFloat = 0

    public var windowSeconds: TimeInterval { TimeInterval(windowMinutes * 60) }
    /// Where the guide's ruler starts on screen.
    public var guideTop: CGFloat { heroBlockBottom + heroBottomGap + guideSheetDrop }
    /// A 1080p hero/panel/tray/clock size at this layout.
    public func ui(_ hd: CGFloat) -> CGFloat { hd * uiScale }

    /// The layout while a picture plays and the times and rows sit on one glass sheet (mockup `onePanel`): the sheet starts
    /// `ui(28 + 12)` under the hero block, the ruler `ui(10)` inside it and `ui(14)` shorter, and the rows keep their 14 px lead-in.
    public func withGuideSheet() -> LiveTVGlassLayout {
        var sheet = self
        sheet.guideSheetDrop = ui(12) + ui(10)
        sheet.rulerHeight = rulerHeight - ui(14)
        return sheet
    }

    /// The app's 1080p guide (the mockup's 1080 column as tuned in POLISH-1).
    public static let hd1080 = LiveTVGlassLayout(
        rowHeight: 82, rowGap: 10, cellGap: 12, cellRadius: 24, rulerHeight: 52, rulerRowGap: 14, rulerFontSize: 22, plateWidth: 204,
        plateNumberWidth: 64, plateLeadingInset: 8, plateLogoTrailingInset: 30, cellFontSize: 27, windowMinutes: 120,
        leadingInset: 144, trailingInset: 80, heroBlockBottom: 330, heroBottomGap: 28, headingLeadingX: 130,
        uiScale: 1, panelWidth: 600, panelMargin: 40, pixelScale: 1)

    /// The mockup's `LAYOUT["4k"]` × 0.75 and `AL(true)` (every `z(n)` = round(n × 1.2) in the 2560 space, then × 0.75):
    /// rowH 74, rowGap 10, cg 10, cellR 22, rulerH 50, plateW 202 + 8 (the mockup's 250 + 8, 48 narrower), numW 49, pPad 8, logoPad 22, fsCell 25, fsRuler 22, win 180,
    /// LX z(144), PX 96, hb z(330), gy − hb z(28), the heading at LX + pPad − z(22), the panel 760 wide and 40 from the edges.
    public static let uhd4K: LiveTVGlassLayout = {
        let u = uhdScale
        func z(_ n: CGFloat) -> CGFloat { (n * uhdUIFactor).rounded() }
        let row = 74 * u
        let referenceScale = row / 82
        return LiveTVGlassLayout(
            rowHeight: row, rowGap: 10 * u, cellGap: 10 * u, cellRadius: 22 * u,
            rulerHeight: 50 * u, rulerRowGap: 14 * u, rulerFontSize: 22 * u, plateWidth: (202 + 8) * u,
            plateNumberWidth: 49 * u / referenceScale, plateLeadingInset: 8 * u / referenceScale,
            plateLogoTrailingInset: 22 * u / referenceScale, cellFontSize: 25 * u, windowMinutes: 180,
            leadingInset: z(144) * u, trailingInset: 96 * u, heroBlockBottom: z(330) * u, heroBottomGap: z(28) * u,
            headingLeadingX: (z(144) + 8 - z(22)) * u,
            uiScale: uhdUIFactor * u, panelWidth: 760 * u, panelMargin: 40 * u, pixelScale: u)
    }()

    /// 4K when the display mode is at least 3840×2160 pixels.
    public static func chooser(pixelWidth: CGFloat, pixelHeight: CGFloat) -> LiveTVGlassLayout {
        max(pixelWidth, pixelHeight) >= 3_840 && min(pixelWidth, pixelHeight) >= 2_160 ? .uhd4K : .hd1080
    }

    /// Tests pin a layout here so they do not depend on the simulator's display mode.
    nonisolated(unsafe) public static var override: LiveTVGlassLayout?

    /// The layout for the screen's current mode, or the DEBUG launch argument `-PlozzLiveTVLayout 1080|4k`.
    public static var active: LiveTVGlassLayout {
        if let override { return override }
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "PlozzLiveTVLayout")?.lowercased() {
        case "1080": return .hd1080
        case "4k": return .uhd4K
        default: break
        }
        #endif
        #if os(tvOS)
        let size = UIScreen.main.currentMode?.size ?? UIScreen.main.nativeBounds.size
        return chooser(pixelWidth: size.width, pixelHeight: size.height)
        #else
        return .hd1080
        #endif
    }
}

private struct LiveTVGlassLayoutKey: EnvironmentKey {
    static let defaultValue = LiveTVGlassLayout.hd1080
}

extension EnvironmentValues {
    /// The Live TV layout tokens in force; `.hd1080` unless an ancestor applies `liveTVGlassLayoutTracking()` or sets it.
    public var liveTVGlassLayout: LiveTVGlassLayout {
        get { self[LiveTVGlassLayoutKey.self] }
        set { self[LiveTVGlassLayoutKey.self] = newValue }
    }
}

/// Publishes the layout for the screen's current display mode and recomputes it when the mode changes.
private struct LiveTVGlassLayoutTracking: ViewModifier {
    @State private var layout = LiveTVGlassLayout.active

    func body(content: Content) -> some View {
        content
            .environment(\.liveTVGlassLayout, layout)
            #if os(tvOS)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.modeDidChangeNotification)) { _ in
                let next = LiveTVGlassLayout.active
                if next != layout { layout = next }
            }
            #endif
    }
}

extension View {
    /// Sets `\.liveTVGlassLayout` from the display mode and keeps it current across mode changes.
    public func liveTVGlassLayoutTracking() -> some View { modifier(LiveTVGlassLayoutTracking()) }
}
