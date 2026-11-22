import CoreGraphics
import CoreUI
import XCTest
@testable import FeatureLiveTV

final class GlassPanelLogicTests: XCTestCase {
    // MARK: Quick menu

    private func entry(
        _ id: String, _ kind: LiveTVGlassQuickMenuKind, selected: Bool = false
    ) -> LiveTVGlassQuickMenuEntry {
        LiveTVGlassQuickMenuEntry(id: id, kind: kind, title: id, isSelected: selected)
    }

    /// The mockup's `#v=browse&r=1080&m=filter` menu, measured from `listPanel` (native): pad 14, large rows 70, "Edit" row 62,
    /// divider 25, tools row 74, tools 60 wide at pitch 70.
    func testMenuLayoutMatchesMockupGeometry() {
        let layout = LiveTVGlassQuickMenuLayout(
            entries: [
                entry("all", .myChannels), entry("canada", .favoriteFilter, selected: true), entry("sports", .favoriteFilter),
                entry("edit", .facet), entry("search", .tool), entry("mv", .tool), entry("manage", .tool)
            ],
            headingWidth: 300, caption: "Updated 6:41 PM")
        XCTAssertEqual(layout.frames["all"], CGRect(x: 14, y: 14, width: layout.width - 28, height: 70))
        XCTAssertEqual(layout.frames["canada"]?.minY, 84)
        XCTAssertEqual(layout.frames["sports"]?.minY, 154)
        XCTAssertEqual(layout.frames["edit"]?.minY, 224)
        XCTAssertEqual(layout.frames["edit"]?.height, 62)
        // Divider centred in its 25 pt band; the tools row follows it.
        let dividerWidth: CGFloat = layout.width - 28 - 48
        XCTAssertEqual(layout.dividerFrame, CGRect(x: 38, y: 299, width: dividerWidth, height: 1))
        XCTAssertEqual(layout.frames["search"], CGRect(x: 27, y: 318, width: 60, height: 60))
        XCTAssertEqual(layout.frames["mv"]?.minX, 97)
        XCTAssertEqual(layout.frames["manage"]?.minX, 167)
        let expectedHeight: CGFloat = 14 + 210 + 62 + 25 + 74 + 14
        XCTAssertEqual(layout.contentHeight, expectedHeight)
        XCTAssertGreaterThanOrEqual(layout.width, 520)
        XCTAssertEqual(layout.initialFocusID, "canada")
        XCTAssertEqual(layout.anchorID, "canada")
        XCTAssertEqual(layout.entries.map(\.id), ["all", "canada", "sports", "edit", "search", "mv", "manage"])
    }

    /// The ticked large row opens exactly over the heading pill's centre.
    func testMenuOpensWithTheTickedRowCentredOnTheHeading() {
        let layout = LiveTVGlassQuickMenuLayout(
            entries: [entry("all", .myChannels), entry("canada", .favoriteFilter, selected: true), entry("edit", .facet)],
            headingWidth: 300)
        XCTAssertEqual(layout.top(headingCenter: 319.5), (319.5 - 119).rounded())
        let none = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels), entry("edit", .facet)], headingWidth: 0)
        XCTAssertEqual(none.anchorID, "all", "nothing ticked: the first row opens over the heading")
        XCTAssertEqual(none.top(headingCenter: 319.5), (319.5 - 49).rounded())
        XCTAssertEqual(none.top(headingCenter: 10), 24, "never above the top margin")
    }

    func testThereIsNoHeadingRowAboveMyChannels() {
        let layout = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels)], headingWidth: 0)
        XCTAssertEqual(layout.frames["all"]?.minY, 14, "My Channels is the first row of the panel; nothing above it")
        XCTAssertEqual(layout.contentHeight, 98)
    }

    func testMenuScrollsOnlyWhenTheScreenLeavesLessThanItsContent() {
        let favourites = (0..<12).map { entry("f\($0)", .favoriteFilter) }
        let layout = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels)] + favourites + [entry("edit", .facet)], headingWidth: 0)
        XCTAssertEqual(layout.height(available: 5_000), layout.contentHeight)
        XCTAssertEqual(layout.height(available: 500), 500)
        XCTAssertEqual(layout.scrollOffset(focusedID: "f0", height: layout.contentHeight), 0)
        XCTAssertEqual(layout.scrollOffset(focusedID: "all", height: 500), 0)
        XCTAssertGreaterThan(layout.scrollOffset(focusedID: "f11", height: 500), 0)
        XCTAssertLessThanOrEqual(layout.scrollOffset(focusedID: "edit", height: 500), layout.contentHeight - 500)
    }

    func testMyChannelsCountsOfTheMergedTotalOnlyWhileFocused() {
        let partial = LiveTVGlassQuickMenuEntry.myChannels(
            id: "all", title: "My Channels", count: 16_300, mergedTotal: 34_500, showsTotal: true, isSelected: true)
        XCTAssertEqual(partial.countText(isFocused: false), "16.3k")
        XCTAssertEqual(partial.countText(isFocused: true), "16.3k of 34.5k")
        XCTAssertEqual(partial.kind, .myChannels)
    }

    func testMyChannelsHasNoTotalWhenEverythingIsLoadedOrTheViewIsRestricted() {
        let everything = LiveTVGlassQuickMenuEntry.myChannels(
            id: "all", title: "My Channels", count: 34_500, mergedTotal: 34_500, showsTotal: true, isSelected: false)
        XCTAssertEqual(everything.countText(isFocused: true), "34.5k")
        let unknown = LiveTVGlassQuickMenuEntry.myChannels(
            id: "all", title: "My Channels", count: 900, mergedTotal: 0, showsTotal: true, isSelected: false)
        XCTAssertEqual(unknown.countText(isFocused: true), "900")
        // A Kids profile, or a view of a single source, never shows "of".
        let restricted = LiveTVGlassQuickMenuEntry.myChannels(
            id: "all", title: "My Channels", count: 100, mergedTotal: 34_500, showsTotal: false, isSelected: false)
        XCTAssertEqual(restricted.countText(isFocused: true), "100")
    }

    func testUpdatedCaptionIsTheTimeToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = LiveTVGlassQuickMenuCaption.updated(now.addingTimeInterval(-600), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(text?.hasPrefix("Updated ") == true && text?.hasSuffix("PM") == true || text?.hasSuffix("AM") == true, "\(text ?? "nil")")
        XCTAssertFalse(text?.contains(",") ?? true)
        let older = LiveTVGlassQuickMenuCaption.updated(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(older?.contains(",") == true)
        XCTAssertNil(LiveTVGlassQuickMenuCaption.updated(nil))
    }

    func testDividerSitsBetweenTheRowsAndTheTools() {
        let layout = LiveTVGlassQuickMenuLayout(
            entries: [entry("all", .myChannels), entry("edit", .facet), entry("search", .tool)], headingWidth: 0)
        let divider = try? XCTUnwrap(layout.dividerFrame)
        XCTAssertEqual(divider?.height, 1)
        XCTAssertGreaterThan(divider?.minY ?? 0, layout.frames["edit"]?.maxY ?? .infinity)
        XCTAssertLessThan(divider?.minY ?? .infinity, layout.frames["search"]?.minY ?? 0)
        XCTAssertNil(LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels)], headingWidth: 0).dividerFrame)
    }

    func testAWideHeadingWidensTheSheetAndTheToolsRowNeedsItsCaption() {
        let wide = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels)], headingWidth: 700)
        XCTAssertEqual(wide.width, 728)
        let narrow = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels), entry("search", .tool)], headingWidth: 0)
        XCTAssertEqual(narrow.width, 520)
        let long = LiveTVGlassQuickMenuLayout(
            entries: [entry("all", .myChannels), entry("search", .tool), entry("mv", .tool), entry("manage", .tool)], headingWidth: 0,
            caption: "Updated Nov 3, 6:41 PM, a rather long caption for the tools row")
        XCTAssertGreaterThan(long.width, 520)
    }

    func testNewFilterIsALargeRowOnlyWithoutFavoriteFilters() {
        let without = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels), entry("new", .newFilter)], headingWidth: 0)
        XCTAssertEqual(without.frames["new"]?.height, 70)
        XCTAssertEqual(without.frames["new"]?.minY, 84)
        let with = LiveTVGlassQuickMenuLayout(entries: [entry("f", .favoriteFilter), entry("new", .newFilter)], headingWidth: 0)
        XCTAssertNil(with.frames["new"], "with favourites the menu offers Edit Favourite Filters instead")
    }

    func testUnsuppliedEntriesAreNotDrawn() {
        let layout = LiveTVGlassQuickMenuLayout(entries: [entry("all", .myChannels), entry("search", .tool)], headingWidth: 0)
        XCTAssertEqual(Set(layout.frames.keys), ["all", "search"])
        XCTAssertEqual(layout.entries.map(\.id), ["all", "search"])
        XCTAssertEqual(layout.contentHeight, 197)
    }

    // MARK: List panel

    func testListPanelHeightAndScrollOffset() {
        let metrics = LiveTVGlassListMetrics(
            width: 560, padding: 14, rowHeight: 62, labelHeight: 52,
            fontSize: 28, cornerRadius: 40, maxHeight: 400
        )
        let rows = (0..<12).map { LiveTVGlassListItem.row(.init(id: "r\($0)", title: "r\($0)")) }
        XCTAssertEqual(metrics.panelHeight(for: Array(rows.prefix(2))), 2 * 62 + 28)
        XCTAssertEqual(metrics.panelHeight(for: rows), 400)
        XCTAssertEqual(metrics.scrollOffset(items: rows, focusedID: "r0"), 0)
        // Visible window is 372; row 11 ends at 744; wants 744 + 124 - 372 capped to total - visible = 372.
        XCTAssertEqual(metrics.scrollOffset(items: rows, focusedID: "r11"), 372)
        XCTAssertEqual(metrics.scrollOffset(items: Array(rows.prefix(3)), focusedID: "r2"), 0)
    }

    func testListItemHeightsAndFocusability() {
        let metrics = LiveTVGlassListMetrics.contextMenu
        XCTAssertEqual(metrics.height(of: .gap(id: "g")), 18)
        XCTAssertEqual(metrics.height(of: .divider(id: "d")), 25)
        XCTAssertEqual(metrics.height(of: .label("x")), 52)
        XCTAssertEqual(metrics.height(of: .spacer(70)), 70)
        XCTAssertTrue(LiveTVGlassListItem.title(id: "t", text: "t").isFocusable)
        XCTAssertFalse(LiveTVGlassListItem.footer("f").isFocusable)
    }

    // MARK: Context menu

    private let canvas = CGSize(width: 1920, height: 1080)

    func testContextMenuHeight() {
        XCTAssertEqual(LiveTVGlassContextMenuGeometry.height(entryCount: 5), 338)
    }

    func testContextMenuOpensBelowCellWhenItFits() {
        let cell = CGRect(x: 600, y: 424, width: 400, height: 82)
        let origin = LiveTVGlassContextMenuGeometry.origin(forCellFrame: cell, canvas: canvas, entryCount: 5)
        XCTAssertEqual(origin, CGPoint(x: 612, y: 520))
    }

    func testContextMenuOpensAboveCellNearBottom() {
        let cell = CGRect(x: 600, y: 900, width: 400, height: 82)
        let origin = LiveTVGlassContextMenuGeometry.origin(forCellFrame: cell, canvas: canvas, entryCount: 5)
        XCTAssertEqual(origin.y, 900 - 338 - 14)
    }

    func testContextMenuClampsHorizontally() {
        let left = LiveTVGlassContextMenuGeometry.origin(
            forCellFrame: CGRect(x: 0, y: 100, width: 300, height: 82), canvas: canvas, entryCount: 4
        )
        XCTAssertEqual(left.x, 144)
        let right = LiveTVGlassContextMenuGeometry.origin(
            forCellFrame: CGRect(x: 1700, y: 100, width: 300, height: 82), canvas: canvas, entryCount: 4
        )
        XCTAssertEqual(right.x, 1920 - 80 - 500)
    }

    // MARK: Channel panel

    private func programs(_ count: Int, tomorrowFrom: Int? = nil) -> [LiveTVGlassUpcomingProgram] {
        (0..<count).map { index in
            LiveTVGlassUpcomingProgram(
                id: "p\(index)", title: "P\(index)", timeText: "\(index):00",
                startsTomorrow: tomorrowFrom.map { index >= $0 } ?? false
            )
        }
    }

    func testUpcomingIsCappedAtSix() {
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(programs(9), room: 10_000)
        XCTAssertEqual(rows.count, 6)
    }

    func testUpcomingDropsRowsThatDoNotFit() {
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(programs(6), room: 54 * 3 + 10)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(LiveTVGlassChannelPanelLayout.upcomingRows(programs(3), room: 53).isEmpty)
    }

    func testTomorrowSeparatorAppearsOnceBeforeFirstNextDayProgramme() {
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(programs(5, tomorrowFrom: 2), room: 10_000)
        XCTAssertEqual(rows.map(\.id), ["p0", "p1", "separator", "p2", "p3", "p4"])
    }

    func testSeparatorCostCountsTowardRoom() {
        let items = programs(4, tomorrowFrom: 1)
        // p0 (54) + separator (42) + p1 (54) = 150 fits; p2 would need 204.
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(items, room: 150)
        XCTAssertEqual(rows.map(\.id), ["p0", "separator", "p1"])
    }

    func testPanelGeometryAndRoom() {
        XCTAssertEqual(LiveTVGlassChannelPanelLayout.originX(canvasWidth: 1920), 1280)
        XCTAssertEqual(LiveTVGlassChannelPanelLayout.maxHeight(canvasHeight: 1080), 1000)
        typealias Layout = LiveTVGlassChannelPanelLayout
        let withProgram = Layout.upcomingRoom(canvasHeight: 1080, content: .init(titleLines: 1))
        let withoutProgram = Layout.upcomingRoom(canvasHeight: 1080, content: .init())
        XCTAssertGreaterThan(withoutProgram, withProgram)
        let withProviders = Layout.upcomingRoom(canvasHeight: 1080, content: .init(hasProviders: true, titleLines: 1))
        XCTAssertLessThan(withProviders, withProgram)
    }

    // MARK: Reserved height follows the content actually drawn

    private func rows(_ content: LiveTVGlassChannelPanelLayout.Content, canvasHeight: CGFloat = 1080, programs count: Int = 6) -> Int {
        let room = LiveTVGlassChannelPanelLayout.upcomingRoom(canvasHeight: canvasHeight, content: content)
        return LiveTVGlassChannelPanelLayout.upcomingRows(programs(count), room: room).count
    }

    func testNoDescriptionFitsFiveOrMoreRowsAt1080() {
        XCTAssertGreaterThanOrEqual(rows(.init(titleLines: 1)), 5)
        XCTAssertGreaterThanOrEqual(rows(.init(titleLines: 2)), 5)
        XCTAssertGreaterThanOrEqual(rows(.init(hasTags: true, titleLines: 2)), 5)
    }

    func testThreeLineDescriptionStillFitsThreeRows() {
        XCTAssertGreaterThanOrEqual(rows(.init(hasTags: true, titleLines: 1, descriptionLines: 3)), 3)
        XCTAssertGreaterThanOrEqual(rows(.init(titleLines: 1, descriptionLines: 3)), 4)
        // Everything at once (two-line title, provider line, tags, three-line description) leaves room for one row, never none.
        XCTAssertGreaterThanOrEqual(rows(.init(hasProviders: true, hasTags: true, titleLines: 2, descriptionLines: 3)), 1)
    }

    func testMoreContentNeverGivesMoreRoom() {
        typealias C = LiveTVGlassChannelPanelLayout.Content
        let room = { (content: C) in LiveTVGlassChannelPanelLayout.upcomingRoom(canvasHeight: 1080, content: content) }
        XCTAssertGreaterThan(room(.init(titleLines: 1)), room(.init(titleLines: 2)))
        XCTAssertGreaterThan(room(.init(titleLines: 1)), room(.init(titleLines: 1, descriptionLines: 1)))
        XCTAssertGreaterThan(room(.init(titleLines: 1, descriptionLines: 1)), room(.init(titleLines: 1, descriptionLines: 3)))
        XCTAssertGreaterThan(room(.init(titleLines: 1)), room(.init(hasTags: true, titleLines: 1)))
    }

    func testLineCountsAreMeasuredAtThePanelWidth() {
        typealias Layout = LiveTVGlassChannelPanelLayout
        XCTAssertEqual(Layout.lineCount("The Rookie", fontSize: 52, bold: true, limit: 2), 1)
        XCTAssertEqual(
            Layout.lineCount("The Rookie: Feds and the Long Road Home Again", fontSize: 52, bold: true, limit: 2), 2)
        XCTAssertEqual(Layout.lineCount(String(repeating: "word ", count: 80), fontSize: 29, bold: false, limit: 3), 3)
        let none = Layout.content(title: "The Rookie", description: nil, hasMatchupCard: false, hasProviders: false, hasTags: false)
        XCTAssertEqual(none.descriptionLines, 0)
        XCTAssertEqual(none.titleLines, 1)
        XCTAssertEqual(Layout.content(title: nil, description: nil, hasMatchupCard: false, hasProviders: false, hasTags: false).titleLines, 0)
    }

    func testConsecutiveSameTitleProgrammesMergeKeepingTheFirstStart() {
        func program(_ id: String, _ title: String, _ time: String) -> LiveTVGlassUpcomingProgram {
            .init(id: id, title: title, timeText: time, startsTomorrow: false)
        }
        let merged = LiveTVGlassChannelPanelLayout.mergingConsecutiveTitles([
            program("a", "Kourtney & Khloé Take Miami", "6:00"), program("b", "Kourtney & Khloé Take Miami", "6:30"),
            program("c", "E! News", "7:00"), program("d", "Kourtney & Khloé Take Miami", "7:30")
        ])
        XCTAssertEqual(merged.map(\.id), ["a", "c", "d"], "only consecutive repeats merge")
        XCTAssertEqual(merged.first?.timeText, "6:00")
    }

    func testRowsComeFromBeyondAGuideWindow() {
        // Eight distinct programmes spread over two days: the panel takes the next six, not those in a 3-hour window.
        let items = (0..<8).map { LiveTVGlassUpcomingProgram(id: "p\($0)", title: "T\($0)", timeText: "\($0)", startsTomorrow: $0 >= 5) }
        let rows = LiveTVGlassChannelPanelLayout.upcomingRows(
            LiveTVGlassChannelPanelLayout.mergingConsecutiveTitles(items), room: 10_000)
        XCTAssertEqual(rows.map(\.id), ["p0", "p1", "p2", "p3", "p4", "separator", "p5"])
    }

    /// PANEL-1 at both sizes: the Upcoming room is measured in the panel's scaled units, so the drawn panel (header, now block, actions,
    /// label and the rows kept) never exceeds the canvas less its margins, and 4K keeps at least as many rows as 1080p.
    func testUpcomingRoomHoldsAtBothSizes() {
        typealias Panel = LiveTVGlassChannelPanelLayout
        let content = Panel.Content(hasMatchupCard: false, hasProviders: false, hasTags: true, titleLines: 2, descriptionLines: 3)
        var kept: [Int] = []
        for layout in [LiveTVGlassLayout.hd1080, .uhd4K] {
            let room = Panel.upcomingRoom(canvasHeight: 1080, content: content, layout: layout)
            let rows = Panel.upcomingRows(programs(6, tomorrowFrom: 3), room: room)
            let used = rows.reduce(CGFloat(0)) { total, row in
                total + (row == .separator ? Panel.separatorHeight : Panel.upcomingRowHeight)
            }
            let drawn = (2 * Panel.padding + Panel.reservedHeight(content) + Panel.sectionSpacing + Panel.labelHeight + used) * layout.uiScale
            XCTAssertLessThanOrEqual(drawn, 1080 - 2 * layout.panelMargin + 0.001, "\(layout.uiScale)")
            XCTAssertEqual(room * layout.uiScale, 1080 - 2 * layout.panelMargin
                - (2 * Panel.padding + Panel.reservedHeight(content) + Panel.sectionSpacing + Panel.labelHeight) * layout.uiScale, accuracy: 0.001)
            kept.append(rows.count)
        }
        XCTAssertGreaterThanOrEqual(kept[1], kept[0])
        XCTAssertEqual(Panel.unitWidth(.hd1080), 600)
        XCTAssertEqual(Panel.unitWidth(.uhd4K) * LiveTVGlassLayout.uhd4K.uiScale, 570, accuracy: 0.001)
    }

    /// An event's title takes a third line before it would lose a word; a linear title does too.
    func testTitleWrapsInsteadOfTruncatingAndEventHeaderHasNoLogoBlock() {
        typealias Layout = LiveTVGlassChannelPanelLayout
        let title = "2025 STIHL Timbersports: Men's Singles Championship Final Round"
        let event = Layout.content(title: title, description: nil, hasMatchupCard: false, hasProviders: false, hasTags: false, isEvent: true, hasEventService: true)
        let linear = Layout.content(title: title, description: nil, hasMatchupCard: false, hasProviders: false, hasTags: false)
        XCTAssertEqual(event.titleLines, 4, "the whole title wraps; none is cut at two or three lines")
        XCTAssertEqual(linear.titleLines, 4)
        XCTAssertLessThan(Layout.reservedHeight(.init(isEvent: true, hasEventService: true, titleLines: 1)), Layout.reservedHeight(.init(titleLines: 1)))
        XCTAssertEqual(Layout.reservedHeight(.init(isEvent: true, hasEventService: false, titleLines: 1)) + 88,
                       Layout.reservedHeight(.init(isEvent: true, hasEventService: true, titleLines: 1)))
    }

    /// The mockup headlines the programme on now and lists the ones after it; with none airing, the next is the headline and the list
    /// starts after it, so no programme is shown twice.
    func testHeadlineAndLaterFollowTheMockupsUpcomingSplit() {
        typealias Layout = LiveTVGlassChannelPanelLayout
        let airing = Layout.headlineAndLater(current: "News", next: ["Quiz", "Movie"])
        XCTAssertEqual(airing.headline, "News")
        XCTAssertEqual(airing.later, ["Quiz", "Movie"])
        let gap = Layout.headlineAndLater(current: String?.none, next: ["Quiz", "Movie"])
        XCTAssertEqual(gap.headline, "Quiz")
        XCTAssertEqual(gap.later, ["Movie"])
        let empty = Layout.headlineAndLater(current: String?.none, next: [String]())
        XCTAssertNil(empty.headline)
        XCTAssertTrue(empty.later.isEmpty)
    }
}
