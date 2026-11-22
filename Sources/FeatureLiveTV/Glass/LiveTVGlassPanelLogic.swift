import CoreGraphics
import CoreText
import CoreUI
import FeatureLiveTVCore
import Foundation

// Pure layout and entry logic for the Live TV glass panels. No SwiftUI, so it
// compiles and is tested on every platform; the views that use it are tvOS-only.

// MARK: - List panel entries

/// One row in `LiveTVGlassListPanel`.
struct LiveTVGlassRow: Identifiable, Equatable {
    let id: String
    var title: String
    /// Preformatted count, right-aligned before the accessory column.
    var count: String?
    /// Value text such as an active group name. Ignored when `count` is set.
    var value: String?
    var isSelected = false
    /// SF Symbol drawn in the accessory column when the row is neither selected nor a facet.
    var icon: String?
    /// Draws a trailing chevron instead of the icon.
    var isFacet = false
}

/// The kinds of entry a glass list mixes: rows and the spacing/labels between them.
enum LiveTVGlassListItem: Identifiable, Equatable {
    case row(LiveTVGlassRow)
    case spacer(CGFloat)
    case gap(id: String)
    case divider(id: String)
    case label(String)
    case footer(String)
    /// "‹ title" row that pops a sub-page.
    case title(id: String, text: String)

    var id: String {
        switch self {
        case let .row(row): row.id
        case let .spacer(height): "spacer-\(height)"
        case let .gap(id): "gap-\(id)"
        case let .divider(id): "divider-\(id)"
        case let .label(text): "label-\(text)"
        case let .footer(text): "footer-\(text)"
        case let .title(id, _): "title-\(id)"
        }
    }

    /// Whether the focus engine can land on the entry.
    var isFocusable: Bool {
        switch self {
        case .row, .title: true
        case .spacer, .gap, .divider, .label, .footer: false
        }
    }
}

/// Metrics shared by the list panel and the context menu (`g` in the mockup's `listPanel`).
struct LiveTVGlassListMetrics: Equatable {
    var width: CGFloat
    var padding: CGFloat
    var rowHeight: CGFloat
    var labelHeight: CGFloat
    var fontSize: CGFloat
    var cornerRadius: CGFloat
    var maxHeight: CGFloat

    static let gapHeight: CGFloat = 18
    static let dividerHeight: CGFloat = 25
    static let bottomFade: CGFloat = 80

    /// Context menu: width 500, pad 14, row 62, radius 34.
    static let contextMenu = LiveTVGlassListMetrics(
        width: 500, padding: 14, rowHeight: 62, labelHeight: 52,
        fontSize: 28, cornerRadius: 34, maxHeight: 1080
    )

    func height(of item: LiveTVGlassListItem) -> CGFloat {
        switch item {
        case .row, .title: rowHeight
        case let .spacer(height): height
        case .gap: Self.gapHeight
        case .divider: Self.dividerHeight
        case .label, .footer: labelHeight
        }
    }

    func contentHeight(of items: [LiveTVGlassListItem]) -> CGFloat {
        items.reduce(0) { $0 + height(of: $1) }
    }

    /// `min(maxHeight, content + 2·padding)`; overflow scrolls.
    func panelHeight(for items: [LiveTVGlassListItem]) -> CGFloat {
        min(maxHeight, contentHeight(of: items) + 2 * padding)
    }

    /// Scroll offset that keeps `focusedID` inside the visible window and clear of the bottom fade.
    /// Returns 0 when the content fits.
    func scrollOffset(items: [LiveTVGlassListItem], focusedID: String?) -> CGFloat {
        let visible = panelHeight(for: items) - 2 * padding
        let total = contentHeight(of: items)
        guard total > visible, let focusedID else { return 0 }
        var top: CGFloat = 0
        for item in items {
            let h = height(of: item)
            if item.id == focusedID {
                let wanted = top + h + rowHeight * 2 - visible
                return min(max(wanted, 0), total - visible)
            }
            top += h
        }
        return 0
    }
}

// MARK: - Quick menu

/// What a quick-menu entry is. The menu draws only the entries it is given.
enum LiveTVGlassQuickMenuKind: Equatable {
    /// Saved favorite filter row (large).
    case favoriteFilter
    /// "New Favorite Filter": a large row with a trailing plus, offered only while there are no favorite filters.
    case newFilter
    /// "My Channels": the first row, as large as a favourite filter.
    case myChannels
    /// "Edit Favorite Filters": a regular row, the pencil leading and a chevron trailing.
    case facet
    /// Round tool button in the tools row (Search, Multiview, Set Up My Channels).
    case tool
}

/// The mockup's own glyphs for the quick menu (`IC` in the mockup): drawn as shapes, so Multiview and Set Up match it.
enum LiveTVGlassQuickMenuGlyph: Equatable {
    case search, multiview, sliders, pencil, plus
    /// Drawn by the row itself (the tick and the chevron), not supplied by an entry.
    case check, chevron
    /// The channel panel's buttons: Watch's play triangle and the favourite star (drawn filled when it is one).
    case play, star
}

struct LiveTVGlassQuickMenuEntry: Identifiable, Equatable {
    let id: String
    var kind: LiveTVGlassQuickMenuKind
    var title: String
    /// Preformatted count (`14.8k`), drawn right after the title.
    var count: String?
    /// Preformatted total the count is a part of (`34.5k`): drawn after the count as "of 34.5k" only while the row is focused.
    var focusedTotal: String?
    var isSelected = false
    var glyph: LiveTVGlassQuickMenuGlyph?

    /// The "My Channels" row. `mergedTotal` is everything the providers in use carry; it is shown only when it is
    /// known to be larger than the count and `showsTotal` allows it (never a Kids profile or a single-source view).
    static func myChannels(
        id: String, title: String, count: Int, mergedTotal: Int, showsTotal: Bool, isSelected: Bool
    ) -> LiveTVGlassQuickMenuEntry {
        LiveTVGlassQuickMenuEntry(
            id: id, kind: .myChannels, title: title, count: LiveTVGlassFormatting.shortCount(count),
            focusedTotal: showsTotal && count < mergedTotal ? LiveTVGlassFormatting.shortCount(mergedTotal) : nil,
            isSelected: isSelected)
    }

    /// The text after the title: the count, and while focused "16.3k of 34.5k" when a total was supplied.
    func countText(isFocused: Bool) -> String? {
        guard let count else { return nil }
        guard isFocused, let focusedTotal else { return count }
        return String(localized: "\(count) of \(focusedTotal)")
    }
}

/// The grey line beside the tools: when the guide last updated ("Updated 6:41 PM"; "Updated Nov 3, 6:41 PM" on another day).
enum LiveTVGlassQuickMenuCaption {
    static func updated(
        _ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let date else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if !calendar.isDate(date, inSameDayAs: now) {
            style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        }
        let text = date.formatted(style)
        return String(localized: "Updated \(text)")
    }
}

/// Text widths, to size the menu from its words as the mockup does (`textW`).
enum LiveTVGlassTextMeasure {
    static func width(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = bold ? (CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base) : base
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]) as CFAttributedString)
        return CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up)
    }
}

/// Frames, in menu-local coordinates, of the quick menu: one list on one sheet of glass (the mockup's `listPanel`, native):
/// My Channels and the favourite filters in large rows, "Edit Favourite Filters" (or "New Favourite Filter" when there are none),
/// a divider, and the round tools with the guide's last update beside them.
struct LiveTVGlassQuickMenuLayout: Equatable {
    /// Where focus lands when the menu is shown again after the page it opened (Set Up My Channels, Favourite Filters, the new-filter
    /// picker) closes: on the row that opened it. Nil for entries that do not open a page.
    static func returnFocusID(afterOpeningEntry id: String) -> String? {
        ["manage", "editFilters", "newFilter"].contains(id) ? id : nil
    }

    static let minWidth: CGFloat = 520
    static let padding: CGFloat = 14
    static let cornerRadius: CGFloat = 45
    static let largeRowHeight: CGFloat = 70
    static let rowHeight: CGFloat = 62
    static let dividerHeight: CGFloat = 25
    static let toolsRowHeight: CGFloat = 74
    static let rowInset: CGFloat = 24
    static let toolSize: CGFloat = 60
    static let toolPitch: CGFloat = 70
    static let toolFontSize: CGFloat = 32
    /// The mockup's `round(28 × 1.14 × .6)`: the room the first tool needs left of the row's icon column.
    static let firstToolAllowance: CGFloat = 19
    static let captionFontSize: CGFloat = 24
    /// Bottom margin kept below the menu on screen.
    static let bottomMargin: CGFloat = 30

    let width: CGFloat
    /// Height of everything; the sheet is `min(contentHeight, available)` and scrolls beyond that.
    let contentHeight: CGFloat
    /// Frame per entry id (rows and round tools).
    let frames: [String: CGRect]
    /// Where the caption beside the round tools goes; nil without tools.
    let captionFrame: CGRect?
    /// The hairline between the rows above and the tools; nil without tools.
    let dividerFrame: CGRect?
    /// Entries in the order the layout drew them.
    let entries: [LiveTVGlassQuickMenuEntry]
    /// The ticked large row (else the first row): the menu opens with it over the heading, as a pop-up opens on its current choice.
    let anchorID: String?

    /// `headingWidth` is the heading pill's width; the sheet is at least `headingWidth + 28` wide, and wide enough for the tools
    /// row with its longest caption (`caption`, or a tool's title while it is focused).
    init(entries supplied: [LiveTVGlassQuickMenuEntry], headingWidth: CGFloat, caption: String? = nil) {
        let pad = Self.padding
        var frames: [String: CGRect] = [:]
        var order: [LiveTVGlassQuickMenuEntry] = []
        var y = pad

        func row(_ entry: LiveTVGlassQuickMenuEntry, height: CGFloat, width: CGFloat) {
            frames[entry.id] = CGRect(x: pad, y: y, width: width, height: height)
            order.append(entry)
            y += height
        }
        let hasFavorites = supplied.contains { $0.kind == .favoriteFilter }
        let tools = supplied.filter { $0.kind == .tool }

        let captionWidth = ([caption].compactMap { $0 }.map { LiveTVGlassTextMeasure.width($0, size: Self.captionFontSize, bold: false) }
            + tools.map { LiveTVGlassTextMeasure.width($0.title, size: Self.captionFontSize, bold: true) }).max() ?? 0
        let toolsWidth = 2 * pad + 2 * Self.rowInset + Self.firstToolAllowance + CGFloat(tools.count) * Self.toolPitch + 8 + captionWidth
        let width = tools.isEmpty ? max(Self.minWidth, headingWidth + 2 * pad) : max(Self.minWidth, headingWidth + 2 * pad, toolsWidth.rounded(.up))
        let inner = width - 2 * pad

        for entry in supplied where entry.kind == .myChannels { row(entry, height: Self.largeRowHeight, width: inner) }
        for entry in supplied where entry.kind == .favoriteFilter { row(entry, height: Self.largeRowHeight, width: inner) }
        if !hasFavorites {
            for entry in supplied where entry.kind == .newFilter { row(entry, height: Self.largeRowHeight, width: inner) }
        }
        for entry in supplied where entry.kind == .facet { row(entry, height: Self.rowHeight, width: inner) }

        var captionFrame: CGRect?
        var dividerFrame: CGRect?
        if !tools.isEmpty {
            dividerFrame = CGRect(
                x: pad + Self.rowInset, y: y + (Self.dividerHeight / 2).rounded(), width: inner - 2 * Self.rowInset, height: 1)
            y += Self.dividerHeight
            // Each glyph sits on the leading-icon column above it: the first exactly under those icons.
            let iconColumn = (Self.toolFontSize * 1.2).rounded()
            let firstX = pad + Self.rowInset + (iconColumn / 2 - Self.toolSize / 2).rounded()
            let top = y + ((Self.toolsRowHeight - Self.toolSize) / 2).rounded()
            for (index, entry) in tools.enumerated() {
                frames[entry.id] = CGRect(
                    x: firstX + CGFloat(index) * Self.toolPitch, y: top, width: Self.toolSize, height: Self.toolSize)
                order.append(entry)
            }
            let captionX = firstX + CGFloat(tools.count) * Self.toolPitch + 8
            captionFrame = CGRect(
                x: captionX, y: y, width: max(0, pad + inner - Self.rowInset - captionX), height: Self.toolsRowHeight)
            y += Self.toolsRowHeight
        }

        self.width = width
        self.contentHeight = y + pad
        self.frames = frames
        self.captionFrame = captionFrame
        self.dividerFrame = dividerFrame
        self.entries = order
        self.anchorID = order.first { $0.isSelected && $0.kind != .tool && $0.kind != .facet }?.id
            ?? order.first { $0.kind != .tool }?.id
    }

    /// The sheet's height when `available` is all the screen leaves below its top.
    func height(available: CGFloat) -> CGFloat { min(contentHeight, max(available, 0)) }

    /// Where the sheet's top goes (1080p units): the anchor row centred on the heading pill's centre, never above 24.
    func top(headingCenter: CGFloat) -> CGFloat {
        guard let id = anchorID, let frame = frames[id] else { return max(24, headingCenter - Self.padding - Self.largeRowHeight / 2) }
        return max(24, (headingCenter - frame.midY).rounded())
    }

    /// Scroll offset that keeps the focused row visible and clear of the bottom fade; 0 while everything fits.
    func scrollOffset(focusedID: String?, height: CGFloat) -> CGFloat {
        guard contentHeight > height, let focusedID, let frame = frames[focusedID] else { return 0 }
        let wanted = frame.maxY + Self.rowHeight * 2 - (height - Self.padding)
        return min(max(wanted, 0), contentHeight - height)
    }

    /// The entry to focus first: the selected entry, else the first drawn.
    var initialFocusID: String? {
        entries.first(where: \.isSelected)?.id ?? entries.first?.id
    }

    /// The heading pill's width as the guide draws it (title, count, chevron, padding), for sizing the sheet over it.
    static func headingWidth(title: String, count: String) -> CGFloat {
        (2 * 22 + LiveTVGlassTextMeasure.width(title, size: 28, bold: true) + 10
            + LiveTVGlassTextMeasure.width(count, size: 22, bold: false) + 4 + 21).rounded(.up)
    }
}

// MARK: - Context menu

/// One action in the long-press context menu. The caller supplies only the actions that exist.
struct LiveTVGlassContextEntry: Identifiable, Equatable {
    let id: String
    var title: String
    /// SF Symbol drawn at the end of the row.
    var icon: String
    /// Drawn in red (Delete).
    var isDestructive = false

    /// The menu for a cell. An ended programme (or an idle event slot) has nothing to watch,
    /// so Watch / Resume is left out; the other actions stay.
    static func entries(
        offersWatch: Bool, isPlayingChannel: Bool, offersMultiview: Bool, isFavorite: Bool, canChangeLogo: Bool
    ) -> [LiveTVGlassContextEntry] {
        var entries: [LiveTVGlassContextEntry] = []
        if offersWatch {
            entries.append(.init(
                id: "watch", title: isPlayingChannel ? String(localized: "Resume") : String(localized: "Watch"),
                icon: "play.fill"))
        }
        if offersMultiview {
            entries.append(.init(id: "multiview", title: String(localized: "Add to Multiview"), icon: "square.grid.2x2"))
        }
        entries.append(.init(
            id: "favorite",
            title: isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
            icon: isFavorite ? "star.slash" : "star"))
        entries.append(.init(id: "details", title: String(localized: "Channel Details"), icon: "info.circle"))
        if canChangeLogo {
            entries.append(.init(id: "logo", title: String(localized: "Change Logo…"), icon: "photo"))
        }
        return entries
    }
}

enum LiveTVGlassContextMenuGeometry {
    /// Left edge never goes under the rail column; right edge keeps the screen margin.
    static let minX: CGFloat = 144
    static let rightMargin: CGFloat = 80
    static let bottomMargin: CGFloat = 24
    static let anchorGap: CGFloat = 14

    static func height(entryCount: Int, metrics: LiveTVGlassListMetrics = .contextMenu) -> CGFloat {
        2 * metrics.padding + CGFloat(entryCount) * metrics.rowHeight
    }

    /// Top-left of the menu: below the focused cell when it fits, else above it; x follows the cell, clamped.
    static func origin(
        forCellFrame cell: CGRect,
        canvas: CGSize,
        entryCount: Int = 5,
        metrics: LiveTVGlassListMetrics = .contextMenu
    ) -> CGPoint {
        let menuHeight = height(entryCount: entryCount, metrics: metrics)
        let maxX = canvas.width - rightMargin - metrics.width
        let x = min(max(cell.minX + 12, minX), max(minX, maxX))
        let below = cell.maxY + anchorGap
        let y = below + menuHeight <= canvas.height - bottomMargin
            ? below
            : cell.minY - menuHeight - anchorGap
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Channel panel

struct LiveTVGlassUpcomingProgram: Identifiable, Equatable {
    let id: String
    var title: String
    /// Preformatted start time (`6:30`).
    var timeText: String
    /// Starts a day or more after now: the first such row gets a "Tomorrow" separator.
    var startsTomorrow: Bool
}

enum LiveTVGlassUpcomingRow: Identifiable, Equatable {
    case separator
    case program(LiveTVGlassUpcomingProgram)

    var id: String {
        switch self {
        case .separator: "separator"
        case let .program(program): program.id
        }
    }
}

/// The right panel is laid out in 1080p "panel units" and drawn scaled by the layout's `uiScale` (the mockup's `z(n)`), so every constant
/// below is the 1080p value. At 4K the panel is wider than `width × uiScale` (760 × 0.75 against 600 × 0.9), so its width in panel units
/// is `unitWidth`, and the room for Upcoming rows is measured in the same units.
enum LiveTVGlassChannelPanelLayout {
    static let width: CGFloat = 600
    static let padding: CGFloat = 56
    static let cornerRadius: CGFloat = 48
    static let trailingMargin: CGFloat = 40
    static let topMargin: CGFloat = 40
    static let maxUpcoming = 6
    static let upcomingRowHeight: CGFloat = 54
    static let separatorHeight: CGFloat = 42
    static let labelHeight: CGFloat = 42
    static let sectionSpacing: CGFloat = 30

    static func originX(canvasWidth: CGFloat, layout: LiveTVGlassLayout = .hd1080) -> CGFloat {
        canvasWidth - layout.panelMargin - layout.panelWidth
    }
    /// The panel's width in panel units: 600 at 1080p, 760 × 0.75 / 0.9 at 4K.
    static func unitWidth(_ layout: LiveTVGlassLayout) -> CGFloat { layout.panelWidth / layout.uiScale }
    static func contentWidth(_ layout: LiveTVGlassLayout) -> CGFloat { unitWidth(layout) - 2 * padding }
    /// The panel's tallest extent in panel units: the canvas less its top and bottom margins, divided by the scale.
    static func maxHeight(canvasHeight: CGFloat, layout: LiveTVGlassLayout = .hd1080) -> CGFloat {
        (canvasHeight - 2 * layout.panelMargin) / layout.uiScale
    }

    /// What the panel draws above the Upcoming section, so the room left for rows is the room actually left.
    struct Content: Equatable {
        /// The channel's number-and-name line or, for a channel with no logo, its name over its number.
        var hasMatchupCard = false
        var hasProviders = false
        var hasTags = false
        /// An event slot: no logo block; its service (when the name has one) is the bold line above the event title, which may take
        /// a third line rather than cut a word off.
        var isEvent = false
        var hasEventService = false
        /// Lines the now-playing title takes (0 when nothing is on, at most 2).
        var titleLines = 0
        /// Lines the description takes (0 when there is none, at most 3).
        var descriptionLines = 0
        var hasProgram: Bool { titleLines > 0 }
    }

    static let titleLineHeight: CGFloat = 58
    static let descriptionLineHeight: CGFloat = 39
    static let maxTitleLines = 4
    /// The mockup clamps a title at two lines; a title takes up to four before it loses a word; Upcoming gives up rows to make the room.
    static func titleLineLimit(isEvent: Bool) -> Int { maxTitleLines }
    static let maxDescriptionLines = 3
    static let titleFontSize: CGFloat = 52
    static let descriptionFontSize: CGFloat = 29

    /// Height reserved above the Upcoming section for exactly this content: logo (or matchup card) with the number line, the provider
    /// and tag rows when shown, the now block with the title lines and description lines actually drawn, and the actions row.
    static func reservedHeight(_ content: Content) -> CGFloat {
        let logo: CGFloat = content.hasMatchupCard ? 259 : 124
        var header: CGFloat = logo + 16 + 34 + (content.hasTags ? 12 + 30 : 0) + (content.hasProviders ? 8 + 28 : 0) + 44
        if content.isEvent && !content.hasMatchupCard {
            header = (content.hasEventService ? 44 : 0) + (content.hasProviders ? 8 + 28 : 0) + (content.hasEventService ? 44 : 0)
        }
        let now: CGFloat
        if content.hasProgram {
            let description = content.descriptionLines > 0
                ? 24 + CGFloat(min(content.descriptionLines, maxDescriptionLines)) * descriptionLineHeight : 0
            now = CGFloat(min(content.titleLines, titleLineLimit(isEvent: content.isEvent))) * titleLineHeight + 16 + 35 + description
        } else {
            now = 35
        }
        let actions: CGFloat = 40 + 60
        return header + now + actions
    }

    /// Space left for upcoming rows: `canvas − 2·padding − reserved − section spacing − label`.
    static func upcomingRoom(canvasHeight: CGFloat, content: Content, layout: LiveTVGlassLayout = .hd1080) -> CGFloat {
        maxHeight(canvasHeight: canvasHeight, layout: layout) - 2 * padding - reservedHeight(content) - sectionSpacing - labelHeight
    }

    /// The now block's line counts, measured at the panel's content width: the title in 52 pt bold (up to 2 lines) and the description in
    /// 29 pt (up to 3 lines; none when there is no description).
    static func content(
        title: String?, description: String?, hasMatchupCard: Bool, hasProviders: Bool, hasTags: Bool,
        isEvent: Bool = false, hasEventService: Bool = false, layout: LiveTVGlassLayout = .hd1080
    ) -> Content {
        let width = contentWidth(layout)
        return Content(
            hasMatchupCard: hasMatchupCard, hasProviders: hasProviders, hasTags: hasTags,
            isEvent: isEvent, hasEventService: hasEventService,
            titleLines: title.map { lineCount($0, fontSize: titleFontSize, bold: true, width: width, limit: titleLineLimit(isEvent: isEvent)) } ?? 0,
            descriptionLines: description.flatMap { $0.isEmpty ? nil : $0 }
                .map { lineCount($0, fontSize: descriptionFontSize, bold: false, width: width, limit: maxDescriptionLines) } ?? 0)
    }

    /// Lines `text` wraps to at the panel's content width, at least 1 and at most `limit`.
    static func lineCount(_ text: String, fontSize: CGFloat, bold: Bool, width: CGFloat = width - 2 * padding, limit: Int) -> Int {
        guard !text.isEmpty else { return 1 }
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): base])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        let length = attributed.length
        var start = 0, lines = 0
        while start < length, lines < limit {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { break }
            start += count
            lines += 1
        }
        return max(lines, 1)
    }

    /// The mockup's `upcoming(ch)` (programmes not yet over) split as it does: the first is what the panel headlines, the rest are the
    /// Upcoming list. When a programme is airing it is the headline; when none is, the next one is, shown as "Starts 7:00", and the
    /// list holds the ones after it.
    static func headlineAndLater<Program>(current: Program?, next: [Program]) -> (headline: Program?, later: [Program]) {
        if let current { return (current, next) }
        return (next.first, Array(next.dropFirst()))
    }

    /// Consecutive programmes with the same title become one row, keeping the first one's start time.
    static func mergingConsecutiveTitles(_ programs: [LiveTVGlassUpcomingProgram]) -> [LiveTVGlassUpcomingProgram] {
        var merged: [LiveTVGlassUpcomingProgram] = []
        for program in programs {
            if let last = merged.last, last.title.caseInsensitiveCompare(program.title) == .orderedSame { continue }
            merged.append(program)
        }
        return merged
    }

    /// Up to six rows, with a "Tomorrow" separator before the first next-day programme.
    /// Rows that do not fit in `room` are dropped, never scrolled.
    static func upcomingRows(
        _ programs: [LiveTVGlassUpcomingProgram],
        room: CGFloat
    ) -> [LiveTVGlassUpcomingRow] {
        var rows: [LiveTVGlassUpcomingRow] = []
        var used: CGFloat = 0
        var separated = false
        for program in programs.prefix(maxUpcoming) {
            var cost = upcomingRowHeight
            let needsSeparator = program.startsTomorrow && !separated
            if needsSeparator { cost += separatorHeight }
            guard used + cost <= room else { break }
            if needsSeparator {
                rows.append(.separator)
                separated = true
            }
            rows.append(.program(program))
            used += cost
        }
        return rows
    }
}
