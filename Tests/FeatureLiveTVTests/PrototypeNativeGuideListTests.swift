#if DEBUG && os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class PrototypeNativeGuideListTests: XCTestCase {
    private typealias Guide = PrototypeNativeGuideList<Int, Text, Text>

    private func list(rows: [LiveTVGuideRowID], scroll: PrototypeGuideScrollController,
                      initialOffset: CGFloat = 0, render: @escaping (LiveTVGuideRowID) -> Text) -> Guide {
        Guide(rows: rows, scrollController: scroll, scrolled: { _, _ in }, revision: { _ in 0 },
              timelineWidth: 5_000, pinnedWidth: 140, initialTimelineOffset: initialOffset,
              stationaryContent: render, scrollingContent: { _ in Text("Programme") })
    }

    func testOversizedPressStepsToEitherEndWithoutPassingIt() {
        for rtl in [false, true] {
            let geometry = PrototypeGuideHorizontalGeometry(width: 900, pinnedWidth: 150, timelineWidth: 4_500, isRTL: rtl)
            let range: ClosedRange<CGFloat> = 200...2_000
            XCTAssertEqual(geometry.reveal(range, at: 0, forward: true), 200)
            XCTAssertEqual(geometry.oversizedStep(for: range, at: 200, forward: true), 950)
            XCTAssertEqual(geometry.oversizedStep(for: range, at: 950, forward: true), 1_250)
            XCTAssertNil(geometry.oversizedStep(for: range, at: 1_250, forward: true))
            XCTAssertEqual(geometry.oversizedStep(for: range, at: 1_250, forward: false), 500)
            XCTAssertEqual(geometry.oversizedStep(for: range, at: 500, forward: false), 200)
            XCTAssertNil(geometry.oversizedStep(for: range, at: 200, forward: false))
            XCTAssertEqual(geometry.reveal(range, at: 1_450, forward: false), 1_250)
            XCTAssertNil(geometry.oversizedStep(for: 2_000...2_400, at: 1_250, forward: true))
            XCTAssertEqual(geometry.reveal(2_000...2_400, at: 1_250, forward: true), 1_650)
            XCTAssertEqual(geometry.reveal(2_000...2_400, at: 1_250, forward: true,
                                           leavingViewportSizedItem: true), 2_000)
            XCTAssertEqual(geometry.reveal(0...180, at: 200, forward: false), 0)
            XCTAssertEqual(geometry.reveal(1_400...1_800, at: 1_250, forward: true), 1_250)
            XCTAssertEqual(geometry.reveal(1_700...2_700, at: 1_250, forward: true), 1_950)
            XCTAssertEqual(geometry.reveal(1_700...2_700, at: 2_250, forward: false), 1_700)
            XCTAssertEqual(geometry.reveal(2_900...3_800, at: 1_250, forward: true), 2_000)
            for logical: CGFloat in [0, 950, 1_250, geometry.maximumOffset] {
                XCTAssertEqual(geometry.logical(geometry.physical(logical)), logical)
            }
        }
    }

    func testNativeJumpKeepsStationaryContentPinnedAndProgrammeGeometryFixed() throws {
        for rtl in [false, true] {
            let rows = (0..<200).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
            let scroll = PrototypeGuideScrollController()
            let controller = Guide.Controller()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 720))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                Guide.dismantleUIViewController(controller, coordinator: ())
            }
            controller.view.frame = window.bounds
            var environment = EnvironmentValues()
            environment.layoutDirection = rtl ? .rightToLeft : .leftToRight
            controller.update(list(rows: rows, scroll: scroll, initialOffset: 240) { Text($0.channelID) },
                              environment: environment)
            controller.view.layoutIfNeeded()
            let collection = try XCTUnwrap(controller.collectionView)
            let layout = try XCTUnwrap(collection.collectionViewLayout as? PrototypeGuideCollectionLayout)
            let geometry = layout.horizontal
            XCTAssertEqual(collection.contentOffset.x, geometry.physical(240), accuracy: 1)
            scroll.scrollTo(rows[100], anchor: .center)
            controller.view.layoutIfNeeded()
            let y = collection.contentOffset.y
            let path = IndexPath(item: 100, section: 0)
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? Guide.Cell)
            for offset: CGFloat in [500, 1_900, -100, 10_000] {
                scroll.jump(toTimelineOffset: offset)
                controller.view.layoutIfNeeded()
                let x = geometry.physical(offset)
                XCTAssertEqual(collection.contentOffset.x, x, accuracy: 1)
                XCTAssertEqual(collection.contentOffset.y, y, accuracy: 1)
                XCTAssertTrue(collection.cellForItem(at: path) === cell)
                let station = try XCTUnwrap(cell.stationaryHost?.view)
                let programme = try XCTUnwrap(cell.scrollingHost?.view)
                XCTAssertEqual(station.convert(station.bounds, to: collection).minX, x, accuracy: 1)
                let programmeFrame = programme.convert(programme.bounds, to: collection)
                XCTAssertEqual(programmeFrame.minX, rtl ? 0 : 140, accuracy: 1)
                XCTAssertEqual(programmeFrame.width, 5_000, accuracy: 1)
                let clip = cell.scrollingClip.convert(cell.scrollingClip.bounds, to: collection)
                if rtl { XCTAssertEqual(clip.maxX, x + geometry.viewport, accuracy: 1) }
                else { XCTAssertEqual(clip.minX, x + geometry.pinnedWidth, accuracy: 1) }
                XCTAssertLessThan(controller.children.count, 100)
            }
            // Native focus's implicit scroll requests may carry an x as well as y.
            let finalX = collection.contentOffset.x
            collection.contentOffset = CGPoint(x: geometry.physical(1_000), y: y + 60)
            XCTAssertEqual(collection.contentOffset.x, finalX, accuracy: 1)
            XCTAssertEqual(collection.contentOffset.y, y + 60, accuracy: 1)
        }
    }

    func testLayoutIncludesSectionHeadersAndOnlyReturnsIntersectingRows() throws {
        let layout = PrototypeGuideCollectionLayout()
        let collection = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 1_400, height: 720), collectionViewLayout: layout)
        layout.update(rowCount: 100_000, rowHeight: 144, sectionHeight: 68, sectionStarts: [2, 5])
        let expectedHeights: [CGFloat] = [144, 144, 212, 144, 144, 212, 144]
        var y = PrototypeLayout.smallGap
        for (index, height) in expectedHeights.enumerated() {
            let attributes = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
            XCTAssertEqual(attributes.frame, CGRect(x: 0, y: y, width: 1_400, height: height))
            XCTAssertEqual(
                layout.layoutAttributesForElements(in: attributes.frame)?.map(\.indexPath.item), [index])
            y += height
        }
        let target = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 99_900, section: 0)))
        let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(
            x: 0, y: target.frame.minY, width: 1_400, height: 720)))
        XCTAssertEqual(visible.map(\.indexPath.item), Array(99_900..<99_905))
        XCTAssertEqual(layout.collectionViewContentSize.height, PrototypeLayout.smallGap + 100_000 * 144 + 2 * 68)
        XCTAssertEqual(layout.collectionViewContentSize.width, collection.bounds.width)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: 100_000, section: 0)))
        XCTAssertTrue(try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: -100, width: 100, height: 10))).isEmpty)
    }

    func testLayoutAdaptsToScaledHeightsWidthAndCatalogRemoval() throws {
        let layout = PrototypeGuideCollectionLayout()
        let collection = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 1_400, height: 720), collectionViewLayout: layout)
        layout.update(rowCount: 30, rowHeight: 288, sectionHeight: 100, sectionStarts: [2, 5])
        let section = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 5, section: 0)))
        XCTAssertEqual(section.frame.height, 388)
        XCTAssertEqual(section.frame.minY, PrototypeLayout.smallGap + 5 * 288 + 100)
        XCTAssertTrue(layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 0, y: 0, width: 600, height: 720)))
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: collection.bounds.offsetBy(dx: 0, dy: 288)))
        collection.bounds.size.width = 600
        XCTAssertEqual(layout.layoutAttributesForItem(at: section.indexPath)?.frame.width, 600)
        layout.update(rowCount: 0, rowHeight: 288, sectionHeight: 100, sectionStarts: [])
        XCTAssertNil(layout.layoutAttributesForItem(at: section.indexPath))
        XCTAssertTrue(try XCTUnwrap(layout.layoutAttributesForElements(in: collection.bounds)).isEmpty)
        XCTAssertEqual(layout.collectionViewContentSize.height, PrototypeLayout.smallGap)
    }

    func testColdRestorationIntoHundredThousandRowsRemainsBounded() {
        let rows = (0..<100_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        var renders = 0
        let list = list(rows: rows, scroll: scroll) { row in
            renders += 1
            return Text(row.channelID)
        }
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        controller.update(list, environment: EnvironmentValues())
        let started = ContinuousClock.now
        scroll.scrollTo(rows[99_900], anchor: .center)
        controller.view.layoutIfNeeded()
        let elapsed = started.duration(to: .now)
        print("Guide cold restoration: rows=100000 elapsed=\(elapsed) rendered=\(renders)")
        XCTAssertLessThan(elapsed, .milliseconds(500), "Restoration must not synchronously lay out the entire catalog")
        XCTAssertLessThan(renders, 100)
        XCTAssertTrue(controller.collectionView.indexPathsForVisibleItems.contains { $0.item == 99_900 })
        for (index, anchor) in [(0, UnitPoint.top), (99_999, .center), (50_000, .top)] {
            scroll.scrollTo(rows[index], anchor: anchor)
            controller.view.layoutIfNeeded()
            XCTAssertTrue(controller.collectionView.indexPathsForVisibleItems.contains { $0.item == index })
        }
    }

    func testThousandsOfChannelsOnlyCreateVisibleRowHostsAndReuseUnchangedContent() {
        let rows = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        var renders = 0
        let list = list(rows: rows, scroll: scroll) { row in
            renders += 1
            return Text(row.channelID)
        }
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        let rendered = renders
        XCTAssertGreaterThan(rendered, 0)
        XCTAssertLessThan(rendered, 100, "Offscreen channels must not materialize a full-catalog focus tree")
        XCTAssertLessThan(controller.children.count, 100)

        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        XCTAssertEqual(renders, rendered, "Unchanged row revisions must reuse their hosted content")

        scroll.scrollTo(rows[4_900], anchor: .top)
        controller.view.layoutIfNeeded()
        XCTAssertLessThan(renders, 200)
        XCTAssertLessThan(controller.children.count, 100, "Offscreen hosts must leave the controller hierarchy")
    }

    func testPresentationEnvironmentIgnoresPrivateFocusChangesButTracksVisiblePreferences() {
        var environment = EnvironmentValues()
        let baseline = Guide.RowEnvironment(environment)
        XCTAssertEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = false
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = true
        environment.layoutDirection = .rightToLeft
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
    }

    // MARK: Opening at a saved position

    private func guide(
        rows: [LiveTVGuideRowID], scroll: PrototypeGuideScrollController,
        initial: PrototypeGuideListViewport?, reported: ((LiveTVGuideRowID, CGFloat) -> Void)? = nil
    ) -> Guide {
        Guide(
            rows: rows, scrollController: scroll, scrolled: { _, _ in }, viewportChanged: reported,
            initialViewport: initial, revision: { _ in 0 }, timelineWidth: 5_000, pinnedWidth: 140,
            stationaryContent: { Text($0.channelID) }, scrollingContent: { _ in Text("Programme") }
        )
    }

    func testFirstFrameIsAlreadyAtTheSavedViewportWithoutAnyScrollCommand() throws {
        let rows = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        var reported: [(LiveTVGuideRowID, CGFloat)] = []
        let initial = PrototypeGuideListViewport(row: rows[3_000], relativeOffset: 37)
        let list = guide(rows: rows, scroll: scroll, initial: initial) { reported.append(($0, $1)) }
        controller.update(list, environment: EnvironmentValues())
        XCTAssertTrue(controller.collectionView.visibleCells.isEmpty,
                      "update must not force layout or render cells before the native pass")
        XCTAssertEqual(scroll.scrollCommandCount, 0)
        controller.view.layoutIfNeeded()
        let collection = controller.collectionView!
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 3_000, section: 0)))
        XCTAssertEqual(cell.convert(cell.bounds, to: collection).minY - collection.bounds.minY, -37, accuracy: 0.5)
        let visible = controller.collectionView.indexPathsForVisibleItems.map(\.item)
        XCTAssertEqual(visible.min(), 3_000, "the first visible row is the saved anchor, not the top of the list")
        XCTAssertFalse(visible.contains(0))
        XCTAssertEqual(scroll.scrollCommandCount, 0)
        XCTAssertTrue(scroll.isVisible(rows[3_000]))
        XCTAssertFalse(scroll.isVisible(rows[0]))
        let settled = expectation(description: "reported")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(reported.last?.0, rows[3_000])
        XCTAssertEqual(try XCTUnwrap(reported.last?.1), 37, accuracy: 0.5)
        XCTAssertEqual(scroll.scrollCommandCount, 0)
    }

    func testListWithoutASavedViewportOrWithAnUnknownAnchorStartsAtTheTop() {
        let rows = (0..<500).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        for initial in [nil, PrototypeGuideListViewport(row: .init(channelID: "removed"), relativeOffset: 12)] {
            let scroll = PrototypeGuideScrollController()
            let controller = Guide.Controller()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.update(guide(rows: rows, scroll: scroll, initial: initial), environment: EnvironmentValues())
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.collectionView.contentOffset.y, 0)
            XCTAssertEqual(controller.collectionView.indexPathsForVisibleItems.map(\.item).min(), 0)
            XCTAssertEqual(scroll.scrollCommandCount, 0)
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
    }

    func testFullerLineupReplacingSavedRowsKeepsTheVisibleRowsInPlaceWithoutAScrollCommand() throws {
        let all = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let saved = Array(all[2_980..<3_130])
        let scroll = PrototypeGuideScrollController()
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        let initial = PrototypeGuideListViewport(row: all[3_000], relativeOffset: 37)
        controller.update(guide(rows: saved, scroll: scroll, initial: initial), environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.collectionView.indexPathsForVisibleItems.map(\.item).min(), 20)
        let list = controller.collectionView!
        let first = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 20, section: 0)))
        let y = first.convert(first.bounds, to: list).minY - list.bounds.minY
        XCTAssertEqual(y, -37, accuracy: 0.5)
        // The provider's lineup arrives and the saved position is dropped, as it is when the saved rows are replaced.
        controller.update(guide(rows: all, scroll: scroll, initial: nil), environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        let full = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 3_000, section: 0)))
        XCTAssertEqual(full.convert(full.bounds, to: list).minY - list.bounds.minY, y, accuracy: 0.5)
        XCTAssertEqual(controller.collectionView.indexPathsForVisibleItems.map(\.item).min(), 3_000)
        XCTAssertEqual(scroll.scrollCommandCount, 0)
        // Later replacements are ordinary: the offset is the viewer's, not held to an anchor.
        controller.update(guide(rows: Array(all[0..<10]), scroll: scroll, initial: nil), environment: EnvironmentValues())
        XCTAssertEqual(scroll.scrollCommandCount, 0)
    }
}
#endif
