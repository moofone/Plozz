import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

typealias PrototypeBrowseFocus = LiveTVGuideFocusTarget

enum PrototypeGuidePlateRequest: Equatable {
    case rememberedRow
    case firstVisibleRow
}

#if DEBUG && os(tvOS)
/// Installed only by the app-hosted navigation profiler, never by the product app.
@MainActor enum GuideNavigationProfileHook {
    static var focus: ((LiveTVGuideFocusTarget) -> Void)?
    static var verticalRoute: ((String) -> Void)?
}
#endif

/// The guide rows whose content is on screen. A recycled native guide cell can show a row in its new cell before the
/// old cell reports that row gone, so each row is counted: it stays mounted until every appearance has gone.
struct PrototypeMountedRows: Equatable {
    private var counts: [LiveTVGuideRowID: Int] = [:]

    func contains(_ row: LiveTVGuideRowID) -> Bool { counts[row] != nil }

    mutating func insert(_ row: LiveTVGuideRowID) { counts[row, default: 0] += 1 }

    mutating func remove(_ row: LiveTVGuideRowID) {
        guard let count = counts[row] else { return }
        counts[row] = count > 1 ? count - 1 : nil
    }
}

struct PrototypeBrowser: View {
    let model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    /// Says a selected favourite filter's country is not in My Channels (shown when the filter matches nothing).
    var lineupNotice: String?
    @Binding var selectedID: String?
    @Binding var selectedRowID: LiveTVGuideRowID?
    @Binding var railActive: Bool
    @Binding var focusedProgram: LiveTVPrototypeProgram?
    @Binding var hasFocus: Bool
    let topRequest: Int
    let nowRequest: Int
    @Binding var guideOffset: TimeInterval
    @Binding var timeAnchor: Date
    @Binding var timelineOffset: CGFloat
    let restoreFocusRequest: Int
    let isPresented: Bool
    let isRestoringFocus: Bool
    let restoresPlaybackFocus: Bool
    var guideFocusMayScroll = true
    let watchOrigin: LiveTVGuideRowID?
    let focusRestored: (Int) -> Void
    let tune: (LiveTVGuideRowID) -> Void
    let details: (LiveTVPrototypeProgram) -> Void
    let openControls: () -> Void
    let openSources: () -> Void
    let openGuideTime: () -> Void
    let openToolbar: (() -> Void)?
    let isLoading: Bool
    let loadFailed: Bool
    let reload: () -> Void
    var openChannelManagement: (() -> Void)?
    var hideChannel: ((LiveTVPrototypeChannel, LiveTVGuideRowID) -> Void)?
    var selectionAction: LocalizedStringResource?
    var selectedChannelIDs: Set<String> = []
    var libraryCatalog: PrototypeLibraryCatalogRevision?
    var loadLibraryGuide: ((Set<String>, DateInterval) -> Void)?
    var openLibraryItem: ((LibraryChannelItem) -> Void)?
    var leadingExit: (() -> Void)?
    var plateRequest: Binding<PrototypeGuidePlateRequest?>?
    var isEmbeddedInPlayer = false
    var previewChannel: ((LiveTVGuideRowID) -> Void)?
    /// tvOS Liquid Glass presentation hooks. With either set, the plate's `Menu`
    /// and the cells' `.contextMenu` are not attached; nil keeps them.
    /// Plate Select.
    var onChannelSelect: ((LiveTVPrototypeChannel) -> Void)?
    /// Select held on a cell, with the cell's screen frame (`nil` programme on a gap).
    var onProgramHold: ((LiveTVPrototypeChannel, LiveTVPrototypeProgram?, CGRect) -> Void)?
    @State private var scrollID: LiveTVGuideRowID?
    @State private var pendingFocus: PrototypeBrowseFocus?
    @State private var restorationFallback: PrototypeBrowseFocus?
    @State private var verticalFade = PrototypeScrollFade()
    @State private var lastFocused: PrototypeBrowseFocus?
    @State private var confirmedFocus: PrototypeBrowseFocus?
    @State private var mountedRows = PrototypeMountedRows()
    @State private var restrictDirectionalEntry = true
    @State private var guideHours = Self.initialGuideHours
    @State private var guideWidth: CGFloat = 0
    @State private var timeline = PrototypeTimelineScroll()
    @State private var appliedPreparationRevision = 0
    @Environment(LiveTVGuidePreparationModel.self) private var guidePreparation: LiveTVGuidePreparationModel?
    #if os(tvOS)
    @State private var nativeScroll = PrototypeGuideScrollController()
    @State private var browsesTimeline = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var timelineJump: PrototypeGuideTimelineJump?
    @Environment(\.prototypeGuideSheetPlan) private var sheetPlan
    @ScaledMetric(relativeTo: .subheadline) private var nativeRowHeight = PrototypeLayout.rowHeight
    #endif
    @FocusState private var focused: PrototypeBrowseFocus?
    @FocusState private var recoveryFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private struct GuideWorkRequest: Equatable {
        let window: PrototypeServerGuideRequest?
        let preparationRevision: Int
    }

    var body: some View {
        let guideRequest = guideOpenTraced("browse.serverGuideRequest") { serverGuideRequest }
        let cachedWindowRequest = cachedGuideRequest
        let generatedWindowRequest = libraryGuideRequest
        let preparationRevision = guidePreparation?.completionRevision ?? 0
        GeometryReader { geometry in
            let focusReturnTarget = returnTarget
            VStack(spacing: PrototypeLayout.rulerGap) {
                if !guideOpenTraced("browse.guideChannels", { model.guideChannels.isEmpty }) || isLoading {
                    if geometry.size.width > 0 {
                        PrototypeTimelineReader(timeline: timeline) { offset in
                            PrototypeTimeRuler(
                                start: guideStart, now: model.now, width: geometry.size.width,
                                timelineOffset: offset, section: currentSection,
                                showsNowMarker: !isLoading, isLoading: isLoading, span: guideSpan
                            )
                        }
                        .disabled(railActive || isRestoringFocus)
                    } else {
                        PrototypeGuideSectionLabel(section: currentSection)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if isLoading {
                    PrototypeGuideSkeletonRows(width: geometry.size.width)
                } else if model.channels.isEmpty && loadFailed {
                    ContentUnavailableView {
                        Label("Channels unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection or open TV Sources to review what needs attention.")
                    } actions: {
                        Button("Retry", action: reload).buttonStyle(PrototypeButtonStyle())
                            .focused($recoveryFocused)
                        Button(action: openSources) { Text(SettingsCopy.tvSources) }
                            .buttonStyle(PrototypeButtonStyle())
                    }
                } else if model.channels.isEmpty {
                    ContentUnavailableView {
                        Label("No channels available", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Your enabled sources haven't provided any channels. Open TV Sources to check their status or add another source.")
                    } actions: {
                        Button("Refresh channels", action: reload).buttonStyle(PrototypeButtonStyle())
                            .focused($recoveryFocused)
                        Button(action: openSources) { Text(SettingsCopy.tvSources) }
                            .buttonStyle(PrototypeButtonStyle())
                    }
                } else if allChannelsHidden {
                    ContentUnavailableView {
                        Label("All channels are hidden", systemImage: "eye.slash")
                    } description: {
                        Text("Your channels are still saved. Review Hidden channels to show them again.")
                    } actions: {
                        if let openChannelManagement {
                            Button("Manage channels", action: openChannelManagement)
                                .buttonStyle(PrototypeButtonStyle())
                                .focused($recoveryFocused)
                        }
                    }
                } else if model.visibleChannels.isEmpty {
                    ContentUnavailableView {
                        if model.guideOnly && imports.guidePhase == .loading {
                            Label("Loading guide listings", systemImage: "calendar")
                        } else {
                            Label("No matching channels", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } description: {
                        if model.guideOnly && imports.guidePhase == .loading {
                            Text("Matching channels appear as each guide source loads. Clear filters to browse all channels now.")
                        } else if let lineupNotice {
                            Text(lineupNotice)
                        } else {
                            Text("Try another search or clear your filters.")
                        }
                    } actions: {
                        Button("Clear filters") { model.resetFilters() }
                            .buttonStyle(PrototypeButtonStyle(surface: .guide))
                            .focusEffectDisabled()
                    }
                } else {
                    #if os(tvOS)
                    let gatesFocus = (railActive && restrictDirectionalEntry)
                        || isRestoringFocus || requiresContentFocusHandoff
                    PrototypeNativeGuideList(
                        rows: guideOpenTraced("browse.guideRowIDs") { model.guideRowIDs },
                        rowHeight: PrototypeLayout.rowHeight(for: geometry.size.width, scaledHeight: nativeRowHeight)
                            + PrototypeLayout.rowGap,
                        // The tvOS guide draws no section labels, so sections take no height.
                        sectionHeight: 0,
                        scrollController: nativeScroll,
                        scrolled: { row, offset in
                            if scrollID != row { scrollID = row }
                            let fade = PrototypeScrollFade(before: offset)
                            if verticalFade != fade { verticalFade = fade }
                        },
                        viewportChanged: isEmbeddedInPlayer ? nil : { row, relativeOffset in
                            imports.noteGuideViewport(anchor: row, relativeOffset: Double(relativeOffset))
                        },
                        initialViewport: isEmbeddedInPlayer ? nil : imports.restoredGuideViewport.map {
                            PrototypeGuideListViewport(row: $0.anchor, relativeOffset: CGFloat($0.relativeOffset))
                        },
                        revision: { row in
                            model.guideEntry(for: row).map { entry in
                                PrototypeGuideRowRevision(
                                    entry: entry,
                                    showsSection: Self.showsSectionLabels
                                        && entry.startsSection && entry.section != model.guideChannels.first?.section,
                                    programs: model.programs(for: row.channelID, from: guideStart, hours: guideHours),
                                    start: guideStart, hours: guideHours, now: model.now,
                                    width: geometry.size.width, gatesFocus: gatesFocus,
                                    returnTarget: gatesFocus && focusReturnTarget?.rowID == row ? focusReturnTarget : nil,
                                    favorite: model.favoriteIDs.contains(row.channelID),
                                    playing: model.playingChannelID == row.channelID,
                                    gapState: imports.gapState(
                                        for: entry.channel, from: dataRange.start, to: dataRange.end),
                                    selectionAction: selectionAction,
                                    selectionMarked: selectedChannelIDs.contains(row.channelID),
                                    canHide: hideChannel != nil,
                                    routesGlassPresentation: onChannelSelect != nil || onProgramHold != nil,
                                    page: timeline.page)
                            }
                        },
                        leadingExit: !gatesFocus && !voiceOver ? leadingExit : nil,
                        focusNow: plateRequest != nil && !gatesFocus && !voiceOver ? focusNowOnRow : nil,
                        nowTimelineX: plateRequest != nil && !gatesFocus && !voiceOver ? nowTimelineX : nil,
                        isAtNowBoundary: plateRequest != nil && !gatesFocus && !voiceOver ? isAtNowBoundary : nil,
                        focusChannel: focusChannelPlate,
                        focusEarlierSlot: plateRequest != nil && !gatesFocus && !voiceOver ? focusEarlierSlot : nil,
                        didBrowseHorizontally: { browsesTimeline = true },
                        focusAdjacentCurrent: !browsesTimeline && !voiceOver && !gatesFocus ? focusCurrentRow : nil,
                        hasProgrammePlane: { row in
                            !model.programs(for: row.channelID, from: guideStart, hours: guideHours).isEmpty
                        },
                        timelineWidth: PrototypeLayout.timelineContentWidth(for: geometry.size.width, span: guideSpan),
                        pinnedWidth: PrototypeLayout.stationWidth(for: geometry.size.width) + PrototypeLayout.columnGap,
                        initialTimelineOffset: timelineOffset,
                        timelineJump: timelineJump,
                        timelineDidScroll: timeline.scrolled
                    ) { row in
                        if let entry = model.guideEntry(for: row) {
                            let content = guideRow(entry, width: geometry.size.width, returnTarget: focusReturnTarget,
                                                   scrollTo: nativeScroll.scrollTo)
                            rowPlane(entry) { content.inPlane(.stationary) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    } scrollingContent: { row in
                        if let entry = model.guideEntry(for: row) {
                            let content = guideRow(entry, width: geometry.size.width, returnTarget: focusReturnTarget,
                                                   scrollTo: nativeScroll.scrollTo)
                            content.inPlane(.programmes)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    // The list holds whole rows only: on the glass sheet it ends where the sheet's last row does, elsewhere
                    // after the last row that fits. Settled scrolling rests on row edges, so no row is cut under the times.
                    .frame(height: sheetPlan?.listHeight)
                    .modifier(PrototypeWholeGuideRows(
                        isActive: sheetPlan == nil,
                        pitch: PrototypeLayout.rowHeight(for: geometry.size.width, scaledHeight: nativeRowHeight)
                            + PrototypeLayout.rowGap,
                        gap: PrototypeLayout.rowGap))
                    .onChange(of: topRequest) { _, _ in
                        goToTop(scrollTo: nativeScroll.scrollTo, movesFocus: !railActive)
                    }
                    .task(id: isPresented && isRestoringFocus ? restoreFocusRequest : -1) {
                        await restoreFocus(
                            scrollTo: nativeScroll.scrollTo, isVisible: nativeScroll.isVisible,
                            width: geometry.size.width)
                    }
                    #else
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: PrototypeLayout.rowGap) {
                                ForEach(model.guideChannels) { entry in
                                    rowPlane(entry) {
                                        guideRow(entry, width: geometry.size.width, returnTarget: focusReturnTarget) {
                                            proxy.scrollTo($0, anchor: $1)
                                        }
                                    }
                                    .id(entry.id)
                                    .onAppear { mountRow(entry.id) }
                                    .onDisappear { mountedRows.remove(entry.id) }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.top, PrototypeLayout.sectionLabelGap)
                        }
                        .scrollIndicators(.hidden)
                        .verticalEdgeFadeMask(
                            fadeHeight: PrototypeLayout.verticalFade,
                            topStrength: verticalFade.leading,
                            // Fades into the tab bar while there's more below.
                            bottomStrength: verticalFade.trailing
                        )
                        .onScrollGeometryChange(for: PrototypeScrollFade.self) { geometry in
                            PrototypeScrollFade(
                                before: geometry.contentOffset.y + geometry.contentInsets.top,
                                after: geometry.contentSize.height
                                    - (geometry.contentOffset.y + geometry.containerSize.height)
                            )
                        } action: { _, fade in
                            verticalFade = fade
                        }
                        .scrollPosition(id: $scrollID, anchor: .top)
                        .onChange(of: topRequest) { _, _ in
                            goToTop { proxy.scrollTo($0, anchor: $1) }
                        }
                        .task(id: isPresented && isRestoringFocus ? restoreFocusRequest : -1) {
                            await restoreFocus(
                                scrollTo: { proxy.scrollTo($0, anchor: $1) }, width: geometry.size.width)
                        }
                    }
                    #endif
                }
            }
            .onChange(of: geometry.size.width, initial: true) { old, new in
                guideWidth = new
                timeline.pageWidth = PrototypeLayout.timelineWidth(for: new)
                timeline.pageSeconds = PrototypeLayout.viewportSeconds(for: new)
                // Keep the same programme time at the leading edge.
                let seconds = (old > 0 ? timeline.offset : timelineOffset)
                    / PrototypeLayout.timelineX(1, for: old > 0 ? old : new)
                let adjustedOffset = max(0, PrototypeLayout.timelineX(seconds.isFinite ? seconds : 0, for: new))
                guideHours = max(guideHours, PrototypeLayout.hoursCoveringTimelineOffset(adjustedOffset, for: new))
                setTimelineOffset(min(
                    PrototypeLayout.maximumTimelineOffset(for: new, span: guideSpan),
                    adjustedOffset
                ))
            }
        }
        .onAppear {
            let committed = $timelineOffset
            let hours = $guideHours
            let width = $guideWidth
            timeline.settled = { committed.wrappedValue = $0 }
            timeline.moved = { Self.extendGuideIfNeeded(at: $0, width: width.wrappedValue, hours: hours) }
        }
        .onDisappear {
            timeline.stop()
        }
        .onChange(of: guideStart) { _, _ in
            guideHours = PrototypeLayout.hoursCoveringTimelineOffset(timelineOffset, for: guideWidth)
            refocusIfProgramLeftWindow()
        }
        .onChange(of: model.guideWindowStart) { old, new in
            shiftScrolledTimeline(from: old, to: new)
        }
        .onChange(of: timelineOffset, initial: true) { _, value in
            // Now, guide time and bookmarks move the guide from outside.
            if abs(timeline.offset - value) >= 1 {
                guideHours = max(guideHours, PrototypeLayout.hoursCoveringTimelineOffset(value, for: guideWidth))
                setTimelineOffset(value)
            }
        }
        #if os(tvOS)
        // The Liquid Glass guide fills its container edge to edge (plate at its
        // leading edge, ruler at its top) and sits flat on the app background.
        .background { PrototypeGuideSurface() }
        .focusSection()
        .onChange(of: plateRequest?.wrappedValue) { _, request in
            guard let request else { return }
            plateRequest?.wrappedValue = nil
            guard isPresented, !isRestoringFocus, !railActive, !voiceOver else { return }
            let row: LiveTVGuideRowID?
            switch request {
            case .rememberedRow:
                row = selectedRowID.flatMap { model.guideEntry(for: $0)?.id } ?? nativeScroll.firstVisibleRow?()
            case .firstVisibleRow:
                row = nativeScroll.firstVisibleRow?()
            }
            if let row { focusChannelPlate(row) }
        }
        .onExitCommand(perform: openToolbar.map { action in
            { if !isRestoringFocus, !TVBackConsumption.wasJustConsumed() { action() } }
        })
        #else
        .padding(.leading, PrototypeLayout.guideInset)
        .padding(.top, isEmbeddedInPlayer ? 0 : PrototypeLayout.guideInset)
        .padding(.trailing, PrototypeLayout.guideTrailingInset)
        .background {
            if !isEmbeddedInPlayer { PrototypeGuideSurface() }
        }
        .clipShape(PrototypeLayout.guideShape)
        #endif
        .onChange(of: confirmedFocus, initial: true) { _, target in
            hasFocus = target != nil
            if let target {
                if pendingFocus == target { pendingFocus = nil }
                switch target {
                case .channel, .channelContent:
                    focusedProgram = nil
                case .program(let channelID, let programID, _):
                    focusedProgram = model.programs(for: channelID, from: guideStart, hours: guideHours)
                        .first { $0.id == programID }
                }
                selectedID = target.channelID
                selectedRowID = target.rowID
                if !isEmbeddedInPlayer { imports.noteGuideFocus(target.channelID) }
                lastFocused = target
                restrictDirectionalEntry = true
                railActive = false
                if isRestoringFocus, target == returnTarget {
                    focusRestored(restoreFocusRequest)
                }
            }
        }
        #if os(iOS)
        .onChange(of: selectedRowID) { _, row in
            // A tapped cell is already on screen; only follow selections made
            // elsewhere (search, playback return) so the guide stays put.
            guard row != confirmedFocus?.rowID else { return }
            scrollID = row
        }
        #endif
        .onChange(of: nowRequest) { _, _ in goToNow() }
        .onChange(of: isRestoringFocus) { _, restoring in
            if !restoring { restorationFallback = nil }
            if restoring, restorationTarget == nil {
                focusRestored(restoreFocusRequest)
            }
        }
        .onChange(of: restoreFocusRequest) { _, request in
            guard isPresented, !isLoading, model.channels.isEmpty else { return }
            recoveryFocused = true
            railActive = false
            focusRestored(request)
        }
        .onChange(of: model.guideChannels) { _, rows in
            if rows.isEmpty, isRestoringFocus {
                focusRestored(restoreFocusRequest)
            }
            if !rows.contains(where: { $0.id == selectedRowID }) {
                focusedProgram = nil
                let replacement = selectedID.flatMap { model.guideRow(for: $0) } ?? rows.first?.id
                selectedRowID = replacement
                selectedID = replacement?.channelID
                scrollID = replacement
                lastFocused = replacement.map {
                    .defaultContent(in: model, row: $0, from: guideStart, hours: guideHours)
                }
                if hasFocus, !isRestoringFocus {
                    pendingFocus = lastFocused
                    focused = lastFocused
                }
            }
        }
        .onChange(of: browseReturnTarget) { _, target in
            guard requiresContentFocusHandoff, let target else { return }
            pendingFocus = target
            focused = target
        }
        .task(id: GuideWorkRequest(window: guideRequest, preparationRevision: preparationRevision)) {
            guard let guideRequest else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Block by block, so extending the guide fetches only the new hours
            // instead of re-requesting the whole span as one partly loaded chunk.
            var blockStart = guideRequest.from
            let force = appliedPreparationRevision != preparationRevision
            while blockStart < guideRequest.to, !Task.isCancelled {
                let blockEnd = min(guideRequest.to, blockStart.addingTimeInterval(Self.guideStepSeconds))
                await imports.reloadServerGuides(
                    channelIDs: guideRequest.channels.map(\.id),
                    from: blockStart, to: blockEnd, into: model, force: force
                )
                blockStart = blockEnd
            }
            if !Task.isCancelled { appliedPreparationRevision = preparationRevision }
        }
        .task(id: cachedWindowRequest) {
            guard let cachedWindowRequest else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected guide window delay failure")
                return
            }
            guard !Task.isCancelled else { return }
            await imports.loadGuideWindow(
                channelIDs: cachedWindowRequest.channelIDs,
                range: cachedWindowRequest.range, into: model
            )
        }
        .task(id: generatedWindowRequest) {
            guard let generatedWindowRequest else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected library guide delay failure")
                return
            }
            guard !Task.isCancelled else { return }
            loadLibraryGuide?(generatedWindowRequest.channelIDs, generatedWindowRequest.range)
        }
        .onDisappear { hasFocus = false }
    }

    /// The tvOS glass guide draws no section labels.
    private static var showsSectionLabels: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private struct PrototypeGuideRowRevision: Equatable {
        let entry: LiveTVGuideChannel
        let showsSection: Bool
        let programs: [LiveTVPrototypeProgram]
        let start: Date
        let hours: Int
        let now: Date
        let width: CGFloat
        let gatesFocus: Bool
        let returnTarget: PrototypeBrowseFocus?
        let favorite: Bool
        let playing: Bool
        let gapState: LiveTVGuideGapState
        let selectionAction: LocalizedStringResource?
        let selectionMarked: Bool
        let canHide: Bool
        let routesGlassPresentation: Bool
        let page: Int
    }

    #if os(tvOS)
    private func focusCurrentRow(_ row: LiveTVGuideRowID) {
        requestRowFocus(.defaultContent(in: model, row: row, from: guideStart, hours: guideHours),
                        usesNativeCell: true)
    }

    private func focusNowOnRow(_ row: LiveTVGuideRowID) {
        guard model.now >= guideStart, model.now < guideStart.addingTimeInterval(guideSpan) else {
            goToNow()
            return
        }
        revealCurrentTime(width: guideWidth)
        browsesTimeline = false
        requestRowFocus(horizontalNowTarget(on: row))
    }

    /// Where `focusNowOnRow` lands when all it does is focus the programme on now: nil while the timeline is being
    /// browsed (it ends that) or when now is outside the guide (it goes to now).
    private func nowTimelineX() -> CGFloat? {
        guard !browsesTimeline, model.now >= guideStart, model.now < guideStart.addingTimeInterval(guideSpan) else {
            return nil
        }
        return PrototypeLayout.timelineX(model.now.timeIntervalSince(guideStart), for: guideWidth)
    }

    private func isAtNowBoundary(_ row: LiveTVGuideRowID, offset: CGFloat) -> Bool {
        let nowX = PrototypeLayout.timelineX(model.now.timeIntervalSince(guideStart), for: guideWidth)
        return model.now >= guideStart && model.now < guideStart.addingTimeInterval(guideSpan)
            && offset <= nowX + 1 && confirmedFocus == horizontalNowTarget(on: row)
    }

    private func focusChannelPlate(_ row: LiveTVGuideRowID) {
        browsesTimeline = false
        requestRowFocus(.channel(row.channelID, section: row.section))
    }

    private func horizontalSlots(on row: LiveTVGuideRowID) -> [LiveTVGuideSlot] {
        let programs = model.programs(for: row.channelID, from: guideStart, hours: guideHours)
        guard !programs.isEmpty else { return [] }
        return PrototypeGuideRow.drawnSlots(programs: programs, start: guideStart, span: guideSpan, width: guideWidth)
    }

    private func horizontalTarget(for slot: LiveTVGuideSlot, on row: LiveTVGuideRowID) -> PrototypeBrowseFocus {
        if let program = slot.program {
            return .program(channelID: row.channelID, programID: program.id, section: row.section)
        }
        return .channelContent(row.channelID, slotID: slot.id, section: row.section)
    }

    private func horizontalNowTarget(on row: LiveTVGuideRowID) -> PrototypeBrowseFocus {
        if let slot = horizontalSlots(on: row).first(where: { $0.start <= model.now && model.now < $0.end }) {
            return horizontalTarget(for: slot, on: row)
        }
        return .channelContent(row.channelID, section: row.section)
    }

    /// UIKit can ignore a clipped preceding cell even when a few points of it are visible.
    /// Reveal and focus that cell together, without using the press on the pinned column.
    private func focusEarlierSlot(_ row: LiveTVGuideRowID, offset: CGFloat, viewport: CGFloat) -> Bool {
        let slots = horizontalSlots(on: row)
        guard let index = slots.firstIndex(where: { horizontalTarget(for: $0, on: row) == confirmedFocus }),
              index > slots.startIndex else { return false }
        let previous = slots[index - 1]
        let start = PrototypeLayout.timelineX(previous.start.timeIntervalSince(guideStart), for: guideWidth)
        let end = PrototypeLayout.timelineX(previous.end.timeIntervalSince(guideStart), for: guideWidth)
        let reveal = max(0, min(offset, max(start, end - viewport)))
        guard offset - reveal <= viewport else { return false }
        if reveal < offset {
            setTimelineOffset(reveal)
            nativeScroll.jump(toTimelineOffset: reveal)
        }
        requestRowFocus(horizontalTarget(for: previous, on: row))
        return true
    }

    private func requestRowFocus(_ target: PrototypeBrowseFocus, usesNativeCell: Bool = false) {
        let row = target.rowID
        pendingFocus = target
        let ready = usesNativeCell ? nativeScroll.hasVisibleCell(row) : mountedRows.contains(row)
        #if DEBUG
        GuideNavigationProfileHook.verticalRoute?("request row=\(row.channelID) nativeReady=\(ready) mounted=\(mountedRows.contains(row)) visible=\(nativeScroll.isVisible(row)) restoring=\(isRestoringFocus)")
        #endif
        if ready {
            completePendingFocus(row)
        } else {
            nativeScroll.scrollTo(row, anchor: .center)
            if usesNativeCell, pendingFocus == target, nativeScroll.hasVisibleCell(row, layingOut: true) {
                completePendingFocus(row)
            }
        }
    }
    #endif

    /// A row's stationary content: the touch guide's section label, then the row. It reports mounting for focus restoration.
    private func rowPlane<Content: View>(
        _ entry: LiveTVGuideChannel, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.sectionLabelGap) {
            #if !os(tvOS)
            if entry.startsSection, entry.section != model.guideChannels.first?.section {
                PrototypeGuideSectionLabel(section: entry.section)
            }
            #endif
            content()
        }
        .id(entry.id)
        .onAppear { mountRow(entry.id) }
        .onDisappear { mountedRows.remove(entry.id) }
    }

    private func mountRow(_ row: LiveTVGuideRowID) {
        mountedRows.insert(row)
        completePendingFocus(row)
    }

    private func guideRow(
        _ entry: LiveTVGuideChannel, width: CGFloat, returnTarget: PrototypeBrowseFocus?,
        scrollTo: @escaping (LiveTVGuideRowID, UnitPoint) -> Void
    ) -> PrototypeGuideRow {
        let channel = entry.channel
        return PrototypeGuideRow(
            channel: channel, section: entry.section,
            programs: model.programs(for: channel.id, from: guideStart, hours: guideHours),
            start: guideStart, now: model.now,
            width: width, span: guideSpan, timeline: timeline, focus: $focused,
            railActive: (railActive && restrictDirectionalEntry)
                || isRestoringFocus || requiresContentFocusHandoff,
            returnTarget: returnTarget,
            favorite: model.favoriteIDs.contains(channel.id),
            playing: model.playingChannelID == channel.id,
            toggleFavorite: { model.toggleFavoriteWithFeedback(channel.id) },
            tune: { tune(entry.id) }, details: details, controls: openControls,
            top: { goToTop(scrollTo: scrollTo) }, goToNow: goToNow,
            focusChanged: confirmFocus, sources: openSources, guideTime: openGuideTime,
            hide: hideChannel.map { action in { action(channel, entry.id) } },
            guideGapState: imports.gapState(for: channel, from: dataRange.start, to: dataRange.end),
            selectionAction: selectionAction.map {
                selectedChannelIDs.contains(channel.id) ? "Show in Multiview" : $0
            },
            selectionMarked: selectedChannelIDs.contains(channel.id),
            openLibraryItem: openLibraryItem,
            selectedTarget: touchSelection,
            selectForPreview: previewChannel.map { action in { action(entry.id) } },
            onChannelSelect: onChannelSelect.map { action in { action(channel) } },
            onProgramHold: onProgramHold.map { action in { program, frame in action(channel, program, frame) } }
        )
    }

    private var serverGuideRequest: PrototypeServerGuideRequest? {
        guard isPresented, scenePhase == .active else { return nil }
        let guideSources = Set(imports.serverSources.filter {
            $0.source.isEnabled && $0.availability?.supportsGuide == true
                && $0.guideFailure != .permissionDenied
        }.map(\.id))
        guard !guideSources.isEmpty else { return nil }
        return PrototypeServerGuideRequest(
            rows: model.guideRowIDs,
            anchorIndex: guideAnchorIndex,
            references: imports.serverChannelReferences, enabledSourceIDs: guideSources,
            from: dataRange.start, to: dataRange.end
        )
    }

    private var guideStart: Date {
        timeAnchor.addingTimeInterval(guideOffset)
    }

    private var guideAnchorIndex: Int? {
        model.guideRowIndex(near: scrollID ?? confirmedFocus?.rowID ?? selectedRowID)
    }

    private var cachedGuideRequest: PrototypeGuideWindowRequest? {
        guard isPresented, scenePhase == .active, imports.supportsDurableCatalog else { return nil }
        return PrototypeGuideWindowRequest(
            rows: model.guideRowIDs,
            anchorIndex: guideAnchorIndex,
            from: dataRange.start, to: dataRange.end,
            sources: imports.guideSources, enabledSourceIDs: imports.enabledSourceIDs,
            mappings: imports.mappingOverrides
        )
    }

    private var libraryGuideRequest: PrototypeLibraryGuideRequest? {
        guard isPresented, scenePhase == .active, let libraryCatalog, !libraryCatalog.channels.isEmpty else { return nil }
        return PrototypeLibraryGuideRequest(
            catalog: libraryCatalog, rows: model.guideRowIDs,
            anchorIndex: guideAnchorIndex,
            from: dataRange.start, to: dataRange.end
        )
    }

    /// Listings are loaded for the six-hour block being viewed and the blocks
    /// either side, not the whole browsable span, so a long guide keeps a
    /// bounded amount of data live and each move loads only what it reaches.
    private var dataRange: DateInterval {
        let step = Self.guideStepSeconds
        let end = guideStart.addingTimeInterval(guideSpan)
        let first = guideStart.addingTimeInterval(Double(max(0, timeline.block - 1)) * step)
        let last = min(end, guideStart.addingTimeInterval(Double(timeline.block + 2) * step))
        return DateInterval(start: min(first, last), end: last)
    }

    private var allChannelsHidden: Bool {
        guard model.visibleChannels.isEmpty else { return false }
        let hidden = model.effectiveHiddenChannelIDs
        return !model.channels.isEmpty && model.channels.allSatisfy { hidden.contains($0.id) }
    }

    private var currentSection: LiveTVGuideSection {
        scrollID.flatMap { model.guideEntry(for: $0)?.section }
            ?? model.guideChannels.first?.section ?? .channels
    }

    private var returnTarget: PrototypeBrowseFocus? {
        if isRestoringFocus { return restorationFallback ?? restorationTarget }
        return browseReturnTarget
    }

    private var browseReturnTarget: PrototypeBrowseFocus? {
        if let lastFocused, lastFocused.rowID == selectedRowID,
           lastFocused.isAvailable(in: model, from: guideStart, hours: guideHours) {
            return lastFocused
        }
        let row = selectedID.flatMap {
            model.guideRow(for: $0, preferring: selectedRowID?.section)
        } ?? model.guideChannels.first?.id
        return row.map { .defaultContent(in: model, row: $0, from: guideStart, hours: guideHours) }
    }

    private var requiresContentFocusHandoff: Bool {
        guard isPresented, !railActive, !isRestoringFocus, let lastFocused,
              lastFocused.rowID == selectedRowID else { return false }
        return !lastFocused.isAvailable(in: model, from: guideStart, hours: guideHours)
    }

    private var restorationTarget: PrototypeBrowseFocus? {
        restoresPlaybackFocus ? playbackReturnTarget : browseReturnTarget
    }

    private var playbackReturnTarget: PrototypeBrowseFocus? {
        .returningToPlayback(
            in: model, selectedChannelID: selectedID, originRow: watchOrigin,
            from: guideStart, hours: guideHours
        )
    }

    private func completePendingFocus(_ id: LiveTVGuideRowID) {
        guard !isRestoringFocus, pendingFocus?.rowID == id else { return }
        #if DEBUG && os(tvOS)
        GuideNavigationProfileHook.verticalRoute?("submit row=\(id.channelID) repeated=\(focused == pendingFocus) alreadyConfirmed=\(confirmedFocus == pendingFocus) visible=\(nativeScroll.isVisible(id))")
        #endif
        focused = pendingFocus
        pendingFocus = nil
    }

    /// On touch, the last thing tapped is the selection the info bar shows.
    private var touchSelection: PrototypeBrowseFocus? {
        #if os(iOS)
        confirmedFocus
        #else
        nil
        #endif
    }

    private func confirmFocus(_ target: PrototypeBrowseFocus, _ isFocused: Bool) {
        #if DEBUG && os(tvOS)
        if isFocused { GuideNavigationProfileHook.focus?(target) }
        #endif
        model.noteGuideInteraction()
        if isFocused { confirmedFocus = target }
        else if confirmedFocus == target { confirmedFocus = nil }
    }

    /// `isVisible` lets a row that is already on screen keep its position: focus is restored on it without a scroll.
    private func restoreFocus(
        scrollTo: (LiveTVGuideRowID, UnitPoint) -> Void,
        isVisible: (LiveTVGuideRowID) -> Bool = { _ in false },
        width: CGFloat
    ) async {
        guard isPresented, isRestoringFocus else { return }
        let request = restoreFocusRequest
        if restoresPlaybackFocus { revealCurrentTime(width: width) }
        guard let target = restorationTarget else {
            railActive = false
            focusRestored(request)
            return
        }
        pendingFocus = nil
        restorationFallback = nil
        let mayScroll = guideFocusMayScroll
        let needsScroll = mayScroll && !isVisible(target.rowID)
        if needsScroll { scrollTo(target.rowID, .center) }
        if needsScroll && !reduceMotion { try? await Task.sleep(for: .milliseconds(340)) }
        else { await Task.yield() }
        guard !Task.isCancelled else { return }
        guard var latestTarget = restorationTarget else {
            railActive = false
            focusRestored(request)
            return
        }
        if restoresPlaybackFocus { revealCurrentTime(width: width) }
        if mayScroll, latestTarget.rowID != target.rowID, !isVisible(latestTarget.rowID) {
            scrollTo(latestTarget.rowID, .center)
        }
        #if os(tvOS)
        if !mayScroll, !isVisible(latestTarget.rowID) {
            // A saved focus row can still be admitted without being in the saved viewport.
            // Keep the viewport and hand off to the first mounted row instead.
            if scrollID == nil { await waitForRow(latestTarget.rowID) }
            guard !Task.isCancelled else { return }
            if !isVisible(latestTarget.rowID), let row = scrollID, isVisible(row) {
                latestTarget = .defaultContent(in: model, row: row, from: guideStart, hours: guideHours)
                restorationFallback = latestTarget
            }
        }
        #endif
        await waitForRow(latestTarget.rowID)
        guard !Task.isCancelled else { return }
        focused = latestTarget
        await waitForFocus(latestTarget)
        guard !Task.isCancelled else { return }
        if confirmedFocus == latestTarget {
            focusRestored(request)
            return
        }
        let fallback = PrototypeBrowseFocus.channel(latestTarget.channelID, section: latestTarget.rowID.section)
        restorationFallback = fallback
        if mayScroll, !isVisible(latestTarget.rowID) { scrollTo(latestTarget.rowID, .center) }
        await Task.yield()
        guard !Task.isCancelled else { return }
        HandoffDiagnostics.emit("LIVE_TV event=guideFocusFallback kind=channel")
        focused = fallback
        await waitForFocus(fallback)
        guard !Task.isCancelled else { return }
        if confirmedFocus != fallback {
            HandoffDiagnostics.emit("LIVE_TV event=guideFocusRestore result=unconfirmed")
            // A failed handoff must not strand directional focus on the sidebar.
            restrictDirectionalEntry = false
        }
        railActive = false
        focusRestored(request)
    }

    private func waitForRow(_ row: LiveTVGuideRowID) async {
        for _ in 0..<10 {
            guard !Task.isCancelled, !mountedRows.contains(row) else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForFocus(_ target: PrototypeBrowseFocus) async {
        for _ in 0..<8 {
            guard !Task.isCancelled, confirmedFocus != target else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The window start moved while the viewer has scrolled right: the anchor follows the clock and
    /// the scroll gives back the same distance, so the programmes on screen stay where they are.
    /// A guide at its start is moved by the owner, and a guide set to another day stays put.
    private func shiftScrolledTimeline(from old: Date, to new: Date) {
        guard guideOffset == 0, timelineOffset > 0, timeAnchor == old, new > old, guideWidth > 0 else { return }
        let shifted = LiveTVGuideClock.timelineAfterShift(
            anchor: old, offset: timelineOffset, newAnchor: new,
            pointsPerSecond: PrototypeLayout.timelineX(1, for: guideWidth))
        let apply = {
            timeAnchor = shifted.anchor
            setTimelineOffset(shifted.offset)
        }
        if reduceMotion || new.timeIntervalSince(old) > LiveTVGuideClock.slot { apply() }
        else { withAnimation(.easeInOut(duration: LiveTVGuideClock.shiftAnimationDuration), apply) }
    }

    /// The window moved on with the clock: a focused programme that ended before the new start has
    /// scrolled out, so focus moves to the same channel's current programme. The row never changes.
    private func refocusIfProgramLeftWindow() {
        guard guideStart == model.guideWindowStart,
              case .program(let channelID, let programID, let section)? = confirmedFocus,
              let focusedProgram, focusedProgram.id == programID, focusedProgram.end <= guideStart,
              let row = confirmedFocus?.rowID else { return }
        let target: PrototypeBrowseFocus = model.programToFocusAfterWindowShift(
            focusedProgramID: programID, channelID: channelID
        ).map { .program(channelID: channelID, programID: $0.id, section: section) }
            ?? .defaultContent(in: model, row: row, from: guideStart, hours: guideHours)
        lastFocused = target
        pendingFocus = target
        focused = target
    }

    private func revealCurrentTime(width: CGFloat) {
        if model.now < guideStart || model.now >= guideStart.addingTimeInterval(Double(guideHours) * 3_600) {
            goToNow()
        }
        let viewport = PrototypeLayout.viewportSeconds(for: width)
        let visibleStart = guideStart.addingTimeInterval(
            Double(timeline.offset / PrototypeLayout.timelineX(1, for: width))
        )
        let visibleEnd = visibleStart.addingTimeInterval(viewport)
        if model.now < visibleStart || model.now >= visibleEnd {
            setTimelineOffset(min(PrototypeLayout.maximumTimelineOffset(for: width, span: guideSpan), max(
                0, PrototypeLayout.timelineX(model.now.timeIntervalSince(guideStart) - viewport / 4, for: width)
            )))
        }
    }

    private static let initialGuideHours = Int(PrototypeLayout.timelineSpanSeconds / 3_600)
    private static let guideStepSeconds = PrototypeLayout.timelineSpanSeconds

    private var guideSpan: TimeInterval { TimeInterval(guideHours) * 3_600 }

    /// Adds the next six hours once the viewer is within a screen of the end,
    /// so listings are requested before they are reached.
    private static func extendGuideIfNeeded(at offset: CGFloat, width: CGFloat, hours: Binding<Int>) {
        let span = TimeInterval(hours.wrappedValue) * 3_600
        guard width > 0, span < PrototypeLayout.maximumTimelineSpanSeconds else { return }
        let remaining = PrototypeLayout.maximumTimelineOffset(for: width, span: span) - offset
        guard remaining <= PrototypeLayout.timelineWidth(for: width) else { return }
        hours.wrappedValue = min(
            Int(PrototypeLayout.maximumTimelineSpanSeconds / 3_600),
            hours.wrappedValue + Int(Self.guideStepSeconds / 3_600))
    }

    /// Moves the rows and the owner's committed offset together, so a pending
    /// scroll commit can't restore where the guide was.
    private func setTimelineOffset(_ offset: CGFloat) {
        timeline.reset(to: offset)
        timelineOffset = offset
        #if os(tvOS)
        timelineJump = PrototypeGuideTimelineJump(offset: offset, sequence: (timelineJump?.sequence ?? 0) + 1)
        #endif
    }

    private func goToNow() {
        #if os(tvOS)
        browsesTimeline = false
        #endif
        model.alignGuideWindowToNow()
        timeAnchor = model.guideWindowStart
        guideOffset = 0
        guideHours = Self.initialGuideHours
        setTimelineOffset(0)
        if let row = selectedRowID, model.guideEntry(for: row) != nil {
            let target = PrototypeBrowseFocus.defaultContent(in: model, row: row, from: guideStart, hours: guideHours)
            lastFocused = target
            pendingFocus = target
            focused = target
        }
    }

    private func goToTop(scrollTo: (LiveTVGuideRowID, UnitPoint) -> Void, movesFocus: Bool = true) {
        guard let first = model.guideChannels.first else { return }
        selectedID = first.channel.id
        selectedRowID = first.id
        focusedProgram = nil
        scrollTo(first.id, .top)
        if movesFocus {
            railActive = false
            pendingFocus = .defaultContent(in: model, row: first.id, from: guideStart, hours: guideHours)
            focused = pendingFocus
        }
    }
}

struct PrototypeGuideSectionLabel: View {
    let section: LiveTVGuideSection
    @Environment(\.themePalette) private var palette
    @ScaledMetric(relativeTo: .caption) private var fontSize = PrototypeLayout.sectionFontSize

    var body: some View {
        Text(section.title)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, PrototypeLayout.rowInset)
            #if os(tvOS)
            .frame(height: PrototypeLayout.guideSectionLabelHeight(fontSize: fontSize), alignment: .leading)
            #else
            .frame(minHeight: PrototypeLayout.sectionLabelHeight, alignment: .leading)
            #endif
            .accessibilityAddTraits(.isHeader)
    }
}

struct PrototypeTimeRuler: View {
    let start: Date
    let now: Date
    let width: CGFloat
    let timelineOffset: CGFloat
    let section: LiveTVGuideSection
    let showsNowMarker: Bool
    var isLoading = false
    var span: TimeInterval = PrototypeLayout.timelineSpanSeconds
    @Environment(\.themePalette) private var palette
    @Environment(\.calendar) private var calendar
    #if os(tvOS)
    @Environment(\.prototypeGuideSheetPlan) private var sheetPlan
    #endif
    @Environment(\.layoutDirection) private var direction
    @ScaledMetric(relativeTo: .caption) private var scaledHeight: CGFloat = PrototypeLayout.rulerHeight

    /// The sheet's shorter ruler while the guide sits on it.
    private var height: CGFloat {
        #if os(tvOS)
        sheetPlan?.rulerHeight ?? scaledHeight
        #else
        scaledHeight
        #endif
    }

    var body: some View {
        HStack(alignment: .center, spacing: PrototypeLayout.columnGap) {
            Group {
                #if os(tvOS)
                // The channel heading is drawn above the guide; this cell stays empty.
                Color.clear.frame(height: height)
                #else
                if isLoading {
                    PrototypeSkeletonText(font: .caption, fraction: 0.6)
                        .padding(.horizontal, PrototypeLayout.rowInset)
                        .frame(height: height)
                } else {
                    PrototypeGuideSectionLabel(section: section)
                }
                #endif
            }
            .frame(width: PrototypeLayout.stationWidth(for: width), alignment: .leading)
            GeometryReader { geometry in
                let tickWidth = geometry.size.width * 1_800 / PrototypeLayout.viewportSeconds(for: width)
                let ticks = visibleTicks(tickWidth: tickWidth)
                HStack(spacing: 0) {
                    // Only labels around the visible time are built; the rest is space.
                    Color.clear.frame(width: CGFloat(ticks.lowerBound) * tickWidth)
                    ForEach(ticks, id: \.self) { tick in
                        let time = start.addingTimeInterval(TimeInterval(tick * 1_800))
                        // A time the timeline has scrolled past slides in to the visible edge, and goes once it
                        // no longer fits before the next one, so no time reads cut off.
                        let lead = PrototypeGuideCellMetrics.rulerLabelLead(
                            offset: timelineOffset, tickX: CGFloat(tick) * tickWidth, tickWidth: tickWidth,
                            labelWidth: PrototypeGuideCellMetrics.rulerLabelWidth(fontSize: PrototypeLayout.rulerFontSize))
                        // Midnight carries the new day's name.
                        Text(time, format: calendar.startOfDay(for: time) == time
                            ? .dateTime.weekday(.abbreviated).hour().minute()
                            : .dateTime.hour().minute())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            #if os(tvOS)
                            .font(.system(size: PrototypeLayout.rulerFontSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(PrototypePlayingGlass.rulerInkOpacity))
                            .padding(.leading, PrototypeLayout.rulerLabelInset)
                            #else
                            .padding(.leading, PrototypeLayout.rowInset)
                            #endif
                            .padding(.leading, lead ?? 0)
                            .opacity(lead == nil ? 0 : 1)
                            .frame(width: tickWidth, alignment: .leading)
                    }
                }
                .frame(width: PrototypeLayout.timelineContentWidth(for: width, span: span), height: height,
                       alignment: .leading)
                .frame(width: geometry.size.width, alignment: .leading)
                .offset(x: direction == .rightToLeft ? timelineOffset : -timelineOffset)
            }
            .frame(height: height)
            .horizontalEdgeFadeMask(
                fadeWidth: PrototypeLayout.horizontalFade,
                leadingStrength: horizontalFade.leading,
                trailingStrength: horizontalFade.trailing
            )
            .overlay(alignment: .leading) {
                // Once browsing leaves today, the day stays pinned at the start.
                if let visibleDay, !isLoading {
                    Text(visibleDay, format: .dateTime.weekday(
                        PrototypeLayout.isCompact(width) ? .abbreviated : .wide))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, PrototypeLayout.rowInset)
                        .frame(maxHeight: .infinity)
                        .background(Capsule().fill(palette.cardOpaqueSurface))
                }
            }
            .overlay(alignment: .bottom) {
                // Apple-style tvOS shows "now" by the focused programme's fill instead.
                if showsNowMarker && Self.drawsNowMarker {
                    PrototypeNowMarker(
                        start: start, now: now, timelineOffset: timelineOffset,
                        viewportSeconds: PrototypeLayout.viewportSeconds(for: width)
                    )
                        .offset(y: PrototypeNowMarker.rulerOffset)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(palette.primaryText)
    }

    private static var drawsNowMarker: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Half-hour ticks from a screen before the visible time to a screen after it.
    private func visibleTicks(tickWidth: CGFloat) -> Range<Int> {
        let count = Int(span / 1_800)
        guard tickWidth > 0, count > 0 else { return 0..<0 }
        let perScreen = Int(ceil(PrototypeLayout.viewportSeconds(for: width) / 1_800))
        let first = Int(max(0, timelineOffset) / tickWidth)
        let lower = min(count, max(0, first - perScreen))
        return lower..<min(count, first + perScreen * 2 + 1)
    }

    /// The day at the visible timeline's leading edge, when it isn't today.
    private var visibleDay: Date? {
        let seconds = timelineOffset / PrototypeLayout.timelineX(1, for: width)
        let leading = start.addingTimeInterval(seconds.isFinite ? TimeInterval(seconds) : 0)
        return calendar.isDate(leading, inSameDayAs: now) ? nil : leading
    }

    private var horizontalFade: PrototypeScrollFade {
        return PrototypeScrollFade(
            before: timelineOffset,
            after: PrototypeLayout.maximumTimelineOffset(for: width, span: span) - timelineOffset,
            distance: PrototypeLayout.horizontalFade
        )
    }
}

struct PrototypeNowMarker: View {
    #if os(iOS)
    // Small enough to sit inside the touch ruler, under its times, instead of
    // hanging down over the first row.
    static let size = CGSize(width: 12, height: 7)
    static let rulerOffset: CGFloat = 0
    #else
    static let size = CGSize(width: 20, height: 12)
    static let rulerOffset = PrototypeLayout.gap
    #endif
    let start: Date
    let now: Date
    let timelineOffset: CGFloat
    var viewportSeconds: TimeInterval = 7_200
    @Environment(\.themePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let x = geometry.size.width * now.timeIntervalSince(start) / viewportSeconds - timelineOffset
            if x >= 0, x <= geometry.size.width {
                Image(systemName: "arrowtriangle.down.fill")
                    .resizable()
                    .foregroundStyle(palette.primaryText)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .shadow(color: .black.opacity(contrast == .increased ? 0.95 : 0.65), radius: 1, y: 1)
                    .position(x: x, y: Self.size.height / 2)
            }
        }
        .frame(height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PrototypeElapsedProgramFill: View {
    let elapsedWidth: CGFloat
    @Environment(\.themePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, max(0, elapsedWidth))
            if width > 0 {
                Rectangle()
                    .fill(palette.primaryText.opacity(contrast == .increased ? 0.16 : 0.08))
                    .frame(width: width, height: geometry.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PrototypeLayout.programRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PrototypeGuideRow: View {
    let channel: LiveTVPrototypeChannel
    var section: LiveTVGuideSection = .channels
    let programs: [LiveTVPrototypeProgram]
    let start: Date
    let now: Date
    let width: CGFloat
    var span: TimeInterval = PrototypeLayout.timelineSpanSeconds
    let timeline: PrototypeTimelineScroll
    let focus: FocusState<PrototypeBrowseFocus?>.Binding
    let railActive: Bool
    let returnTarget: PrototypeBrowseFocus?
    let favorite: Bool
    let playing: Bool
    let toggleFavorite: () -> Void
    let tune: () -> Void
    let details: (LiveTVPrototypeProgram) -> Void
    let controls: () -> Void
    let top: () -> Void
    let goToNow: () -> Void
    var focusChanged: (PrototypeBrowseFocus, Bool) -> Void = { _, _ in }
    var sources: () -> Void = {}
    var guideTime: () -> Void = {}
    var hide: (() -> Void)?
    var guideGapState: LiveTVGuideGapState?
    var selectionAction: LocalizedStringResource?
    var selectionMarked = false
    var openLibraryItem: ((LibraryChannelItem) -> Void)?
    /// What the viewer picked by touch, which has no focus to show it with.
    var selectedTarget: PrototypeBrowseFocus?
    var selectForPreview: (() -> Void)?
    var onChannelSelect: (() -> Void)?
    var onProgramHold: ((LiveTVPrototypeProgram?, CGRect) -> Void)?
    #if os(tvOS)
    /// Set once a hold fires, so the release that follows doesn't also act as a tap.
    @State private var holdConsumedSelect = false
    #endif
    @ScaledMetric(relativeTo: .subheadline) private var scaledRowHeight: CGFloat = PrototypeLayout.rowHeight

    private var rowHeight: CGFloat {
        PrototypeLayout.rowHeight(for: width, scaledHeight: scaledRowHeight)
    }

    private var currentLibraryItem: LibraryChannelItem? {
        guard channel.source == .plozz else { return nil }
        return programs.first { $0.start <= now && now < $0.end }?.libraryItem
    }

    private func isFocusDisabled(_ target: PrototypeBrowseFocus) -> Bool {
        #if os(iOS)
        // Directional-entry gates exist for the remote; disabling cells here
        // would silently swallow taps after the toolbar or search had focus.
        return false
        #else
        return railActive && returnTarget != target
        #endif
    }

    #if os(tvOS)
    enum Plane { case stationary, programmes }
    var plane: Plane = .stationary
    func inPlane(_ plane: Plane) -> Self {
        var copy = self
        copy.plane = plane
        return copy
    }
    #endif

    var body: some View {
        #if os(tvOS)
        if plane == .programmes { programmes }
        else { stationary }
        #else
        stationary
        #endif
    }

    private var stationary: some View {
        // These metrics depend on the row's geometry, not on the timeline page or slot.
        let timelineWidth = PrototypeLayout.timelineWidth(for: width)
        let viewportSeconds = PrototypeLayout.viewportSeconds(for: width)
        let cellGap = PrototypeLayout.cellGap
        return HStack(spacing: PrototypeLayout.columnGap) {
            PrototypeGuideStation(
                channel: channel, section: section,
                favorite: favorite, playing: playing, tune: tune, toggleFavorite: toggleFavorite,
                controls: controls, top: top, height: rowHeight,
                width: PrototypeLayout.stationWidth(for: width),
                focusChanged: { focusChanged(channelFocus, $0) },
                sources: sources, guideTime: programs.isEmpty ? nil : guideTime, hide: hide,
                selectionAction: selectionAction, selectionMarked: selectionMarked,
                libraryItem: currentLibraryItem, openLibraryItem: openLibraryItem,
                selectForPreview: selectForPreview, onSelect: onChannelSelect
            )
                .frame(width: PrototypeLayout.stationWidth(for: width))
                .focused(focus, equals: channelFocus)
                .disabled(isFocusDisabled(channelFocus))
            if programs.isEmpty {
                channelContent(
                    elapsedWidth: timelineWidth * now.timeIntervalSince(start) / viewportSeconds,
                    followsTimeline: true, viewportWidth: timelineWidth
                )
                    .frame(maxWidth: .infinity)
                    #if os(tvOS)
                    .padding(.trailing, cellGap)
                    #endif
            }
            #if os(iOS)
            if !programs.isEmpty {
                PrototypeTouchSynchronizedTimeline(
                    timeline: timeline,
                    isFocusedRow: focus.wrappedValue?.rowID == channelFocus.rowID,
                    viewportWidth: timelineWidth,
                    maximumOffset: max(0, PrototypeLayout.timelineContentWidth(for: width, span: span) - timelineWidth)
                ) { programmes }
                    .frame(width: timelineWidth, height: rowHeight)
            }
            #endif
        }
        .frame(height: rowHeight)
    }

    /// The programme cells at the full timeline width. On tvOS the native guide list scrolls this plane and the touch
    /// guide scrolls it in its own row. Only programmes near the viewport are built, because focus can't move to cells
    /// that haven't been made.
    private var programmes: some View {
        let timelineWidth = PrototypeLayout.timelineWidth(for: width)
        let viewportSeconds = PrototypeLayout.viewportSeconds(for: width)
        let cellGap = PrototypeLayout.cellGap
        return HStack(spacing: 0) {
            if !programs.isEmpty {
                ForEach(timelineItems(timelineWidth: timelineWidth, viewportSeconds: viewportSeconds)) { item in
                    if let slot = item.slot {
                        let gap = min(cellGap, item.width / 4)
                        let elapsed = timelineWidth * now.timeIntervalSince(slot.start) / viewportSeconds
                        if let program = slot.program {
                            programCell(
                                program, slot: slot, slotWidth: item.width, trailingGap: gap, elapsedWidth: elapsed)
                        } else if !Self.drawsGapCell(isEventSlot: channel.eventSlot != nil) {
                            // An event slot's single programme is all its row has: the time around it is left empty, as in the
                            // mockup (a row draws only its programmes), not filled with "No guide information".
                            Color.clear.frame(width: item.width, height: rowHeight)
                        } else {
                            channelContent(
                                slotID: slot.id,
                                elapsedWidth: elapsed, cellWidth: item.width - gap, viewportWidth: timelineWidth
                            )
                                .frame(width: item.width - gap)
                                .padding(.trailing, gap)
                                .frame(width: item.width, height: rowHeight)
                                .programSlotClip()
                        }
                    } else {
                        Color.clear.frame(width: item.width, height: rowHeight)
                    }
                }
            }
        }
        .frame(width: PrototypeLayout.timelineContentWidth(for: width, span: span), height: rowHeight)
    }

    private var channelFocus: PrototypeBrowseFocus {
        .channel(channel.id, section: section)
    }

    /// Where a slot starts on the full timeline (the `programmes` plane), leading-relative.
    private func cellX(of slot: LiveTVGuideSlot) -> CGFloat {
        let seconds = PrototypeLayout.viewportSeconds(for: width)
        guard seconds > 0 else { return 0 }
        return PrototypeLayout.timelineWidth(for: width) * slot.start.timeIntervalSince(start) / seconds
    }

    /// Whether the time with no listing draws a "No guide information" cell. Not on an event slot's row: its one programme is
    /// all the row has, and the mockup draws nothing around it.
    static func drawsGapCell(isEventSlot: Bool) -> Bool { !isEventSlot }

    private struct TimelineItem: Identifiable {
        let id: String
        let slot: LiveTVGuideSlot?
        let width: CGFloat
    }

    /// The row's slots within a screen either side of the visible one, with
    /// the rest collapsed into spacers. The window moves a screen at a time,
    /// so scrolling rebuilds rows only when it crosses into the next screen.
    private func timelineItems(timelineWidth: CGFloat, viewportSeconds: TimeInterval) -> [TimelineItem] {
        let slots = Self.drawnSlots(programs: programs, start: start, span: span, width: width)
        func slotWidth(_ slot: LiveTVGuideSlot) -> CGFloat {
            timelineWidth * slot.end.timeIntervalSince(slot.start) / viewportSeconds
        }
        guard timeline.pageWidth > 0 else {
            return slots.map { TimelineItem(id: $0.id, slot: $0, width: slotWidth($0)) }
        }
        let windowStart = start.addingTimeInterval(Double(timeline.page - 1) * viewportSeconds)
        let windowEnd = start.addingTimeInterval(Double(timeline.page + 3) * viewportSeconds)
        var items: [TimelineItem] = []
        var skipped: CGFloat = 0
        for slot in slots {
            let nearby = slot.end > windowStart && slot.start < windowEnd
            // The current programme is where vertical moves and restoration land.
            let current = slot.start <= now && now < slot.end
            if nearby || current {
                if skipped > 0 {
                    items.append(TimelineItem(id: "skipped-before-\(slot.id)", slot: nil, width: skipped))
                    skipped = 0
                }
                items.append(TimelineItem(id: slot.id, slot: slot, width: slotWidth(slot)))
            } else {
                skipped += slotWidth(slot)
            }
        }
        if skipped > 0 { items.append(TimelineItem(id: "skipped-end", slot: nil, width: skipped)) }
        return items
    }

    private func programFocus(_ id: String) -> PrototypeBrowseFocus {
        .program(channelID: channel.id, programID: id, section: section)
    }

    private func channelContent(
        slotID: String? = nil, elapsedWidth: CGFloat = 0, followsTimeline: Bool = false,
        cellWidth: CGFloat? = nil, viewportWidth: CGFloat
    ) -> some View {
        let target = PrototypeBrowseFocus.channelContent(channel.id, slotID: slotID, section: section)
        return Button {
            #if os(iOS)
            focusChanged(target, true)
            if selectionAction != nil { tune() }
            else { selectForPreview?() }
            #else
            if consumeHold() { return }
            tune()
            #endif
        } label: {
            PrototypeGuideGap(
                channelName: channel.name, height: rowHeight,
                state: guideGapState, showsStatus: focus.wrappedValue?.rowID == channelFocus.rowID,
                cellWidth: cellWidth, isIdleEvent: channel.eventSlot?.isIdle == true
            )
                .frame(maxWidth: .infinity)
                #if !os(tvOS)
                .background {
                    if followsTimeline {
                        PrototypeTimelineReader(timeline: timeline) {
                            PrototypeElapsedProgramFill(elapsedWidth: elapsedWidth - $0)
                        }
                    } else {
                        PrototypeElapsedProgramFill(elapsedWidth: elapsedWidth)
                    }
                }
                #endif
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(PrototypeGuideCellStyle(
            tone: .noData, cellWidth: cellWidth ?? viewportWidth, elapsedWidth: 0,
            focusChanged: { focusChanged(target, $0) }))
        .holdsForPresentation(onProgramHold.map { hold in { frame in hold(nil, frame) } }, consumed: $holdConsumedSelect)
        #else
        .buttonStyle(PrototypeButtonStyle(
            selected: selectedTarget == target,
            padded: false, surface: .guide, focusChanged: { focusChanged(target, $0) }
        ))
        #endif
        .focusEffectDisabled()
        .focused(focus, equals: target)
        .disabled(isFocusDisabled(target))
        .accessibilityLabel(Text(channel.name))
        .accessibilityValue(guideGapState.map { Text($0.title) } ?? Text(verbatim: ""))
        .accessibilityHint(Text(selectionAction ?? "Play channel"))
        .accessibilityAddTraits(selectionMarked ? .isSelected : [])
        .accessibilityIdentifier("live-tv-channel-content-\(section.rawValue)-\(channel.number)-\(slotID ?? "whole")")
        .optionalContextMenu(isAttached: onProgramHold == nil) {
            PrototypeChannelActions(
                favorite: favorite, play: tune, toggleFavorite: toggleFavorite, hide: hide,
                primaryTitle: selectionAction ?? "Play channel", isSelection: selectionAction != nil,
                libraryItem: currentLibraryItem, openLibraryItem: openLibraryItem, channel: channel)
            Button("Search channels", systemImage: "magnifyingglass", action: controls)
            Button(action: sources) {
                Label {
                    Text(SettingsCopy.tvSources)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
            Button("Back to top", systemImage: "arrow.up.to.line", action: top)
        }
    }

    /// One programme cell. Touch and the classic TV guide keep the outlined,
    /// padded button; the tvOS Liquid Glass guide tones the cell by the clock.
    private func programCell(
        _ program: LiveTVPrototypeProgram, slot: LiveTVGuideSlot, slotWidth: CGFloat, trailingGap: CGFloat, elapsedWidth: CGFloat
    ) -> some View {
        let cell = slotWidth - trailingGap
        return Button {
            #if os(tvOS)
            if consumeHold() { return }
            #endif
            activate(program)
        } label: {
            #if os(tvOS)
            // A programme that began before the visible edge keeps its title on screen: it starts at the edge.
            PrototypeTimelineReader(timeline: timeline) { offset in
                let lead = PrototypeGuideCellMetrics.titleLead(offset: offset, cellX: cellX(of: slot), cellWidth: cell)
                PrototypeGuideCellTitle(program: program, now: now, cellWidth: cell - lead, channelIsPlaying: playing)
                    .padding(.leading, lead)
            }
                .padding(.horizontal, PrototypeLayout.cellInset)
                .frame(width: cell, height: PrototypeLayout.programHeight(in: rowHeight), alignment: .leading)
            #else
            PrototypeProgramLabel(
                program: program, now: now,
                availableWidth: max(0, cell - PrototypeLayout.rowInset * 2)
            )
            .padding(.horizontal, min(PrototypeLayout.rowInset, slotWidth / 4))
            .frame(
                width: cell,
                height: PrototypeLayout.programHeight(in: rowHeight),
                alignment: .leading
            )
            .clipped()
            .background {
                PrototypeElapsedProgramFill(elapsedWidth: elapsedWidth)
            }
            #endif
        }
        #if os(tvOS)
        .buttonStyle(PrototypeGuideCellStyle(
            tone: PrototypeGuideTone(program: program, now: now), cellWidth: cell, elapsedWidth: elapsedWidth,
            clipsLeading: PrototypeGuideCellMetrics.continuesBeforeWindow(programStart: program.start, slotStart: slot.start),
            focusChanged: { focusChanged(programFocus(program.id), $0) }))
        .holdsForPresentation(onProgramHold.map { hold in { frame in hold(program, frame) } }, consumed: $holdConsumedSelect)
        #else
        .buttonStyle(PrototypeButtonStyle(
            selected: selectedTarget == programFocus(program.id),
            padded: false, surface: .program,
            focusChanged: { focusChanged(programFocus(program.id), $0) }
        ))
        #endif
        .focusEffectDisabled()
        .padding(.vertical, PrototypeLayout.programInset)
        .padding(.trailing, trailingGap)
        .frame(width: slotWidth, height: rowHeight)
        .programSlotClip()
        .focused(focus, equals: programFocus(program.id))
        .accessibilityIdentifier("live-tv-programme-\(program.id)")
        .disabled(isFocusDisabled(programFocus(program.id)))
        .optionalContextMenu(isAttached: onProgramHold == nil) {
            Button("Program details", systemImage: "info.circle") { details(program) }
            PrototypeChannelActions(
                favorite: favorite, play: tune, toggleFavorite: toggleFavorite, hide: hide,
                primaryTitle: selectionAction ?? "Play channel", isSelection: selectionAction != nil,
                libraryItem: channel.source == .plozz ? program.libraryItem : nil,
                openLibraryItem: openLibraryItem)
            Button("Search channels", systemImage: "magnifyingglass", action: controls)
            Button(action: sources) {
                Label {
                    Text(SettingsCopy.tvSources)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
            Button("Guide time", systemImage: "calendar", action: guideTime)
            Button("Back to top", systemImage: "arrow.up.to.line", action: top)
            Button("Now", systemImage: "clock", action: goToNow)
        }
    }

    /// True once when a hold has already handled this Select press.
    private func consumeHold() -> Bool {
        #if os(tvOS)
        guard holdConsumedSelect else { return false }
        holdConsumedSelect = false
        TVBackDiagnostics.notice("event=glassInputDropped reason=select-release-after-hold channel=\(channel.id)")
        return true
        #else
        return false
        #endif
    }

    /// The shortest slot drawn: a thinner one is absorbed by a neighbour. On tvOS a cell has to be wide enough to read as a
    /// programme (its gap included), not merely wider than its corner radii; elsewhere it only has to clear the radii.
    static func drawnSlots(
        programs: [LiveTVPrototypeProgram], start: Date, span: TimeInterval, width: CGFloat
    ) -> [LiveTVGuideSlot] {
        #if os(tvOS)
        let minimumWidth = max(PrototypeLayout.rowRadius * 2, PrototypeLayout.minimumCellWidth + PrototypeLayout.cellGap)
        #else
        let minimumWidth = PrototypeLayout.rowRadius * 2
        #endif
        let minimumDuration = LiveTVGuideTimeline.minimumDuration(
            viewportSeconds: PrototypeLayout.viewportSeconds(for: width),
            timelineWidth: Double(PrototypeLayout.timelineWidth(for: width)), minimumSlotWidth: Double(minimumWidth))
        return LiveTVGuideTimeline.slots(
            programs: programs, from: start, to: start.addingTimeInterval(span), minimumDuration: minimumDuration)
    }

    /// Touch selects the info bar and starts the channel's inline preview.
    /// Explicit Watch and the remote's Select still open fullscreen.
    private func activate(_ program: LiveTVPrototypeProgram) {
        #if os(iOS)
        if selectionAction == nil {
            focusChanged(programFocus(program.id), true)
            selectForPreview?()
            return
        }
        #endif
        open(program)
    }

    private func open(_ program: LiveTVPrototypeProgram) {
        switch LiveTVGuideCellSelection.action(for: program, now: now, picksChannel: selectionAction != nil) {
        case .tune: tune()
        case .details: details(program)
        case .nothing: break
        }
    }
}

struct PrototypeGuideStation: View {
    let channel: LiveTVPrototypeChannel
    let section: LiveTVGuideSection
    let favorite: Bool
    let playing: Bool
    let tune: () -> Void
    let toggleFavorite: () -> Void
    let controls: () -> Void
    let top: () -> Void
    var height: CGFloat? = nil
    var width: CGFloat? = nil
    var focusChanged: ((Bool) -> Void)?
    var sources: () -> Void = {}
    var guideTime: (() -> Void)?
    var hide: (() -> Void)?
    var selectionAction: LocalizedStringResource?
    var selectionMarked = false
    var libraryItem: LibraryChannelItem?
    var openLibraryItem: ((LibraryChannelItem) -> Void)?
    var selectForPreview: (() -> Void)?
    /// Select on the plate, when the presentation owner replaces the channel menu.
    var onSelect: (() -> Void)?

    var body: some View {
        Group {
            if selectionAction != nil {
                Button(action: tune) { stationMark }
                    .contextMenu {
                        PrototypeChannelActions(
                            favorite: favorite, play: tune, toggleFavorite: toggleFavorite, hide: hide,
                            primaryTitle: selectionAction ?? "Play channel", isSelection: true, channel: channel)
                    }
            } else if let onSelect {
                Button(action: onSelect) { stationMark }
            } else if let selectForPreview {
                Button {
                    focusChanged?(true)
                    selectForPreview()
                } label: {
                    stationMark
                }
                .contextMenu { channelActions }
            } else {
                Menu {
                    channelActions
                } label: {
                    stationMark
                }
            }
        }
        #if os(tvOS)
        .buttonStyle(PrototypeGuidePlateStyle(focusChanged: focusChanged))
        #else
        .buttonStyle(PrototypeButtonStyle(padded: false, surface: .station, focusChanged: focusChanged))
        #endif
        .focusEffectDisabled()
        .accessibilityLabel(Text(channel.name))
        .accessibilityValue(Text("Channel \(channel.number)"))
        .accessibilityHint(Text(selectionAction ?? (selectForPreview == nil ? "Channel actions" : "Play channel")))
        .accessibilityAddTraits(playing || selectionMarked ? .isSelected : [])
        .accessibilityIdentifier("live-tv-channel-\(section.rawValue)-\(channel.number)")
    }

    private var channelActions: some View {
        Group {
            PrototypeChannelActions(
                favorite: favorite, play: tune, toggleFavorite: toggleFavorite, hide: hide,
                libraryItem: libraryItem, openLibraryItem: openLibraryItem, channel: channel
            )
            Divider()
            Button("Search channels", systemImage: "magnifyingglass", action: controls)
            Button(action: sources) {
                Label {
                    Text(SettingsCopy.tvSources)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
            if let guideTime {
                Button("Guide time", systemImage: "calendar", action: guideTime)
            }
            Button("Back to top", systemImage: "arrow.up.to.line", action: top)
        }
    }

    @ViewBuilder
    private var stationMark: some View {
        #if os(tvOS)
        PrototypeGuidePlateContent(
            channel: channel,
            size: CGSize(
                width: width ?? PrototypeLayout.stationColumnWidth, height: height ?? PrototypeLayout.rowHeight)
        )
        .overlay(alignment: .topTrailing) { selectionBadge }
        #else
        PrototypeStationMark(
            channel: channel,
            plateSize: CGSize(
                width: width ?? PrototypeLayout.stationColumnWidth, height: height ?? PrototypeLayout.rowHeight
            ),
            cornerRadius: PrototypeLayout.rowRadius,
            usesBareLogo: true,
            usesSyncedMarks: true
        )
        .clipped()
        .overlay(alignment: .topTrailing) { selectionBadge }
        #endif
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if selectionMarked {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.8))
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PrototypeChannelActions: View {
    let favorite: Bool
    let play: () -> Void
    let toggleFavorite: () -> Void
    let hide: (() -> Void)?
    var primaryTitle: LocalizedStringResource = "Play channel"
    var isSelection = false
    var libraryItem: LibraryChannelItem?
    var openLibraryItem: ((LibraryChannelItem) -> Void)?
    /// The channel the menu is for; "Change Logo…" is offered when the host can change it.
    var channel: LiveTVPrototypeChannel?
    @Environment(\.changeChannelLogo) private var changeLogo
    @Environment(LiveTVPrototypeModel.self) private var logoModel: LiveTVPrototypeModel?

    var body: some View {
        Button(action: play) {
            Label {
                Text(primaryTitle)
            } icon: {
                Image(systemName: isSelection ? "rectangle.split.2x2" : "play.fill")
            }
        }
        Button(
            favorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: favorite ? "star.slash" : "star", action: toggleFavorite
        )
        if !isSelection, let libraryItem, let openLibraryItem {
            LibraryChannelNavigationButton(item: libraryItem, action: openLibraryItem)
        }
        if !isSelection, let channel, let changeLogo, logoModel?.canChangeLogo(of: channel) == true {
            Button("Change Logo…", systemImage: "photo") { changeLogo(channel) }
        }
        if let hide {
            Button("Hide channel", systemImage: "eye.slash", action: hide)
        }
    }
}

struct PrototypeProgramLabel: View {
    let program: LiveTVPrototypeProgram
    let now: Date
    var availableWidth: CGFloat? = nil
    @ScaledMetric(relativeTo: .subheadline) private var minimumTitleWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
            if let availableWidth, availableWidth < minimumTitleWidth {
                Image(systemName: "ellipsis").font(.caption)
            } else {
                Text(program.title).font(.system(size: fontSize, weight: .regular))
                    .lineLimit(availableWidth == nil ? 2 : 1)
            }
            if availableWidth == nil {
                Text(program.start, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit()).opacity(0.7)
                    .lineLimit(1)
            }
            if availableWidth == nil, program.start <= now && now < program.end {
                ProgressView(value: program.progress(at: now)).tint(ThemePalette.brandBlue)
                    .accessibilityLabel("Program progress")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(program.title))
        .accessibilityValue(
            Text("\(program.start, format: .dateTime.hour().minute()) to \(program.end, format: .dateTime.hour().minute())")
        )
    }
}

struct PrototypeGuideGap: View {
    let channelName: String
    let height: CGFloat
    var state: LiveTVGuideGapState?
    var showsStatus = false
    /// The tvOS cell's width; the "No guide information" title hides below 110 pt.
    var cellWidth: CGFloat?
    /// An event slot with no event: the cell says so instead of "No guide information".
    var isIdleEvent = false
    @Environment(\.themePalette) private var palette
    @Environment(\.isFocused) private var focused
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
            #if os(tvOS)
            if PrototypeGuideCellMetrics.showsTitle(cellWidth: cellWidth ?? .infinity) {
                Text(isIdleEvent ? "No event" : "No guide information")
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(PrototypeGuideCellTitle.ink(tone: .ended, focused: focused).opacity(isIdleEvent && !focused ? 0.7 : 1))
                    .lineLimit(1)
            }
            #else
            Text(channelName)
                .font(.system(size: fontSize))
                .foregroundStyle(palette.primaryText.opacity(0.8))
                .lineLimit(2)
            #endif
            if showsStatus, let state, state == .loading || state == .failed || state == .unrequested {
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, PrototypeLayout.cellInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .accessibilityHint("No program listing for this time.")
    }
}

/// Observes horizontal position without driving a scroll view. The ruler reads
/// the live value; rows and data requests subscribe to page and block changes.
@MainActor
@Observable
final class PrototypeTimelineScroll {
    var offset: CGFloat { didSet { updatePage() } }
    /// Which screen-width of the timeline the leading edge is on. Rows build
    /// their cells around it, so they rebuild per screen rather than per frame.
    private(set) var page = 0
    /// The visible timeline's width; zero builds every cell.
    @ObservationIgnored var pageWidth: CGFloat = 0 { didSet { updatePage() } }
    /// Programme time one page spans.
    @ObservationIgnored var pageSeconds: TimeInterval = 0 { didSet { updatePage() } }
    /// Which six-hour block the leading edge is in; guide listings load around it.
    private(set) var block = 0
    @ObservationIgnored var settled: ((CGFloat) -> Void)?
    /// Called during motion to prefetch the next timeline block.
    @ObservationIgnored var moved: ((CGFloat) -> Void)?
    @ObservationIgnored private var commit: Task<Void, Never>?

    init(offset: CGFloat = 0) {
        self.offset = offset
    }

    private func updatePage() {
        let next = pageWidth > 0 ? Int(max(0, offset) / pageWidth) : 0
        if next != page { page = next }
        let seconds = pageWidth > 0 ? Double(max(0, offset) / pageWidth) * pageSeconds : 0
        let nextBlock = Int(seconds / PrototypeLayout.timelineSpanSeconds)
        if nextBlock != block { block = nextBlock }
    }

    func reset(to value: CGFloat) {
        commit?.cancel()
        commit = nil
        offset = value
    }

    /// Publishes the scroll owner's position, then commits it after movement stops.
    func scrolled(to value: CGFloat) {
        offset = value
        moved?(value)
        commit?.cancel()
        commit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.settled?(self.offset)
        }
    }

    func stop() {
        commit?.cancel()
        commit = nil
        settled = nil
        moved = nil
    }
}

#if os(tvOS)
/// Fits the native guide list to whole rows in the height it is offered, top-aligned.
struct PrototypeWholeGuideRows: ViewModifier {
    let isActive: Bool
    let pitch: CGFloat
    let gap: CGFloat

    func body(content: Content) -> some View {
        if isActive {
            GeometryReader { geometry in
                content
                    .frame(height: PrototypeGuideCollectionLayout.wholeRowsHeight(
                        available: geometry.size.height, pitch: pitch, gap: gap))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            content
        }
    }
}
#endif

/// Reads the live offset in its own view, keeping the dependency out of the
/// caller's body.
struct PrototypeTimelineReader<Content: View>: View {
    let timeline: PrototypeTimelineScroll
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View { content(timeline.offset) }
}

#if os(iOS)
/// On iPhone and iPad, the dragged row publishes movement and the other touch
/// scrollers follow it without feeding back.
private struct PrototypeTouchSynchronizedTimeline<Content: View>: View {
    let timeline: PrototypeTimelineScroll
    let isFocusedRow: Bool
    let viewportWidth: CGFloat
    let maximumOffset: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(x: 0)
    @State private var tracking = Tracking()
    @State private var isDragging = false

    private final class Tracking {
        var current: CGFloat = 0
        var synchronizationTarget: CGFloat?
    }

    var body: some View {
        ScrollView(.horizontal) {
            content()
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        // A focused cell grows and casts its shadow past the row.
        .scrollClipDisabled()
        #endif
        .modifier(PrototypeTouchTimelineEdgeFade(timeline: timeline, maximumOffset: maximumOffset))
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in
            isDragging = phase == .tracking || phase == .interacting || phase == .decelerating
            if isDragging { tracking.synchronizationTarget = nil }
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            min(max(0, $0.contentOffset.x + $0.contentInsets.leading), maximumOffset)
        } action: { _, value in
            tracking.current = value
            if let target = tracking.synchronizationTarget {
                if abs(target - value) < 1 { tracking.synchronizationTarget = nil }
                return
            }
            guard isFocusedRow || isDragging, abs(timeline.offset - value) >= 1 else { return }
            timeline.scrolled(to: value)
        }
        .modifier(PrototypeTouchTimelineFollower(
            timeline: timeline, viewportWidth: viewportWidth, maximumOffset: maximumOffset,
            synchronize: synchronize
        ))
        .onAppear { synchronize(to: timeline.offset) }
    }

    private func synchronize(to value: CGFloat) {
        guard abs(tracking.current - value) >= 1 else { return }
        tracking.synchronizationTarget = value
        position.scrollTo(x: value)
    }
}

private struct PrototypeTouchTimelineFollower: ViewModifier {
    let timeline: PrototypeTimelineScroll
    let viewportWidth: CGFloat
    let maximumOffset: CGFloat
    let synchronize: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: timeline.offset) { _, value in synchronize(value) }
            .onChange(of: viewportWidth) { _, _ in
                synchronize(min(timeline.offset, maximumOffset))
            }
    }
}

private struct PrototypeTouchTimelineEdgeFade: ViewModifier {
    let timeline: PrototypeTimelineScroll
    let maximumOffset: CGFloat

    func body(content: Content) -> some View {
        let fade = PrototypeScrollFade(
            before: timeline.offset, after: maximumOffset - timeline.offset,
            distance: PrototypeLayout.horizontalFade
        )
        content.horizontalEdgeFadeMask(
            fadeWidth: PrototypeLayout.horizontalFade,
            verticalOverhang: Self.verticalOverhang,
            leadingStrength: fade.leading,
            trailingStrength: fade.trailing
        )
    }

    private static var verticalOverhang: CGFloat {
        #if os(tvOS)
        // Room for a focused cell's scale and shadow above and below the row.
        PrototypeLayout.rowGap * 3
        #else
        0
        #endif
    }
}
#endif
