import CoreModels
import FeatureLiveTVCore
import XCTest
@testable import FeatureLiveTV

final class LiveTVGlassFilterLogicTests: XCTestCase {
    private func rows(_ names: [String]) -> [LiveTVGlassFilterRow] {
        names.enumerated().map { LiveTVGlassFilterRow(id: "f\($0.offset)", name: $0.element, count: 7 - $0.offset) }
    }

    // MARK: Favourite Filters page

    func testPageListsNewRowDividerFiltersAndTheHoldHintInTheMockupsOrder() {
        let items = LiveTVGlassFavouriteFiltersPlan.items(rows: rows(["Canada", "Sports · 4K"]))
        XCTAssertEqual(items.map(\.id), [
            "title-filters-back", "filters-new", "divider-filters", "f0", "f1", "footer-Hold Select to move or delete"])
        guard case let .row(first) = items[3], case let .row(new) = items[1] else { return XCTFail("rows") }
        XCTAssertEqual(first.title, "Canada")
        XCTAssertEqual(first.count, "7")
        XCTAssertTrue(first.isFacet, "each filter ends in ›")
        XCTAssertEqual(new.icon, "plus")
        XCTAssertNil(new.count)
    }

    func testPageWithoutFiltersOffersOnlyNewAndNoHoldHint() {
        let items = LiveTVGlassFavouriteFiltersPlan.items(rows: [])
        XCTAssertEqual(items.map(\.id), ["title-filters-back", "filters-new", "divider-filters"])
        XCTAssertFalse(items.contains { if case .footer = $0 { true } else { false } })
    }

    func testPageDoesNotOfferKidsChannels() {
        let texts = LiveTVGlassFavouriteFiltersPlan.items(rows: rows(["Canada"])).compactMap { item -> String? in
            switch item {
            case let .row(row): row.title
            case let .label(text), let .footer(text): text
            default: nil
            }
        }
        XCTAssertFalse(texts.contains { $0.contains("Kids") }, "no Kids' Channels page exists yet")
    }

    /// The mockup's page for Canada and Sports · 4K: 14 + title 62 + new 62 + divider 25 + 2 × 62 + hint 52 + 14.
    func testPageSizeMatchesTheReferenceRender() {
        let size = LiveTVGlassFavouriteFiltersPlan.size(rowCount: 2, maxHeight: 1_000)
        XCTAssertEqual(size.height, 14 + 62 + 62 + 25 + 124 + 52 + 14)
        XCTAssertEqual(size.width, LiveTVGlassQuickMenuLayout.minWidth + 16 + 380, "the page is as wide as the tray")
    }

    func testPageScrollsInsteadOfGrowingPastTheCanvas() {
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.size(rowCount: 60, maxHeight: 700).height, 700)
    }

    func testPageOpensOnTheFilterJustWorkedOnThenTheSelectedOneThenNew() {
        let rows = rows(["A", "B", "C"])
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.initialFocusID(preferred: "f2", selected: "f1", rows: rows), "f2")
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.initialFocusID(preferred: "gone", selected: "f1", rows: rows), "f1")
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.initialFocusID(preferred: nil, selected: nil, rows: rows), "filters-new")
    }

    // MARK: Hold menu

    func testHoldMenuOmitsMoveUpOnTheFirstAndMoveDownOnTheLast() {
        func ids(_ index: Int, _ count: Int) -> [String] { LiveTVGlassFilterHoldMenu.content(index: index, count: count).entries.map(\.id) }
        XCTAssertEqual(ids(0, 3), ["edit", "down", "delete"])
        XCTAssertEqual(ids(1, 3), ["edit", "up", "down", "delete"])
        XCTAssertEqual(ids(2, 3), ["edit", "up", "delete"])
        XCTAssertEqual(ids(0, 1), ["edit", "delete"])
    }

    func testDeleteIsDestructiveAndConfirmationFocusesCancel() {
        let menu = LiveTVGlassFilterHoldMenu.content(index: 0, count: 2)
        XCTAssertEqual(menu.entries.last?.isDestructive, true)
        let confirm = LiveTVGlassFilterHoldMenu.confirmation(name: "Sports · 4K")
        XCTAssertEqual(confirm.title, "Delete “Sports · 4K”?")
        XCTAssertEqual(confirm.entries.map(\.id), ["confirm-delete", "cancel"])
        XCTAssertEqual(confirm.initialFocusID, "cancel", "a stray press must not delete")
    }

    func testHoldMenuSitsLevelWithTheHeldRowAndStaysOnTheCanvas() {
        let plain = LiveTVGlassFilterHoldMenu.content(index: 1, count: 3)
        XCTAssertEqual(LiveTVGlassFilterHoldMenu.top(rowTop: 300, content: plain, canvasHeight: 1_080), 286)
        XCTAssertEqual(LiveTVGlassFilterHoldMenu.top(rowTop: 5, content: plain, canvasHeight: 1_080), 24)
        let bottom = LiveTVGlassFilterHoldMenu.top(rowTop: 1_050, content: plain, canvasHeight: 1_080)
        XCTAssertEqual(bottom + LiveTVGlassFilterHoldMenu.height(of: plain), 1_080 - 24)
        let confirm = LiveTVGlassFilterHoldMenu.confirmation(name: "x")
        XCTAssertEqual(LiveTVGlassFilterHoldMenu.top(rowTop: 300, content: confirm, canvasHeight: 1_080), 300 - 14 - 52,
                       "the confirmation's title takes the room above the row")
    }

    /// (Indices count the focusable rows: Favourite Filters, New, then the filters.)
    /// Deleting a filter leaves focus on its neighbour (the last when it was last), or on New when none is left; from the page's
    /// hold menu the list does the same.
    func testFocusAfterDeletingAFilterGoesToItsNeighbour() {
        let rows = ["a", "b", "c"].map { LiveTVGlassFilterRow(id: $0, name: $0, count: 1) }
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.focusID(afterDeleting: "a", rows: rows), "b")
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.focusID(afterDeleting: "b", rows: rows), "c")
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.focusID(afterDeleting: "c", rows: rows), "b")
        XCTAssertEqual(LiveTVGlassFavouriteFiltersPlan.focusID(afterDeleting: "a", rows: [rows[0]]), LiveTVGlassFavouriteFiltersPlan.newRowID)
        let items = LiveTVGlassFavouriteFiltersPlan.items(rows: [rows[0], rows[2]])
        XCTAssertEqual(LiveTVGlassListPanel.focusID(returningTo: "a", index: 2, items: items), "a")
        XCTAssertEqual(LiveTVGlassListPanel.focusID(returningTo: "b", index: 3, items: items), "c", "b is gone: its place is c's")
        XCTAssertEqual(LiveTVGlassListPanel.focusID(returningTo: "c", index: 4, items: items), "c")
        let last = LiveTVGlassFavouriteFiltersPlan.items(rows: [rows[0]])
        XCTAssertEqual(LiveTVGlassListPanel.focusID(returningTo: "c", index: 4, items: last), "a", "the last row went: the one before it")
    }

    // MARK: Tag picker draft

    func testDraftKeepsPickOrderAndTogglesOff() {
        var draft = LiveTVGlassTagPickerDraft(editing: nil)
        XCTAssertEqual(draft.title, "New Favourite Filter")
        draft.toggle("sports")
        draft.toggle("4k")
        XCTAssertEqual(draft.tagIDs, ["sports", "4k"])
        XCTAssertEqual(draft.title, "New Favourite Filter", "the title says what you are doing, not the name")
        XCTAssertEqual(draft.displayName, "Sports · 4K", "the name box shows the tags' name until one is typed")
        draft.name = "Match day"
        XCTAssertEqual(draft.displayName, "Match day")
        draft.toggle("sports")
        XCTAssertEqual(draft.tagIDs, ["4k"])
        XCTAssertFalse(draft.isPicked("sports"))
    }

    func testDraftStartsFromTheFilterBeingEdited() {
        let draft = LiveTVGlassTagPickerDraft(editing: LiveTVFavoriteFilter(id: "x", tagIDs: ["canada", "news"]))
        XCTAssertEqual(draft.editingID, "x")
        XCTAssertEqual(draft.tagIDs, ["canada", "news"])
        XCTAssertEqual(draft.title, "Edit Favourite Filter")
        XCTAssertEqual(draft.displayName, "Canada · News")
        let named = LiveTVGlassTagPickerDraft(editing: LiveTVFavoriteFilter(id: "y", tagIDs: ["canada"], name: "Home"))
        XCTAssertEqual(named.name, "Home")
        XCTAssertEqual(named.displayName, "Home")
    }

    func testNoteFollowsTheMockup() {
        var draft = LiveTVGlassTagPickerDraft(editing: nil)
        XCTAssertEqual(draft.note(check: .noTags, matchingCount: 0, saveFailed: false), .pickTags)
        draft.toggle("sports")
        XCTAssertEqual(draft.note(check: .ok, matchingCount: 1, saveFailed: false).text, "1 channel")
        XCTAssertEqual(draft.note(check: .ok, matchingCount: 1_204, saveFailed: false), .channels(1_204))
        XCTAssertEqual(draft.note(check: .duplicate, matchingCount: 5, saveFailed: false), .duplicate)
        XCTAssertEqual(draft.note(check: .ok, matchingCount: 5, saveFailed: true), .saveFailed)
    }

    func testSaveIsOnlyOfferedWhenTheModelAcceptsTheDraft() {
        XCTAssertTrue(LiveTVGlassTagPickerDraft.canSave(.ok))
        for check in [LiveTVFavoriteFilterState.SaveCheck.noTags, .duplicate, .unchanged] {
            XCTAssertFalse(LiveTVGlassTagPickerDraft.canSave(check), "\(check)")
        }
    }

    func testPickerGeometryFollowsTheMockup() {
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.fixedRowTop, 114)
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.fixedHeight, 188)
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.width(leading: 118, canvasWidth: 1_920, scale: 1), 1_180)
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.height(canvasHeight: 1_080, scale: 1), 1_000)
        // At 4K the unit width is what 1180 × 0.9 points hold, and the height is the canvas less the margins in units.
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.width(leading: 100, canvasWidth: 1_000, scale: 0.9), (1_000 - 100 - 40) / 0.9, accuracy: 0.001)
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.width(leading: 100, canvasWidth: 1_920, scale: 0.9), 1_180, accuracy: 0.001)
        XCTAssertEqual(LiveTVGlassTagPickerMetrics.height(canvasHeight: 1_080, scale: 0.9), 1_000 / 0.9, accuracy: 0.001)
    }

    // MARK: Plozz-like tag sheet

    func testTagSheetGeometryFollowsTheMockup() {
        typealias Sheet = LiveTVGlassTagSheetMetrics
        XCTAssertEqual(Sheet.fixedRowTop, 48 + 52 + 22)
        XCTAssertEqual(Sheet.fixedHeight, 48 + 52 + 22 + 56 + 18)
        XCTAssertEqual([Sheet.labelColumn, Sheet.sectionGap, Sheet.tagPadding, Sheet.tagGap, Sheet.searchWidth], [250, 30, 18, 2, 560])
        XCTAssertEqual(Sheet.size(canvas: CGSize(width: 1_920, height: 1_080), scale: 1), CGSize(width: 1_840, height: 1_000))
        let uhd = Sheet.size(canvas: CGSize(width: 1_920, height: 1_080), scale: 0.9)
        XCTAssertEqual(uhd.width, 1_840 / 0.9, accuracy: 0.001)
        XCTAssertEqual(uhd.height, 1_000 / 0.9, accuracy: 0.001)
    }

    func testSearchHighlightSplitsAtTheTypedLetters() {
        let parts = LiveTVGlassTagHighlight.parts(of: "United States", query: " ted ")
        XCTAssertEqual(parts.before, "Uni")
        XCTAssertEqual(parts.match, "ted")
        XCTAssertEqual(parts.after, " States")
        XCTAssertNil(LiveTVGlassTagHighlight.parts(of: "Canada", query: "xyz").match)
        XCTAssertNil(LiveTVGlassTagHighlight.parts(of: "Canada", query: "").match)
    }

    func testNewDraftStartsWithTheDefaultTagsAndAnEditedOneKeepsItsOwn() {
        XCTAssertEqual(LiveTVGlassTagPickerDraft(editing: nil, defaultTagIDs: ["english", "canada"]).tagIDs, ["english", "canada"])
        XCTAssertEqual(LiveTVGlassTagPickerDraft(editing: nil).tagIDs, [], "no default until one is saved")
        let filter = LiveTVFavoriteFilter(tagIDs: ["sports"])
        XCTAssertEqual(LiveTVGlassTagPickerDraft(editing: filter, defaultTagIDs: ["english"]).tagIDs, ["sports"])
        var draft = LiveTVGlassTagPickerDraft(editing: nil)
        draft.replaceTags(["news"])
        XCTAssertEqual(draft.tagIDs, ["news"])
    }

    func testMoreMenuRowsSaySaveAndRestoreWithTheirStates() {
        let rows = LiveTVGlassTagMoreMenu.rows(
            draftTagIDs: ["english", "canada", "united-states"], defaultTagIDs: [], canSave: true, canRestore: false)
        XCTAssertEqual(rows.map(\.kind), [.saveDefault, .restoreDefault])
        XCTAssertEqual(rows[0].title, "Save as Default")
        XCTAssertEqual(rows[0].subtitle, "New filters start with English · Canada or US")
        XCTAssertTrue(rows[0].isEnabled)
        XCTAssertEqual(rows[1].title, "Restore Default")
        XCTAssertEqual(rows[1].subtitle, "No default saved")
        XCTAssertFalse(rows[1].isEnabled)
        let empty = LiveTVGlassTagMoreMenu.rows(draftTagIDs: [], defaultTagIDs: ["sports"], canSave: false, canRestore: true)
        XCTAssertEqual(empty[0].subtitle, "New filters start with No tags")
        XCTAssertEqual(empty[1].subtitle, "Sports")
    }
}
