#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// "Edit Favourite Filters": New Favourite Filter, then the saved filters with their counts. Select opens the tag picker for
/// that filter; hold Select opens Edit / Move Up / Move Down / Delete beside the row, and Delete asks first. Laid out in 1080p
/// units; the host draws it scaled by the layout's `uiScale`.
struct LiveTVGlassFavouriteFiltersPage: View {
    let model: LiveTVPrototypeModel
    /// The page's top and the canvas height, in units: the page may grow to 30 above the canvas bottom, and its hold menu stays on the canvas.
    let top: CGFloat
    let canvasHeight: CGFloat
    /// The filter just worked on; focus returns to it.
    var preferredFocusID: String?
    let onNew: () -> Void
    let onEdit: (String) -> Void
    let onBack: () -> Void

    private struct Hold: Equatable {
        var filterID: String
        var confirming = false
    }

    @State private var hold: Hold?

    private var rows: [LiveTVGlassFilterRow] {
        model.favoriteFilterList.map {
            LiveTVGlassFilterRow(id: $0.id, name: model.favoriteFilterName($0), count: model.favoriteFilterCount($0))
        }
    }

    var body: some View {
        let rows = rows
        let items = LiveTVGlassFavouriteFiltersPlan.items(rows: rows)
        let metrics = LiveTVGlassFavouriteFiltersPlan.metrics(maxHeight: canvasHeight - top - 30)
        ZStack(alignment: .topLeading) {
            LiveTVGlassListPanel(
                items: items,
                metrics: metrics,
                look: .menu,
                initialFocusID: LiveTVGlassFavouriteFiltersPlan.initialFocusID(
                    preferred: preferredFocusID, selected: model.selectedFavoriteFilterID, rows: rows),
                onSelect: { id in
                    if id == LiveTVGlassFavouriteFiltersPlan.newRowID { onNew() } else { onEdit(id) }
                },
                onHold: { id in
                    if rows.contains(where: { $0.id == id }) { hold = Hold(filterID: id) }
                },
                onBack: onBack
            )
            // The page keeps its place while the menu is up; only the menu takes focus.
            .disabled(hold != nil)
            if let hold, let index = rows.firstIndex(where: { $0.id == hold.filterID }) {
                holdMenu(hold, index: index, rows: rows, items: items, metrics: metrics)
            }
        }
        .frame(
            width: metrics.width + LiveTVGlassFavouriteFiltersPlan.holdMenuGap + LiveTVGlassFilterHoldMenu.metrics.width,
            alignment: .topLeading)
        .onChange(of: rows.map(\.id)) { _, ids in
            // The held filter went away (deleted here or elsewhere).
            if let hold, !ids.contains(hold.filterID) { self.hold = nil }
        }
    }

    private func holdMenu(
        _ hold: Hold, index: Int, rows: [LiveTVGlassFilterRow], items: [LiveTVGlassListItem], metrics: LiveTVGlassListMetrics
    ) -> some View {
        let content = hold.confirming
            ? LiveTVGlassFilterHoldMenu.confirmation(name: rows[index].name)
            : LiveTVGlassFilterHoldMenu.content(index: index, count: rows.count)
        let rowTop = rowTop(of: hold.filterID, items: items, metrics: metrics)
        return LiveTVGlassContextMenu(
            entries: content.entries,
            title: content.title,
            metrics: LiveTVGlassFilterHoldMenu.metrics,
            initialFocusID: content.initialFocusID,
            onSelect: { select($0, hold: hold) },
            onClose: { self.hold = hold.confirming ? Hold(filterID: hold.filterID) : nil }
        )
        .id(hold.confirming)
        .offset(
            x: metrics.width + LiveTVGlassFavouriteFiltersPlan.holdMenuGap,
            y: LiveTVGlassFilterHoldMenu.top(rowTop: top + rowTop, content: content, canvasHeight: canvasHeight) - top)
    }

    /// The held row's top inside the page, as the list draws it (padding, the rows above and the scroll that keeps the row visible).
    private func rowTop(of id: String, items: [LiveTVGlassListItem], metrics: LiveTVGlassListMetrics) -> CGFloat {
        var top = metrics.padding
        for item in items {
            if item.id == id { break }
            top += metrics.height(of: item)
        }
        return top - metrics.scrollOffset(items: items, focusedID: id)
    }

    private func select(_ id: String, hold: Hold) {
        switch id {
        case "edit":
            self.hold = nil
            onEdit(hold.filterID)
        case "up", "down":
            self.hold = nil
            model.moveFavoriteFilter(id: hold.filterID, id == "up" ? .up : .down)
        case LiveTVGlassFilterHoldMenu.deleteID:
            self.hold = Hold(filterID: hold.filterID, confirming: true)
        case LiveTVGlassFilterHoldMenu.confirmDeleteID:
            self.hold = nil
            model.deleteFavoriteFilter(id: hold.filterID)
        default:
            self.hold = Hold(filterID: hold.filterID)
        }
    }
}
#endif
