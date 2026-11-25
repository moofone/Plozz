import XCTest
@testable import FeatureLiveTV

final class LiveTVPrototypeGlassStateTests: XCTestCase {
    func testDimmingFollowsThePresentation() {
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.none.dimming, .none)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.rail.dimming, .recede)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.rightPanel(channelID: "a").dimming, .recede)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.quickMenu.dimming, .none)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.context(channelID: "a", programID: nil).dimming, .none)
    }

    func testBackClosesOnlyOurPresentations() {
        XCTAssertFalse(LiveTVPrototypeGlassPresentation.none.handlesBack)
        XCTAssertFalse(LiveTVPrototypeGlassPresentation.rail.handlesBack)
        for presentation: LiveTVPrototypeGlassPresentation in [
            .quickMenu, .rightPanel(channelID: "a"), .context(channelID: "a", programID: "p")
        ] {
            XCTAssertTrue(presentation.handlesBack)
            XCTAssertEqual(presentation.backResult, .none)
        }
    }

    func testFocusReturnsToWhereThePresentationOpened() {
        XCTAssertNil(LiveTVPrototypeGlassPresentation.none.focusReturn)
        XCTAssertNil(LiveTVPrototypeGlassPresentation.rail.focusReturn)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.quickMenu.focusReturn, .heading)
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.rightPanel(channelID: "a").focusReturn, .plate(channelID: "a"))
        XCTAssertEqual(
            LiveTVPrototypeGlassPresentation.context(channelID: "a", programID: "p").focusReturn,
            .cell(channelID: "a", programID: "p"))
    }

    // MARK: - Transition table

    private typealias Presentation = LiveTVPrototypeGlassPresentation
    private typealias Event = LiveTVPrototypeGlassEvent

    private let allStates: [Presentation] = [
        .none, .rail, .quickMenu, .rightPanel(channelID: "a"), .context(channelID: "a", programID: "p")
    ]

    func testEveryStateAndEventHasTheDocumentedResult() {
        for state in allStates {
            let presented = state != .none && state != .rail
            // Closing events: from a presentation they land on .none, from .none they are no-ops.
            // The rail belongs to the shell, so only `railClosed` ends it.
            for event in [Event.close, .closeForSheet, .reset, .contentUnavailable] {
                XCTAssertEqual(state.applying(event, canPresent: true),
                               state == .none || state == .rail ? nil : Presentation.none, "\(event) in \(state)")
            }
            // The rail opening from anywhere replaces the state; closing it is valid only from .rail.
            XCTAssertEqual(state.applying(.railOpened, canPresent: true), state == .rail ? nil : Presentation.rail)
            XCTAssertEqual(state.applying(.railClosed, canPresent: true), state == .rail ? Presentation.none : nil)
            XCTAssertEqual(state.applying(.back, canPresent: true), state.handlesBack ? Presentation.none : nil, "back in \(state)")
            // Opening needs .none; a presentation never replaces another.
            XCTAssertEqual(state.applying(.toggleQuickMenu, canPresent: true),
                           state == .none ? .quickMenu : (state == .quickMenu ? Presentation.none : nil))
            XCTAssertEqual(state.applying(.openRightPanel(channelID: "b"), canPresent: true),
                           state == .none ? .rightPanel(channelID: "b") : nil)
            XCTAssertEqual(state.applying(.openContext(channelID: "b", programID: nil), canPresent: true),
                           state == .none ? .context(channelID: "b", programID: nil) : nil)
            XCTAssertEqual(state.trapsFocus, presented)
        }
    }

    // MARK: - Favourite filter pages

    private let filtersPage = Presentation.favouriteFilters
    private let pickerFromTray = Presentation.tagPicker(editing: nil, origin: .tray)
    private let pickerFromPage = Presentation.tagPicker(editing: "f1", origin: .filtersPage)

    func testTrayOpensTheFiltersPageAndThePickerClosingTheTrayFirst() {
        XCTAssertEqual(Presentation.quickMenu.applying(.openFavouriteFilters, canPresent: true), filtersPage)
        XCTAssertEqual(Presentation.quickMenu.applying(.openTagPicker(editing: nil), canPresent: true), pickerFromTray)
        XCTAssertEqual(filtersPage.applying(.openTagPicker(editing: "f1"), canPresent: true), pickerFromPage)
        XCTAssertEqual(filtersPage.applying(.openTagPicker(editing: nil), canPresent: true), .tagPicker(editing: nil, origin: .filtersPage))
    }

    func testFilterPagesOpenOnlyFromTheirParents() {
        for state in allStates + [filtersPage, pickerFromTray, pickerFromPage] {
            XCTAssertEqual(state.applying(.openFavouriteFilters, canPresent: true), state == .quickMenu ? filtersPage : nil, "\(state)")
            let opensPicker = state == .quickMenu || state == filtersPage
            XCTAssertEqual(state.applying(.openTagPicker(editing: nil), canPresent: true) != nil, opensPicker, "\(state)")
        }
        XCTAssertNil(filtersPage.applying(.toggleQuickMenu, canPresent: true))
        XCTAssertNil(pickerFromTray.applying(.toggleQuickMenu, canPresent: true))
    }

    func testBackStepsBackToWhatOpenedThePage() {
        XCTAssertEqual(filtersPage.applying(.back, canPresent: true), Presentation.quickMenu)
        XCTAssertEqual(pickerFromTray.applying(.back, canPresent: true), Presentation.quickMenu, "Save, Delete and Back return to the tray")
        XCTAssertEqual(pickerFromPage.applying(.back, canPresent: true), filtersPage, "…or to the page it came from")
    }

    func testFilterPagesTrapFocusAndReturnItToTheHeading() {
        for state in [filtersPage, pickerFromTray, pickerFromPage] {
            XCTAssertTrue(state.trapsFocus)
            XCTAssertTrue(state.handlesBack)
            XCTAssertEqual(state.focusReturn, .heading)
            for event in [Event.close, .closeForSheet, .reset, .contentUnavailable] {
                XCTAssertEqual(state.applying(event, canPresent: true), Presentation.none, "\(event) in \(state)")
            }
            XCTAssertEqual(state.applying(.railOpened, canPresent: true), Presentation.rail)
            XCTAssertNil(state.applying(.openRightPanel(channelID: "a"), canPresent: true))
            XCTAssertNil(state.applying(.openContext(channelID: "a", programID: nil), canPresent: true))
            XCTAssertEqual(BackAction.resolve(presentation: state, isPlaying: true, isFullScreen: false), .closePresentation)
        }
    }

    /// The UI's journeys, one event per press: the tray's Edit row, a filter (hold menu Edit or Select), Save / Delete / Back out of the picker.
    func testFilterJourneysFollowTheMockupsRemote() {
        func run(_ events: [Event], from start: Presentation = .none) -> Presentation? {
            var state = start
            for event in events {
                guard let next = state.applying(event, canPresent: true) else { return nil }
                state = next
            }
            return state
        }
        // Heading → tray → page → picker (edit) → Save (back) → page → Back → tray → Back → guide.
        XCTAssertEqual(run([.toggleQuickMenu, .openFavouriteFilters, .openTagPicker(editing: "f1")]), pickerFromPage)
        XCTAssertEqual(run([.toggleQuickMenu, .openFavouriteFilters, .openTagPicker(editing: "f1"), .back]), filtersPage)
        XCTAssertEqual(run([.toggleQuickMenu, .openFavouriteFilters, .openTagPicker(editing: "f1"), .back, .back]), .quickMenu)
        XCTAssertEqual(run([.toggleQuickMenu, .openFavouriteFilters, .back, .back]), Presentation.none)
        // The tray's New Favourite Filter (no filters yet) → picker → Save returns to the tray.
        XCTAssertEqual(run([.toggleQuickMenu, .openTagPicker(editing: nil), .back]), .quickMenu)
        // New from the page, Delete from the picker (dispatched as back), then the page again.
        XCTAssertEqual(run([.toggleQuickMenu, .openFavouriteFilters, .openTagPicker(editing: nil), .back]), filtersPage)
        // Selecting a filter in the tray closes it for good; a picker cannot open another page.
        XCTAssertEqual(run([.toggleQuickMenu, .close]), Presentation.none)
        XCTAssertNil(run([.toggleQuickMenu, .openTagPicker(editing: nil), .openFavouriteFilters]))
        XCTAssertNil(run([.toggleQuickMenu, .openFavouriteFilters, .openTagPicker(editing: nil), .openTagPicker(editing: "f1")]))
    }

    /// Set Up My Channels: tray → the set-up page → Back / Apply (dispatched as back) → tray → Back → guide; nothing opens it but the tray.
    func testLineupJourneyFollowsTheMockupsRemote() {
        func run(_ events: [Event]) -> Presentation? {
            var state = Presentation.none
            for event in events {
                guard let next = state.applying(event, canPresent: true) else { return nil }
                state = next
            }
            return state
        }
        XCTAssertEqual(run([.toggleQuickMenu, .openLineup]), .lineup)
        XCTAssertEqual(run([.toggleQuickMenu, .openLineup, .back]), .quickMenu)
        XCTAssertEqual(run([.toggleQuickMenu, .openLineup, .back, .back]), Presentation.none)
        XCTAssertNil(run([.openLineup]), "not from the guide")
        XCTAssertNil(run([.toggleQuickMenu, .openFavouriteFilters, .openLineup]), "not from another page")
        XCTAssertNil(run([.toggleQuickMenu, .openLineup, .toggleQuickMenu]), "the page traps focus: the heading cannot reopen the tray")
        XCTAssertNil(run([.toggleQuickMenu, .openLineup, .openLineup]))
        for closing in [Event.close, .closeForSheet, .reset, .contentUnavailable] {
            XCTAssertEqual(run([.toggleQuickMenu, .openLineup, closing]), Presentation.none)
        }
        XCTAssertEqual(Presentation.lineup.dimming, .recede)
        XCTAssertTrue(Presentation.lineup.trapsFocus)
        XCTAssertTrue(Presentation.lineup.handlesBack)
        XCTAssertEqual(Presentation.lineup.focusReturn, .heading)
        XCTAssertEqual(Presentation.lineup.backResult, .quickMenu)
    }

    func testTheMenuAndItsFilterPageLeaveTheGuideLitButThePickerRecedesIt() {
        XCTAssertEqual(filtersPage.dimming, .none)
        XCTAssertEqual(pickerFromTray.dimming, .recede)
    }

    func testOpeningIsRefusedWhenTheScreenCannotPresent() {
        let none = Presentation.none
        XCTAssertNil(none.applying(.toggleQuickMenu, canPresent: false))
        XCTAssertNil(none.applying(.openRightPanel(channelID: "a"), canPresent: false))
        XCTAssertNil(none.applying(.openContext(channelID: "a", programID: nil), canPresent: false))
        // Closing is always allowed.
        XCTAssertEqual(Presentation.quickMenu.applying(.toggleQuickMenu, canPresent: false), Presentation.none)
        XCTAssertEqual(Presentation.quickMenu.applying(.reset, canPresent: false), Presentation.none)
    }

    func testEveryPresentedStateHasABackExitThatReturnsFocusToItsAnchor() {
        for state in allStates where state.trapsFocus {
            XCTAssertEqual(state.applying(.back, canPresent: true), Presentation.none)
            XCTAssertNotNil(state.focusReturn, "\(state) must know where focus returns")
        }
    }

    func testOpeningASheetFromTheTrayClosesTheTrayFirst() {
        XCTAssertEqual(Presentation.quickMenu.applying(.closeForSheet, canPresent: true), Presentation.none)
        XCTAssertEqual(Presentation.rightPanel(channelID: "a").applying(.closeForSheet, canPresent: true), Presentation.none)
    }

    func testContentDisappearingWhilePresentedResetsTheState() {
        for state in allStates where state.trapsFocus {
            XCTAssertEqual(state.applying(.contentUnavailable, canPresent: true), Presentation.none)
        }
    }

    func testSceneTabPlaybackCatalogAndProfileChangesResetThePresentation() {
        for state in allStates where state.trapsFocus {
            XCTAssertEqual(state.applying(.reset, canPresent: false), Presentation.none)
        }
    }

    // MARK: - Back on the guide page (mockup: "playing, Back first shows the picture full-screen")

    private typealias BackAction = LiveTVPrototypeBackAction

    // MARK: - Back inside the guide browser (owner: Back steps to the filter heading, Back again opens the main menu)

    private func browseBack(
        watch: Bool = false, restoring: Bool = false, searching: Bool = false, multiview: Bool = false, heading: Bool = true
    ) -> LiveTVPrototypeGuideBrowseBack {
        .resolve(hasPendingWatch: watch, isRestoringFocus: restoring, isSearching: searching,
                 isSelectingMultiview: multiview, headingAvailable: heading)
    }

    /// Guards the glass screen: Back on a programme used to request focus for a toolbar the glass screen never shows,
    /// so the press did nothing.
    func testBackInTheGuideStepsToTheHeadingWhenTheGlassScreenHasOne() {
        XCTAssertEqual(browseBack(), .focusHeading)
        XCTAssertEqual(browseBack(heading: false), .focusToolbar)
    }

    func testBackInTheGuideClosesWhatIsOpenBeforeLeavingForTheHeading() {
        XCTAssertEqual(browseBack(watch: true, searching: true, multiview: true), .cancelWatch)
        XCTAssertEqual(browseBack(restoring: true, searching: true), .ignore)
        XCTAssertEqual(browseBack(searching: true, multiview: true), .closeSearch)
        XCTAssertEqual(browseBack(multiview: true), .finishMultiviewSelection)
    }

    func testBackWhilePlayingWithTheGuideOverTheVideoShowsTheVideoFullScreen() {
        XCTAssertEqual(BackAction.resolve(presentation: .none, isPlaying: true, isFullScreen: false), .showVideoFullScreen)
    }

    func testBackWithNothingPlayingIsTheShells() {
        XCTAssertEqual(BackAction.resolve(presentation: .none, isPlaying: false, isFullScreen: false), .shell)
        XCTAssertEqual(BackAction.resolve(presentation: .rail, isPlaying: false, isFullScreen: false), .shell)
    }

    /// One Back closes the top panel only: it steps to what opened it (or to nothing), never past it, and the quick menu returns
    /// focus to the heading that opened it. The sidebar is the shell's, reached only by a later press (`TVBackConsumption`).
    func testOneBackClosesOnlyTheTopPanelForEveryPanel() {
        let panels: [Presentation] = [
            .quickMenu, .favouriteFilters, .lineup, .rightPanel(channelID: "a"), .context(channelID: "a", programID: nil),
            .tagPicker(editing: nil, origin: .tray), .tagPicker(editing: "f", origin: .filtersPage),
        ]
        for panel in panels {
            XCTAssertTrue(panel.handlesBack, "\(panel)")
            let next = panel.applying(.back, canPresent: true)
            XCTAssertEqual(next, panel.backResult, "\(panel)")
            XCTAssertNotEqual(next, .rail, "\(panel)")
        }
        XCTAssertEqual(Presentation.quickMenu.applying(.back, canPresent: true), Presentation.none)
        XCTAssertEqual(Presentation.quickMenu.focusReturn, .heading)
        XCTAssertEqual(Presentation.favouriteFilters.applying(.back, canPresent: true), .quickMenu)
        XCTAssertEqual(Presentation.lineup.applying(.back, canPresent: true), .quickMenu)
        XCTAssertEqual(Presentation.tagPicker(editing: nil, origin: .tray).applying(.back, canPresent: true), .quickMenu)
    }

    func testBackClosesAnOpenPresentationBeforeAnythingElseWhetherOrNotPlaying() {
        for state in allStates where state.handlesBack {
            for isPlaying in [true, false] {
                XCTAssertEqual(BackAction.resolve(presentation: state, isPlaying: isPlaying, isFullScreen: false),
                               .closePresentation, "\(state) playing=\(isPlaying)")
            }
        }
    }

    func testBackFromTheRailWhilePlayingGoesToTheShellNotTheFullScreenVideo() {
        XCTAssertEqual(BackAction.resolve(presentation: .rail, isPlaying: true, isFullScreen: false), .shell)
    }

    func testBackInFullScreenVideoBelongsToThePlayer() {
        for state in allStates {
            XCTAssertEqual(BackAction.resolve(presentation: state, isPlaying: true, isFullScreen: true), .player)
        }
    }

    func testEveryStateHasExactlyOneBackAction() {
        for state in allStates {
            for isPlaying in [true, false] {
                for isFullScreen in [true, false] {
                    let action = BackAction.resolve(presentation: state, isPlaying: isPlaying, isFullScreen: isFullScreen)
                    XCTAssertEqual(action == .closePresentation, state.handlesBack && !isFullScreen,
                                   "\(state) \(isPlaying) \(isFullScreen)")
                    XCTAssertEqual(action.handledByGuide, action == .closePresentation || action == .showVideoFullScreen)
                }
            }
        }
    }

    // MARK: - Rail (the shell's expanded rail, mirrored by the page)

    func testBackOpensTheRailAndAnyFocusExitFromItClearsStateAndDimming() {
        var state = Presentation.none
        state = state.applying(.railOpened, canPresent: true) ?? state
        XCTAssertEqual(state, .rail)
        XCTAssertEqual(state.dimming, .recede)
        XCTAssertFalse(state.trapsFocus, "Focus is in the rail, so the page must not trap it")
        // →, selecting Live TV again or focus entering content all collapse the rail.
        state = state.applying(.railClosed, canPresent: true) ?? state
        XCTAssertEqual(state, .none)
        XCTAssertEqual(state.dimming, .none)
    }

    func testBackFromTheRailIsTheShellsAndGoesHome() {
        XCTAssertFalse(Presentation.rail.handlesBack, "Back from the rail is the shell's: it goes Home")
        XCTAssertNil(Presentation.rail.applying(.back, canPresent: true))
    }

    func testOpeningTheRailClosesAPresentationItLeft() {
        for state in allStates where state.trapsFocus {
            XCTAssertEqual(state.applying(.railOpened, canPresent: true), Presentation.rail)
            XCTAssertEqual(Presentation.rail.applying(.railClosed, canPresent: true), Presentation.none)
        }
    }

    func testNothingOpensWhileTheRailIsOpenAndReopeningIsANoOp() {
        let rail = Presentation.rail
        XCTAssertNil(rail.applying(.toggleQuickMenu, canPresent: true))
        XCTAssertNil(rail.applying(.openRightPanel(channelID: "a"), canPresent: true))
        XCTAssertNil(rail.applying(.railOpened, canPresent: true))
        XCTAssertNil(Presentation.none.applying(.railClosed, canPresent: true))
    }

    // MARK: Select / Back are never silently stuck

    /// Open the channel panel, Back, then Select on the plate opens it again.
    func testPanelBackThenPlateSelectOpensThePanelAgain() {
        var state = LiveTVPrototypeGlassPresentation.none
        state = state.applying(.openRightPanel(channelID: "a"), canPresent: true) ?? state
        XCTAssertEqual(state, .rightPanel(channelID: "a"))
        state = state.applying(.back, canPresent: true) ?? state
        XCTAssertEqual(state, .none)
        XCTAssertEqual(state.applying(.openRightPanel(channelID: "a"), canPresent: true), .rightPanel(channelID: "a"))
    }

    /// A rail the shell no longer shows must not refuse Select on a plate: reconciling drops it.
    func testStaleRailIsDroppedSoPlateSelectOpensAfterReturningFromTheSidebar() {
        let stuck = LiveTVPrototypeGlassPresentation.rail
        XCTAssertNil(stuck.applying(.openRightPanel(channelID: "a"), canPresent: true), "the validating table refuses it")
        XCTAssertEqual(stuck.dropReason(of: .openRightPanel(channelID: "a"), canPresent: true), "rail-open")
        let live = stuck.reconciled(railIsExpanded: false)
        XCTAssertEqual(live, .none)
        XCTAssertEqual(live.applying(.openRightPanel(channelID: "a"), canPresent: true), .rightPanel(channelID: "a"))
        XCTAssertEqual(stuck.reconciled(railIsExpanded: true), .rail, "a rail that is open stays")
    }

    /// While a sheet, picture or multiview owns the screen the open is refused, and the reason says why.
    func testRefusedOpenNamesItsReason() {
        XCTAssertNil(LiveTVPrototypeGlassPresentation.none.applying(.openRightPanel(channelID: "a"), canPresent: false))
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.none.dropReason(of: .openRightPanel(channelID: "a"), canPresent: false), "cannot-present")
        XCTAssertEqual(LiveTVPrototypeGlassPresentation.quickMenu.dropReason(of: .openRightPanel(channelID: "a"), canPresent: true), "another-presentation-open")
        XCTAssertNil(LiveTVPrototypeGlassPresentation.none.dropReason(of: .reset, canPresent: true), "resetting nothing is quiet")
    }

    /// Guide import: a reset of nothing leaves a following Select working; a panel opened during the import survives a quiet reset.
    func testImportResetBetweenOpenAndSelectLeavesPlateSelectWorking() {
        var state = LiveTVPrototypeGlassPresentation.none
        state = state.applying(.reset, canPresent: true) ?? state
        XCTAssertEqual(state.applying(.openRightPanel(channelID: "a"), canPresent: true), .rightPanel(channelID: "a"))
    }

    /// Set Up My Channels, one Back at a time: the first closes only that panel and shows the tray, the second closes the tray to the
    /// guide. The rail never opens in between, and no step is dropped.
    func testSetUpMyChannelsBackChainClosesOnePanelPerPress() {
        var state = Presentation.none
        func step(_ event: LiveTVPrototypeGlassEvent, _ expected: Presentation, line: UInt = #line) {
            let next = state.applying(event, canPresent: true)
            XCTAssertEqual(next, expected, line: line)
            state = next ?? state
            XCTAssertNotEqual(state, .rail, line: line)
        }
        step(.toggleQuickMenu, .quickMenu)
        step(.openLineup, .lineup)
        step(.back, .quickMenu)
        step(.back, .none)
        XCTAssertNil(Presentation.none.applying(.back, canPresent: true), "a Back with no panel is the shell's, not a panel's")
        XCTAssertFalse(Presentation.none.trapsFocus)
    }

    /// Back and Apply from Set Up My Channels return to the tray with focus on the row that opened it.
    func testTrayReturnsFocusToTheRowThatOpenedAPage() {
        typealias Layout = LiveTVGlassQuickMenuLayout
        XCTAssertEqual(Layout.returnFocusID(afterOpeningEntry: "manage"), "manage")
        XCTAssertEqual(Layout.returnFocusID(afterOpeningEntry: "editFilters"), "editFilters")
        XCTAssertNil(Layout.returnFocusID(afterOpeningEntry: "search"))
    }

    /// Over a playing picture the tray and the context menu leave only the picture and the popup; everything else is unchanged.
    func testGuideChromeHidesOnlyForTrayAndContextOverPlayback() {
        XCTAssertFalse(Presentation.quickMenu.showsGuideChrome(isPlaying: true))
        XCTAssertFalse(Presentation.context(channelID: "a", programID: nil).showsGuideChrome(isPlaying: true))
        XCTAssertTrue(Presentation.quickMenu.showsGuideChrome(isPlaying: false))
        XCTAssertTrue(Presentation.context(channelID: "a", programID: nil).showsGuideChrome(isPlaying: false))
        XCTAssertFalse(Presentation.rightPanel(channelID: "a").showsGuideChrome(isPlaying: true))
        XCTAssertTrue(Presentation.rightPanel(channelID: "a").showsGuideChrome(isPlaying: false))
        XCTAssertTrue(Presentation.none.showsGuideChrome(isPlaying: true))
        XCTAssertTrue(Presentation.lineup.showsGuideChrome(isPlaying: true))
        XCTAssertTrue(Presentation.tagPicker(editing: nil, origin: .tray).showsGuideChrome(isPlaying: true))
        XCTAssertTrue(Presentation.favouriteFilters.showsGuideChrome(isPlaying: true))
        // Multiview is never "playing behind the guide", so it reads as not playing and keeps its chrome.
        XCTAssertTrue(Presentation.quickMenu.showsGuideChrome(isPlaying: false))
    }

    /// The shell sidebar hides exactly when the guide chrome does (popup over playback), and never otherwise.
    func testSidebarHidesExactlyWhenGuideChromeDoes() {
        let all: [Presentation] = [.none, .rail, .quickMenu, .context(channelID: "a", programID: nil), .rightPanel(channelID: "a"),
                                   .lineup, .favouriteFilters, .tagPicker(editing: nil, origin: .tray)]
        for presentation in all {
            for playing in [true, false] {
                XCTAssertEqual(presentation.hidesAppSidebar(isPlaying: playing), !presentation.showsGuideChrome(isPlaying: playing))
            }
        }
        XCTAssertTrue(Presentation.quickMenu.hidesAppSidebar(isPlaying: true))
        XCTAssertFalse(Presentation.quickMenu.hidesAppSidebar(isPlaying: false))
        XCTAssertFalse(Presentation.none.hidesAppSidebar(isPlaying: true))
        XCTAssertFalse(Presentation.rail.hidesAppSidebar(isPlaying: true))
    }
}
