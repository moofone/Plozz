#if os(tvOS)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// The tag picker, as the mockup's Plozz-like `tagSheet` draws it: one dark glass sheet over the whole screen (40 pt margin all round).
/// The title says what you are doing with the note beside it; "…", Delete (when editing) and Save end that line. Under it the filter's
/// name, which you can type (grey while it is only the tags' own name), and, at the right, a search that narrows every section to the
/// tags containing what you typed. Then Suggested and the tag sections, each a row: its name in a column at the left, its tags as bare
/// words flowing beside it. Tags of one section widen, sections narrow. Nothing is saved until Save; Back drops the draft. Laid out in
/// 1080p units; the host draws it scaled.
struct LiveTVGlassTagPicker: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    enum Control: Hashable { case save, delete, more, name, search }

    let model: LiveTVPrototypeModel
    /// Size in units.
    let size: CGSize
    let editingID: String?
    /// Saves the picked tags and typed name; true when they were saved (the host then goes back).
    let onSave: (_ tagIDs: [String], _ name: String?) -> Bool
    /// Present when editing: deletes the filter (the host then goes back).
    let onDelete: (() -> Void)?
    let onBack: () -> Void

    @State private var draft: LiveTVGlassTagPickerDraft
    @State private var saveFailed = false
    @State private var query = ""
    @State private var isAskingForName = false
    @State private var isAskingForQuery = false
    @State private var alertText = ""
    @State private var isMoreOpen = false
    @FocusState private var focus: Control?

    init(
        model: LiveTVPrototypeModel, size: CGSize, editingID: String?,
        onSave: @escaping ([String], String?) -> Bool, onDelete: (() -> Void)?, onBack: @escaping () -> Void
    ) {
        self.model = model
        self.size = size
        self.editingID = editingID
        self.onSave = onSave
        self.onDelete = onDelete
        self.onBack = onBack
        _draft = State(initialValue: LiveTVGlassTagPickerDraft(
            editing: model.favoriteFilterList.first { $0.id == editingID }, defaultTagIDs: model.favoriteFilterDefaultTagIDs))
    }

    var body: some View {
        let check = model.checkFavoriteFilter(tagIDs: draft.tagIDs, name: draft.name, editing: draft.editingID)
        let note = draft.note(
            check: check, matchingCount: draft.tagIDs.isEmpty ? 0 : model.matchingChannelCount(tagIDs: draft.tagIDs),
            saveFailed: saveFailed)
        let canSave = LiveTVGlassTagPickerDraft.canSave(check)
        ZStack(alignment: .topLeading) {
            titleRow(note: note, canSave: canSave)
                .offset(x: Metrics.padding, y: Metrics.padding)
            HStack(spacing: 0) {
                nameField.frame(width: Metrics.nameWidth, height: Metrics.chipHeight)
                Spacer(minLength: 0)
                searchField.frame(width: Metrics.searchWidth, height: Metrics.chipHeight)
            }
            .frame(width: size.width - 2 * Metrics.padding, height: Metrics.chipHeight)
            .focusSection()
            .offset(x: Metrics.padding, y: Metrics.fixedRowTop)
            LiveTVGlassTagSections(
                sections: model.filterTagSections(query: query, selectedTagIDs: draft.tagIDs), query: query, picked: Set(draft.tagIDs),
                toggle: { id in
                    saveFailed = false
                    draft.toggle(id)
                }
            )
            .frame(width: size.width, height: size.height - Metrics.fixedHeight)
            .focusSection()
            .offset(y: Metrics.fixedHeight)
            if isMoreOpen { moreMenu }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .liveTVGlassSurface(cornerRadius: Metrics.cornerRadius)
        .focusSection()
        .onExitCommand {
            if isMoreOpen { isMoreOpen = false; focus = .more } else { TVBackConsumption.closePanel("tagPicker") { onBack() } }
        }
        .alert(String(localized: "Name"), isPresented: $isAskingForName) {
            TextField(String(localized: "Name"), text: $alertText)
            Button(String(localized: "Done")) { draft.name = alertText.trimmingCharacters(in: .whitespacesAndNewlines); saveFailed = false }
            Button(String(localized: "Use the Tags’ Name"), role: .destructive) { draft.name = ""; saveFailed = false }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Search tags"), isPresented: $isAskingForQuery) {
            TextField(String(localized: "Search tags"), text: $alertText)
            Button(String(localized: "Find")) { query = alertText.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button(String(localized: "Clear"), role: .destructive) { query = "" }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    /// The title and note on the left; "…", Delete and Save at the line's end (the mockup's `fixed` row, `y = padding − 2`).
    private func titleRow(note: LiveTVGlassTagPickerNote, canSave: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(draft.title)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(note.text)
                    .font(.system(size: Metrics.noteSize).monospacedDigit())
                    .foregroundStyle(LiveTVGlassInk.menuSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 24)
            Button { isMoreOpen = true } label: { LiveTVGlassSheetButtonLabel(title: "···", isRound: true) }
                .buttonStyle(LiveTVGlassButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .more)
                .accessibilityLabel(String(localized: "More"))
                .padding(.trailing, Metrics.spacing)
            if onDelete != nil {
                Button { onDelete?() } label: { LiveTVGlassSheetButtonLabel(title: String(localized: "Delete")) }
                    .buttonStyle(LiveTVGlassButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .delete)
                    .padding(.trailing, Metrics.spacing)
            }
            Button { if canSave { saveFailed = !onSave(draft.tagIDs, draft.name) } } label: {
                LiveTVGlassSheetButtonLabel(title: String(localized: "Save"), isPrimary: canSave, isDisabled: !canSave)
            }
            .buttonStyle(LiveTVGlassButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: .save)
        }
        .frame(width: size.width - 2 * Metrics.padding, height: Metrics.chipHeight, alignment: .leading)
        .offset(y: -2)
        .focusSection()
    }

    /// Select opens the tvOS keyboard in a text-input alert (a `TextField` brings its own chrome, which cannot be restyled to the
    /// 56 pt capsule); it starts with the name in it, as the mockup's does. Up goes to Save, never Delete or "…".
    private var nameField: some View {
        Button {
            alertText = draft.displayName
            isAskingForName = true
        } label: {
            LiveTVGlassSheetFieldLabel(
                text: draft.displayName, isPlaceholder: draft.name.isEmpty, placeholder: String(localized: "Name"), symbol: .pencil)
        }
        .buttonStyle(LiveTVGlassButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .name)
        .onMoveCommand { if $0 == .up { focus = .save } }
        .accessibilityLabel(String(localized: "Name"))
        .accessibilityValue(draft.displayName)
    }

    /// "Search tags": what you typed; below, the letters that match stand out in each tag.
    private var searchField: some View {
        Button {
            alertText = query
            isAskingForQuery = true
        } label: {
            LiveTVGlassSheetFieldLabel(text: query, isPlaceholder: query.isEmpty, placeholder: String(localized: "Search tags"), symbol: .search)
        }
        .buttonStyle(LiveTVGlassButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .search)
        .onMoveCommand { if $0 == .up { focus = .save } }
        .accessibilityLabel(String(localized: "Search tags"))
        .accessibilityValue(query)
    }

    /// The "…" menu under its button: one solid card (no glass on the glass), rows as in Plozz's menus.
    private var moreMenu: some View {
        let rows = LiveTVGlassTagMoreMenu.rows(draft: draft, model: model)
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                Button { perform(row) } label: { LiveTVGlassTagMoreRowLabel(row: row) }
                    .buttonStyle(LiveTVGlassButtonStyle())
                    .focusEffectDisabled()
            }
        }
        .padding(10)
        .frame(width: Metrics.moreMenuWidth)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(red: 30 / 255, green: 30 / 255, blue: 33 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
        .focusSection()
        .offset(x: size.width - Metrics.padding - Metrics.moreMenuWidth, y: Metrics.padding - 2 + Metrics.chipHeight + 12)
    }

    private func perform(_ row: LiveTVGlassTagMoreMenu.Row) {
        guard row.isEnabled else { return }
        switch row.kind {
        case .saveDefault: _ = model.saveFavoriteFilterDefault(tagIDs: draft.tagIDs)
        case .restoreDefault: draft.replaceTags(model.favoriteFilterDefaultTagIDs)
        }
        saveFailed = false
        isMoreOpen = false
        focus = .more
    }
}

/// The "…" menu's row: title, then what it would do in a quieter size under it; off (36% ink) when it would do nothing.
private struct LiveTVGlassTagMoreRowLabel: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    let row: LiveTVGlassTagMoreMenu.Row
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.system(size: Metrics.fontSize, weight: .semibold))
            Text(row.subtitle).font(.system(size: 21)).lineLimit(1)
                .foregroundStyle(isFocused ? Color.black.opacity(0.5) : Color.white.opacity(row.isEnabled ? 0.6 : 0.36))
        }
        .foregroundStyle(isFocused ? Color.black.opacity(row.isEnabled ? 1 : 0.4) : Color.white.opacity(row.isEnabled ? 1 : 0.36))
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, minHeight: Metrics.moreRowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isFocused ? Color.white : .clear))
    }
}

/// A title-row button: a quiet 11% capsule; Save is solid white with dark ink once it can save, and 36% on 6% while it can't. Focus is a
/// white card with dark ink and does not lift.
struct LiveTVGlassSheetButtonLabel: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    let title: String
    var isRound = false
    var isPrimary = false
    var isDisabled = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(title)
            .font(.system(size: Metrics.fontSize, weight: isRound ? .heavy : .semibold))
            .tracking(isRound ? Metrics.fontSize * 0.06 : 0)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, isRound ? 0 : Metrics.buttonPadding)
            .frame(width: isRound ? Metrics.chipHeight : nil, height: Metrics.chipHeight)
            .background(shape.fill(fill))
    }

    private var shape: some Shape {
        isFocused ? AnyShape(RoundedRectangle(cornerRadius: Metrics.fontSize * 0.55, style: .continuous)) : AnyShape(Capsule())
    }

    private var fill: Color {
        if isFocused { return .white }
        if isDisabled { return .white.opacity(0.06) }
        return isPrimary ? .white : .white.opacity(0.11)
    }

    private var ink: Color {
        if isFocused { return isDisabled ? Color.black.opacity(0.4) : LiveTVGlassInk.focusedInk }
        if isDisabled { return .white.opacity(0.36) }
        return isPrimary ? LiveTVGlassInk.focusedInk : .white.opacity(0.82)
    }
}

/// The name and search fields: an icon and the text on an 11% capsule; focus is a white card with dark ink.
struct LiveTVGlassSheetFieldLabel: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    let text: String
    let isPlaceholder: Bool
    let placeholder: String
    let symbol: LiveTVGlassQuickMenuGlyph
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 12) {
            LiveTVGlassMockupShape(glyph: symbol)
                .stroke(style: StrokeStyle(lineWidth: Metrics.fontSize * 1.7 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: Metrics.fontSize, height: Metrics.fontSize)
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: Metrics.fontSize, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(textInk)
        }
        .foregroundStyle(isFocused ? LiveTVGlassInk.focusedInk : Color.white.opacity(0.9))
        .padding(.horizontal, Metrics.fontSize * 0.9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(isFocused ? Color.white : Color.white.opacity(0.11)))
    }

    private var textInk: Color {
        isPlaceholder ? (isFocused ? Color.black.opacity(0.5) : Color.white.opacity(0.36)) : (isFocused ? LiveTVGlassInk.focusedInk : .white)
    }

    private var shape: some Shape {
        isFocused ? AnyShape(RoundedRectangle(cornerRadius: Metrics.fontSize * 0.55, style: .continuous)) : AnyShape(Capsule())
    }
}

/// "Find a tag", Save and (editing) Delete.
struct LiveTVGlassTagPickerControls: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics

    @Binding var query: String
    let canSave: Bool
    let offersDelete: Bool
    let save: () -> Void
    let delete: () -> Void
    /// What the field says while empty, and the primary button's title: Set Up My Channels reuses this row as "Find a country" and "Apply".
    var placeholder = String(localized: "Find a tag")
    var primaryTitle = String(localized: "Save")

    @FocusState private var focus: String?
    @State private var isAskingForText = false
    @State private var alertText = ""

    var body: some View {
        HStack(spacing: 0) {
            field
                .frame(width: Metrics.fieldWidth, height: Metrics.chipHeight)
            Button(action: { if canSave { save() } }) {
                LiveTVGlassTagChipLabel(title: primaryTitle, isOn: canSave, isDimmed: !canSave)
            }
            .buttonStyle(LiveTVGlassButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: "save")
            .padding(.leading, 2 * Metrics.spacing)
            if offersDelete {
                Button(action: delete) { LiveTVGlassTagChipLabel(title: String(localized: "Delete")) }
                    .buttonStyle(LiveTVGlassButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: "delete")
                    .padding(.leading, Metrics.spacing)
            }
        }
        .frame(height: Metrics.chipHeight)
    }

    /// "Find a tag": Select opens the tvOS keyboard in a text-input alert (a `TextField` brings its own 70 pt chrome, which cannot
    /// be restyled to the reference's 56 pt capsule). The typed text narrows the sections as soon as the alert is confirmed.
    private var field: some View {
        Button {
            alertText = query
            isAskingForText = true
        } label: {
            LiveTVGlassTagFieldLabel(query: query, placeholder: placeholder)
        }
        .buttonStyle(LiveTVGlassButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: "search")
        .alert(placeholder, isPresented: $isAskingForText) {
            TextField(placeholder, text: $alertText)
            Button(String(localized: "Find")) { query = alertText }
            Button(String(localized: "Clear"), role: .destructive) { query = "" }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .accessibilityLabel(placeholder)
        .accessibilityValue(query)
    }
}

struct LiveTVGlassTagFieldLabel: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics

    /// What the field holds, or the placeholder while `isPlaceholder` (the picker's name shows the tags' own name in grey).
    let text: String
    var isPlaceholder = false
    var placeholder = ""
    var symbol: LiveTVGlassQuickMenuGlyph = .search
    @Environment(\.isFocused) private var isFocused

    /// The Set Up My Channels search field: its query, or the placeholder while empty.
    init(query: String, placeholder: String) {
        text = query
        isPlaceholder = query.isEmpty
        self.placeholder = placeholder
    }

    init(text: String, isPlaceholder: Bool, placeholder: String, symbol: LiveTVGlassQuickMenuGlyph) {
        self.text = text
        self.isPlaceholder = isPlaceholder
        self.placeholder = placeholder
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 12) {
            LiveTVGlassMockupShape(glyph: symbol)
                .stroke(style: StrokeStyle(lineWidth: Metrics.fontSize * 1.7 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: Metrics.fontSize, height: Metrics.fontSize)
                .foregroundStyle(.white.opacity(0.9))
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: Metrics.fontSize, weight: .semibold))
                .foregroundStyle(isPlaceholder ? Color.white.opacity(0.45) : .white)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.fontSize * 0.9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Capsule().fill(.white.opacity(isFocused ? 0.26 : 0.1)))
        .scaleEffect(isFocused ? 1.08 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 14, x: 0, y: 14)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Suggested and the tag sections, each a row: its name in a column at the left (secondary ink), its tags flowing beside it as bare words,
/// and a hairline between sections.
private struct LiveTVGlassTagSections: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    let sections: [LiveTVFilterTagSection]
    let query: String
    let picked: Set<String>
    let toggle: (String) -> Void

    @FocusState private var focusedKey: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    HStack(alignment: .top, spacing: 0) {
                        Text(section.title)
                            .font(.system(size: Metrics.labelSize, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .frame(width: Metrics.labelColumn - Metrics.tagPadding, height: Metrics.chipHeight, alignment: .leading)
                        LiveTVGlassFlowLayout(spacing: Metrics.tagGap) {
                            ForEach(section.tags, id: \.tag.id) { choice in
                                Button { toggle(choice.tag.id) } label: {
                                    LiveTVGlassTagWordLabel(title: choice.tag.title, query: query, isPicked: picked.contains(choice.tag.id))
                                }
                                .buttonStyle(LiveTVGlassButtonStyle())
                                .focusEffectDisabled()
                                .focused($focusedKey, equals: Self.key(section, choice))
                                .accessibilityAddTraits(picked.contains(choice.tag.id) ? .isSelected : [])
                            }
                        }
                        // The last word may reach the sheet's matching right edge: the chip's own padding is outside the column.
                        .padding(.trailing, -Metrics.tagPadding)
                    }
                    .padding(.top, index == 0 ? 0 : Metrics.sectionGap)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).offset(y: Metrics.sectionGap / 2)
                        }
                    }
                }
                if sections.isEmpty {
                    Text(String(localized: "No tags match “\(query)”"))
                        .font(.system(size: Metrics.noteSize))
                        .foregroundStyle(.white.opacity(0.36))
                        .frame(height: Metrics.chipHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, Metrics.padding)
            .padding(.top, 10)
            .padding(.bottom, Metrics.bottomFade)
        }
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Metrics.bottomFade)
            }
        }
        .onAppear {
            if focusedKey == nil, let section = sections.first, let first = section.tags.first {
                focusedKey = Self.key(section, first)
            }
        }
    }

    /// The mockup's `tg:<section>:<tag>`: a tag in Suggested and in its own section is two words.
    private static func key(_ section: LiveTVFilterTagSection, _ choice: LiveTVFilterTagChoice) -> String {
        "\(section.id):\(choice.tag.id)"
    }
}

/// One tag as a bare word: 82% white; picked, an accent checkmark before it and white semibold text. While searching, the letters typed
/// stand out and the rest steps back. Focus is a white card with dark ink (radius .55 em) and does not lift.
struct LiveTVGlassTagWordLabel: View {
    typealias Metrics = LiveTVGlassTagSheetMetrics

    let title: String
    let query: String
    let isPicked: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: Metrics.fontSize * 0.4) {
            if isPicked {
                Image(systemName: "checkmark")
                    .font(.system(size: Metrics.fontSize * 0.75, weight: .bold))
                    .foregroundStyle(isFocused ? LiveTVGlassInk.focusedInk : LiveTVGlassInk.selectedCheck)
            }
            text
        }
        .font(.system(size: Metrics.fontSize, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, Metrics.tagPadding)
        .frame(height: Metrics.chipHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.fontSize * 0.55, style: .continuous).fill(isFocused ? Color.white : .clear))
    }

    private var ink: Color {
        if isFocused { return LiveTVGlassInk.focusedInk }
        return isPicked ? .white : .white.opacity(0.82)
    }

    private var text: Text {
        let parts = LiveTVGlassTagHighlight.parts(of: title, query: query)
        guard let match = parts.match else { return Text(title).foregroundStyle(ink) }
        let quiet = ink.opacity(0.6)
        return Text(parts.before).foregroundStyle(quiet) + Text(match).foregroundStyle(ink) + Text(parts.after).foregroundStyle(quiet)
    }
}

struct LiveTVGlassTagChipLabel: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics

    let title: String
    /// A count after the title (Set Up My Channels' chips), in the secondary ink.
    var count: String?
    /// An SF Symbol before the title (Adult's lock).
    var leadingSymbol: String?
    var isOn = false
    var isDimmed = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        // Weight is fixed: the layout measures chips at 600, as the mockup does, so focus never reflows a line.
        HStack(spacing: 12) {
            if let leadingSymbol { Image(systemName: leadingSymbol).font(.system(size: Metrics.fontSize * 0.85)) }
            Text(title).foregroundStyle(isOn ? Color.black : Color.white)
            if let count {
                Text(count)
                    .font(.system(size: Metrics.fontSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(isOn ? Color.black.opacity(0.5) : Color.white.opacity(0.5))
            }
        }
            .font(.system(size: Metrics.fontSize, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, Metrics.chipPadding)
            .frame(height: Metrics.chipHeight)
            .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(isFocused ? 0.26 : 0.1)))
            .scaleEffect(isFocused ? 1.08 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 14, x: 0, y: 14)
            .opacity(isDimmed ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Chips left to right, wrapping to the next line when the next does not fit; every line is as tall as the chips.
struct LiveTVGlassFlowLayout: Layout {
    var spacing: CGFloat

    /// Frames for `sizes` in a line of `width`; also the total height.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, y + lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing)
        let used = result.frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width, spacing: spacing)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
#endif
