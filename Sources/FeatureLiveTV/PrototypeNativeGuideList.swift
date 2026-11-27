#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit

@MainActor
final class PrototypeGuideScrollController {
    fileprivate weak var collection: UICollectionView?
    fileprivate var indices: [LiveTVGuideRowID: Int] = [:]
    fileprivate var jump: ((CGFloat) -> Void)?
    var firstVisibleRow: (() -> LiveTVGuideRowID?)?
    /// Programmatic scroll requests made through this controller; opening or restoring a position must make none.
    private(set) var scrollCommandCount = 0
    /// The same count across every list, for a caller that cannot reach this list's controller.
    private(set) static var totalScrollCommandCount = 0

    /// Unanimated and silent (no echo to `timelineDidScroll`). Update the ruler
    /// and supply the span before requesting a jump. The offset is leading-relative.
    func jump(toTimelineOffset offset: CGFloat) { jump?(offset) }

    /// Whether any part of the row is on screen now. It reads layout geometry only and does not lay the list out.
    func isVisible(_ row: LiveTVGuideRowID) -> Bool {
        guard let collection, let index = indices[row],
              let frame = collection.collectionViewLayout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0))?.frame else { return false }
        return frame.intersects(collection.bounds)
    }

    /// A reused host can be on screen without another SwiftUI onAppear.
    func hasVisibleCell(_ row: LiveTVGuideRowID, layingOut: Bool = false) -> Bool {
        guard let collection, let index = indices[row], let window = collection.window else { return false }
        if layingOut { collection.layoutIfNeeded() }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collection.cellForItem(at: path) else { return false }
        return cell.window === window && cell.frame.intersects(collection.bounds)
    }

    func scrollTo(_ row: LiveTVGuideRowID, anchor: UnitPoint) {
        guard let collection, let index = indices[row] else { return }
        scrollCommandCount += 1
        Self.totalScrollCommandCount += 1
        collection.layoutIfNeeded()
        guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let proposed = anchor == .top ? frame.minY : frame.midY - collection.bounds.height / 2
        let maxY = max(0, collection.contentSize.height - collection.bounds.height)
        collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: min(maxY, max(0, proposed))), animated: false)
    }
}

/// Where the list is first drawn: the row whose top the viewport started inside, and how far below that row's top it sat.
struct PrototypeGuideListViewport: Equatable {
    let row: LiveTVGuideRowID
    let relativeOffset: CGFloat
}

/// Physical collection coordinates are always LTR; public offsets are logical timeline points.
struct PrototypeGuideHorizontalGeometry: Equatable {
    let width: CGFloat
    let pinnedWidth: CGFloat
    let timelineWidth: CGFloat
    let isRTL: Bool

    var viewport: CGFloat { max(0, width - pinnedWidth) }
    var contentWidth: CGFloat { pinnedWidth + max(viewport, timelineWidth) }
    var maximumOffset: CGFloat { max(0, contentWidth - width) }

    func clamped(_ offset: CGFloat) -> CGFloat {
        min(maximumOffset, max(0, offset.isFinite ? offset : 0))
    }

    func physical(_ logical: CGFloat) -> CGFloat { isRTL ? maximumOffset - clamped(logical) : clamped(logical) }
    func logical(_ physical: CGFloat) -> CGFloat { clamped(isRTL ? maximumOffset - physical : physical) }

    func timelineRange(of frame: CGRect) -> ClosedRange<CGFloat> {
        if isRTL {
            return (contentWidth - pinnedWidth - frame.maxX)...(contentWidth - pinnedWidth - frame.minX)
        }
        return (frame.minX - pinnedWidth)...(frame.maxX - pinnedWidth)
    }

    /// Hide programmes behind the station. The collection itself clips the far edge.
    func scrollingClip(at x: CGFloat) -> CGRect {
        let origin = isRTL ? 0 : x + pinnedWidth
        let end = isRTL ? x + width - pinnedWidth : contentWidth
        return CGRect(x: origin, y: 0, width: max(0, end - origin), height: 0)
    }

    func oversizedStep(for range: ClosedRange<CGFloat>, at offset: CGFloat, forward: Bool) -> CGFloat? {
        guard viewport > 0, range.upperBound - range.lowerBound > viewport else { return nil }
        let edge = forward ? range.upperBound - viewport : range.lowerBound
        let target = clamped(forward ? min(offset + viewport, edge) : max(offset - viewport, edge))
        return (forward ? target - offset : offset - target) > 1 ? target : nil
    }

    func reveal(_ range: ClosedRange<CGFloat>, at offset: CGFloat, forward: Bool,
                leavingViewportSizedItem: Bool = false) -> CGFloat {
        let leading = range.lowerBound
        let trailing = range.upperBound - viewport
        let near = forward ? leading : trailing
        let far = forward ? trailing : leading
        if trailing > leading {
            // If the old and new viewports together cover the whole card,
            // enter at the far edge instead of requiring a redundant page.
            let nearIsVisible = forward ? leading >= offset && leading <= offset + viewport
                                        : range.upperBound >= offset && range.upperBound <= offset + viewport
            let farIsReachable = abs(far - offset) <= viewport
            return boundedStep(from: offset, toward: nearIsVisible && farIsReachable ? far : near, forward: forward)
        }
        // Keep visible neighbours on screen for reversal. After moving off a
        // card that filled the viewport, look ahead from the entering edge.
        let intersectsViewport = leading < offset + viewport && range.upperBound > offset
        return boundedStep(from: offset, toward: leavingViewportSizedItem && !intersectsViewport ? near : far,
                           forward: forward)
    }

    func boundedStep(from offset: CGFloat, toward target: CGFloat, forward: Bool) -> CGFloat {
        clamped(forward ? min(offset + viewport, max(offset, target)) : max(offset - viewport, min(offset, target)))
    }
}

/// The layout computes only requested rows, even when the catalog is very large.
@MainActor
final class PrototypeGuideCollectionLayout: UICollectionViewLayout {
    private var rowCount = 0
    private var rowHeight: CGFloat = PrototypeLayout.rowHeight + PrototypeLayout.rowGap
    private var sectionHeight: CGFloat = 0
    private var sectionStarts: [Int] = []
    private(set) var timelineWidth: CGFloat = 0
    private(set) var pinnedWidth: CGFloat = 0
    private(set) var isRTL = false

    var horizontal: PrototypeGuideHorizontalGeometry {
        let width = collectionView?.bounds.width ?? 0
        return PrototypeGuideHorizontalGeometry(
            width: width, pinnedWidth: min(width, pinnedWidth), timelineWidth: timelineWidth, isRTL: isRTL)
    }

    final class RowAttributes: UICollectionViewLayoutAttributes {
        // NSObject equality is nonisolated; UIKit builds and uses these attributes on the main actor.
        nonisolated(unsafe) var physicalOffset: CGFloat = 0
        nonisolated(unsafe) var horizontal = PrototypeGuideHorizontalGeometry(width: 0, pinnedWidth: 0, timelineWidth: 0, isRTL: false)

        override func copy(with zone: NSZone? = nil) -> Any {
            let copied = super.copy(with: zone)
            if let copy = copied as? RowAttributes {
                copy.physicalOffset = physicalOffset
                copy.horizontal = horizontal
            }
            return copied
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? RowAttributes else { return false }
            return physicalOffset == other.physicalOffset && horizontal == other.horizontal && super.isEqual(other)
        }
    }

    override class var layoutAttributesClass: AnyClass { RowAttributes.self }
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { false }

    func update(rowCount: Int, rowHeight: CGFloat, sectionHeight: CGFloat, sectionStarts: [Int],
                timelineWidth: CGFloat = 0, pinnedWidth: CGFloat = 0, isRTL: Bool = false) {
        guard self.rowCount != rowCount || self.rowHeight != rowHeight
                || self.sectionHeight != sectionHeight || self.sectionStarts != sectionStarts
                || self.timelineWidth != timelineWidth || self.pinnedWidth != pinnedWidth || self.isRTL != isRTL else { return }
        self.rowCount = rowCount
        self.rowHeight = rowHeight
        self.sectionHeight = sectionHeight
        self.sectionStarts = sectionStarts
        self.timelineWidth = timelineWidth
        self.pinnedWidth = pinnedWidth
        self.isRTL = isRTL
        invalidateLayout()
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: horizontal.contentWidth, height: PrototypeLayout.smallGap + CGFloat(rowCount) * rowHeight
                + CGFloat(sectionStarts.count) * sectionHeight)
    }

    /// Where a settled vertical scroll should rest: on a row edge, with the top row where the first row sits (after the
    /// lead-in), so no row shows cut under the ruler (mockup: scrolling stops on an edge). Of the two edges either side
    /// of `y`, the nearer one that keeps `focus` whole in a `height`-tall list; nil when neither does.
    func verticalStop(for y: CGFloat, height: CGFloat, keeping focus: CGRect) -> CGFloat? {
        let lead = PrototypeLayout.smallGap
        let maxY = max(0, collectionViewContentSize.height - height)
        guard rowCount > 0, height > 0, y.isFinite else { return nil }
        let probe = CGRect(x: 0, y: min(max(0, y), maxY) + lead, width: 1, height: 1)
        guard let index = layoutAttributesForElements(in: probe)?.first?.indexPath.item else { return nil }
        let lower = min(maxY, max(0, frame(at: index).minY - lead))
        let upper = index + 1 < rowCount ? min(maxY, frame(at: index + 1).minY - lead) : maxY
        return [lower, upper].sorted { abs($0 - y) < abs($1 - y) }
            .first { focus.minY >= $0 - 0.5 && focus.maxY <= $0 + height + 0.5 }
    }

    /// Where a focus-driven vertical scroll aimed at `y` should land instead: the row edge at or beyond `y` in the
    /// direction of travel. The focus engine aims just far enough to reveal the newly focused row on the side it scrolls
    /// towards, so going on to that side's next edge keeps the row whole while no row rests cut under the ruler. nil
    /// when there are no rows.
    func verticalStop(for y: CGFloat, height: CGFloat, movingDown: Bool) -> CGFloat? {
        let lead = PrototypeLayout.smallGap
        let maxY = max(0, collectionViewContentSize.height - height)
        guard rowCount > 0, height > 0, y.isFinite else { return nil }
        let clamped = min(max(0, y), maxY)
        let probe = CGRect(x: 0, y: clamped + lead, width: 1, height: 1)
        guard let index = layoutAttributesForElements(in: probe)?.first?.indexPath.item else { return nil }
        let lower = min(maxY, max(0, frame(at: index).minY - lead))
        let upper = index + 1 < rowCount ? min(maxY, frame(at: index + 1).minY - lead) : maxY
        if abs(lower - clamped) <= 0.5 { return lower }
        return movingDown ? upper : lower
    }

    /// A list height that holds whole rows: the lead-in, then as many rows (and the gaps between them) as fit.
    static func wholeRowsHeight(available: CGFloat, pitch: CGFloat, gap: CGFloat) -> CGFloat {
        let lead = PrototypeLayout.smallGap
        guard pitch > 0, available.isFinite, available >= lead + pitch - gap else { return available }
        let rows = ((available - lead + gap) / pitch).rounded(.down)
        return lead + rows * pitch - gap
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, (0..<rowCount).contains(indexPath.item) else { return nil }
        return attributes(at: indexPath, frame: frame(at: indexPath.item))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard rowCount > 0, !rect.isEmpty else { return [] }
        var lower = 0
        var upper = rowCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frame(at: middle).maxY <= rect.minY { lower = middle + 1 }
            else { upper = middle }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = lower
        while index < rowCount {
            let frame = frame(at: index)
            guard frame.minY < rect.maxY else { break }
            if frame.intersects(rect) {
                result.append(attributes(at: IndexPath(item: index, section: 0), frame: frame))
            }
            index += 1
        }
        return result
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || newBounds.minX != collectionView?.bounds.minX
    }

    private func attributes(at indexPath: IndexPath, frame: CGRect) -> RowAttributes {
        let attributes = RowAttributes(forCellWith: indexPath)
        attributes.frame = frame
        attributes.horizontal = horizontal
        attributes.physicalOffset = horizontal.physical(horizontal.logical(collectionView?.bounds.minX ?? 0))
        return attributes
    }

    private func frame(at index: Int) -> CGRect {
        var lower = 0
        var upper = sectionStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sectionStarts[middle] < index { lower = middle + 1 }
            else { upper = middle }
        }
        let isSectionStart = lower < sectionStarts.count && sectionStarts[lower] == index
        return CGRect(
            x: 0, y: PrototypeLayout.smallGap + CGFloat(index) * rowHeight + CGFloat(lower) * sectionHeight,
            width: horizontal.contentWidth, height: rowHeight + (isSectionStart ? sectionHeight : 0)
        )
    }
}

struct PrototypeGuideTimelineJump: Equatable {
    let offset: CGFloat
    let sequence: Int
}

/// Two focusable content planes in each reusable row, but only one scroll view.
/// Stationary content gets the viewport width; scrolling content gets the full timeline width.
struct PrototypeNativeGuideList<Revision: Equatable, Stationary: View, Scrolling: View>: UIViewControllerRepresentable {
    let rows: [LiveTVGuideRowID]
    var rowHeight: CGFloat = PrototypeLayout.rowHeight + PrototypeLayout.rowGap
    var sectionHeight: CGFloat = PrototypeLayout.guideSectionLabelHeight(fontSize: PrototypeLayout.sectionFontSize)
        + PrototypeLayout.smallGap + PrototypeLayout.sectionLabelGap
    let scrollController: PrototypeGuideScrollController
    let scrolled: (LiveTVGuideRowID?, CGFloat) -> Void
    /// The first visible row and the viewport's offset into it, reported as the list scrolls.
    var viewportChanged: ((LiveTVGuideRowID, CGFloat) -> Void)?
    /// The position the list is laid out at from its first frame. While it is set, replacing the rows keeps the
    /// first visible row where it is, so a fuller lineup does not move what is on screen.
    var initialViewport: PrototypeGuideListViewport?
    let revision: (LiveTVGuideRowID) -> Revision
    var leadingExit: (() -> Void)?
    var focusNow: ((LiveTVGuideRowID) -> Void)?
    /// Where `focusNow` lands on the timeline (now, leading-relative), when native focus may make that move itself:
    /// nil when `focusNow` has more to do than focus the programme on now.
    var nowTimelineX: (() -> CGFloat?)?
    var isAtNowBoundary: ((LiveTVGuideRowID, CGFloat) -> Bool)?
    var focusChannel: ((LiveTVGuideRowID) -> Void)?
    var focusEarlierSlot: ((LiveTVGuideRowID, CGFloat, CGFloat) -> Bool)?
    var didBrowseHorizontally: () -> Void = {}
    var focusAdjacentCurrent: ((LiveTVGuideRowID) -> Void)?
    var hasProgrammePlane: (LiveTVGuideRowID) -> Bool = { _ in true }
    var timelineWidth: CGFloat = 0
    var pinnedWidth: CGFloat = 0
    /// Seeds a newly mounted collection. Use `jump(toTimelineOffset:)` afterwards.
    var initialTimelineOffset: CGFloat = 0
    /// Applied after installing the span and geometry from the same update.
    var timelineJump: PrototypeGuideTimelineJump?
    /// Live leading-relative offset from the shared native scroll view, for the ruler.
    var timelineDidScroll: (CGFloat) -> Void = { _ in }
    @ViewBuilder let stationaryContent: (LiveTVGuideRowID) -> Stationary
    @ViewBuilder let scrollingContent: (LiveTVGuideRowID) -> Scrolling

    struct RowEnvironment: Equatable {
        let palette: ThemePalette
        let reduceTransparency: Bool
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let dynamicType: DynamicTypeSize
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
        let isEnabled: Bool

        init(_ environment: EnvironmentValues) {
            palette = environment.themePalette
            reduceTransparency = environment.plozzReduceTransparency
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            direction = environment.layoutDirection
            dynamicType = environment.dynamicTypeSize
            locale = environment.locale
            calendar = environment.calendar
            timeZone = environment.timeZone
            isEnabled = environment.isEnabled
        }
    }

    @MainActor
    @Observable
    final class RowState<Content: View> {
        let id: LiveTVGuideRowID
        var content: Content
        var environment: RowEnvironment

        init(id: LiveTVGuideRowID, content: Content, environment: RowEnvironment) {
            self.id = id
            self.content = content
            self.environment = environment
        }
    }

    struct HostedRow<Content: View>: View {
        let state: RowState<Content>

        var body: some View {
            // Don't copy another hosting controller's private focus/scroll environment.
            state.content.id(state.id)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .environment(\.themePalette, state.environment.palette)
                .environment(\.plozzReduceTransparency, state.environment.reduceTransparency)
                .environment(\.colorScheme, state.environment.colorScheme)
                .environment(\.layoutDirection, state.environment.direction)
                .environment(\.dynamicTypeSize, state.environment.dynamicType)
                .environment(\.locale, state.environment.locale)
                .environment(\.calendar, state.environment.calendar)
                .environment(\.timeZone, state.environment.timeZone)
                .environment(\.isEnabled, state.environment.isEnabled)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.parentView = self
        controller.swiftUIEnvironment = context.environment
        controller.loadViewIfNeeded()
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self, environment: context.environment)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.collectionView.delegate = nil
        controller.collectionView.dataSource = nil
        if let scroll = controller.parentView?.scrollController, scroll.collection === controller.collectionView {
            scroll.collection = nil
            scroll.jump = nil
            scroll.firstVisibleRow = nil
        }
        controller.parentView = nil
        controller.swiftUIEnvironment = nil
        for child in controller.children {
            child.willMove(toParent: nil)
            child.removeFromParent()
        }
    }

    final class Controller: UICollectionViewController, HorizontalNavigationInputOwning {
        var parentView: PrototypeNativeGuideList?
        var swiftUIEnvironment: EnvironmentValues?
        // The category handoff completes on release, after the rail's passive edge check.
        var ownsHorizontalNavigationInput: Bool { parentView?.leadingExit != nil }
        private var rowIDs: [LiveTVGuideRowID] = []
        private var sectionStarts: [Int] = []
        private var indices: [LiveTVGuideRowID: Int] = [:]
        private var scrollReportScheduled = false
        private var rowEdgeSettle: DispatchWorkItem?
        private var settledY: CGFloat = .nan
        private var hasPlacedInitialViewport = false
        private var holdsAnchorOnReplacement = false
        private let guideLayout: PrototypeGuideCollectionLayout
        private var pendingJump: CGFloat?
        private var appliedJump: PrototypeGuideTimelineJump?
        private var lastGeometry: PrototypeGuideHorizontalGeometry?
        private var lastOffset: CGFloat?
        private var horizontalReportScheduled = false
        private var ignoreHorizontalReports = false
        private var lastVerticalReport: (LiveTVGuideRowID?, CGFloat)?

        init() {
            let layout = PrototypeGuideCollectionLayout()
            guideLayout = layout
            super.init(collectionViewLayout: layout)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private lazy var positionedCollection = GuideCollectionView(frame: .zero, collectionViewLayout: guideLayout)

        override func loadView() {
            collectionView = positionedCollection
            view = positionedCollection
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            collectionView.dataSource = self
            collectionView.delegate = self
            positionedCollection.attached = { [weak self] in self?.attachScrollController() }
            // A report skipped while the list was unattached or not yet placed is made once it is placed.
            positionedCollection.placed = { [weak self] in self?.reportScroll() }
            positionedCollection.failedFocusMove = { [weak self] context in
                guard let self else { return }
                if !redirectVerticalFocus(in: context) { _ = redirectHorizontalFocus(in: context) }
            }
            #if DEBUG
            positionedCollection.didLayout = { [weak self] in self?.observeViewport() }
            #endif
            view.backgroundColor = .clear
            collectionView.backgroundColor = .clear
            collectionView.showsVerticalScrollIndicator = false
            collectionView.showsHorizontalScrollIndicator = false
            collectionView.bounces = false
            collectionView.semanticContentAttribute = .forceLeftToRight
            collectionView.allowsSelection = false
            // Remembering a cell redirects directional moves to its first descendant.
            collectionView.remembersLastFocusedIndexPath = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.register(Cell.self, forCellWithReuseIdentifier: "guide-row")
            collectionView.addGestureRecognizer(GuideHorizontalPressRecognizer(
                actionForPress: { [weak self] type in
                    guard let self else { return nil }
                    let forward = type == (guideLayout.isRTL ? .leftArrow : .rightArrow)
                    if let target = oversizedStep(forward: forward), let item = focusedItem {
                        return .onPress { [weak self, weak item] in
                            guard let self, let item, focusedItem === item else { return }
                            let geometry = guideLayout.horizontal
                            let offset = geometry.logical(collectionView.contentOffset.x)
                            let step = geometry.boundedStep(from: offset, toward: target, forward: forward)
                            if abs(step - offset) > 1 { moveTimeline(to: step, animated: true) }
                        }
                    }
                    guard let item = focusedItem, let index = rowIndex(of: item) else { return nil }
                    let row = rowIDs[index]
                    if isLeadingColumnFocused {
                        if forward, parentView?.focusNow != nil {
                            // With now in view, native focus takes the move in the press's own focus update, as it does
                            // between programmes; `shouldUpdateFocus` checks that it lands on the programme on now.
                            if visibleNowX != nil { return nil }
                            return .onPress { [weak self, weak item] in
                                guard let self, let item, focusedItem === item else { return }
                                parentView?.focusNow?(row)
                            }
                        }
                        if !forward, parentView?.leadingExit != nil {
                            return .onRelease { [weak self, weak item] in
                                guard let self, let item, focusedItem === item else { return }
                                requestLeadingExit()
                            }
                        }
                    }
                    return nil
                }
            ))
            if let parentView, let swiftUIEnvironment { update(parentView, environment: swiftUIEnvironment) }
        }

        private var focusedItem: (any UIFocusItem)? { UIFocusSystem.focusSystem(for: collectionView)?.focusedItem }

        private func oversizedStep(forward: Bool) -> CGFloat? {
            guard let range = timelineRange(of: focusedItem) else { return nil }
            let horizontal = guideLayout.horizontal
            return horizontal.oversizedStep(for: range, at: horizontal.logical(collectionView.contentOffset.x), forward: forward)
        }

        private func timelineRange(of item: (any UIFocusItem)?) -> ClosedRange<CGFloat>? {
            guard let frame = NativeFocusRegion.frame(of: item, in: collectionView) else { return nil }
            var parent: (any UIFocusEnvironment)? = item
            while let current = parent {
                if let view = current as? UIView {
                    var ancestor: UIView? = view
                    while let currentView = ancestor, currentView !== collectionView {
                        if currentView is GuideTimelineClipView { return guideLayout.horizontal.timelineRange(of: frame) }
                        ancestor = currentView.superview
                    }
                    return nil
                }
                parent = current.parentFocusEnvironment
            }
            return nil
        }

        private var isLeadingColumnFocused: Bool { isInLeadingColumn(focusedItem) }

        private func isInLeadingColumn(_ item: (any UIFocusItem)?) -> Bool {
            guard let frame = NativeFocusRegion.frame(of: item, in: collectionView) else { return false }
            let distance = guideLayout.isRTL
                ? collectionView.bounds.maxX - frame.midX : frame.midX - collectionView.bounds.minX
            return distance >= 0 && distance < PrototypeLayout.stationWidth(for: collectionView.bounds.width)
                && timelineRange(of: item) == nil
        }

        /// Now's timeline point while it is in view, so `focusNow` would not move the timeline.
        private var visibleNowX: CGFloat? {
            guard parentView?.focusNow != nil, let now = parentView?.nowTimelineX?() else { return nil }
            let geometry = guideLayout.horizontal
            let offset = geometry.logical(collectionView.contentOffset.x)
            return now >= offset && now < offset + geometry.viewport ? now : nil
        }

        /// Whether native focus's Right from the plate goes where `focusNow` would: the same row's programme on now,
        /// or, on a row without programmes, its one content cell.
        private func landsOnNow(_ item: (any UIFocusItem)?, row index: Int) -> Bool {
            guard let now = visibleNowX, let item, rowIndex(of: item) == index else { return false }
            guard let range = timelineRange(of: item) else {
                return parentView?.hasProgrammePlane(rowIDs[index]) == false && !isInLeadingColumn(item)
            }
            // A cell ends a gap before its slot does; the next slot starts where this one ends.
            return range.lowerBound <= now + 0.5 && now < range.upperBound + PrototypeLayout.cellGap
        }

        /// The cell native focus is entering from the plate in place of `focusNow`: it lands without a reveal.
        private weak var nativeNowEntry: AnyObject?

        func update(_ parent: PrototypeNativeGuideList, environment: EnvironmentValues) {
            parentView = parent
            swiftUIEnvironment = environment
            let rowsChanged = guideOpenTraced("list.rowsCompare", { rowIDs != parent.rows })
            let heldAnchor = rowsChanged && holdsAnchorOnReplacement ? currentViewport() : nil
            if rowsChanged {
                rowIDs = parent.rows
                sectionStarts = guideOpenTraced("list.sectionStarts") {
                    rowIDs.indices.filter { $0 > 0 && rowIDs[$0].section != rowIDs[$0 - 1].section }
                }
                indices = guideOpenTraced("list.indices") {
                    Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
                }
            }
            attachScrollController()
            guideLayout.update(
                rowCount: rowIDs.count, rowHeight: parent.rowHeight,
                sectionHeight: parent.sectionHeight, sectionStarts: sectionStarts,
                timelineWidth: parent.timelineWidth, pinnedWidth: parent.pinnedWidth,
                isRTL: environment.layoutDirection == .rightToLeft
            )
            if rowsChanged {
                placeViewport(initial: parent.initialViewport, held: heldAnchor)
                guideOpenTraced("list.reloadData") { collectionView.reloadData() }
            } else {
                for case let cell as Cell in collectionView.visibleCells {
                    guard let path = collectionView.indexPath(for: cell), rowIDs.indices.contains(path.item) else { continue }
                    configure(cell, row: rowIDs[path.item])
                }
            }
            holdsAnchorOnReplacement = parent.initialViewport != nil
            if let request = parent.timelineJump, request != appliedJump {
                appliedJump = request
                pendingJump = request.offset
            }
            reconcileHorizontalGeometry()
            reportScroll()
        }

        private func attachScrollController() {
            guard collectionView.window != nil, let scroll = parentView?.scrollController else { return }
            scroll.collection = collectionView
            scroll.indices = indices
            scroll.jump = { [weak self] offset in self?.jump(to: offset) }
            scroll.firstVisibleRow = { [weak self] in self?.currentViewport()?.row }
            reportScroll()
        }

        #if DEBUG
        private func observeViewport() {
            guard collectionView.window != nil, !collectionView.isHidden,
                  let observer = swiftUIEnvironment?.liveTVGuideViewportObserver else { return }
            let cells = collectionView.visibleCells.compactMap { cell -> LiveTVGuideViewportObserver.HostedCell? in
                guard let id = (cell as? Cell)?.stationaryState?.id else { return nil }
                return .init(channelID: id.channelID, cell: cell)
            }
            observer.didLayout(collectionView, rowIDs.count, cells)
        }
        #endif

        private func currentViewport() -> PrototypeGuideListViewport? {
            if let placement = positionedCollection.pendingPlacement, rowIDs.indices.contains(placement.index) {
                return .init(row: rowIDs[placement.index], relativeOffset: placement.relativeOffset)
            }
            return anchor(atOffset: collectionView.contentOffset.y)
        }

        /// The row at the top edge of the viewport and the distance below that row's top, from layout geometry alone.
        private func anchor(atOffset offset: CGFloat) -> PrototypeGuideListViewport? {
            guard !rowIDs.isEmpty else { return nil }
            // Rows sit below a lead-in (the first at `smallGap`), and a list resting on a row edge starts that far above
            // the row, inside the gap under the row before it: that row is off screen, so probe past the lead-in.
            let probe = CGRect(x: 0, y: max(0, offset) + PrototypeLayout.smallGap, width: 1, height: 1)
            guard let first = guideLayout.layoutAttributesForElements(in: probe)?.first,
                  rowIDs.indices.contains(first.indexPath.item) else { return nil }
            return .init(row: rowIDs[first.indexPath.item], relativeOffset: offset - first.frame.minY)
        }

        /// Resolve the anchor against this projection, but install its geometry in the native layout pass.
        private func placeViewport(
            initial: PrototypeGuideListViewport?, held: PrototypeGuideListViewport?
        ) {
            let target: PrototypeGuideListViewport?
            if !hasPlacedInitialViewport, !rowIDs.isEmpty {
                hasPlacedInitialViewport = true
                target = initial
            } else {
                target = held
            }
            positionedCollection.pendingPlacement = target.flatMap { target in
                indices[target.row].map { ($0, target.relativeOffset) }
            }
        }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rowIDs.count }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "guide-row", for: indexPath) as? Cell else {
                preconditionFailure("Expected native guide row cell")
            }
            configure(cell, row: rowIDs[indexPath.item])
            return cell
        }

        override func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let cell = cell as? Cell else { return }
            for host in cell.hosts where host.parent == nil {
                addChild(host)
                host.didMove(toParent: self)
            }
        }

        override func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let cell = cell as? Cell else { return }
            for host in cell.hosts where host.parent === self {
                host.willMove(toParent: nil)
                host.removeFromParent()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            reconcileHorizontalGeometry()
        }

        private func reconcileHorizontalGeometry() {
            let geometry = guideLayout.horizontal
            guard let parentView, geometry.viewport > 0, geometry != lastGeometry || pendingJump != nil else { return }
            let logical = pendingJump ?? lastGeometry?.logical(collectionView.contentOffset.x) ?? parentView.initialTimelineOffset
            lastGeometry = geometry
            if pendingJump != nil || lastOffset == nil || abs(geometry.physical(logical) - collectionView.contentOffset.x) > 0.5 {
                jump(to: logical, mayLayout: false)
            }
        }

        /// `mayLayout` is false while the list is being updated: the jump then waits for the native layout pass
        /// (`viewDidLayoutSubviews`) instead of forcing cells to render early.
        private func jump(to offset: CGFloat, mayLayout: Bool = true) {
            guard guideLayout.horizontal.viewport > 0 else { pendingJump = offset; return }
            if collectionView.contentSize.width != guideLayout.horizontal.contentWidth {
                guard mayLayout else { pendingJump = offset; return }
                collectionView.layoutIfNeeded()
            }
            pendingJump = nil
            moveTimeline(to: offset, animated: false, report: false)
        }

        private func moveTimeline(to offset: CGFloat, animated: Bool, report: Bool = true) {
            let horizontal = guideLayout.horizontal
            if !report { lastOffset = horizontal.clamped(offset) }
            ignoreHorizontalReports = !report
            defer { ignoreHorizontalReports = false }
            (collectionView as? GuideCollectionView)?.moveTimeline(toX: horizontal.physical(offset),
                animated: animated && swiftUIEnvironment?.accessibilityReduceMotion != true && !UIAccessibility.isReduceMotionEnabled)
        }

        /// tvOS reports focus-driven scrolling here before animating it. Its own deceleration creeps the last few points
        /// a pixel per frame (~0.83 s total). Cancel that deceleration and move directly to the row edge in one standard
        /// UIKit scroll animation (~0.33 s, or immediately with Reduce Motion), so the list lands whole and stays put.
        override func scrollViewWillEndDragging(
            _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard !scrollView.isTracking, positionedCollection.pendingPlacement == nil else { return }
            let y = scrollView.contentOffset.y
            let target = targetContentOffset.pointee.y
            guard abs(target - y) > 0.5,
                  let stop = guideLayout.verticalStop(for: target, height: scrollView.bounds.height, movingDown: target > y)
            else { return }
            #if DEBUG
            GuideNavigationProfileHook.verticalRoute?("focusScroll from=\(Int(y)) proposed=\(Int(target)) stop=\(Int(stop))")
            #endif
            targetContentOffset.pointee = scrollView.contentOffset
            rowEdgeSettle?.cancel()
            settledY = stop
            let reduceMotion = swiftUIEnvironment?.accessibilityReduceMotion == true || UIAccessibility.isReduceMotionEnabled
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: stop), animated: !reduceMotion)
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportScroll()
            if scrollView.contentOffset.y != settledY { scheduleRowEdgeSettle() }
            guard !ignoreHorizontalReports, pendingJump == nil, !horizontalReportScheduled,
                  guideLayout.horizontal.logical(scrollView.contentOffset.x) != lastOffset else { return }
            horizontalReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                horizontalReportScheduled = false
                let offset = guideLayout.horizontal.logical(collectionView.contentOffset.x)
                guard offset != lastOffset else { return }
                lastOffset = offset
                parentView?.timelineDidScroll(offset)
            }
        }

        private func rowIndex(of item: (any UIFocusItem)?) -> Int? {
            var environment: (any UIFocusEnvironment)? = item
            while let current = environment {
                if let view = current as? UIView {
                    var ancestor: UIView? = view
                    while let currentView = ancestor, currentView !== collectionView {
                        if let cell = currentView as? Cell { return collectionView.indexPath(for: cell)?.item }
                        ancestor = currentView.superview
                    }
                    return nil
                }
                environment = current.parentFocusEnvironment
            }
            return nil
        }

        private var hasPendingVerticalMove = false

        /// Native focus may find no candidate under a very wide programme. In that case it
        /// reports a failed movement instead of calling `shouldUpdateFocus`.
        private func redirectVerticalFocus(in context: UIFocusUpdateContext) -> Bool {
            guard context.focusHeading == .down || context.focusHeading == .up else { return false }
            #if DEBUG
            GuideNavigationProfileHook.verticalRoute?("proposal heading=\(context.focusHeading.rawValue) handler=\(parentView?.focusAdjacentCurrent != nil) row=\(rowIndex(of: context.previouslyFocusedItem).map(String.init) ?? "nil")")
            #endif
            // On the channel column, Up/Down stays there: native focus moves to the plate above or below. Only a
            // programme goes on to the adjacent row's current programme.
            guard !isLeadingColumnFocused else { return false }
            guard parentView?.focusAdjacentCurrent != nil,
                  let epoch = DetailTransitionNavigation.navigationInputEpoch(in: collectionView),
                  let previous = context.previouslyFocusedItem, previous === focusedItem,
                  let index = rowIndex(of: previous) else { return false }
            let step = context.focusHeading == .down ? 1 : -1
            let adjacent = index + step
            guard rowIDs.indices.contains(adjacent) else { return false }
            guard !hasPendingVerticalMove else { return true }
            hasPendingVerticalMove = true
            let row = rowIDs[adjacent]
            DispatchQueue.main.async { [weak self, weak previous] in
                guard let self else { return }
                hasPendingVerticalMove = false
                // Both a veto and its failure notification may reach here. A later focus
                // scope or lineup change must not apply an old request to a recycled row.
                guard let previous, focusedItem === previous,
                      DetailTransitionNavigation.navigationInputEpoch(in: collectionView) == epoch,
                      let index = rowIndex(of: previous), indices[row] == index + step else { return }
                #if DEBUG
                GuideNavigationProfileHook.verticalRoute?("dispatch row=\(row.channelID)")
                #endif
                parentView?.focusAdjacentCurrent?(row)
            }
            return true
        }

        private var hasPendingHorizontalMove = false

        private func redirectHorizontalFocus(in context: UIFocusUpdateContext) -> Bool {
            let leading: UIFocusHeading = guideLayout.isRTL ? .right : .left
            let trailing: UIFocusHeading = guideLayout.isRTL ? .left : .right
            guard context.focusHeading == leading || context.focusHeading == trailing,
                  let epoch = DetailTransitionNavigation.navigationInputEpoch(in: collectionView),
                  let previous = context.previouslyFocusedItem, previous === focusedItem,
                  let index = rowIndex(of: previous) else { return false }
            let forward = context.focusHeading == trailing
            let plate = isLeadingColumnFocused
            nativeNowEntry = nil
            if oversizedStep(forward: forward) != nil { return true }
            if plate, forward, landsOnNow(context.nextFocusedItem, row: index) {
                nativeNowEntry = context.nextFocusedItem
                return false
            }
            let geometry = guideLayout.horizontal
            let offset = geometry.logical(collectionView.contentOffset.x)
            let atNow = !plate && !forward && parentView?.isAtNowBoundary?(rowIDs[index], offset) == true
            if plate {
                guard forward ? parentView?.focusNow != nil : parentView?.leadingExit != nil else { return false }
            } else {
                // Native focus owns ordinary neighbours on the same timeline. The pinned
                // plate becomes eligible only after the current-time boundary is reached.
                guard !forward, parentView?.focusEarlierSlot != nil,
                      atNow || rowIndex(of: context.nextFocusedItem) != index || timelineRange(of: context.nextFocusedItem) == nil
                else { return false }
            }
            guard !hasPendingHorizontalMove else { return true }
            hasPendingHorizontalMove = true
            let row = rowIDs[index]
            DispatchQueue.main.async { [weak self, weak previous] in
                guard let self else { return }
                hasPendingHorizontalMove = false
                guard let previous, focusedItem === previous,
                      DetailTransitionNavigation.navigationInputEpoch(in: collectionView) == epoch,
                      let index = rowIndex(of: previous), rowIDs[index] == row else { return }
                if plate {
                    if forward { parentView?.focusNow?(row) }
                    else { requestLeadingExit() }
                } else {
                    guard parentView?.focusEarlierSlot != nil else { return }
                    let geometry = guideLayout.horizontal
                    let offset = geometry.logical(collectionView.contentOffset.x)
                    if parentView?.isAtNowBoundary?(row, offset) == true {
                        parentView?.focusChannel?(row)
                        return
                    }
                    if parentView?.focusEarlierSlot?(row, offset, geometry.viewport) == true { return }
                    // The previous cell may be clipped. Pan first, without spending
                    // this press on an exit from the guide.
                    if offset > 1 {
                        moveTimeline(to: max(0, offset - geometry.viewport), animated: true)
                    } else {
                        parentView?.focusNow?(row)
                    }
                }
            }
            return true
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if redirectVerticalFocus(in: context) || redirectHorizontalFocus(in: context) { return false }
            return super.shouldUpdateFocus(in: context)
        }

        private func requestLeadingExit() {
            parentView?.leadingExit?()
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            let entersNow = nativeNowEntry != nil && nativeNowEntry === context.nextFocusedItem
            nativeNowEntry = nil
            // Like `focusNow`'s move: the timeline stays, and the guide is not being browsed.
            guard !entersNow else { return }
            guard context.focusHeading == .left || context.focusHeading == .right,
                  NativeFocusRegion.frame(of: context.previouslyFocusedItem, in: collectionView) != nil else { return }
            guard let range = timelineRange(of: context.nextFocusedItem) else { return }
            let horizontal = guideLayout.horizontal
            let offset = horizontal.logical(collectionView.contentOffset.x)
            let forward = context.focusHeading == (horizontal.isRTL ? .left : .right)
            let previousWidth = timelineRange(of: context.previouslyFocusedItem).map { $0.upperBound - $0.lowerBound }
            let leavingViewportSizedItem = previousWidth.map {
                $0 <= horizontal.viewport && $0 + PrototypeLayout.cellGap >= horizontal.viewport
            } ?? false
            let target = horizontal.reveal(range, at: offset, forward: forward,
                                           leavingViewportSizedItem: leavingViewportSizedItem)
            if abs(target - offset) > 1 { moveTimeline(to: target, animated: true) }
            parentView?.didBrowseHorizontally()
        }

        private func configure(_ cell: Cell, row: LiveTVGuideRowID) {
            guard let parentView, let swiftUIEnvironment else { return }
            let revision = parentView.revision(row)
            let environment = RowEnvironment(swiftUIEnvironment)
            if cell.stationaryState?.id != row || cell.revision != revision {
                cell.revision = revision
                cell.stationaryHost = bind(cell.stationaryHost, to: &cell.stationaryState, in: cell.contentView,
                    row: row, content: parentView.stationaryContent(row), environment: environment)
                // A row without programmes has no second plane to host; opening the guide builds only what is drawn.
                let hasProgrammePlane = parentView.hasProgrammePlane(row)
                if hasProgrammePlane {
                    cell.scrollingHost = bind(cell.scrollingHost, to: &cell.scrollingState, in: cell.scrollingClip,
                        row: row, content: parentView.scrollingContent(row), environment: environment)
                }
                cell.scrollingClip.isHidden = !hasProgrammePlane
                // The full-width stationary host would mask programme targets during focus search.
                cell.contentView.bringSubviewToFront(cell.scrollingClip)
                cell.setNeedsLayout()
            } else if cell.stationaryState?.environment != environment {
                cell.stationaryState?.environment = environment
                cell.scrollingState?.environment = environment
            }
        }

        private func bind<Content: View>(
            _ host: UIHostingController<HostedRow<Content>>?, to state: inout RowState<Content>?,
            in container: UIView, row: LiveTVGuideRowID, content: Content, environment: RowEnvironment
        ) -> UIHostingController<HostedRow<Content>> {
            if let host, let state, state.id == row {
                state.content = content
                state.environment = environment
                return host
            }
            let next = RowState(id: row, content: content, environment: environment)
            state = next
            let root = HostedRow(state: next)
            if let host {
                host.rootView = root
                return host
            }
            let host = UIHostingController(rootView: root)
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            container.addSubview(host.view)
            return host
        }

        /// Once vertical scrolling has been still for a moment with focus in the guide, ease onto a row edge so no row
        /// rests cut under the ruler. This runs after the fact and never alters a scroll request (focus scrolling, focus
        /// restoration and the guide's own jumps all land exactly where they asked), so it cannot steer focus.
        private func scheduleRowEdgeSettle() {
            rowEdgeSettle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settleOnRowEdge() }
            rowEdgeSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        private func settleOnRowEdge() {
            let y = collectionView.contentOffset.y
            settledY = y
            guard collectionView.window != nil, positionedCollection.pendingPlacement == nil,
                  !collectionView.isTracking, !collectionView.isDecelerating,
                  let focus = NativeFocusRegion.frame(of: focusedItem, in: collectionView),
                  let stop = guideLayout.verticalStop(for: y, height: collectionView.bounds.height, keeping: focus),
                  abs(stop - y) > 0.5 else { return }
            settledY = stop
            let reduceMotion = swiftUIEnvironment?.accessibilityReduceMotion == true || UIAccessibility.isReduceMotionEnabled
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: stop), animated: !reduceMotion)
        }

        private func reportScroll() {
            guard !scrollReportScheduled else { return }
            scrollReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollReportScheduled = false
                guard let parentView = self.parentView,
                      parentView.scrollController.collection === self.collectionView, self.collectionView.window != nil,
                      self.positionedCollection.pendingPlacement == nil else { return }
                // The top row from layout geometry, not `indexPathsForVisibleItems`: the collection keeps the focused cell
                // alive after it scrolls away, which pinned the reported row (and the guide listings loaded around it) to
                // where focus had been.
                let row = self.anchor(atOffset: self.collectionView.contentOffset.y)?.row
                let y = self.collectionView.contentOffset.y + self.collectionView.adjustedContentInset.top
                if self.lastVerticalReport?.0 != row || self.lastVerticalReport?.1 != y {
                    self.lastVerticalReport = (row, y)
                    parentView.scrolled(row, y)
                }
                if let anchor = self.anchor(atOffset: self.collectionView.contentOffset.y) {
                    parentView.viewportChanged?(anchor.row, anchor.relativeOffset)
                }
            }
        }
    }

    final class Cell: UICollectionViewCell {
        var stationaryHost: UIHostingController<HostedRow<Stationary>>?
        var scrollingHost: UIHostingController<HostedRow<Scrolling>>?
        var stationaryState: RowState<Stationary>?
        var scrollingState: RowState<Scrolling>?
        var revision: Revision?
        var hosts: [UIViewController] { [stationaryHost as UIViewController?, scrollingHost as UIViewController?].compactMap { $0 } }
        let scrollingClip: UIView = GuideTimelineClipView()
        private var attributes: PrototypeGuideCollectionLayout.RowAttributes?

        override var canBecomeFocused: Bool { false }

        override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
            super.apply(layoutAttributes)
            attributes = layoutAttributes as? PrototypeGuideCollectionLayout.RowAttributes
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let attributes else { return }
            let geometry = attributes.horizontal
            let x = attributes.physicalOffset
            let height = bounds.height
            stationaryHost?.view.frame = CGRect(x: x, y: 0, width: geometry.width, height: height)
            let clip = geometry.scrollingClip(at: x)
            scrollingClip.frame = CGRect(x: clip.minX, y: 0, width: clip.width, height: height)
            // Equal shifts of frame and bounds keep the programme host fixed in content coordinates.
            scrollingClip.bounds.origin.x = clip.minX
            scrollingHost?.view.frame = CGRect(x: geometry.isRTL ? 0 : geometry.pinnedWidth, y: 0,
                width: geometry.contentWidth - geometry.pinnedWidth, height: height)
            // Render both planes in this pass, so a row's station and programmes appear in the same frame.
            stationaryHost?.view.layoutIfNeeded()
            scrollingHost?.view.layoutIfNeeded()
        }

        override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
            layoutAttributes
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            preservesSuperviewLayoutMargins = false
            insetsLayoutMarginsFromSafeArea = false
            layoutMargins = .zero
            contentView.preservesSuperviewLayoutMargins = false
            contentView.layoutMargins = .zero
            scrollingClip.clipsToBounds = true
            contentView.addSubview(scrollingClip)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

/// Native focus is free to move and vertically reveal its selection, but the
/// guide, not UIKit's full-card reveal heuristic, chooses horizontal targets.
private final class GuideCollectionView: UICollectionView {
    // Leave headroom for display cadence under the 100 ms visible-motion ceiling.
    private static let timelineDuration: CFTimeInterval = 0.065
    private var timelineMove: (from: CGFloat, to: CGFloat, started: CFTimeInterval)?
    private var timelineDisplayLink: CADisplayLink?
    var pendingPlacement: (index: Int, relativeOffset: CGFloat)?
    var attached: (() -> Void)?
    /// Called after layout installs a pending placement, so the placed position is reported even when the offset did not move.
    var placed: (() -> Void)?
    var failedFocusMove: ((UIFocusUpdateContext) -> Void)?
    #if DEBUG
    var didLayout: (() -> Void)?
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let center = NotificationCenter.default
        let notification = UIFocusSystem.movementDidFailNotification
        center.removeObserver(self, name: notification, object: nil)
        guard window != nil else { stopTimelineMove(); return }
        center.addObserver(self, selector: #selector(focusMovementFailed(_:)), name: notification, object: nil)
        attached?()
    }

    @objc private func focusMovementFailed(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                as? UIFocusUpdateContext else { return }
        failedFocusMove?(context)
    }

    override func layoutSubviews() {
        let placing = pendingPlacement != nil && !bounds.isEmpty
        defer { if placing { placed?() } }
        if let placement = pendingPlacement, !bounds.isEmpty {
            pendingPlacement = nil
            // SwiftUI resizes the represented view before layout. UIScrollView clamps against
            // its old (initially zero) content size during that resize. Install the new extent
            // and origin together, before UICollectionView asks for visible cells.
            let layout = collectionViewLayout
            if let frame = layout.layoutAttributesForItem(at: IndexPath(item: placement.index, section: 0))?.frame {
                let size = layout.collectionViewContentSize
                contentSize = size
                let top = min(max(0, frame.minY + placement.relativeOffset), max(0, size.height - bounds.height))
                if contentOffset.y != top { contentOffset.y = top }
            }
        }
        super.layoutSubviews()
        #if DEBUG
        didLayout?()
        #endif
    }

    /// UIKit re-centres the vertical offset when the frame's height changes (the list is resized to whole sheet rows
    /// after its first layout), which would move the first visible row. Resizing keeps the offset, clamped to the content.
    override var frame: CGRect {
        get { super.frame }
        set {
            let offset = super.contentOffset.y
            let resized = !bounds.isEmpty && newValue.size != super.frame.size
            super.frame = newValue
            guard resized else { return }
            let restored = min(offset, max(0, contentSize.height - bounds.height))
            if super.contentOffset.y != restored { contentOffset.y = restored }
        }
    }

    /// True while the guide itself moves the timeline. UIScrollView's `setContentOffset(_:animated:)` assigns
    /// `contentOffset` internally, which reaches the override below; without this the guide's own horizontal
    /// moves were discarded with UIKit's, and focus walked off the right edge with the view standing still.
    private var isMovingTimeline = false

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            let current = super.contentOffset
            let proposed = CGPoint(x: isMovingTimeline ? newValue.x : current.x, y: newValue.y)
            if proposed != current { super.contentOffset = proposed }
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        let proposed = CGPoint(x: isMovingTimeline ? contentOffset.x : super.contentOffset.x, y: contentOffset.y)
        if proposed != super.contentOffset { super.setContentOffset(proposed, animated: animated) }
    }

    func moveTimeline(toX x: CGFloat, animated: Bool) {
        let current = super.contentOffset.x
        guard animated, window != nil, abs(x - current) > 1 else {
            stopTimelineMove()
            setTimelineX(x)
            return
        }
        timelineMove = (current, x, CACurrentMediaTime())
        guard timelineDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(advanceTimeline(_:)))
        timelineDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceTimeline(_ link: CADisplayLink) {
        guard let move = timelineMove else { stopTimelineMove(); return }
        // Update the real offset, not a layer transform: the ruler, cells and
        // pinned plate layout must see the same geometry on every frame.
        let progress = CGFloat(min(1, max(0, (link.targetTimestamp - move.started) / Self.timelineDuration)))
        let eased = progress * (2 - progress)
        setTimelineX(move.from + (move.to - move.from) * eased)
        if progress == 1, timelineMove?.started == move.started { stopTimelineMove() }
    }

    private func setTimelineX(_ x: CGFloat) {
        guard super.contentOffset.x != x else { return }
        isMovingTimeline = true
        defer { isMovingTimeline = false }
        super.setContentOffset(CGPoint(x: x, y: super.contentOffset.y), animated: false)
    }

    private func stopTimelineMove() {
        timelineDisplayLink?.invalidate()
        timelineDisplayLink = nil
        timelineMove = nil
    }
}

private final class GuideTimelineClipView: UIView {}

private final class GuideHorizontalPressRecognizer: UIGestureRecognizer {
    enum Action {
        case onPress(() -> Void)
        case onRelease(() -> Void)
    }

    private let actionForPress: (UIPress.PressType) -> Action?
    private var consumedPress: UIPress?
    private var releaseAction: (() -> Void)?

    init(actionForPress: @escaping (UIPress.PressType) -> Action?) {
        self.actionForPress = actionForPress
        super.init(target: nil, action: nil)
        allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue), NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        allowedTouchTypes = []
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { consumedPress != nil }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Ancestor navigation can begin before descendant press delivery.
        guard let view, let ancestor = otherGestureRecognizer.view,
              view !== ancestor, view.isDescendant(of: ancestor) else { return false }
        return otherGestureRecognizer.allowedPressTypes.contains {
            $0.intValue == UIPress.PressType.leftArrow.rawValue || $0.intValue == UIPress.PressType.rightArrow.rawValue
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }),
              DetailTransitionNavigation.navigationInputEpoch(in: view) != nil else {
            state = .failed
            return
        }
        guard let action = actionForPress(press.type) else { state = .failed; return }
        consumedPress = press
        switch action {
        case .onPress(let page):
            state = .began
            page()
        case .onRelease(let release):
            releaseAction = release
            state = .began
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard let consumedPress, presses.contains(where: { $0 === consumedPress }) else { return }
        let action = releaseAction
        state = .ended
        action?()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .cancelled }

    override func reset() {
        consumedPress = nil
        releaseAction = nil
        super.reset()
    }
}
#endif
