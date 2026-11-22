import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

/// How a guide cell reads against the clock. Drives the cell's fill and ink.
enum PrototypeGuideTone: Equatable {
    case upcoming, onNow, ended, noData

    init(program: LiveTVPrototypeProgram?, now: Date) {
        guard let program else {
            self = .noData
            return
        }
        if program.end <= now { self = .ended }
        else if program.start <= now { self = .onNow }
        else { self = .upcoming }
    }

    /// White opacity of the resting cell fill: `ThemePalette.dark`'s fill (11%) and fillSubtle (6%).
    var fillOpacity: Double {
        switch self {
        case .upcoming, .onNow: PrototypePlayingGlass.cellFillOpacity
        case .ended, .noData: PrototypePlayingGlass.quietCellFillOpacity
        }
    }

    /// White opacity of the title at rest; focus turns it black.
    var inkOpacity: Double {
        switch self {
        case .upcoming: 1
        case .onNow: 0.8
        case .ended, .noData: PrototypePlayingGlass.quietInkOpacity
        }
    }
}

/// Pure geometry for a guide cell and its ruler, shared by the views and tests.
enum PrototypeGuideCellMetrics {
    /// A cell narrower than this shows no title.
    static let minimumTitleWidth: CGFloat = 110
    static func showsTitle(cellWidth: CGFloat) -> Bool {
        cellWidth >= minimumTitleWidth
    }

    /// Width of the progress track drawn inside a focused cell: `elapsed` points from the cell's leading edge, so its right edge is
    /// where "now" is. The cell does not scale on focus.
    static func elapsedFillWidth(elapsed: CGFloat, cellWidth: CGFloat) -> CGFloat {
        guard elapsed > 0, cellWidth > 0 else { return 0 }
        return min(elapsed, cellWidth)
    }

    /// How far to move a cell's title in from its leading edge so it starts at the visible timeline's leading edge
    /// (mockup: a cell is drawn from `max(start, windowStart)`). `offset` is the scrolled timeline offset and
    /// `cellX` the cell's position on the timeline, both leading-relative. The title keeps at least
    /// `minimumTitleWidth` of the cell, so near the cell's end it rides out with the cell rather than vanishing.
    static func titleLead(offset: CGFloat, cellX: CGFloat, cellWidth: CGFloat) -> CGFloat {
        guard offset.isFinite, cellX.isFinite, cellWidth.isFinite else { return 0 }
        return min(max(0, offset - cellX), max(0, cellWidth - minimumTitleWidth))
    }

    /// Whether the programme began before the cell's visible start (the window start clips it), so the cell
    /// is drawn flat on its leading side to show it continues earlier.
    static func continuesBeforeWindow(programStart: Date, slotStart: Date) -> Bool {
        programStart < slotStart
    }

    /// The cell's corners: all rounded, or square on the leading side when the window clips the programme.
    static func cornerRadii(radius: CGFloat, clipsLeading: Bool) -> RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: clipsLeading ? 0 : radius, bottomLeading: clipsLeading ? 0 : radius,
            bottomTrailing: radius, topTrailing: radius)
    }
}

/// The playing indicator: three bars before the title of the playing channel's now-cell
/// (mockup `.eq`). Sizes are in em of the cell's font.
enum PrototypeGuideEqMetrics {
    static let barWidth: CGFloat = 0.17
    static let barGap: CGFloat = 0.13
    static let height: CGFloat = 0.78
    static let cornerRadius: CGFloat = 0.1
    /// The gap between the bars and the title.
    static let titleGap: CGFloat = 0.45
    static let period: TimeInterval = 1.1
    static let lowScale: CGFloat = 0.4
    /// Start offsets of the three bars, in seconds (the mockup's animation delays).
    static let delays: [TimeInterval] = [0, -0.35, -0.7]
    /// The bars at rest (reduced motion): the mockup's inline scales.
    static let restingScales: [CGFloat] = [0.55, 1, 0.4]

    /// The indicator is drawn on the playing channel's current programme only, focused or not.
    static func isShown(channelIsPlaying: Bool, phase: LiveTVProgramPhase) -> Bool {
        channelIsPlaying && phase == .onNow
    }

    /// One bar's height scale at `time`: 0.4 → 1 → 0.4 each period, eased at both ends.
    static func scale(bar: Int, at time: TimeInterval) -> CGFloat {
        let progress = ((time - delays[bar]) / period).truncatingRemainder(dividingBy: 1)
        let wave = 0.5 - 0.5 * cos(2 * .pi * progress)
        return lowScale + (1 - lowScale) * CGFloat(wave)
    }

    static func width(fontSize: CGFloat) -> CGFloat { fontSize * (barWidth * 3 + barGap * 2) }
}

#if os(tvOS)
/// Programme cell, drawn as Plozz's player chrome draws over video (mockup `.screen.pz`): a flat white fill (11%, finished or empty 6%) at
/// rest; focus is a solid white card with black ink and a black 10% played track, switched on instantly (no lift, no glow, no scale).
/// The title colour comes from `PrototypeGuideCellTitle`.
struct PrototypeGuideCellStyle: ButtonStyle {
    let tone: PrototypeGuideTone
    let cellWidth: CGFloat
    /// Points from the cell's leading edge to "now" (≤ 0 when not on now).
    let elapsedWidth: CGFloat
    /// The programme began before the window: the leading side is flat.
    var clipsLeading = false
    var focusChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        PrototypeGuideCellBody(
            configuration: configuration, tone: tone, cellWidth: cellWidth,
            elapsedWidth: elapsedWidth, clipsLeading: clipsLeading, focusChanged: focusChanged)
    }
}

private struct PrototypeGuideCellBody: View {
    let configuration: ButtonStyle.Configuration
    let tone: PrototypeGuideTone
    let cellWidth: CGFloat
    let elapsedWidth: CGFloat
    let clipsLeading: Bool
    let focusChanged: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused

    var body: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: PrototypeGuideCellMetrics.cornerRadii(
                radius: PrototypeLayout.programRadius, clipsLeading: clipsLeading),
            style: .continuous)
        configuration.label
            .background {
                ZStack {
                    shape.fill(focused ? Color.white : Color.white.opacity(tone.fillOpacity))
                    if focused, tone == .onNow {
                        Rectangle()
                            .fill(.black.opacity(PrototypePlayingGlass.focusedTrackOpacity))
                            .frame(width: PrototypeGuideCellMetrics.elapsedFillWidth(elapsed: elapsedWidth, cellWidth: cellWidth))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipShape(shape)
                    }
                }
            }
            .zIndex(focused ? 1 : 0)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .transaction { $0.animation = nil }
            .onChange(of: focused, initial: true) { _, value in focusChanged?(value) }
    }
}

/// Channel plate: transparent at rest, a white 20% fill when focused (mockup `.plate.lg.f` under Plozz-like); it never scales.
struct PrototypeGuidePlateStyle: ButtonStyle {
    var focusChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        PrototypeGuidePlateBody(configuration: configuration, focusChanged: focusChanged)
    }
}

private struct PrototypeGuidePlateBody: View {
    let configuration: ButtonStyle.Configuration
    let focusChanged: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrototypeLayout.rowRadius, style: .continuous)
        configuration.label
            .background {
                if focused { shape.fill(.white.opacity(PrototypePlayingGlass.focusedPlateFillOpacity)) }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .transaction { $0.animation = nil }
            .onChange(of: focused, initial: true) { _, value in focusChanged?(value) }
    }
}

/// A programme cell's title: 27 pt, medium (semibold when focused), toned by the clock.
struct PrototypeGuideCellTitle: View {
    let program: LiveTVPrototypeProgram
    let now: Date
    let cellWidth: CGFloat
    /// This channel is the one playing: its current programme carries the playing indicator.
    var channelIsPlaying = false
    @Environment(\.isFocused) private var focused
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize

    /// Black on the focused white card (a finished programme's at 45%); otherwise the tone's white.
    static func ink(tone: PrototypeGuideTone, focused: Bool) -> Color {
        guard focused else { return Color.white.opacity(tone.inkOpacity) }
        return Color.black.opacity(tone == .ended ? PrototypePlayingGlass.focusedEndedInkOpacity : 1)
    }

    var body: some View {
        let tone = PrototypeGuideTone(program: program, now: now)
        Group {
            if PrototypeGuideCellMetrics.showsTitle(cellWidth: cellWidth) {
                let ink = Self.ink(tone: tone, focused: focused)
                HStack(spacing: fontSize * PrototypeGuideEqMetrics.titleGap) {
                    if PrototypeGuideEqMetrics.isShown(
                        channelIsPlaying: channelIsPlaying, phase: LiveTVProgramPhase(program: program, now: now)) {
                        PrototypeGuideEqBars(fontSize: fontSize)
                            .foregroundStyle(ink)
                    }
                    Text(program.title)
                        .font(.system(size: fontSize, weight: focused ? .semibold : .medium))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    if program.isContinuousLoop {
                        Text(verbatim: LiveTVPrototypeProgram.loopTag)
                            .font(.system(size: fontSize * 0.8, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.7))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            } else {
                Color.clear
            }
        }
        #if DEBUG
        .observesGuideProgramme(program)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(program.title))
        .accessibilityValue(
            program.isContinuousLoop
                ? Text(verbatim: LiveTVPrototypeProgram.loopTag)
                : Text("\(program.start, format: .dateTime.hour().minute()) to \(program.end, format: .dateTime.hour().minute())")
        )
    }
}

/// Three bars that dance while the channel plays (static under Reduce Motion).
struct PrototypeGuideEqBars: View {
    let fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                bars { PrototypeGuideEqMetrics.restingScales[$0] }
            } else {
                TimelineView(.animation) { context in
                    bars { PrototypeGuideEqMetrics.scale(bar: $0, at: context.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .frame(height: fontSize * PrototypeGuideEqMetrics.height)
        .accessibilityHidden(true)
    }

    private func bars(scale: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: fontSize * PrototypeGuideEqMetrics.barGap) {
            ForEach(0..<3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: fontSize * PrototypeGuideEqMetrics.cornerRadius)
                    .frame(width: fontSize * PrototypeGuideEqMetrics.barWidth)
                    .frame(height: fontSize * PrototypeGuideEqMetrics.height * scale(bar))
            }
        }
        .frame(height: fontSize * PrototypeGuideEqMetrics.height, alignment: .bottom)
    }
}

/// The channel's name with the 4K word hung outside the text's top-right corner, as in the mockup: the text is at most `maxWidth`
/// wide and keeps its own size, so the word never covers a glyph. The first subview is the text, the optional second the badge.
struct PrototypeNameWithBadge: Layout {
    let maxWidth: CGFloat
    /// How far the word rises above the text's top edge.
    let badgeRise: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: min(maxWidth, proposal.width ?? maxWidth), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        text.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        guard subviews.count > 1 else { return }
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY - badgeRise), anchor: .topLeading, proposal: .unspecified)
    }
}

/// The channel plate: the number when numbers are shown, then the logo (or the name when there is none).
struct PrototypeGuidePlateContent: View {
    let channel: LiveTVPrototypeChannel
    let size: CGSize
    @Environment(\.isFocused) private var focused
    /// The model the logo is read from, so the plate redraws when a match or a measured guide icon arrives.
    @Environment(LiveTVPrototypeModel.self) private var logoModel: LiveTVPrototypeModel?
    @Environment(\.liveTVGuideStationMarks) private var stationMarks

    private var scale: CGFloat { size.height / 82 }

    /// The most the number may shrink to fit its column.
    static let numberMinimumScale: CGFloat = 0.8

    /// The widest channel number's digit count in the lineup (at least this channel's own).
    private var numberDigits: Int {
        max(String(channel.number).count, logoModel?.widestChannelNumberDigits ?? 0)
    }

    /// Whether the row draws its channel number: the profile's "Show Channel Numbers" setting, off by default.
    private var showsNumber: Bool { logoModel?.showsChannelNumbers ?? false }

    /// The number column: the layout's width, widened when the lineup's widest number would not fit at the smallest scale,
    /// and absent when numbers are hidden. Every row of a lineup gets the same width, so the logos stay aligned.
    private var numberWidth: CGFloat {
        Self.numberColumn(
            showsNumber: showsNumber, digits: numberDigits, scale: scale,
            layoutWidth: PrototypeLayout.plateNumberWidth * scale)
    }

    static func numberColumn(showsNumber: Bool, digits: Int, scale: CGFloat, layoutWidth: CGFloat) -> CGFloat {
        showsNumber ? numberColumnWidth(digits: digits, scale: scale, layoutWidth: layoutWidth) : 0
    }

    static func numberColumnWidth(digits: Int, scale: CGFloat, layoutWidth: CGFloat) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 25 * scale, weight: .medium)
        let digit = ("8" as NSString).size(withAttributes: [.font: font]).width
        return max(layoutWidth, ceil(digit * CGFloat(max(digits, 1)) * numberMinimumScale) + 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsNumber {
                Text(channel.number, format: .number.grouping(.never))
                    .font(.system(size: 25 * scale, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(focused ? 0.62 : 0.40))
                    .lineLimit(1)
                    .minimumScaleFactor(Self.numberMinimumScale)
                    .offset(y: -0.7 * scale)
                    .frame(width: numberWidth, alignment: .leading)
            }
            logoZone
        }
        .padding(.leading, PrototypeLayout.plateLeadingInset * scale)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The channel's name as the mark, per the mockup's `.lfb`: 19 pt semibold, 1.14 line height, centred, two lines,
    /// 88% white. The text gives up the 4K word's room (2.5 badge font sizes); the word hangs at its top-right corner.
    /// A long word shrinks (down to 70%) rather than breaking mid-word; "/" offers a break point.
    private func nameMark(width: CGFloat) -> some View {
        let badge = channel.guideQualityBadgeText()
        let badgeFont = Self.badgeFontSize * scale
        return PrototypeNameWithBadge(maxWidth: Self.nameMaxWidth(zoneWidth: width, hasBadge: badge != nil, badgeRoom: (badgeFont * 2.5).rounded()),
                                      badgeRise: badgeFont * 1.34 * 0.22) {
            Text(Self.breakableName(channel.name))
                .font(.system(size: 19 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .lineSpacing(-1 * scale)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let badge { QualityBadge(text: badge, fontSize: badgeFont) }
        }
    }

    /// Whether the plate draws the channel's name: the channel has no displayable logo (a provider logo never is).
    /// `logoURL` is what the plate would draw (`LiveTVPrototypeModel.effectiveLogoURL(for:)`).
    static func drawsNameAsMark(_ channel: LiveTVPrototypeChannel, logoURL: URL?) -> Bool {
        logoURL == nil && channel.source != .plozz
    }

    /// The 4K word's font size in the 1080p reference cell.
    static let badgeFontSize: CGFloat = 18.5

    /// The widest the name may be: the zone, less a few points either side and the 4K word's room when it is drawn.
    static func nameMaxWidth(zoneWidth: CGFloat, hasBadge: Bool, badgeRoom: CGFloat) -> CGFloat {
        max(1, zoneWidth - 8 - (hasBadge ? badgeRoom : 0))
    }

    /// The name with a zero-width break opportunity after each "/", so "A/B" can wrap there instead of mid-word.
    static func breakableName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "/\u{200B}")
    }

    /// The width of the reference cell the logo draws in: the 252 pt cell, narrowed only when the zone is narrower than its
    /// 164 pt logo box (channel numbers shown in the narrowed column), so a wide logo never runs into the number.
    static func logoReferenceWidth(zoneWidth: CGFloat, scale: CGFloat) -> CGFloat {
        // CoreUI's `ChannelLogoExtraction.GuideGeometry` reference cell (252 × 82) and logo box (164 × 52).
        let reference = 252 * scale
        let box = 164 * scale
        return reference * min(1, zoneWidth / box)
    }

    /// The remaining width, less the trailing inset; the logo is centred in it.
    private var logoZone: some View {
        let zoneWidth = max(
            1, size.width - (PrototypeLayout.plateLeadingInset + PrototypeLayout.plateLogoTrailingInset) * scale - numberWidth)
        let synced = stationMarks.read(channel)
        return Group {
            if synced == .name
                || (synced == .unsynced
                    && Self.drawsNameAsMark(channel, logoURL: logoModel?.effectiveLogoURL(for: channel) ?? channel.displayedLogoURL)) {
                nameMark(width: zoneWidth)
            } else {
                // The logo draws itself in a 252 × 82 reference cell; it is
                // centred in the zone, which sits left of that cell's centre.
                PrototypeStationMark(
                    channel: channel,
                    plateSize: CGSize(width: Self.logoReferenceWidth(zoneWidth: zoneWidth, scale: scale), height: size.height),
                    cornerRadius: PrototypeLayout.rowRadius, usesBareLogo: true,
                    qualityBadge: channel.guideQualityBadgeText(), usesSyncedMarks: true)
                    .fixedSize()
            }
        }
        .frame(width: zoneWidth, height: size.height)
        #if DEBUG
        .observesGuidePlate(channel)
        #endif
    }
}
#endif

extension View {
    /// Programme slots clip to the row, except on tvOS where a focused cell grows past it.
    @ViewBuilder
    func programSlotClip() -> some View {
        #if os(tvOS)
        self
        #else
        clipped()
        #endif
    }

    /// The standard guide context menu, unless the presentation owner replaces it.
    @ViewBuilder
    func optionalContextMenu<Menu: View>(
        isAttached: Bool, @ViewBuilder content menu: () -> Menu
    ) -> some View {
        if isAttached { contextMenu { menu() } } else { self }
    }
}

#if os(tvOS)
extension View {
    /// Reports a held Select with the view's screen frame. `consumed` is set so
    /// the release that follows isn't also taken as a tap; it clears on its own
    /// if no release reaches the button.
    @ViewBuilder
    func holdsForPresentation(_ hold: ((CGRect) -> Void)?, consumed: Binding<Bool>) -> some View {
        if let hold {
            modifier(PrototypeGuideHold(hold: hold, consumed: consumed))
        } else {
            self
        }
    }
}

private struct PrototypeGuideHold: ViewModifier {
    /// Held Select, in seconds.
    static let duration = 0.45
    private static let consumedLifetime: Duration = .seconds(1)
    private final class FrameBox { var frame = CGRect.zero }

    let hold: (CGRect) -> Void
    @Binding var consumed: Bool
    @State private var box = FrameBox()

    func body(content: Content) -> some View {
        content
            // Written into a plain box: scrolling must not re-render every cell.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [box] in box.frame = $0 }
            .simultaneousGesture(LongPressGesture(minimumDuration: Self.duration).onEnded { _ in
                consumed = true
                hold(box.frame)
                Task { @MainActor in
                    try? await Task.sleep(for: Self.consumedLifetime)
                    consumed = false
                }
            })
    }
}
#endif
