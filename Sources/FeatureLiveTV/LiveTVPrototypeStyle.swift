import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

enum PrototypeLayout {
    static let gap = PlozzTheme.Spacing.medium
    static let smallGap = PlozzTheme.Spacing.xSmall
    static let radius = PlozzTheme.Metrics.cornerRadius
    static let sectionGap = PlozzTheme.Spacing.large
    #if os(tvOS)
    /// Liquid Glass guide: programmes sit 12 pt apart.
    static var cellGap: CGFloat { LiveTVGlassLayout.active.cellGap }
    #else
    static let cellGap = PlozzTheme.Spacing.xSmall
    #endif
    // On touch the grid is one even mesh: rows, the logo column and programmes
    // all sit a programme-gap apart. The TV keeps wider row and column gaps.
    #if os(iOS)
    static let rowGap = cellGap
    static let columnGap = cellGap
    #elseif os(tvOS)
    static var rowGap: CGFloat { LiveTVGlassLayout.active.rowGap }
    /// The plate-to-programmes gap is the mockup's `cg`, the same as the gap between programmes.
    static var columnGap: CGFloat { LiveTVGlassLayout.active.cellGap }
    #else
    static let rowGap = PlozzTheme.Spacing.medium
    static let columnGap = PlozzTheme.Spacing.small
    #endif
    static let rowInset = PlozzTheme.Spacing.medium
    static let logoRadius = PlozzTheme.Metrics.Radius.content
    /// Concentric with the logo plate on a TV and a tablet. A phone's short
    /// rows (`compactRowHeight`) turned that radius into a full capsule, so
    /// its cells get the TV's proportion instead: squarer, like the tvOS grid.
    static var rowRadius: CGFloat {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 14 : logoRadius + rowInset
        #elseif os(tvOS)
        LiveTVGlassLayout.active.cellRadius
        #else
        logoRadius + rowInset
        #endif
    }
    static let programInset: CGFloat = 0
    /// The narrowest programme cell the tvOS guide draws; a shorter slot is absorbed by a neighbour.
    static let minimumCellWidth: CGFloat = 64
    static var programRadius: CGFloat { rowRadius - programInset }
    static let horizontalFade = PlozzTheme.Spacing.large
    static let verticalFade = PlozzTheme.Spacing.xLarge
    static let minimumGuideOpacity = 0.05
    static let guideInset = PlozzTheme.Metrics.Radius.inset
    static let stationArtworkInset = guideInset + 8
    static let guideTrailingInset = guideInset
    static var guideRadius: CGFloat { rowRadius + guideInset }
    static let controlRadius = PlozzTheme.Metrics.Radius.control
    static let controlInset = PlozzTheme.Spacing.xSmall
    static let controlGroupRadius = controlRadius + controlInset
    #if os(tvOS)
    static let inset = PlozzTheme.Spacing.xLarge
    static let stationSize: CGFloat = 96
    static let controlHeight: CGFloat = 56
    static var guideFontSize: CGFloat { LiveTVGlassLayout.active.cellFontSize }
    static let sectionFontSize: CGFloat = 22
    #else
    static let inset = PlozzTheme.Spacing.medium
    static let stationSize: CGFloat = 80
    static let controlHeight: CGFloat = 44
    static let guideFontSize: CGFloat = 16
    static let sectionFontSize: CGFloat = 14
    #endif
    #if os(tvOS)
    // The Liquid Glass guide: 82 pt rows and a 252 pt channel plate.
    static var rowHeight: CGFloat { LiveTVGlassLayout.active.rowHeight }
    static var stationColumnWidth: CGFloat { LiveTVGlassLayout.active.plateWidth }
    /// The plate's channel-number column, its leading inset, and the ruler label metrics.
    /// Fits five tabular digits at 25 pt after shrinking to 0.8 (about 61 pt), so a number never truncates.
    static var plateNumberWidth: CGFloat { LiveTVGlassLayout.active.plateNumberWidth }
    static var plateLeadingInset: CGFloat { LiveTVGlassLayout.active.plateLeadingInset }
    static var plateLogoTrailingInset: CGFloat { LiveTVGlassLayout.active.plateLogoTrailingInset }
    static let cellInset: CGFloat = 24
    static var rulerFontSize: CGFloat { LiveTVGlassLayout.active.rulerFontSize }
    static let rulerLabelInset: CGFloat = 6
    #else
    static let rowHeight = stationSize + rowInset * 2
    static let stationColumnWidth = stationSize * 1.75 + rowInset * 2
    /// Programme text inset inside a cell.
    static let cellInset = rowInset
    #endif
    static var guideShape: UnevenRoundedRectangle {
        #if os(tvOS)
        let bottom: CGFloat = 0
        let trailing: CGFloat = 0
        #else
        // Square along the bottom: the list fades out toward the tab bar
        // (see the guide's scroll fade) rather than being cut by a curve.
        let bottom: CGFloat = 0
        let trailing = guideRadius
        #endif
        return UnevenRoundedRectangle(
            topLeadingRadius: guideRadius, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: trailing
        )
    }

    /// Below this the guide is a phone's: a narrow channel column, shorter rows
    /// and one hour of programmes across the screen.
    static let compactWidth: CGFloat = 650

    // The guide's own vertical rhythm on touch is a step tighter than the
    // TV's: section labels and the time ruler read at arm's length, and every
    // point they give back is guide.
    #if os(iOS)
    static let sectionLabelHeight: CGFloat = 22
    static let rulerHeight: CGFloat = 28
    static let sectionLabelGap: CGFloat = 2
    static let toolbarGuideGap: CGFloat = 4
    static let rulerGap: CGFloat = 4
    #else
    static let sectionLabelHeight: CGFloat = 44
    static let sectionLabelGap: CGFloat = rowGap
    static let toolbarGuideGap: CGFloat = sectionGap
    #if os(tvOS)
    // The ruler is 52 pt tall (50 × 0.75 at 4K) and the first row starts `rulerRowGap` (14, 4K 10.5) under it: the
    // list's own 8 pt lead-in (`smallGap`) plus this 6 pt gap.
    static var rulerHeight: CGFloat { LiveTVGlassLayout.active.rulerHeight }
    static var rulerGap: CGFloat { LiveTVGlassLayout.active.rulerRowGap - smallGap }
    #else
    static let rulerHeight: CGFloat = 44
    static let rulerGap: CGFloat = gap
    #endif
    #endif
    static let compactStationWidth: CGFloat = 88
    static let compactRowHeight: CGFloat = 64

    static func isCompact(_ width: CGFloat) -> Bool { width < compactWidth }

    /// A phone keeps its short rows and narrow channel column on its side too:
    /// landscape has no more height than portrait has width, so full-size rows
    /// left room for barely one. The extra width goes to programme time
    /// instead (`viewportSeconds` stays width-based).
    static func usesCompactRows(_ width: CGFloat) -> Bool {
        #if os(iOS)
        isCompact(width) || UIDevice.current.userInterfaceIdiom == .phone
        #else
        isCompact(width)
        #endif
    }

    static func stationWidth(for width: CGFloat) -> CGFloat {
        usesCompactRows(width) ? compactStationWidth : stationColumnWidth
    }

    static func rowHeight(for width: CGFloat, scaledHeight: CGFloat) -> CGFloat {
        usesCompactRows(width) ? scaledHeight * compactRowHeight / rowHeight : scaledHeight
    }

    #if os(tvOS)
    static func guideSectionLabelHeight(fontSize: CGFloat) -> CGFloat {
        max(sectionLabelHeight, ceil(UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight))
    }
    #endif

    static func timelineWidth(for width: CGFloat) -> CGFloat {
        max(1, width - stationWidth(for: width) - columnGap)
    }

    /// How much programme time the visible timeline spans: two half-hour slots
    /// on a phone, four elsewhere.
    static func viewportSeconds(for width: CGFloat) -> TimeInterval {
        if isCompact(width) { return 3_600 }
        #if os(tvOS)
        return LiveTVGlassLayout.active.windowSeconds
        #else
        return 7_200
        #endif
    }

    /// The scrollable guide starts with six hours whatever the viewport, and
    /// grows by the same step as the viewer nears its end.
    static let timelineSpanSeconds: TimeInterval = 21_600
    /// A week, matching how far ahead the guide cache keeps listings.
    static let maximumTimelineSpanSeconds: TimeInterval = 7 * 86_400

    /// Horizontal distance for a stretch of programme time.
    static func timelineX(_ seconds: TimeInterval, for width: CGFloat) -> CGFloat {
        timelineWidth(for: width) * seconds / viewportSeconds(for: width)
    }

    static func timelineContentWidth(
        for width: CGFloat, span: TimeInterval = timelineSpanSeconds
    ) -> CGFloat {
        timelineX(span, for: width)
    }

    static func maximumTimelineOffset(
        for width: CGFloat, span: TimeInterval = timelineSpanSeconds
    ) -> CGFloat {
        max(0, timelineContentWidth(for: width, span: span) - timelineWidth(for: width))
    }

    static func hoursCoveringTimelineOffset(_ offset: CGFloat, for width: CGFloat) -> Int {
        let initialHours = Int(timelineSpanSeconds / 3_600)
        guard width > 0, offset.isFinite else { return initialHours }
        let visibleEnd = Double(max(0, offset) / timelineWidth(for: width)) * viewportSeconds(for: width)
            + viewportSeconds(for: width)
        let cappedEnd = min(maximumTimelineSpanSeconds, visibleEnd)
        guard cappedEnd.isFinite else { return Int(maximumTimelineSpanSeconds / 3_600) }
        return max(initialHours, Int(ceil(cappedEnd / timelineSpanSeconds)) * initialHours)
    }

    static func programHeight(in rowHeight: CGFloat) -> CGFloat {
        max(1, rowHeight - programInset * 2)
    }
}

extension LiveTVGuideSection {
    var title: LocalizedStringResource {
        switch self {
        case .recent: "Recently watched"
        case .favorites: "Favorites"
        case .channels: "Channels"
        }
    }
}

struct PrototypeScrollFade: Equatable {
    let leading: CGFloat
    let trailing: CGFloat

    init(before: CGFloat = 0, after: CGFloat = 0, distance: CGFloat = PrototypeLayout.verticalFade) {
        leading = min(1, max(0, before) / max(1, distance))
        trailing = min(1, max(0, after) / max(1, distance))
    }
}

extension LiveTVPrototypeSource {
    var title: Text {
        switch self {
        case .iptv: Text(verbatim: "IPTV")
        case .jellyfin: Text(verbatim: "Jellyfin")
        case .plex: Text(verbatim: "Plex")
        case .emby: Text(verbatim: "Emby")
        case .plozz: Text("Plozz channels")
        }
    }
}

extension LiveTVPrototypeScenario {
    var title: LocalizedStringResource {
        switch self {
        case .noGuide: "No guide"
        case .mixedGuide: "Partial guide"
        case .fullGuide: "Full guide"
        case .staleGuide: "Stale guide"
        case .failedGuide: "Guide unavailable"
        }
    }
}

extension LiveTVPrototypeSort {
    var title: LocalizedStringResource {
        switch self {
        case .channelNumber: "Channel number"
        case .name: "Name"
        }
    }
}

struct PrototypeStationMark: View {
    let channel: LiveTVPrototypeChannel
    /// Supplies the user's or TMDB's logo in place of the provider's, when the host provides a model.
    @Environment(LiveTVPrototypeModel.self) private var logoModel: LiveTVPrototypeModel?
    var size: CGFloat = PrototypeLayout.stationSize
    var plateSize: CGSize? = nil
    var cornerRadius: CGFloat = PrototypeLayout.logoRadius
    /// The guide's channel column draws the provider logo straight on the row.
    var usesBareLogo = false
    /// The 4K word beside the logo's top-right corner.
    var qualityBadge: String?
    /// The IPTV guide row: the identity, theme and glyph come from what the sync writer committed, read from memory only.
    var usesSyncedMarks = false
    @Environment(\.liveTVGuideStationMarks) private var stationMarks

    private var dimensions: CGSize {
        plateSize ?? CGSize(width: size * 1.75, height: size)
    }

    private var artworkInset: CGFloat {
        plateSize == nil ? 6 : PrototypeLayout.stationArtworkInset
    }

    var body: some View {
        let synced = usesSyncedMarks ? stationMarks.read(channel) : .unsynced
        if synced != .unsynced {
            syncedMark(synced)
        } else {
            modelMark
        }
    }

    /// No effective-logo lookup, placeholder screening, sports parsing, loader or disk: a miss draws the channel name.
    @ViewBuilder
    private func syncedMark(_ read: LiveTVGuideStationMarkRead) -> some View {
        switch read {
        case .glyph(let symbol):
            PrototypeSportsGlyph(symbol: symbol, size: dimensions, cornerRadius: cornerRadius, bare: usesBareLogo)
        case .logo(let identity, let regionLabel):
            ChannelLogoArtwork(
                name: channel.name, logoURL: identity.url, size: dimensions,
                cornerRadius: cornerRadius, artworkInset: artworkInset,
                style: usesBareLogo ? .bare(qualityBadge: qualityBadge) : .plate,
                logoNeedsDarkBackground: identity.providerRequestsDarkBackground,
                regionLabel: usesBareLogo && qualityBadge == nil ? regionLabel : nil,
                preparedArtworkCache: stationMarks.cache
            )
        case .name, .unsynced:
            Text(verbatim: channel.name)
                .font(.system(size: max(10, dimensions.height * 0.23), weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(width: dimensions.width, height: dimensions.height)
        }
    }

    @ViewBuilder
    private var modelMark: some View {
        switch logoModel?.sportsComposition(for: channel) {
        case .twoCrests?, .oneCrest?:
            // The crests are drawn by the channel panel's matchup card; the plate keeps the league badge.
            artwork
        case .broadcaster(_, let glyph)?:
            artwork.overlay(alignment: .bottomTrailing) {
                if let glyph { PrototypeSportsGlyphChip(symbol: glyph.symbolName, plateHeight: dimensions.height) }
            }
        case .leagueBadge?, .glyph?:
            if let symbol = logoModel?.sportsGlyphSymbol(for: channel) {
                PrototypeSportsGlyph(symbol: symbol, size: dimensions, cornerRadius: cornerRadius, bare: usesBareLogo)
            } else {
                artwork
            }
        case .text?, nil:
            artwork
        }
    }

    private var artwork: some View {
        ChannelLogoArtwork(
            name: channel.name,
            logoURL: logoModel.map { $0.effectiveLogoURL(for: channel) } ?? channel.displayedLogoURL, size: dimensions,
            cornerRadius: cornerRadius, artworkInset: artworkInset,
            plozzChannelID: channel.source == .plozz ? channel.id : nil,
            plozzChannelMood: channel.plozzChannelMood,
            style: usesBareLogo ? .bare(qualityBadge: qualityBadge) : .plate,
            logoNeedsDarkBackground: channel.logoNeedsDarkBackground,
            placeholderScreeningKey: logoModel?.placeholderScreeningKey(for: channel),
            regionLabel: usesBareLogo && qualityBadge == nil ? logoModel?.regionLabel(for: channel) : nil
        )
    }
}

/// A sport symbol drawn white and fitted, never stretched, for an event channel with no logo.
struct PrototypeSportsGlyph: View {
    let symbol: String
    let size: CGSize
    let cornerRadius: CGFloat
    let bare: Bool

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(min(size.width, size.height) * 0.18)
            .frame(width: size.width, height: size.height)
            .background {
                if !bare {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.white.opacity(0.12))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The sport glyph in the corner of a broadcaster's logo (composition "broadcaster logo + sport glyph").
struct PrototypeSportsGlyphChip: View {
    let symbol: String
    let plateHeight: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(plateHeight * 0.06)
            .frame(width: plateHeight * 0.36, height: plateHeight * 0.36)
            .background(Circle().fill(.black.opacity(0.55)))
            .accessibilityHidden(true)
    }
}

struct PrototypeFocusOutline: View {
    let cornerRadius: CGFloat
    var color: Color = .white
    var lineWidth: CGFloat = 3.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A dark inner keyline keeps the white focus edge visible on pale logos.
        shape.strokeBorder(.black.opacity(0.9), lineWidth: lineWidth * 2)
            .overlay { shape.strokeBorder(color, lineWidth: lineWidth) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PrototypeButtonStyle: ButtonStyle {
    var selected = false
    var padded = true
    var surface: PrototypeButtonSurface = .standard
    var focusChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        PrototypeButtonBody(
            configuration: configuration, selected: selected, padded: padded,
            surface: surface, focusChanged: focusChanged
        )
    }
}

enum PrototypeButtonSurface: Equatable {
    case standard, guide, station, program, control
}

private struct PrototypeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let padded: Bool
    let surface: PrototypeButtonSurface
    let focusChanged: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var solidFocus: Bool {
        focused && surface != .station
            && ((surface != .guide && surface != .program) || reduceTransparency || contrast == .increased)
    }

    private var cornerRadius: CGFloat {
        switch surface {
        case .standard: PrototypeLayout.radius
        case .guide, .station: PrototypeLayout.rowRadius
        case .program: PrototypeLayout.programRadius
        case .control: PrototypeLayout.controlRadius
        }
    }

    private var fill: Color {
        if solidFocus { return palette.accent }
        if focused || selected { return palette.fill }
        switch surface {
        case .standard: return palette.cardSurface
        case .guide, .station: return .clear
        case .program:
            return palette.fillSubtle.opacity(reduceTransparency || contrast == .increased ? 1 : 0.45)
        case .control: return .clear
        }
    }

    /// A tapped guide cell wears the focus outline, since touch has no focus
    /// of its own to show which programme the info bar is describing.
    private var showsTouchSelection: Bool {
        #if os(iOS)
        selected && (surface == .program || surface == .guide)
        #else
        false
        #endif
    }

    var body: some View {
        configuration.label
            .foregroundStyle(solidFocus ? palette.onAccent : palette.primaryText)
            .padding(padded ? PrototypeLayout.gap : 0)
            .background(
                fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if (focused || showsTouchSelection) && !solidFocus {
                    PrototypeFocusOutline(
                        cornerRadius: cornerRadius,
                        color: surface == .station ? .white : palette.primaryText,
                        lineWidth: contrast == .increased ? 4 : 3.5
                    )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(selected && !focused ? palette.accent.opacity(0.35) : .clear, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            // Directional entry gates remove candidates without dimming the rail.
            .transaction { $0.animation = nil }
            .onChange(of: focused, initial: true) { _, value in
                #if os(iOS)
                // Touch has no focus to lose: a tapped selection stands until
                // another tap replaces it, even as its row scrolls away and back.
                if value { focusChanged?(value) }
                #else
                focusChanged?(value)
                #endif
            }
    }
}

struct PrototypeGuideSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    /// The tvOS guide sits flat on the app background; only the accessibility
    /// fallback below gets a surface.
    private static var isFlat: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Color.clear.plozzSurface(.raised, cornerRadius: 0)
                    .clipShape(PrototypeLayout.guideShape)
            } else if gradientEnabled || Self.isFlat {
                Color.clear
            } else {
                PrototypeLayout.guideShape
                    .fill(LinearGradient(
                        stops: [
                            .init(color: palette.backgroundBase.opacity(PrototypeLayout.minimumGuideOpacity), location: 0),
                            .init(color: palette.backgroundBase.opacity(0.12), location: 0.2),
                            .init(color: palette.backgroundBase.opacity(0.4), location: 0.55),
                            .init(color: palette.backgroundBase.opacity(0.75), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One glass underlay, not a glass layer per programme or a focus-dependent style.
struct PrototypeControlSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzReducePanelGlass) private var reduceGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrototypeLayout.controlGroupRadius, style: .continuous)
        Group {
            if reduceTransparency {
                Color.clear.plozzSurface(.raised, cornerRadius: PrototypeLayout.controlGroupRadius)
            } else if reduceGlass {
                Color.clear.plozzFrostedBackground(shape).plozzFrostedBorder(shape)
            } else {
                Color.clear.plozzGlassPanel(cornerRadius: PrototypeLayout.controlGroupRadius)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChangeChannelLogoKey: EnvironmentKey {
    static let defaultValue: ((LiveTVPrototypeChannel) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the Change Logo sheet for a channel; `nil` where the host offers none.
    var changeChannelLogo: ((LiveTVPrototypeChannel) -> Void)? {
        get { self[ChangeChannelLogoKey.self] }
        set { self[ChangeChannelLogoKey.self] = newValue }
    }
}

enum PrototypeSheet: Identifiable {
    case filters, sources, guideTime, addSource, addPlaylist, serverSetup, multiviewFavorites, organization
    case program(LiveTVPrototypeProgram)
    case diagnostics(PlaybackDiagnosticReport)
    case changeLogo(LiveTVPrototypeChannel)

    var id: String {
        switch self {
        case .filters: "filters"
        case .organization: "organization"
        case .sources: "sources"
        case .addSource: "add-source"
        case .addPlaylist: "add-playlist"
        case .serverSetup: "server-setup"
        case .guideTime: "guide-time"
        case .multiviewFavorites: "multiview-favorites"
        case .program(let program): program.id
        case .diagnostics: "diagnostics"
        case .changeLogo(let channel): "change-logo-\(channel.id)"
        }
    }
}

