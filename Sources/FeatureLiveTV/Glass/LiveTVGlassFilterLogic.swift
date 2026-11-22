import CoreGraphics
import CoreModels
import FeatureLiveTVCore
import Foundation

// Pure entry, geometry and draft logic for the Favourite Filters page, its hold menu and the tag picker. No SwiftUI, so it compiles
// and is tested on every platform; the views that use it are tvOS-only. Sizes are the mockup's 1080p values (`listPanel`, `tagLayout`).

// MARK: - Favourite Filters page

/// One saved filter as the page lists it.
struct LiveTVGlassFilterRow: Identifiable, Equatable {
    let id: String
    var name: String
    var count: Int
}

enum LiveTVGlassFavouriteFiltersPlan {
    /// The row that opens the picker with no filter to edit.
    static let newRowID = "filters-new"
    static let backRowID = "filters-back"

    /// Mockup: `g.w` is the tray's width (560 at its minimum), padding 14, rows 62, labels 52, radius 45.
    static func metrics(maxHeight: CGFloat) -> LiveTVGlassListMetrics {
        LiveTVGlassListMetrics(
            width: LiveTVGlassQuickMenuLayout.minWidth, padding: 14, rowHeight: 62, labelHeight: 52,
            fontSize: 28, cornerRadius: 45, maxHeight: maxHeight)
    }

    /// The gap between the page and its hold menu.
    static let holdMenuGap: CGFloat = 16

    /// "‹ Favourite Filters", New Favourite Filter, a divider, the filters (count and ›), then the hold hint. The hint is left out
    /// when there is nothing to hold. Kids' Channels has no page in the app, so its label and row are not offered.
    static func items(rows: [LiveTVGlassFilterRow]) -> [LiveTVGlassListItem] {
        var items: [LiveTVGlassListItem] = [
            .title(id: backRowID, text: String(localized: "Favourite Filters")),
            .row(.init(id: newRowID, title: String(localized: "New Favourite Filter"), icon: "plus")),
            .divider(id: "filters")
        ]
        items += rows.map {
            .row(.init(id: $0.id, title: $0.name, count: LiveTVGlassFormatting.shortCount($0.count), isFacet: true))
        }
        if !rows.isEmpty { items.append(.footer(String(localized: "Hold Select to move or delete"))) }
        return items
    }

    /// The drawn size: the page and, to its right, room for the hold menu.
    static func size(rowCount: Int, maxHeight: CGFloat) -> CGSize {
        let metrics = metrics(maxHeight: maxHeight)
        let placeholders = (0..<rowCount).map { LiveTVGlassFilterRow(id: "row-\($0)", name: "", count: 0) }
        return CGSize(
            width: metrics.width + holdMenuGap + LiveTVGlassFilterHoldMenu.metrics.width,
            height: metrics.panelHeight(for: items(rows: placeholders)))
    }

    /// The row to focus once `id` is deleted: the filter now in its place (the last when it was last), else New (mockup `closeFilter`).
    static func focusID(afterDeleting id: String, rows: [LiveTVGlassFilterRow]) -> String {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return newRowID }
        let remaining = rows.filter { $0.id != id }
        return remaining.isEmpty ? newRowID : remaining[min(index, remaining.count - 1)].id
    }

    /// The row to focus when the page opens: the filter just worked on, else the selected one, else New.
    static func initialFocusID(preferred: String?, selected: String?, rows: [LiveTVGlassFilterRow]) -> String {
        for id in [preferred, selected] {
            if let id, rows.contains(where: { $0.id == id }) { return id }
        }
        return newRowID
    }
}

// MARK: - Hold menu

/// Hold Select on a filter: Edit, Move Up, Move Down, Delete, then the delete confirmation (mockup `fxEntries`).
enum LiveTVGlassFilterHoldMenu {
    static let metrics = LiveTVGlassListMetrics(
        width: 380, padding: 14, rowHeight: 62, labelHeight: 52, fontSize: 28, cornerRadius: 44, maxHeight: 1080)
    static let deleteID = "delete"
    static let confirmDeleteID = "confirm-delete"
    static let cancelID = "cancel"

    struct Content: Equatable {
        var title: String?
        var entries: [LiveTVGlassContextEntry]
        var initialFocusID: String
    }

    /// Move Up is not offered on the first filter, Move Down not on the last.
    static func content(index: Int, count: Int) -> Content {
        var entries = [LiveTVGlassContextEntry(id: "edit", title: String(localized: "Edit"), icon: "pencil")]
        if index > 0 { entries.append(.init(id: "up", title: String(localized: "Move Up"), icon: "chevron.up")) }
        if index < count - 1 { entries.append(.init(id: "down", title: String(localized: "Move Down"), icon: "chevron.down")) }
        entries.append(.init(id: deleteID, title: String(localized: "Delete"), icon: "trash", isDestructive: true))
        return Content(title: nil, entries: entries, initialFocusID: "edit")
    }

    /// Delete asks first; Cancel is focused so a stray press does not delete.
    static func confirmation(name: String) -> Content {
        Content(
            title: String(localized: "Delete “\(name)”?"),
            entries: [
                .init(id: confirmDeleteID, title: String(localized: "Delete"), icon: "trash", isDestructive: true),
                .init(id: cancelID, title: String(localized: "Cancel"), icon: "xmark")
            ],
            initialFocusID: cancelID)
    }

    static func height(of content: Content) -> CGFloat {
        2 * metrics.padding + CGFloat(content.entries.count) * metrics.rowHeight + (content.title == nil ? 0 : metrics.labelHeight)
    }

    /// Top of the menu: level with the held row's top (the menu's own title sits above it), kept 24 pt inside the canvas.
    static func top(rowTop: CGFloat, content: Content, canvasHeight: CGFloat) -> CGFloat {
        let wanted = rowTop - metrics.padding - (content.title == nil ? 0 : metrics.labelHeight)
        return min(max(wanted, 24), max(24, canvasHeight - height(of: content) - 24))
    }
}

// MARK: - Tag picker

/// What the picker's note line says: the mockup's `tagSheet` note.
enum LiveTVGlassTagPickerNote: Equatable {
    case pickTags
    case duplicate
    case saveFailed
    case channels(Int)

    var text: String {
        switch self {
        case .pickTags: String(localized: "Pick tags — channels must have them all")
        case .duplicate: String(localized: "Already a favourite filter")
        case .saveFailed: String(localized: "Couldn’t save the filter")
        case let .channels(count):
            count == 1 ? String(localized: "1 channel") : String(localized: "\(count.formatted()) channels")
        }
    }
}

/// The tags being picked, in the order they were picked, and the name typed for the filter. Nothing is saved until Save; Back drops
/// the draft.
struct LiveTVGlassTagPickerDraft: Equatable {
    let editingID: String?
    private(set) var tagIDs: [String]
    /// The typed name; empty while the filter is named after its tags.
    var name: String

    /// A new filter starts with the saved default tags ticked (none until the person saves some); an edited one with its own.
    init(editing filter: LiveTVFavoriteFilter?, defaultTagIDs: [String] = []) {
        editingID = filter?.id
        tagIDs = filter?.tagIDs ?? defaultTagIDs
        name = filter?.name ?? ""
    }

    /// "Restore Default": the draft's tags become exactly these.
    mutating func replaceTags(_ ids: [String]) { tagIDs = ids }

    func isPicked(_ id: String) -> Bool { tagIDs.contains(id) }

    mutating func toggle(_ id: String) {
        if let index = tagIDs.firstIndex(of: id) { tagIDs.remove(at: index) } else { tagIDs.append(id) }
    }

    /// The title says what you are doing; the name is in the box below it.
    var title: String {
        editingID == nil ? String(localized: "New Favourite Filter") : String(localized: "Edit Favourite Filter")
    }

    /// What the name box shows: the typed name, else the tags' own name (drawn grey), else nothing.
    var displayName: String {
        name.isEmpty ? (tagIDs.isEmpty ? "" : LiveTVFilterTagCatalog.name(for: tagIDs)) : name
    }

    func note(check: LiveTVFavoriteFilterState.SaveCheck, matchingCount: Int, saveFailed: Bool) -> LiveTVGlassTagPickerNote {
        if saveFailed { return .saveFailed }
        if tagIDs.isEmpty { return .pickTags }
        if check == .duplicate { return .duplicate }
        return .channels(matchingCount)
    }

    /// Save is on when the draft has tags, differs from what is saved and is not another filter.
    static func canSave(_ check: LiveTVFavoriteFilterState.SaveCheck) -> Bool { check == .ok }
}

/// The picker's geometry, in 1080p units (mockup `tagLayout`). The host draws it scaled by the layout's `uiScale`.
enum LiveTVGlassTagPickerMetrics {
    static let top: CGFloat = 40
    static let maxWidth: CGFloat = 1_180
    static let bottomMargin: CGFloat = 40
    static let rightMargin: CGFloat = 40
    static let padding: CGFloat = 40
    static let cornerRadius: CGFloat = 44
    static let titleSize: CGFloat = 38
    static let titleHeight: CGFloat = 52
    static let noteSize: CGFloat = 26
    static let fontSize: CGFloat = 26
    static let chipHeight: CGFloat = 56
    static let chipPadding: CGFloat = 26
    static let spacing: CGFloat = 14
    /// The name box (mockup `fw`).
    static let nameWidth: CGFloat = 620
    /// Set Up My Channels' search field.
    static let fieldWidth: CGFloat = 520
    static let labelHeight: CGFloat = 50
    static let labelSize: CGFloat = 23
    static let sectionGap: CGFloat = 12
    static let bottomFade: CGFloat = 70

    /// The search row's top inside the panel: padding, the title row and 22.
    static var fixedRowTop: CGFloat { padding + titleHeight + 22 }
    /// Below the search row, 18 before the sections.
    static var fixedHeight: CGFloat { fixedRowTop + chipHeight + 18 }

    /// The panel's left edge is the heading's, less 12 (mockup `LX − 28`); its width is capped by the right margin.
    static func width(leading: CGFloat, canvasWidth: CGFloat, scale: CGFloat) -> CGFloat {
        min(maxWidth * scale, canvasWidth - leading - rightMargin) / scale
    }

    static func height(canvasHeight: CGFloat, scale: CGFloat) -> CGFloat {
        (canvasHeight - top - bottomMargin) / scale
    }
}

/// The tag sheet's geometry, in 1080p units (mockup `tagLayout`, Plozz-like): the whole screen with the same margin all round, its
/// sections as rows. The host draws it scaled by the layout's `uiScale`.
enum LiveTVGlassTagSheetMetrics {
    /// The sheet's margin from every screen edge, in points (mockup `x = y = 40`).
    static let margin: CGFloat = 40
    static let padding: CGFloat = 48
    static let cornerRadius: CGFloat = 44
    static let titleSize: CGFloat = 34
    static let titleHeight: CGFloat = 52
    static let noteSize: CGFloat = 26
    static let fontSize: CGFloat = 26
    static let chipHeight: CGFloat = 56
    static let spacing: CGFloat = 14
    static let buttonPadding: CGFloat = 26
    /// The name box (`fw`) and the search box (`qw`).
    static let nameWidth: CGFloat = 620
    static let searchWidth: CGFloat = 560
    /// A section's name column (`labW`), the gap under a section (`secGap`), and a tag word's padding and gaps (`tpx`, `tgx`, `tgy`).
    static let labelColumn: CGFloat = 250
    static let labelSize: CGFloat = 24
    static let sectionGap: CGFloat = 30
    static let tagPadding: CGFloat = 18
    static let tagGap: CGFloat = 2
    static let bottomFade: CGFloat = 70
    /// The "…" menu: one card of two rows.
    static let moreMenuWidth: CGFloat = 560
    static let moreRowHeight: CGFloat = 92

    /// The name and search row's top: padding, the title row and 22.
    static var fixedRowTop: CGFloat { padding + titleHeight + 22 }
    /// Below that row, 18 before the sections.
    static var fixedHeight: CGFloat { fixedRowTop + chipHeight + 18 }

    /// The sheet's size in units for a canvas in points.
    static func size(canvas: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: (canvas.width - 2 * margin) / scale, height: (canvas.height - 2 * margin) / scale)
    }
}

/// While searching, the letters typed stand out in each tag and the rest of its name steps back (mockup `tagMark`).
enum LiveTVGlassTagHighlight {
    static func parts(of title: String, query: String) -> (before: String, match: String?, after: String) {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let range = title.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return (title, nil, "")
        }
        return (String(title[..<range.lowerBound]), String(title[range]), String(title[range.upperBound...]))
    }
}

/// The "…" menu before Delete and Save: Save as Default and Restore Default, each off when it would do nothing (mockup `tagMoreRows`).
enum LiveTVGlassTagMoreMenu {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case saveDefault, restoreDefault }
        let kind: Kind
        let title: String
        let subtitle: String
        let isEnabled: Bool
        var id: Kind { kind }
    }

    @MainActor
    static func rows(draft: LiveTVGlassTagPickerDraft, model: LiveTVPrototypeModel) -> [Row] {
        rows(
            draftTagIDs: draft.tagIDs, defaultTagIDs: model.favoriteFilterDefaultTagIDs,
            canSave: model.canSaveFavoriteFilterDefault(draft.tagIDs), canRestore: model.canRestoreFavoriteFilterDefault(draft.tagIDs))
    }

    static func rows(draftTagIDs: [String], defaultTagIDs: [String], canSave: Bool, canRestore: Bool) -> [Row] {
        func name(_ ids: [String]) -> String { ids.isEmpty ? String(localized: "No tags") : LiveTVFilterTagCatalog.name(for: ids) }
        return [
            Row(
                kind: .saveDefault, title: String(localized: "Save as Default"),
                subtitle: String(localized: "New filters start with \(name(draftTagIDs))"), isEnabled: canSave),
            Row(
                kind: .restoreDefault, title: String(localized: "Restore Default"),
                subtitle: defaultTagIDs.isEmpty ? String(localized: "No default saved") : name(defaultTagIDs), isEnabled: canRestore)
        ]
    }
}
