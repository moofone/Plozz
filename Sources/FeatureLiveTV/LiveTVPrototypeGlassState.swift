import SwiftUI

/// What the Live TV browse screen is presenting above the guide. Focus movement
/// stays with the tvOS focus engine; only the presentation is custom, and it is
/// one value so the dimming and the Back behaviour cannot disagree with it.
enum LiveTVPrototypeGlassPresentation: Equatable {
    case none
    case rail
    case quickMenu
    /// The Favourite Filters page opened from the tray's "Edit Favourite Filters".
    case favouriteFilters
    /// The tag picker: `editing` is the saved filter's identifier, or `nil` for a new one. Back, Save and Delete return to
    /// `origin`, the tray or the Favourite Filters page it was opened from.
    case tagPicker(editing: String?, origin: TagPickerOrigin)
    /// Set Up My Channels,  opened from the tray. Back and Apply return to the tray.
    case lineup
    case rightPanel(channelID: String)
    case context(channelID: String, programID: String?)

    enum TagPickerOrigin: Equatable {
        case tray
        case filtersPage
    }

    /// How the guide behind the presentation is dimmed.
    enum Dimming: Equatable {
        case none
        /// The page recedes: a flat black wash, no blur.
        case recede
    }

    var dimming: Dimming {
        switch self {
        // The quick menu and the Favourite Filters page leave the guide as it is: the mockup draws no wash behind them, and
        // only the menu's own glass blurs what is under it.
        case .none, .context, .quickMenu, .favouriteFilters: .none
        case .rail, .rightPanel, .tagPicker, .lineup: .recede
        }
    }

    /// Where focus goes when the presentation closes.
    enum FocusReturn: Equatable {
        case heading
        case plate(channelID: String)
        case cell(channelID: String, programID: String?)
    }

    /// What Back does: a custom presentation closes to `.none`, except the filter pages, which step back to what opened
    /// them. The rail is the app's own (Back there is the shell's, not ours).
    var backResult: LiveTVPrototypeGlassPresentation {
        switch self {
        case .favouriteFilters: .quickMenu
        case let .tagPicker(_, origin): origin == .tray ? .quickMenu : .favouriteFilters
        case .lineup: .quickMenu
        case .none, .rail, .quickMenu, .rightPanel, .context: .none
        }
    }

    /// Whether Back is ours to handle.
    var handlesBack: Bool {
        switch self {
        case .none, .rail: false
        case .quickMenu, .favouriteFilters, .tagPicker, .lineup, .rightPanel, .context: true
        }
    }

    var focusReturn: FocusReturn? {
        switch self {
        case .none, .rail: nil
        case .quickMenu, .favouriteFilters, .tagPicker, .lineup: .heading
        case let .rightPanel(channelID): .plate(channelID: channelID)
        case let .context(channelID, programID): .cell(channelID: channelID, programID: programID)
        }
    }
}

/// What can happen to a presentation. `LiveTVPrototypeView` is the only owner of the
/// state and changes it only through `applying(_:canPresent:)`, so an impossible
/// transition cannot be reached from a view callback.
enum LiveTVPrototypeGlassEvent: Equatable {
    case toggleQuickMenu
    case openRightPanel(channelID: String)
    case openContext(channelID: String, programID: String?)
    /// The tray's "Edit Favourite Filters": the tray gives way to the Favourite Filters page.
    case openFavouriteFilters
    /// A new filter (`editing` nil) or a saved one, from the tray or the Favourite Filters page: the tray or page it came from
    /// closes as the picker opens.
    case openTagPicker(editing: String?)
    /// The tray's "Set Up My Channels": the tray gives way to the set-up page.
    case openLineup
    /// Back / Menu.
    case back
    /// An entry or button of the presentation closed it.
    case close
    /// A sheet or inline search is about to present: the presentation closes first.
    case closeForSheet
    /// Scene phase, tab, playback start, catalog or profile changed.
    case reset
    /// The content the presentation shows is gone (channel removed, no entries).
    case contentUnavailable
    /// The shell's rail expanded: focus left the page by any route (←, Back), so whatever
    /// was presented closes and the page recedes behind the rail.
    case railOpened
    /// The shell's rail collapsed again (→, reselecting Live TV, focus entering content).
    case railClosed
}

extension LiveTVPrototypeGlassPresentation {
    /// The presentation after `event`, or nil when the event is invalid here (a no-op).
    /// Presentations never replace one another: opening needs `.none` and a screen that
    /// can present (`canPresent`: active, no sheet, no expanded picture, no multiview).
    func applying(_ event: LiveTVPrototypeGlassEvent, canPresent: Bool) -> LiveTVPrototypeGlassPresentation? {
        // `.none` alone would read as `Optional.none`, a no-op.
        let closed = LiveTVPrototypeGlassPresentation.none
        switch event {
        case .railOpened:
            return self == .rail ? nil : .rail
        case .railClosed:
            return self == .rail ? closed : nil
        case .reset, .contentUnavailable, .close, .closeForSheet:
            // The rail belongs to the shell: only `railClosed` ends it.
            return self == closed || self == .rail ? nil : closed
        case .back:
            return handlesBack ? backResult : nil
        case .toggleQuickMenu:
            switch self {
            case .none: return canPresent ? .quickMenu : nil
            case .quickMenu: return closed
            case .rail, .favouriteFilters, .tagPicker, .lineup, .rightPanel, .context: return nil
            }
        case .openLineup:
            return self == .quickMenu ? .lineup : nil
        case .openFavouriteFilters:
            return self == .quickMenu ? .favouriteFilters : nil
        case let .openTagPicker(editing):
            switch self {
            case .quickMenu: return .tagPicker(editing: editing, origin: .tray)
            case .favouriteFilters: return .tagPicker(editing: editing, origin: .filtersPage)
            default: return nil
            }
        case let .openRightPanel(channelID):
            return self == .none && canPresent ? .rightPanel(channelID: channelID) : nil
        case let .openContext(channelID, programID):
            return self == .none && canPresent ? .context(channelID: channelID, programID: programID) : nil
        }
    }

    /// The presentation with a stale `.rail` dropped: the rail belongs to the shell, and if its "collapsed" notice was missed
    /// (or arrived while the page was inactive) `.rail` would refuse every open (Select on a plate, the heading) until a
    /// reset. The shell's live state is the truth.
    func reconciled(railIsExpanded: Bool) -> LiveTVPrototypeGlassPresentation {
        self == .rail && !railIsExpanded ? .none : self
    }

    /// Why `event` was refused here, for the DEBUG log of dropped input. Nil when it is a quiet no-op (a reset of nothing).
    func dropReason(of event: LiveTVPrototypeGlassEvent, canPresent: Bool) -> String? {
        switch event {
        case .reset, .contentUnavailable, .close, .closeForSheet, .railOpened, .railClosed:
            return self == .none && (event == .reset || event == .contentUnavailable) ? nil : "invalid-in-state"
        case .openRightPanel, .openContext, .toggleQuickMenu:
            if self != .none { return self == .rail ? "rail-open" : "another-presentation-open" }
            return canPresent ? "invalid-in-state" : "cannot-present"
        case .back, .openLineup, .openFavouriteFilters, .openTagPicker:
            return "invalid-in-state"
        }
    }

    /// Whether the guide, hero, heading, rail and playing-state scrims are drawn. While the tray, channel panel or context menu is open over a
    /// playing picture the screen is the picture and the popup only; idle browsing keeps the guide behind its popups.
    func showsGuideChrome(isPlaying: Bool) -> Bool {
        switch self {
        case .quickMenu, .context, .rightPanel: !isPlaying
        case .none, .rail, .favouriteFilters, .tagPicker, .lineup: true
        }
    }

    /// Whether the app's left sidebar (icons, avatar, clock) is hidden. It follows the guide chrome: bare video plus the popup only.
    func hidesAppSidebar(isPlaying: Bool) -> Bool { !showsGuideChrome(isPlaying: isPlaying) }

    /// Whether the guide behind is out of the focus chain, so focus stays in the panel.
    var trapsFocus: Bool {
        switch self {
        case .none, .rail: false
        case .quickMenu, .favouriteFilters, .tagPicker, .lineup, .rightPanel, .context: true
        }
    }
}

/// What Back does on the guide page, in the mockup's order: an open presentation closes first,
/// then (playing) the picture goes full-screen, and only with nothing playing is Back the app's own
/// (the rail, then Home). In the full-screen picture Back belongs to the player, which reopens the guide.
enum LiveTVPrototypeBackAction: Equatable {
    case closePresentation
    case showVideoFullScreen
    case shell
    case player

    static func resolve(
        presentation: LiveTVPrototypeGlassPresentation, isPlaying: Bool, isFullScreen: Bool
    ) -> LiveTVPrototypeBackAction {
        if isFullScreen { return .player }
        if presentation.handlesBack { return .closePresentation }
        if presentation == .none, isPlaying { return .showVideoFullScreen }
        return .shell
    }

    /// Whether the guide page claims the press; otherwise it passes through to the shell or player.
    var handledByGuide: Bool { self == .closePresentation || self == .showVideoFullScreen }
}

/// Whether Watch from the guide still shows the guide: the player has been asked for (`isExpanded`) but this channel's
/// first frame is not on screen yet, and the full-screen player has not been shown since. Once it has, channel changes
/// in it are the player's own. Multiview keeps its own presentation.
enum LiveTVFirstFrameHold {
    static func holdsGuide(
        isExpanded: Bool, isMultiview: Bool, playerRevealed: Bool, preparationID: UUID?, framedPreparationID: UUID?
    ) -> Bool {
        guard isExpanded, !isMultiview, !playerRevealed else { return false }
        guard let preparationID else { return true }
        return preparationID != framedPreparationID
    }
}

/// Back inside the guide browser (a programme or channel focused), after any presentation has had the press.
/// A pending Watch, search or multiview selection is closed first. On the glass screen, which has no toolbar, Back then
/// steps to the filter heading, as Left at the guide's leading edge does; Back on the heading goes on to the main menu.
enum LiveTVPrototypeGuideBrowseBack: Equatable {
    case cancelWatch
    case ignore
    case closeSearch
    case finishMultiviewSelection
    case focusHeading
    case focusToolbar

    static func resolve(
        hasPendingWatch: Bool, isRestoringFocus: Bool, isSearching: Bool, isSelectingMultiview: Bool, headingAvailable: Bool
    ) -> LiveTVPrototypeGuideBrowseBack {
        if hasPendingWatch { return .cancelWatch }
        if isRestoringFocus { return .ignore }
        if isSearching { return .closeSearch }
        if isSelectingMultiview { return .finishMultiviewSelection }
        return headingAvailable ? .focusHeading : .focusToolbar
    }
}

#if os(tvOS)
/// The full-screen scrim behind a presentation, drawn above the guide and any
/// mounted picture and below the panels. Reduce Transparency drops the blur and
/// keeps the opacity.
struct LiveTVPrototypeGlassScrim: View {
    let dimming: LiveTVPrototypeGlassPresentation.Dimming
    let reduceTransparency: Bool

    var body: some View {
        Color.black.opacity(dimming == .recede ? 0.40 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
