import CoreUI
import SwiftUI

/// The Plozz-like playing design (mockup `st=plozz`, `v=playing`): one sheet of system glass holds the guide's time ruler and its
/// rows, under a hero panel of the same glass. The values live here so tests can pin them. A "px" is one mockup pixel
/// (`LiveTVGlassLayout.pixelScale` points); `ui(n)` is a 1080p hero/panel size (`LiveTVGlassLayout.uiScale`).
enum PrototypePlayingGlass {
    /// The black tint of every panel over the picture: `.glassEffect(.regular.tint(.black.opacity(0.4)))` (mockup `.screen.pz .guideglass`).
    static let panelTintOpacity = 0.4
    /// The panels' 1 pt rim, `PanelGlassBackground`'s `.white.opacity(0.12)` (FeaturePlayback/PlayerControlsSupport.swift).
    static let rimOpacity = 0.12
    /// The even gap round the cells inside the sheet (mockup `sheetPad`, `sheetGapB`), in px.
    static let sheetPadding: CGFloat = 20
    /// The sheet's top edge below the heading's line, as `ui(n)`: the hero block's gap (28) and 12 more (mockup `hb + z(28) + z(12)`).
    static let sheetTopBelowHeroBlock: CGFloat = 40
    /// The ruler starts this far inside the sheet, as `ui(n)` (mockup `gy = sheetTop + z(10)`).
    static let rulerInset: CGFloat = 10
    /// The ruler is this much shorter than the plain guide's, as `ui(n)` (mockup `rulerH - z(14)`).
    static let rulerShortening: CGFloat = 14
    /// The sheet ends this far above the screen's bottom edge, as `ui(n)`, or at the last row that fits (mockup `H - z(28) - sheetGapB`).
    static let bottomMargin: CGFloat = 28
    /// The heading pill's bottom edge below the hero block's bottom, in px (mockup `hb + 24`).
    static let headingDrop: CGFloat = 24

    /// The fills and ink tiers of `ThemePalette.dark` that Plozz's player chrome draws over video (fill 11%, fillSubtle 6%, secondary 60%,
    /// tertiary 36%), and the focus card.
    static let cellFillOpacity = 0.11
    static let quietCellFillOpacity = 0.06
    static let focusedPlateFillOpacity = 0.2
    /// Focus is a solid white card with black ink; a finished programme's title is black at 45%, the played track black at 10%.
    static let focusedEndedInkOpacity = 0.45
    static let focusedTrackOpacity = 0.1
    static let rulerInkOpacity = 0.6
    static let quietInkOpacity = 0.36
    static let heroMetaOpacity = 0.6
    static let heroDescriptionOpacity = 0.82

    /// The scrim over the picture, drawn instead of the old edge scrims: the one `LiveChannelTransport.scrim` draws over live video
    /// (FeaturePlayback/LiveChannelTransport.swift:372): black 55% fading out by a quarter of the height (at most 220) from the top,
    /// black 70% from the bottom up over 55% of the height (at least 420).
    static let scrimTopOpacity = 0.55
    static let scrimBottomOpacity = 0.7
    static func scrimTopHeight(canvasHeight: CGFloat) -> CGFloat { min(canvasHeight * 0.25, 220) }
    static func scrimBottomHeight(canvasHeight: CGFloat) -> CGFloat { max(canvasHeight * 0.55, 420) }

    /// Whether the guide sits on the glass sheet: a picture plays under it (not multiview), transparency is allowed and the SDK has
    /// Liquid Glass (tvOS 26). Reduce Transparency and increased contrast keep the opaque fills and the older scrims; earlier
    /// systems keep their fallback.
    static func usesSDKGlass(
        hasPicture: Bool, isMultiview: Bool, reduceTransparency: Bool, increasedContrast: Bool, sdkHasLiquidGlass: Bool
    ) -> Bool {
        hasPicture && !isMultiview && !reduceTransparency && !increasedContrast && sdkHasLiquidGlass
    }
}

/// Where the sheet and the rows inside it sit, in screen points on a 1920 × 1080 canvas (mockup `appleScreen`, `onePanel`).
struct PrototypeGuideSheetPlan: Equatable {
    /// The sheet's frame on screen.
    let frame: CGRect
    /// The sheet's corner: the cells' plus the gap, so the two curves are concentric.
    let cornerRadius: CGFloat
    /// The ruler's height inside the sheet.
    let rulerHeight: CGFloat
    /// The rows the sheet holds: whole rows only, as many as fit above the bottom margin, or all of them when there are few.
    let fitRows: Int
    /// The height of the scrolling row list (its lead-in, the whole rows and the gaps between them).
    let listHeight: CGFloat
    /// Where the first row starts on screen.
    let rowsTop: CGFloat
    /// The gap round the cells inside the sheet.
    let padding: CGFloat
    let canvasWidth: CGFloat

    /// `glass` is the plain layout (not `withGuideSheet()`), `canvas` the full screen.
    init(glass: LiveTVGlassLayout, canvas: CGSize, rowCount: Int) {
        let px = glass.pixelScale
        canvasWidth = canvas.width
        padding = PrototypePlayingGlass.sheetPadding * px
        rulerHeight = glass.rulerHeight - glass.ui(PrototypePlayingGlass.rulerShortening)
        let top = glass.heroBlockBottom + glass.heroBottomGap + glass.ui(12)
        let guideTop = top + glass.ui(PrototypePlayingGlass.rulerInset)
        rowsTop = guideTop + rulerHeight + glass.rulerRowGap
        let per = glass.rowHeight + glass.rowGap
        let room = canvas.height - glass.ui(PrototypePlayingGlass.bottomMargin) - padding - rowsTop + glass.rowGap
        fitRows = max(1, min(rowCount, Int((room / per).rounded(.down))))
        let rowsBottom = rowsTop + CGFloat(fitRows) * per - glass.rowGap
        listHeight = PrototypeLayout.smallGap + CGFloat(fitRows) * per - glass.rowGap
        cornerRadius = glass.cellRadius + padding
        // From the plates' left edge less the gap, to the programmes' right edge plus it.
        let left = glass.leadingInset - padding
        let right = canvas.width - glass.trailingInset - glass.cellGap + padding
        frame = CGRect(x: left, y: top, width: right - left, height: rowsBottom + padding - top)
    }
}

private struct PrototypeGuideSheetPlanKey: EnvironmentKey {
    static let defaultValue: PrototypeGuideSheetPlan? = nil
}

extension EnvironmentValues {
    /// Set while the guide sits on the glass sheet: the ruler takes its shorter height and the row list stops at the sheet's last row.
    var prototypeGuideSheetPlan: PrototypeGuideSheetPlan? {
        get { self[PrototypeGuideSheetPlanKey.self] }
        set { self[PrototypeGuideSheetPlanKey.self] = newValue }
    }
}

#if os(tvOS)
extension View {
    /// The panels' system glass (`.regular` tinted black, FeaturePlayback `PanelGlassBackground`'s 12% rim) drawn behind this view.
    /// Reduce Transparency and earlier systems get the opaque panel fill.
    func prototypePanelGlass<S: InsettableShape>(in shape: S) -> some View {
        background { PrototypePanelGlass(shape: shape) }
    }
}

/// One shape of the panel glass. Not an overlay of the content: the effect has its own identity and never wraps focusable content.
struct PrototypePanelGlass<S: InsettableShape>: View {
    let shape: S
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    var body: some View {
        Group {
            if reduceTransparency || reducePanelGlass {
                shape.fill(Color(red: 20 / 255, green: 21 / 255, blue: 26 / 255))
            } else if #available(tvOS 26.0, *) {
                PlayerNativeGlassSurface(shape, glass: .regular.tint(.black.opacity(PrototypePlayingGlass.panelTintOpacity)))
            } else {
                shape.fill(.ultraThinMaterial).overlay { shape.fill(.black.opacity(PrototypePlayingGlass.panelTintOpacity)) }
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(PrototypePlayingGlass.rimOpacity), lineWidth: 1) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The sheet behind the guide: a screen-sized layer that places the one glass shape.
struct PrototypeGuideSheet: View {
    let plan: PrototypeGuideSheetPlan
    /// The origin of the screen's coordinates in this layer's (the layout's `bounds.origin`).
    let origin: CGPoint
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: plan.cornerRadius, style: .continuous)
        PrototypePanelGlass(shape: shape)
            .frame(width: plan.frame.width, height: plan.frame.height)
            .position(
                x: layoutDirection == .rightToLeft ? plan.canvasWidth - (origin.x + plan.frame.midX) : origin.x + plan.frame.midX,
                y: origin.y + plan.frame.midY)
    }
}

/// The fixed scrim over a playing picture (see `PrototypePlayingGlass.scrimTopHeight`).
struct PrototypePlayingScrim: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(PrototypePlayingGlass.scrimTopOpacity), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: PrototypePlayingGlass.scrimTopHeight(canvasHeight: geometry.size.height))
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, .black.opacity(PrototypePlayingGlass.scrimBottomOpacity)], startPoint: .top, endPoint: .bottom)
                    .frame(height: PrototypePlayingGlass.scrimBottomHeight(canvasHeight: geometry.size.height))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
