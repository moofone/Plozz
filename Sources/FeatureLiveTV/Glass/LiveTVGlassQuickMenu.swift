#if os(tvOS)
import CoreUI
import SwiftUI

/// The quick menu that opens over the heading: one list on one sheet of glass (the mockup's native `listPanel`). My Channels and
/// the favourite filters are the large rows, each with its count right after the name; "Edit Favourite Filters" follows (or
/// "New Favourite Filter" while there are none), then a divider and the round tools with the guide's last update beside them.
/// The ticked row opens exactly over the heading, so the heading itself is not drawn. Only the entries supplied are drawn.
struct LiveTVGlassQuickMenu: View {
    let entries: [LiveTVGlassQuickMenuEntry]
    let headingWidth: CGFloat
    /// Shown beside the tools at rest (for example "Updated 6:41 PM"); the focused tool's title replaces it.
    var caption: String?
    /// What the screen leaves for the sheet (1080p units); a taller list scrolls under a fade.
    var maxHeight: CGFloat = .infinity
    /// The entry that takes focus when the menu opens; the ticked one (else the first) when nil.
    var initialFocusID: String?
    let onSelect: (String) -> Void
    /// Menu button / Back: the host closes the menu and refocuses the heading.
    let onClose: () -> Void

    @FocusState private var focusedID: String?

    var body: some View {
        let layout = LiveTVGlassQuickMenuLayout(entries: entries, headingWidth: headingWidth, caption: caption)
        let height = layout.height(available: maxHeight)
        let scroll = layout.scrollOffset(focusedID: focusedID, height: height)
        ZStack(alignment: .topLeading) {
            if let divider = layout.dividerFrame {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(width: divider.width, height: divider.height)
                    .offset(x: divider.minX, y: divider.minY)
            }
            if let captionFrame = layout.captionFrame {
                captionText(focusedTool: layout.entries.first { $0.id == focusedID && $0.kind == .tool })
                    .frame(width: captionFrame.width, height: captionFrame.height, alignment: .leading)
                    .offset(x: captionFrame.minX, y: captionFrame.minY)
            }
            ForEach(layout.entries) { entry in
                if let frame = layout.frames[entry.id] {
                    Button { onSelect(entry.id) } label: {
                        LiveTVGlassQuickMenuLabel(entry: entry)
                    }
                    .buttonStyle(LiveTVGlassButtonStyle())
                    .focusEffectDisabled()
                    .focused($focusedID, equals: entry.id)
                    .accessibilityLabel(entry.title)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .offset(y: -scroll)
        .frame(width: layout.width, height: height, alignment: .topLeading)
        .clipped()
        .mask(alignment: .top) { fade(overflows: layout.contentHeight > height) }
        .liveTVGlassSurface(cornerRadius: LiveTVGlassQuickMenuLayout.cornerRadius)
        .animation(.easeOut(duration: 0.2), value: scroll)
        .focusSection()
        .onExitCommand { TVBackConsumption.closePanel("quickMenu") { onClose() } }
        .onAppear { focusedID = initialFocusID ?? layout.initialFocusID }
    }

    /// Fades the bottom 80 pt only when the list overflows.
    @ViewBuilder
    private func fade(overflows: Bool) -> some View {
        if overflows {
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
    private func captionText(focusedTool: LiveTVGlassQuickMenuEntry?) -> some View {
        if let focusedTool {
            Text(focusedTool.title)
                .font(.system(size: LiveTVGlassQuickMenuLayout.captionFontSize, weight: .semibold))
                .tracking(-0.01 * LiveTVGlassQuickMenuLayout.captionFontSize)
                .foregroundStyle(.white)
                .lineLimit(1)
        } else if let caption {
            Text(caption)
                .font(.system(size: LiveTVGlassQuickMenuLayout.captionFontSize, weight: .medium))
                .tracking(-0.01 * LiveTVGlassQuickMenuLayout.captionFontSize)
                .foregroundStyle(LiveTVGlassInk.menuSecondary)
                .lineLimit(1)
        }
    }
}

private struct LiveTVGlassQuickMenuLabel: View {
    let entry: LiveTVGlassQuickMenuEntry
    @Environment(\.isFocused) private var isFocused

    private static let largeFontSize: CGFloat = 31
    private static let rowFontSize: CGFloat = 28
    private static let accessorySize: CGFloat = 28

    var body: some View {
        Group {
            if entry.kind == .tool { toolBody } else { rowBody }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var isLarge: Bool { entry.kind != .facet }
    private var fontSize: CGFloat { isLarge ? Self.largeFontSize : Self.rowFontSize }
    /// Ink on the focused row's white fill, and the softer ink for counts and chevrons.
    private var ink: Color { isFocused ? LiveTVGlassInk.menuFocusedInk : .white }
    private var accessoryInk: Color { isFocused ? Color.black.opacity(0.55) : LiveTVGlassInk.menuTertiary }

    private var toolBody: some View {
        LiveTVGlassQuickMenuGlyphView(glyph: entry.glyph ?? .search, size: LiveTVGlassQuickMenuLayout.toolFontSize)
            .foregroundStyle(isFocused ? LiveTVGlassInk.menuFocusedInk : Color.white.opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Circle().fill(isFocused ? LiveTVGlassInk.focusedFill : .clear))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 17, x: 0, y: 12)
    }

    private var rowBody: some View {
        HStack(spacing: 16) {
            if !isLarge, let glyph = entry.glyph {
                // The icon leads, as bright as the words (dark on the focused row), a touch larger.
                LiveTVGlassQuickMenuGlyphView(glyph: glyph, size: (Self.rowFontSize * 1.14).rounded())
                    .foregroundStyle(ink)
                    .frame(width: (Self.rowFontSize * 1.14 * 1.2).rounded())
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title)
                    .font(.system(size: fontSize, weight: isFocused ? .semibold : (isLarge ? .semibold : .medium)))
                    .foregroundStyle(isLarge || isFocused ? ink : ink.opacity(0.92))
                    .lineLimit(1)
                    .layoutPriority(0)
                if let count = entry.countText(isFocused: isFocused) {
                    Text(count)
                        .font(.system(size: (fontSize * 0.8).rounded(), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isFocused ? Color.black.opacity(0.5) : LiveTVGlassInk.menuCount)
                        .fixedSize()
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .tracking(-0.01 * fontSize)
            accessory.frame(width: Self.accessorySize)
        }
        .padding(.horizontal, LiveTVGlassQuickMenuLayout.rowInset)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: (fontSize * 0.6).rounded(), style: .continuous)
                .fill(isFocused ? LiveTVGlassInk.menuFocusedFill : .clear)
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 15, x: 0, y: 12)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if entry.isSelected {
            LiveTVGlassQuickMenuMark(kind: .check, size: 25)
                .foregroundStyle(isFocused ? LiveTVGlassInk.focusedCheck : LiveTVGlassInk.selectedCheck)
        } else if entry.kind == .facet {
            LiveTVGlassQuickMenuMark(kind: .chevron, size: 21).foregroundStyle(accessoryInk)
        } else if let glyph = entry.glyph {
            LiveTVGlassQuickMenuGlyphView(glyph: glyph, size: 25).foregroundStyle(isFocused ? Color.black.opacity(0.55) : .white)
        }
    }
}

/// The mockup's icons (its `IC` set), drawn from the same 24-unit paths with its stroke (1.9 of 24, round caps and joins), so the
/// glyphs match its weight and shape rather than the nearest SF Symbol.
struct LiveTVGlassQuickMenuGlyphView: View {
    let glyph: LiveTVGlassQuickMenuGlyph
    let size: CGFloat

    var body: some View {
        LiveTVGlassMockupShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: size * 1.9 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// The tick and chevron the rows end with, from the same icon set.
struct LiveTVGlassQuickMenuMark: View {
    enum Kind { case check, chevron }
    let kind: Kind
    let size: CGFloat

    var body: some View {
        LiveTVGlassMockupShape(glyph: kind == .check ? .check : .chevron)
            .stroke(style: StrokeStyle(lineWidth: size * 1.9 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct LiveTVGlassMockupShape: Shape {
    let glyph: LiveTVGlassQuickMenuGlyph

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        var path = Path()
        switch glyph {
        case .search:
            path.addEllipse(in: CGRect(x: 4 * k, y: 4 * k, width: 13 * k, height: 13 * k))
            path.move(to: point(15.5, 15.5)); path.addLine(to: point(20, 20))
        case .plus:
            path.move(to: point(12, 5)); path.addLine(to: point(12, 19))
            path.move(to: point(5, 12)); path.addLine(to: point(19, 12))
        case .check:
            path.move(to: point(5, 12.5)); path.addLine(to: point(9.5, 17)); path.addLine(to: point(19, 7.5))
        case .play:
            path.move(to: point(7.2, 4.6)); path.addLine(to: point(7.2, 19.4)); path.addLine(to: point(19.2, 12)); path.closeSubpath()
        case .star:
            let pts: [(CGFloat, CGFloat)] = [(12, 3.8), (14.5, 9), (20.1, 9.7), (16, 13.6), (17, 19.2), (12, 16.5), (7, 19.2), (8, 13.6), (3.9, 9.7), (9.5, 9)]
            path.move(to: point(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { path.addLine(to: point(q.0, q.1)) }
            path.closeSubpath()
        case .chevron:
            path.move(to: point(10, 6)); path.addLine(to: point(16, 12)); path.addLine(to: point(10, 18))
        case .multiview:
            path.addRoundedRect(in: CGRect(x: 3 * k, y: 4.5 * k, width: 18 * k, height: 15 * k), cornerSize: CGSize(width: 3 * k, height: 3 * k))
            path.move(to: point(12, 4.5)); path.addLine(to: point(12, 19.5))
            path.move(to: point(3, 12)); path.addLine(to: point(21, 12))
        case .sliders:
            for (x0, x1, y) in [(4.0, 13.0, 7.0), (17.0, 20.0, 7.0), (4.0, 7.0, 17.0), (11.0, 20.0, 17.0)] {
                path.move(to: point(x0, y)); path.addLine(to: point(x1, y))
            }
            for (x, y) in [(15.0, 7.0), (9.0, 17.0)] {
                path.addEllipse(in: CGRect(x: (x - 2) * k, y: (y - 2) * k, width: 4 * k, height: 4 * k))
            }
        case .pencil:
            // The mockup's pencil: the nib stroke, then the body with its two rounded ends.
            path.move(to: point(15.2, 5.2)); path.addLine(to: point(18.8, 8.8))
            path.move(to: point(4.5, 19.5)); path.addLine(to: point(5.5, 15.2)); path.addLine(to: point(16.3, 4.4))
            path.addCurve(to: point(18.6, 4.4), control1: point(17.0, 3.7), control2: point(17.9, 3.7))
            path.addLine(to: point(19.6, 5.4))
            path.addCurve(to: point(19.6, 7.7), control1: point(20.3, 6.1), control2: point(20.3, 7.0))
            path.addLine(to: point(8.8, 18.5))
            path.closeSubpath()
        }
        return path
    }
}

#Preview("Quick menu") {
    LiveTVGlassQuickMenu(
        entries: LiveTVGlassQuickMenuFixture.mockup,
        headingWidth: 300,
        caption: "Updated 6:41 PM",
        onSelect: { _ in },
        onClose: {}
    )
    .padding(80)
    .background(Color.black)
}

/// The mockup's own menu content (`#v=browse&m=filter`): My Channels 16.3k, Canada 7 (ticked), Sports · 4K 5, Edit Favourite Filters.
enum LiveTVGlassQuickMenuFixture {
    static let tools: [LiveTVGlassQuickMenuEntry] = [
        .init(id: "search", kind: .tool, title: "Search", glyph: .search),
        .init(id: "multiview", kind: .tool, title: "Multiview", glyph: .multiview),
        .init(id: "manage", kind: .tool, title: "Set Up My Channels", glyph: .sliders)
    ]
    static let mockup: [LiveTVGlassQuickMenuEntry] = [
        .init(id: "all", kind: .myChannels, title: "My Channels", count: "16.3k"),
        .init(id: "filter:canada", kind: .favoriteFilter, title: "Canada", count: "7", isSelected: true),
        .init(id: "filter:sports", kind: .favoriteFilter, title: "Sports · 4K", count: "5"),
        .init(id: "editFilters", kind: .facet, title: "Edit Favourite Filters", glyph: .pencil)
    ] + tools
}
#endif
