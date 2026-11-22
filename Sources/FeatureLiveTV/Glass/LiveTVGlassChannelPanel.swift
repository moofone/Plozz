#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

/// What the right channel panel shows. Counts, times and "left" text arrive preformatted.
struct LiveTVGlassChannelPanelContent: Equatable {
    struct Now: Equatable {
        var title: String
        /// "42 min left" or "Starts 6:30".
        var meta: String
        /// 0…1 while the programme is on now; nil for a later one (no bar).
        var progress: Double?
        var description: String?
    }

    var channelName: String
    /// Set for a two-team league event: the matchup card replaces the logo block.
    var matchup: LiveTVGlassMatchup?
    var logoURL: URL?
    var logoNeedsDarkBackground = false
    /// Brand key to screen a guide icon under; nil for a user or automatic logo.
    var placeholderScreeningKey: String?
    /// The 4K word for the logo's corner, from the provider's name tags.
    var qualityBadge: String?
    /// An event slot: no logo, and the line under the header is the service it streams on (`channelName`), never the event's own name.
    var isEvent = false
    /// "102" shown before the name; empty for an event slot, which has no channel number.
    var numberText: String

    /// The panel always shows the channel's number, whatever the "Show Channel Numbers" setting says (only an event slot has none).
    static func numberText(forChannelNumber number: Int, isEvent: Bool) -> String {
        isEvent ? "" : String(number)
    }

    /// The channel's playlist, named as in Sources, once there is more than one provider to tell apart (one label then reads as "only
    /// on this one"); nothing for a single provider or a channel that no playlist supplies.
    static func sourceNames(playlistSourceID: String?, playlists: [(id: String, name: String)]) -> [String] {
        guard playlists.count > 1, let playlistSourceID,
              let name = playlists.first(where: { $0.id == playlistSourceID })?.name, !name.isEmpty else { return [] }
        return [name]
    }
    /// The names (as given in Sources) of the providers that carry the channel, drawn as labels after its name; empty with one provider.
    var sourceNames: [String] = []
    var now: Now?
    var isFavorite: Bool
    /// "Watch", or "Resume" when this channel is playing.
    var watchTitle: String
    /// False for an idle event slot, which has nothing to play.
    var canWatch = true
    var upcoming: [LiveTVGlassUpcomingProgram]
}

/// The right channel panel: header, Now, actions, Upcoming.
struct LiveTVGlassChannelPanel: View {
    enum Control: Hashable {
        case watch, multiview, favorite
        case upcoming(String)
    }

    let content: LiveTVGlassChannelPanelContent
    let canvasHeight: CGFloat
    let onWatch: () -> Void
    let onMultiview: () -> Void
    let onToggleFavorite: () -> Void
    /// Select on an upcoming row (nil rows are still focusable for navigation).
    var onSelectUpcoming: ((String) -> Void)?
    let onClose: () -> Void

    @FocusState private var focused: Control?
    @Environment(\.liveTVGlassLayout) private var glass

    private var contentWidth: CGFloat { LiveTVGlassChannelPanelLayout.contentWidth(glass) }

    var body: some View {
        let room = LiveTVGlassChannelPanelLayout.upcomingRoom(
            canvasHeight: canvasHeight,
            content: LiveTVGlassChannelPanelLayout.content(
                title: content.now?.title, description: content.now?.description, hasMatchupCard: content.matchup != nil,
                hasProviders: !content.sourceNames.isEmpty, hasTags: false,
                isEvent: content.isEvent, hasEventService: !content.channelName.isEmpty, layout: glass),
            layout: glass)
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(content.upcoming, room: room)
        LiveTVGlassUnitScale(scale: glass.uiScale) { panel(rows: rows) }
    }

    private func panel(rows: [LiveTVGlassUpcomingRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            nowBlock
            actions
            if !rows.isEmpty { upcoming(rows) }
        }
        .padding(LiveTVGlassChannelPanelLayout.padding)
        .frame(width: LiveTVGlassChannelPanelLayout.unitWidth(glass), alignment: .topLeading)
        .liveTVGlassSurface(cornerRadius: LiveTVGlassChannelPanelLayout.cornerRadius)
        .focusSection()
        .defaultFocus($focused, .watch)
        .onExitCommand { TVBackConsumption.closePanel("channelPanel") { onClose() } }
        .onMoveCommand { direction in
            guard direction == .left else { return }
            switch focused {
            case .watch, .upcoming: onClose()
            default: break
            }
        }
        .onAppear { focused = .watch }
    }

    /// The mockup's header: the logo (left-aligned, 4K at its corner) with `number  name` under it; a channel with no logo shows its
    /// name in bold over its number; an event shows only the service it streams on. Then the sources, when more than one carry it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let matchup = content.matchup {
                LiveTVGlassMatchupCard(matchup: matchup)
                nameLine.padding(.top, 16)
            } else if content.isEvent {
                if !content.channelName.isEmpty {
                    Text(content.channelName)
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-0.36)
                        .lineLimit(1)
                        .frame(maxWidth: contentWidth - 60, alignment: .leading)
                }
            } else if content.logoURL != nil {
                ChannelLogoArtwork(
                    name: content.channelName, logoURL: content.logoURL,
                    size: CGSize(width: (contentWidth * 0.72).rounded(), height: 124), cornerRadius: 0, artworkInset: 0,
                    style: .panelLeading(qualityBadge: content.qualityBadge),
                    logoNeedsDarkBackground: content.logoNeedsDarkBackground,
                    placeholderScreeningKey: content.placeholderScreeningKey
                )
                nameLine.padding(.top, 16)
            } else {
                Text(content.channelName)
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.36)
                    .lineLimit(1)
                    .frame(maxWidth: contentWidth - 60, alignment: .leading)
                if !content.numberText.isEmpty {
                    Text(content.numberText)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                        .padding(.top, 12)
                }
            }
            if !content.sourceNames.isEmpty, !namesFollowNumber {
                LiveTVGlassSourceLabels(names: content.sourceNames).padding(.top, 12)
            }
        }
        .padding(.bottom, content.isEvent && content.channelName.isEmpty ? 0 : 44)
    }

    /// The header shows `number  name` (a matchup card or a logo above it); the source labels follow the name when they fit, else go under it.
    private var namesFollowNumber: Bool { content.matchup != nil || (!content.isEvent && content.logoURL != nil) }

    private var nameLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { numberAndName; LiveTVGlassSourceLabels(names: content.sourceNames) }
            VStack(alignment: .leading, spacing: 12) { numberAndName; LiveTVGlassSourceLabels(names: content.sourceNames) }
        }
    }

    private var numberAndName: some View {
        HStack(spacing: 19) {
            if !content.numberText.isEmpty {
                Text(content.numberText).monospacedDigit().foregroundStyle(.white.opacity(0.46))
            }
            Text(content.channelName).foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 27, weight: .semibold))
        .lineLimit(1)
    }

    @ViewBuilder
    private var nowBlock: some View {
        if let now = content.now {
            VStack(alignment: .leading, spacing: 0) {
                Text(now.title)
                    .font(.system(size: 52, weight: .bold))
                    .tracking(-0.78)
                    .lineLimit(LiveTVGlassChannelPanelLayout.titleLineLimit(isEvent: content.isEvent))
                    .lineSpacing(-4.8)
                    .fixedSize(horizontal: false, vertical: true)
                    // The mockup's line-height 1.1 (57.2 a line); the font's own is 62, and the spacing above only trims between lines.
                    .padding(.vertical, -2.4)
                HStack(spacing: 16) {
                    if let progress = now.progress {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 140)
                    }
                    Text(now.meta).monospacedDigit()
                }
                .font(.system(size: 29))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 16)
                if let description = now.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 29))
                        .lineSpacing(4.5)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(3)
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(String(localized: "No guide information"))
                .font(.system(size: 29))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button(action: onWatch) {
                LiveTVGlassActionLabel(kind: .pill(content.watchTitle))
            }
            .disabled(!content.canWatch)
            .focused($focused, equals: .watch)
            Button(action: onMultiview) {
                LiveTVGlassActionLabel(kind: .icon(.multiview))
            }
            .focused($focused, equals: .multiview)
            .accessibilityLabel(String(localized: "Add to Multiview"))
            Button(action: onToggleFavorite) {
                LiveTVGlassActionLabel(kind: .icon(.star, filled: content.isFavorite))
            }
            .focused($focused, equals: .favorite)
            .accessibilityLabel(content.isFavorite
                ? String(localized: "Remove from Favorites")
                : String(localized: "Add to Favorites"))
        }
        .buttonStyle(LiveTVGlassButtonStyle())
        .focusEffectDisabled()
        .padding(.top, 40)
    }

    private func upcoming(_ rows: [LiveTVGlassUpcomingRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(String(localized: "Upcoming"), height: LiveTVGlassChannelPanelLayout.labelHeight)
            ForEach(rows) { row in
                switch row {
                case .separator:
                    sectionLabel(String(localized: "Tomorrow"), height: LiveTVGlassChannelPanelLayout.separatorHeight)
                case let .program(program):
                    Button { onSelectUpcoming?(program.id) } label: {
                        LiveTVGlassUpcomingLabel(program: program)
                    }
                    .buttonStyle(LiveTVGlassButtonStyle())
                    .focusEffectDisabled()
                    .focused($focused, equals: .upcoming(program.id))
                    .frame(height: LiveTVGlassChannelPanelLayout.upcomingRowHeight)
                }
            }
        }
        .padding(.top, LiveTVGlassChannelPanelLayout.sectionSpacing)
    }

    private func sectionLabel(_ text: String, height: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(.white.opacity(0.46))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
            .padding(.bottom, 6)
    }
}

/// The mockup's `.abtn`: Watch is a white pill with dark ink at rest and focused; the round buttons are dark glass at rest and turn white
/// when focused. Glyphs are the mockup's own, at its 1.7 stroke.
private struct LiveTVGlassActionLabel: View {
    enum Kind { case pill(String), icon(LiveTVGlassQuickMenuGlyph, filled: Bool = false) }
    let kind: Kind
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        content
            .frame(height: 60)
            .background { background }
            .scaleEffect(isFocused ? 1.07 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, x: 0, y: 14)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .pill:
            Capsule().fill(Color.white)
        case .icon:
            if isFocused {
                Capsule().fill(Color.white)
            } else {
                Capsule().fill(Color.black.opacity(0.3))
                    .overlay { Capsule().fill(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)) }
                    .overlay { Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case let .pill(title):
            HStack(spacing: 12) {
                glyph(.play, size: 27.6, filled: true)
                Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.12)
            }
            .foregroundStyle(Color.black)
            .padding(.leading, 24)
            .padding(.trailing, 30)
        case let .icon(glyph, filled):
            self.glyph(glyph, size: 26, filled: filled)
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 60)
        }
    }

    private func glyph(_ glyph: LiveTVGlassQuickMenuGlyph, size: CGFloat, filled: Bool) -> some View {
        LiveTVGlassMockupShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: size * (glyph == .play ? 2.2 : 1.7) / 24, lineCap: .round, lineJoin: .round))
            .background { if filled || glyph == .play { LiveTVGlassMockupShape(glyph: glyph).fill() } }
            .frame(width: size, height: size)
    }
}

/// The providers that carry the channel (mockup `tag("m", …, 20)`): quiet filled labels, 1.5 em tall, bold, one line.
struct LiveTVGlassSourceLabels: View {
    let names: [String]
    var fontSize: CGFloat = 20

    var body: some View {
        HStack(spacing: fontSize * 0.5) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(verbatim: name)
                    .font(.system(size: fontSize, weight: .semibold))
                    .tracking(fontSize * 0.01)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, fontSize * 0.48)
                    .frame(height: fontSize * 1.5)
                    .background(RoundedRectangle(cornerRadius: fontSize * 0.34, style: .continuous).fill(.white.opacity(0.15)))
            }
        }
        .fixedSize()
    }
}

private struct LiveTVGlassUpcomingLabel: View {
    let program: LiveTVGlassUpcomingProgram
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            Text(program.title)
                .font(.system(size: 29, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1 : 0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(program.timeText)
                .font(.system(size: 29).monospacedDigit())
                .foregroundStyle(.white.opacity(isFocused ? 0.7 : 0.46))
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(isFocused ? .white.opacity(0.2) : .clear))
        .padding(.horizontal, -20)
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview("Channel panel") {
    LiveTVGlassChannelPanel(
        content: .init(
            channelName: "Now TV Sport", logoURL: nil, numberText: "102",
            sourceNames: ["Provider A"],
            now: .init(
                title: "Premier League Live", meta: "42 min left", progress: 0.6,
                description: "Live coverage of the weekend's biggest fixture."
            ),
            isFavorite: false, watchTitle: "Watch",
            upcoming: [
                .init(id: "1", title: "Match of the Day", timeText: "9:30", startsTomorrow: false),
                .init(id: "2", title: "Soccer Saturday", timeText: "12:00", startsTomorrow: true)
            ]
        ),
        canvasHeight: 1080,
        onWatch: {}, onMultiview: {}, onToggleFavorite: {}, onClose: {}
    )
    .padding(40)
    .background(Color.black)
}
#endif
