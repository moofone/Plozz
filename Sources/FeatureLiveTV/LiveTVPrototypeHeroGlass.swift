#if os(tvOS)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit

/// What the glass hero and its heading need from the screen: plain values and
/// closures, so the hero stays a view and the screen keeps the state.
struct PrototypeGlassHeroInputs {
    /// "My Channels", or the category/filters in effect.
    var headingTitle: String
    /// The visible channel count, already short-formatted.
    var headingCount: String
    var isHeadingOpen: Bool
    var openHeading: () -> Void
    /// The guide's focus scope, and whether the heading is where focus returns when the tray closes.
    var focusScope: Namespace.ID?
    var prefersFocus = false
    var navigation: PrototypeGuideHeadingNavigation?
    var isPlaying: Bool
    /// The model's clock: what is on, ended or still to come is derived from it, never from a date captured earlier.
    var now: Date
    var isFavorite: Bool
    var toggleFavorite: () -> Void
    /// Nil hides Multiview (nothing to add to, or already choosing channels).
    var multiview: (() -> Void)?
    var info: () -> Void
    /// A picture plays under the guide with no edge scrim: the text column sits on a panel of system glass.
    var glassBacking = false
}

/// The tvOS hero: text and buttons only, on the right half, with the guide's
/// heading on the left of the same line. Nothing connects until Watch.
struct PrototypeGlassHero: View {
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let layout: PrototypePreviewLayout
    let inputs: PrototypeGlassHeroInputs
    let watch: () -> Void
    var watchTitle: LocalizedStringResource?
    @Environment(\.locale) private var locale
    @Environment(\.liveTVGlassLayout) private var glass

    /// The 1080p sizes; the layout tokens scale them (`LiveTVGlassLayout.ui`).
    static let columnWidth: CGFloat = 680
    static let buttonHeight: CGFloat = 60
    /// The heading's capsule hangs below the button line so its letters sit on it.
    static let headingDrop: CGFloat = 19.5
    /// The mockup's hero block ends above the guide's top (`heroBottomGap`, and the sheet's drop while it is shown); the browse layout
    /// adds the section gap.
    static func bottomInset(_ glass: LiveTVGlassLayout) -> CGFloat { glass.guideTop - glass.heroBlockBottom - PrototypeLayout.sectionGap }

    /// The glass panel behind the text while a picture plays (mockup `.heroglass`, Plozz-like: `--hp`/`--hq` 24 px, `--hr` the sheet's
    /// radius), drawn outside the column so the text keeps its place.
    static func backingPadding(_ glass: LiveTVGlassLayout) -> CGFloat { PrototypePlayingGlass.heroPadding * glass.pixelScale }
    static func backingCornerRadius(_ glass: LiveTVGlassLayout) -> CGFloat {
        glass.cellRadius + PrototypePlayingGlass.sheetPadding * glass.pixelScale
    }
    /// How far the heading's capsule bottom hangs below the hero block's bottom: Plozz-like puts it level with the panel's own.
    static func headingDropPoints(_ glass: LiveTVGlassLayout, onSheet: Bool) -> CGFloat {
        onSheet ? PrototypePlayingGlass.headingDrop * glass.pixelScale : glass.ui(headingDrop)
    }
    /// Padding that puts the heading capsule's left edge on screen at the name's line (130 at 1080p), or, on the glass sheet, at the
    /// sheet's own left edge (mockup `leftAt: -20`).
    static func headingLeadingInset(_ layout: PrototypePreviewLayout, glass: LiveTVGlassLayout, onSheet: Bool) -> CGFloat {
        guard onSheet else { return layout.glassHeadingLeadingInset }
        let screenX = glass.leadingInset - PrototypePlayingGlass.sheetPadding * glass.pixelScale
        return screenX - (layout.contentFrame.minX - layout.bounds.minX)
    }
    /// How far the column's right edge sits inside the guide's right edge so the panel's lines up with the sheet's: the panel's padding,
    /// less the sheet's overhang past the programmes (mockup `margin-right: 24 - (20 - cg)`).
    static func columnTrailingInset(_ glass: LiveTVGlassLayout, onSheet: Bool) -> CGFloat {
        guard onSheet else { return 0 }
        return backingPadding(glass) - (PrototypePlayingGlass.sheetPadding * glass.pixelScale - glass.cellGap)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The open tray draws its own copy of the pill in its top slot.
            PrototypeGlassHeading(inputs: inputs)
                .opacity(inputs.isHeadingOpen ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.headingLeadingInset(layout, glass: glass, onSheet: inputs.glassBacking))
                .offset(y: Self.headingDropPoints(glass, onSheet: inputs.glassBacking))
            column
                .frame(width: glass.ui(Self.columnWidth), alignment: .leading)
                .background { if inputs.glassBacking { backing } }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, layout.glassHeroTrailingInset + Self.columnTrailingInset(glass, onSheet: inputs.glassBacking))
        }
        .padding(.bottom, Self.bottomInset(glass))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Drawn outside the column's frame, so the text keeps its place with or without it. The same glass as the guide's sheet.
    private var backing: some View {
        PrototypePanelGlass(shape: RoundedRectangle(cornerRadius: Self.backingCornerRadius(glass), style: .continuous))
            .padding(-Self.backingPadding(glass))
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let program {
                Text(verbatim: program.title)
                    .font(.system(size: glass.ui(52), weight: .bold))
                    .tracking(-0.022 * glass.ui(52))
                    .lineLimit(1)
                if let meta = meta(for: program) {
                    Text(verbatim: meta)
                        .font(.system(size: glass.ui(25)))
                        .foregroundStyle(.white.opacity(PrototypePlayingGlass.heroMetaOpacity))
                        .lineLimit(1)
                        .padding(.top, glass.ui(12))
                }
                tagRow
                if let summary = program.playerInfo.summary {
                    Text(verbatim: summary)
                        .font(.system(size: glass.ui(25)))
                        .lineSpacing(glass.ui(25) * 0.3)
                        .foregroundStyle(.white.opacity(PrototypePlayingGlass.heroDescriptionOpacity))
                        .lineLimit(2)
                        .padding(.top, glass.ui(12))
                }
            } else if let channel {
                // `channel.name` already follows the clean-channel-names setting.
                Text(verbatim: channel.name)
                    .font(.system(size: glass.ui(52), weight: .bold))
                    .tracking(-0.022 * glass.ui(52))
                    .lineLimit(1)
                Text(channel.eventSlot?.isIdle == true ? "No event" : "No guide information")
                    .font(.system(size: glass.ui(25)))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .padding(.top, glass.ui(12))
                tagRow
            }
            buttons
                .padding(.top, glass.ui(26))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: glass.ui(10), y: 1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var tagRow: some View {
        if let channel, !channel.displayedTagTexts().isEmpty {
            LiveTVGlassTagRow(texts: channel.displayedTagTexts(), fontSize: glass.ui(21)).padding(.top, glass.ui(12))
        }
    }

    private var actions: LiveTVHeroActions {
        LiveTVHeroActions(program: program, isPlayingChannel: inputs.isPlaying, now: inputs.now)
    }

    /// "8:00 – 8:30 PM · Season 2, Episode 4", leaving out whatever the guide lacks; "Ended · " first when it is over.
    private func meta(for program: LiveTVPrototypeProgram) -> String? {
        // A 24/7 loop has no times to read: its meta line is the tag.
        if program.isContinuousLoop { return LiveTVPrototypeProgram.loopTag }
        let range = "\(program.start.formatted(.dateTime.hour().minute().locale(locale))) – \(program.end.formatted(.dateTime.hour().minute().locale(locale)))"
        let ended = actions.showsEndedLabel ? String(localized: "Ended") : ""
        let parts = [ended, range, program.subtitle].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var buttons: some View {
        HStack(spacing: glass.ui(16)) {
            if channel != nil {
                if actions.primary != .none { watchButton(now: inputs.now) }
                if actions.showsMultiview, let multiview = inputs.multiview {
                    PrototypeGlassIconButton(
                        symbol: "rectangle.split.2x2", label: "Add to Multiview", action: multiview)
                }
                PrototypeGlassIconButton(
                    symbol: inputs.isFavorite ? "star.fill" : "star",
                    label: inputs.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    action: inputs.toggleFavorite)
                PrototypeGlassIconButton(symbol: "info.circle", label: "Channel Details", action: inputs.info)
            }
        }
        .frame(height: glass.ui(Self.buttonHeight))
    }

    private func watchButton(now: Date) -> some View {
        let isOnNow = program.map { $0.start <= now && now < $0.end } ?? false
        let isFuture = program.map { $0.start > now } ?? false
        let left = isOnNow && program?.isContinuousLoop != true ? program.flatMap {
            LiveTVGlassFormatting.leftShort(remaining: $0.end.timeIntervalSince(now))
        } : nil
        return Button(action: watch) {
            HStack(spacing: glass.ui(10)) {
                Image(systemName: watchTitle == nil ? "play.fill" : "rectangle.split.2x2")
                    .font(.system(size: glass.ui(24), weight: .semibold))
                if let watchTitle {
                    Text(watchTitle)
                } else if !isFuture {
                    Text(actions.primary == .watch(resumes: true) ? "Resume" : "Watch")
                    if let left {
                        Text(left).opacity(0.62)
                    }
                }
            }
            .font(.system(size: glass.ui(27), weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, glass.ui(isFuture && watchTitle == nil ? 20 : 28))
            .frame(minWidth: glass.ui(Self.buttonHeight), minHeight: glass.ui(Self.buttonHeight))
        }
        .disabled(channel?.eventSlot?.isIdle == true)
        .buttonStyle(PrototypeGlassHeroButtonStyle(isWatch: true))
        .accessibilityLabel(Text(watchTitle ?? (actions.primary == .watch(resumes: true) ? "Resume" : "Watch")))
        .accessibilityIdentifier("live-tv-info-watch")
    }
}

/// One 60 pt control. Glass at rest; focus turns it into a white capsule with
/// black ink. Watch is white at rest too, so the primary action reads first.
struct PrototypeGlassHeroButtonStyle: ButtonStyle {
    var isWatch = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let solid = isWatch || isFocused
        configuration.label
            .foregroundStyle(solid ? Color.black : Color.white)
            .background { PrototypeGlassPillBackground(isSolid: solid, reduceTransparency: reduceTransparency) }
            .scaleEffect(isFocused ? 1.07 : (configuration.isPressed ? 0.97 : 1))
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct PrototypeGlassPillBackground: View {
    let isSolid: Bool
    let reduceTransparency: Bool

    @ViewBuilder var body: some View {
        if isSolid {
            Capsule().fill(Color.white)
        } else if reduceTransparency {
            Capsule().fill(Color.white.opacity(0.22))
        } else if #available(tvOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }
}

private struct PrototypeGlassIconButton: View {
    @Environment(\.liveTVGlassLayout) private var glass
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glass.ui(26), weight: .semibold))
                .frame(width: glass.ui(PrototypeGlassHero.buttonHeight), height: glass.ui(PrototypeGlassHero.buttonHeight))
        }
        .buttonStyle(PrototypeGlassHeroButtonStyle())
        .accessibilityLabel(Text(label))
    }
}

/// The guide's heading: the name in bold, the channel count and a grey chevron.
/// Text only at rest; focus turns it into a white capsule whose padding reaches
/// left so the name lines up with the channel numbers below.
struct PrototypeGlassHeading: View {
    let inputs: PrototypeGlassHeroInputs
    @Environment(\.liveTVGlassLayout) private var glass

    var body: some View {
        Group {
            if let navigation = inputs.navigation {
                PrototypeGuideHeadingFocusHost(content: button.focused(navigation.focus), navigation: navigation)
            } else {
                button
            }
        }
        .modifier(PrototypeGlassHeadingFocusPreference(scope: inputs.focusScope, prefers: inputs.prefersFocus))
    }

    private var button: some View {
        Button(action: inputs.openHeading) {
            HStack(spacing: glass.ui(10)) {
                Text(verbatim: inputs.headingTitle)
                    .font(.system(size: glass.ui(28), weight: .bold))
                    .lineLimit(1)
                HStack(spacing: glass.ui(4)) {
                    Text(verbatim: inputs.headingCount)
                        .font(.system(size: glass.ui(22), weight: .medium))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: glass.ui(21), weight: .semibold))
                        .rotationEffect(.degrees(inputs.isHeadingOpen ? 90 : 0))
                }
                .opacity(0.55)
            }
            .padding(.horizontal, glass.ui(22))
            .frame(height: glass.ui(PrototypeGlassHero.buttonHeight))
        }
        .buttonStyle(PrototypeGlassHeadingStyle(glassBacking: inputs.glassBacking))
        .accessibilityLabel(Text(verbatim: "\(inputs.headingTitle), \(inputs.headingCount)"))
        .accessibilityIdentifier("live-tv-heading")
    }
}

struct PrototypeGuideHeadingNavigation {
    let focus: FocusState<Bool>.Binding
    let openSidebar: (() -> Void)?
    let requestPlate: (PrototypeGuidePlateRequest) -> Void
}

/// Scope directional vetoes to the heading alone. SwiftUI's move command can
/// be bypassed when UIKit already has a spatial target (notably on Down).
private struct PrototypeGuideHeadingFocusHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let navigation: PrototypeGuideHeadingNavigation

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(rootView: AnyView(EmptyView()))
        controller.safeAreaRegions = []
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let environment = context.environment
        controller.navigation = environment.isEnabled && !environment.accessibilityVoiceOverEnabled ? navigation : nil
        controller.isRTL = environment.layoutDirection == .rightToLeft
        controller.rootView = AnyView(content
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.plozzReduceTransparency, environment.plozzReduceTransparency))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(by: .init(width: 1_920, height: 1_080)))
    }

    final class Controller: UIHostingController<AnyView>, HorizontalNavigationInputOwning {
        var navigation: PrototypeGuideHeadingNavigation?
        var isRTL = false
        var ownsHorizontalNavigationInput: Bool { navigation?.openSidebar != nil }
        private var pendingMove = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusMovementFailed(_:)),
                name: UIFocusSystem.movementDidFailNotification, object: nil
            )
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            !redirect(context) && super.shouldUpdateFocus(in: context)
        }

        @objc private func focusMovementFailed(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
            _ = redirect(context)
        }

        private func redirect(_ context: UIFocusUpdateContext) -> Bool {
            guard let navigation, let previous = context.previouslyFocusedItem,
                  NativeFocusRegion.contains(previous, in: view),
                  let epoch = DetailTransitionNavigation.navigationInputEpoch(in: view) else { return false }
            let leading: UIFocusHeading = isRTL ? .right : .left
            let trailing: UIFocusHeading = isRTL ? .left : .right
            let action: () -> Void
            switch context.focusHeading {
            case leading:
                guard let openSidebar = navigation.openSidebar else { return false }
                action = openSidebar
            case trailing: action = { navigation.requestPlate(.rememberedRow) }
            case .down: action = { navigation.requestPlate(.firstVisibleRow) }
            default: return false
            }
            guard !pendingMove else { return true }
            pendingMove = true
            DispatchQueue.main.async { [weak self, weak previous] in
                guard let self else { return }
                pendingMove = false
                guard navigation.focus.wrappedValue, self.navigation != nil, let previous,
                      UIFocusSystem.focusSystem(for: view)?.focusedItem === previous,
                      DetailTransitionNavigation.navigationInputEpoch(in: view) == epoch else { return }
                action()
            }
            return true
        }
    }
}

private struct PrototypeGlassHeadingFocusPreference: ViewModifier {
    let scope: Namespace.ID?
    let prefers: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if let scope { content.prefersDefaultFocus(prefers, in: scope) } else { content }
    }
}

private struct PrototypeGlassHeadingStyle: ButtonStyle {
    /// A picture plays under the guide: at rest the pill is a capsule of system glass (mockup `.abtn.ahead.glass`).
    var glassBacking = false
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background {
                if isFocused {
                    Capsule().fill(Color.white)
                } else if glassBacking, #available(tvOS 26.0, *) {
                    Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
                }
            }
            .shadow(color: .black.opacity(isFocused ? 0 : 0.45), radius: 10, y: 1)
            .scaleEffect(isFocused ? 1.07 : 1)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

extension PrototypePreviewLayout {
    /// Screen x of the heading capsule's edge: the name lines up with the plate numbers (130 at 1080p).
    var glassHeadingScreenX: CGFloat { glass.headingLeadingX }
    /// The hero's right edge, inset from the screen edge like the guide's.
    var glassHeroScreenMaxXInset: CGFloat { glass.trailingInset }

    /// Padding that puts the heading capsule at `glassHeadingScreenX` on screen;
    /// negative when the content frame starts to its right.
    var glassHeadingLeadingInset: CGFloat {
        glassHeadingScreenX - (contentFrame.minX - bounds.minX)
    }

    /// Padding that pulls the hero column's right edge in to `glassHeroScreenMaxXInset` from the screen edge.
    var glassHeroTrailingInset: CGFloat {
        max(0, contentFrame.maxX - (bounds.maxX - glassHeroScreenMaxXInset))
    }
}
#endif
