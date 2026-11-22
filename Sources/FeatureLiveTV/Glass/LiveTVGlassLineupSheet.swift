#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Set Up My Channels: the tag picker's sheet, with countries instead of tags. Title and live "N of M channels", a subtitle, "Find a country"
/// and Apply (dim until something changed), then Countries, Regions, Without a Country, Adult and Always Keep. Nothing changes until
/// Apply; Back discards. Laid out in 1080p units; the host draws it scaled.
struct LiveTVGlassLineupSheet: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics
    typealias Layout = LiveTVGlassLineupMetrics

    let state: LiveTVLineupState
    let size: CGSize
    /// Applies the draft; the host then reloads and goes back.
    let onApply: () -> Void
    let onBack: () -> Void

    @State private var query = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    Text(LiveTVGlassLineupText.title)
                        .font(.system(size: Metrics.titleSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(LiveTVGlassLineupText.count(kept: state.draftCount, total: state.totalCount))
                        .font(.system(size: Metrics.noteSize).monospacedDigit())
                        .foregroundStyle(LiveTVGlassInk.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: Metrics.titleHeight)
                Text(LiveTVGlassLineupText.subtitle)
                    .font(.system(size: Layout.subtitleSize))
                    .foregroundStyle(LiveTVGlassInk.secondary)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            .frame(width: size.width - 2 * Metrics.padding, alignment: .leading)
            .offset(x: Metrics.padding, y: Metrics.padding)
            LiveTVGlassTagPickerControls(
                query: $query, canSave: state.hasChanges, offersDelete: false,
                save: onApply, delete: {},
                placeholder: LiveTVGlassLineupText.findCountry, primaryTitle: LiveTVGlassLineupText.apply
            )
            // Full width: a chip anywhere below can move Up into the row and reach Apply.
            .frame(width: size.width - 2 * Metrics.padding, alignment: .leading)
            .focusSection()
            .offset(x: Metrics.padding, y: Layout.fixedRowTop)
            LiveTVGlassLineupChips(state: state, query: query)
                .frame(width: size.width, height: size.height - Layout.fixedHeight)
                .focusSection()
                .offset(y: Layout.fixedHeight)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .liveTVGlassSurface(cornerRadius: Metrics.cornerRadius)
        .focusSection()
        .onExitCommand { TVBackConsumption.closePanel("lineupSheet") { onBack() } }
    }
}

private struct LiveTVGlassLineupChips: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics
    typealias Layout = LiveTVGlassLineupMetrics

    let state: LiveTVLineupState
    let query: String
    @FocusState private var focusedKey: String?

    var body: some View {
        let sections = state.sections(query: query)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    label(section.title)
                    if section.kind == .withoutCountry { sublabel(LiveTVGlassLineupText.withoutCountryNote) }
                    if section.kind == .adult { sublabel(LiveTVGlassLineupText.adultNote) }
                    LiveTVGlassFlowLayout(spacing: Metrics.spacing) {
                        ForEach(section.chips) { chip in
                            Button { state.toggle(chip) } label: {
                                LiveTVGlassTagChipLabel(
                                    title: chip.title, count: chip.count.formatted(),
                                    leadingSymbol: chip.kind == .adult ? "lock.fill" : nil,
                                    isOn: chip.isOn, isDimmed: chip.kind == .adult)
                            }
                            .buttonStyle(LiveTVGlassButtonStyle())
                            .focusEffectDisabled()
                            .focused($focusedKey, equals: "\(section.id):\(chip.id)")
                            .accessibilityAddTraits(chip.isOn ? .isSelected : [])
                        }
                    }
                    .padding(.bottom, Metrics.sectionGap)
                }
                if sections.isEmpty { label(LiveTVGlassLineupText.noMatch(query)) }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    label(LiveTVGlassLineupText.alwaysKeep)
                    ForEach(LiveTVGlassLineupText.keepRows, id: \.keep) { row in
                        Button { state.toggleKeep(row.keep) } label: { keepRow(row) }
                            .buttonStyle(LiveTVGlassButtonStyle())
                            .focusEffectDisabled()
                            .focused($focusedKey, equals: "keep:\(row.keep.rawValue)")
                            .padding(.bottom, Metrics.spacing)
                    }
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
            if focusedKey == nil, let section = sections.first, let chip = section.chips.first { focusedKey = "\(section.id):\(chip.id)" }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Metrics.labelSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .frame(height: Metrics.labelHeight - 10, alignment: .bottomLeading)
            .padding(.leading, 4)
            .padding(.bottom, 10)
    }

    private func sublabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Layout.sublabelSize))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.leading, 4)
            .padding(.top, -8)
            .padding(.bottom, 8)
    }

    private func keepRow(_ row: LiveTVGlassLineupText.KeepRow) -> some View {
        KeepRowLabel(row: row, isOn: state.isOn(row.keep))
    }
}

private struct KeepRowLabel: View {
    typealias Metrics = LiveTVGlassTagPickerMetrics
    typealias Layout = LiveTVGlassLineupMetrics

    let row: LiveTVGlassLineupText.KeepRow
    let isOn: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: Metrics.fontSize, weight: .semibold)).foregroundStyle(.white)
                if let note = row.note {
                    Text(note).font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
            Text(isOn ? String(localized: "On") : String(localized: "Off"))
                .font(.system(size: Metrics.fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.5))
        }
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: row.height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Layout.keepRowRadius).fill(.white.opacity(isFocused ? 0.26 : 0.1)))
        .scaleEffect(isFocused ? 1.03 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 14, x: 0, y: 14)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
