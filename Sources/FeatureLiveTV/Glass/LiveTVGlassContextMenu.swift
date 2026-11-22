#if os(tvOS)
import CoreUI
import SwiftUI

/// Long-press menu for a programme cell: Watch / Resume, Add to Multiview, Add or Remove
/// Favorites, Channel Details. The host supplies only the actions that exist and places the
/// menu with `LiveTVGlassContextMenuGeometry.origin(forCellFrame:canvas:entryCount:)`.
/// No scrim: the guide stays lit behind it.
struct LiveTVGlassContextMenu: View {
    let entries: [LiveTVGlassContextEntry]
    /// A question above the rows (the delete confirmation).
    var title: String?
    var metrics: LiveTVGlassListMetrics = .contextMenu
    var initialFocusID: String?
    /// Runs the action; the host closes the menu afterwards.
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focusedID: String?

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(LiveTVGlassInk.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .frame(height: metrics.labelHeight)
            }
            ForEach(entries) { entry in
                Button { onSelect(entry.id) } label: {
                    LiveTVGlassContextRow(entry: entry, fontSize: metrics.fontSize)
                }
                .buttonStyle(LiveTVGlassButtonStyle())
                .focusEffectDisabled()
                .focused($focusedID, equals: entry.id)
                .frame(height: metrics.rowHeight)
            }
        }
        .padding(metrics.padding)
        .frame(width: metrics.width)
        .liveTVGlassSurface(cornerRadius: metrics.cornerRadius)
        .focusSection()
        .onExitCommand { TVBackConsumption.closePanel("contextMenu") { onClose() } }
        .onAppear { focusedID = initialFocusID ?? entries.first?.id }
    }
}

private struct LiveTVGlassContextRow: View {
    let entry: LiveTVGlassContextEntry
    let fontSize: CGFloat
    @Environment(\.isFocused) private var isFocused

    private static let destructiveInk = Color(red: 1, green: 0.45, blue: 0.42)

    var body: some View {
        HStack(spacing: 14) {
            Text(entry.title)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(entry.isDestructive ? Self.destructiveInk : .white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: entry.icon)
                .font(.system(size: fontSize * 1.04))
                .foregroundStyle(entry.isDestructive ? Self.destructiveInk : .white.opacity(0.82))
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(isFocused ? .white.opacity(0.2) : .clear))
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview("Context menu") {
    LiveTVGlassContextMenu(
        entries: [
            .init(id: "watch", title: "Watch", icon: "play.fill"),
            .init(id: "multiview", title: "Add to Multiview", icon: "square.grid.2x2"),
            .init(id: "favorite", title: "Add to Favorites", icon: "star"),
            .init(id: "details", title: "Channel Details", icon: "info.circle")
        ],
        onSelect: { _ in },
        onClose: {}
    )
    .padding(80)
    .background(Color.black)
}
#endif
