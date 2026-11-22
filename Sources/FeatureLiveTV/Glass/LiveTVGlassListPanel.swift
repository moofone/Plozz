#if os(tvOS)
import CoreUI
import SwiftUI

/// Generic glass list: rows, spacers, labels, dividers and a "‹ title" row, scrolling to keep
/// the focused row visible. Used for the quick menu's sub-pages (Provider Groups, Providers).
struct LiveTVGlassListPanel: View {
    enum Look {
        /// Focused row: white 20 % fill, scale 1.03.
        case standard
        /// Quick-menu sub-pages: focused row is solid near-white with dark ink, no scale.
        case menu
    }

    let items: [LiveTVGlassListItem]
    var metrics: LiveTVGlassListMetrics
    var look: Look = .standard
    var initialFocusID: String?
    let onSelect: (String) -> Void
    /// Hold Select on a row. The Select that ends the hold is not delivered to `onSelect`.
    var onHold: ((String) -> Void)?
    /// ← or Menu pops a sub-page; the host decides what "back" means.
    let onBack: () -> Void

    /// Held Select, in seconds (the guide's hold).
    private static let holdDuration = 0.45
    private static let holdConsumedLifetime: Duration = .seconds(1)

    @FocusState private var focusedID: String?
    @State private var lastFocusedID: String?
    @State private var lastFocusedIndex = 0
    @State private var holdConsumed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let height = metrics.panelHeight(for: items)
        let offset = metrics.scrollOffset(items: items, focusedID: focusedID)
        VStack(spacing: 0) {
            ForEach(items) { item in
                itemView(item)
                    .frame(height: metrics.height(of: item))
            }
        }
        .frame(width: metrics.width - 2 * metrics.padding, alignment: .top)
        .offset(y: -offset)
        .frame(
            width: metrics.width - 2 * metrics.padding,
            height: height - 2 * metrics.padding,
            alignment: .top
        )
        .clipped()
        .mask(alignment: .top) { fadeMask(height: height - 2 * metrics.padding) }
        .padding(metrics.padding)
        .frame(width: metrics.width, height: height)
        .liveTVGlassSurface(cornerRadius: metrics.cornerRadius)
        .focusSection()
        .animation(.easeOut(duration: 0.2), value: offset)
        .onMoveCommand { if $0 == .left { onBack() } }
        .onExitCommand { TVBackConsumption.closePanel("listPanel") { onBack() } }
        .onAppear { focusedID = initialFocusID ?? items.first(where: \.isFocusable)?.id }
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            lastFocusedID = id
            lastFocusedIndex = items.filter(\.isFocusable).firstIndex { $0.id == id } ?? lastFocusedIndex
        }
        // A menu opened over the list disables it; when it closes, focus returns to the row it was on.
        .onChange(of: isEnabled) { _, enabled in
            guard enabled, let lastFocusedID else { return }
            // The row may be gone (a filter deleted from its hold menu): focus goes to the row now in its place, as the mockup does.
            focusedID = Self.focusID(returningTo: lastFocusedID, index: lastFocusedIndex, items: items)
        }
    }

    /// Where focus returns after something opened over the list: the row it was on, else the focusable row now at its position
    /// (the last one when it was last), else the first.
    static func focusID(returningTo id: String, index: Int, items: [LiveTVGlassListItem]) -> String? {
        let focusable = items.filter(\.isFocusable)
        if focusable.contains(where: { $0.id == id }) { return id }
        return focusable.isEmpty ? nil : focusable[min(index, focusable.count - 1)].id
    }

    private func select(_ id: String) {
        guard !holdConsumed else { return }
        onSelect(id)
    }

    private func hold(_ id: String) {
        guard let onHold else { return }
        holdConsumed = true
        onHold(id)
        Task { @MainActor in
            try? await Task.sleep(for: Self.holdConsumedLifetime)
            holdConsumed = false
        }
    }

    /// Fades the bottom 80 pt only when content overflows.
    @ViewBuilder
    private func fadeMask(height: CGFloat) -> some View {
        if metrics.contentHeight(of: items) > height {
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: LiveTVGlassListMetrics.bottomFade)
            }
        } else {
            Rectangle().fill(.black)
        }
    }

    @ViewBuilder
    private func itemView(_ item: LiveTVGlassListItem) -> some View {
        switch item {
        case let .row(row):
            Button { select(row.id) } label: {
                LiveTVGlassRowLabel(row: row, fontSize: metrics.fontSize, look: look)
            }
            .buttonStyle(LiveTVGlassButtonStyle())
            .focusEffectDisabled()
            .focused($focusedID, equals: row.id)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: Self.holdDuration).onEnded { _ in hold(row.id) },
                including: onHold == nil ? .subviews : .all)
        case let .title(id, text):
            Button(action: onBack) {
                LiveTVGlassTitleLabel(text: text, fontSize: metrics.fontSize, look: look)
            }
            .buttonStyle(LiveTVGlassButtonStyle())
            .focusEffectDisabled()
            .focused($focusedID, equals: id)
        case .spacer, .gap:
            Color.clear
        case .divider:
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.horizontal, 24)
        case let .label(text):
            Text(text)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(LiveTVGlassInk.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        case let .footer(text):
            Text(text)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.white.opacity(look == .menu ? 0.42 : 0.55))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
        }
    }
}

private func fillStyle(focused: Bool, look: LiveTVGlassListPanel.Look) -> Color {
    guard focused else { return .clear }
    return look == .menu ? Color.white.opacity(0.94) : Color.white.opacity(0.2)
}

private struct LiveTVGlassRowLabel: View {
    let row: LiveTVGlassRow
    let fontSize: CGFloat
    let look: LiveTVGlassListPanel.Look
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let ink = isFocused && look == .menu ? LiveTVGlassInk.focusedInk : Color.white.opacity(0.92)
        let tail = isFocused && look == .menu ? Color.black.opacity(0.55) : LiveTVGlassInk.secondary
        HStack(spacing: 14) {
            Text(row.title)
                .font(.system(size: fontSize, weight: row.isSelected || (isFocused && look == .menu) ? .semibold : .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count = row.count {
                Text(count).font(.system(size: 24, weight: .regular)).foregroundStyle(tail)
            } else if let value = row.value {
                Text(value).font(.system(size: 23, weight: .regular)).foregroundStyle(tail).lineLimit(1)
            }
            accessory(tail: tail)
                .frame(width: 28)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(fillStyle(focused: isFocused, look: look)))
        .scaleEffect(isFocused && look == .standard ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private func accessory(tail: Color) -> some View {
        if row.isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(isFocused && look == .menu ? LiveTVGlassInk.focusedCheck : LiveTVGlassInk.selectedCheck)
        } else if row.isFacet {
            Image(systemName: "chevron.right").font(.system(size: 21, weight: .semibold)).foregroundStyle(tail)
        } else if let icon = row.icon {
            Image(systemName: icon).font(.system(size: fontSize * 0.9)).foregroundStyle(tail)
        }
    }
}

private struct LiveTVGlassTitleLabel: View {
    let text: String
    let fontSize: CGFloat
    let look: LiveTVGlassListPanel.Look
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left").font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 31, weight: .bold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isFocused && look == .menu ? LiveTVGlassInk.focusedInk : .white)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(fillStyle(focused: isFocused, look: look)))
        .scaleEffect(isFocused && look == .standard ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview("Provider Groups") {
    LiveTVGlassListPanel(
        items: [
            .title(id: "back", text: "Provider Groups"),
            .label("Canada"),
            .row(.init(id: "ca-general", title: "General", count: "1.2k", isSelected: true)),
            .row(.init(id: "ca-sports", title: "Sports", count: "148")),
            .divider(id: "1"),
            .label("United States"),
            .row(.init(id: "us-news", title: "News", count: "14.8k")),
            .footer("A channel on several shows once")
        ],
        metrics: LiveTVGlassListMetrics(
            width: 560, padding: 14, rowHeight: 62, labelHeight: 52,
            fontSize: 28, cornerRadius: 40, maxHeight: 700
        ),
        look: .menu,
        onSelect: { _ in },
        onBack: {}
    )
    .padding(80)
    .background(Color.black)
}
#endif
