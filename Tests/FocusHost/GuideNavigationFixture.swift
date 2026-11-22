import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
@testable import AppShell
@testable import FeatureLiveTV

struct GuideNavigationFixture: View {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    // 2027-01-15 22:13 UTC, with a 22:00 guide window start.
    private static let newsStart = Date(timeIntervalSince1970: 1_800_050_400)
    private static let newsNow = newsStart.addingTimeInterval(13 * 60)
    private static let fixtureWidth: CGFloat = 1_680
    private static let longProgrammeRow = 2
    private let showsLongProgramme: Bool
    private let benchmarksPagingDuration: Bool
    private let showsLoopRun: Bool
    private let showsUpToNow: Bool
    private let showsHorizontalRoute: Bool
    @FocusState private var headingFocused: Bool
    @State private var plateRequest: PrototypeGuidePlateRequest?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.plozzPinnedSidebarInteraction) private var sidebar
    @State private var model: LiveTVPrototypeModel
    @State private var imports = LiveTVPrototypeImportModel()
    @State private var selectedID: String?
    @State private var selectedRow: LiveTVGuideRowID?
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var hasFocus = false
    @State private var railActive = false
    @State private var restoring = true
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor: Date
    @State private var timelineOffset: CGFloat = 0
    @State private var nowRequest = 0

    init(showsLongProgramme: Bool = false, showsLoopRun: Bool = false, showsUpToNow: Bool = false,
         showsHorizontalRoute: Bool = false, benchmarksPagingDuration: Bool = false) {
        self.showsLongProgramme = showsLongProgramme
        self.benchmarksPagingDuration = benchmarksPagingDuration
        self.showsLoopRun = showsLoopRun
        self.showsUpToNow = showsUpToNow
        self.showsHorizontalRoute = showsHorizontalRoute
        let model = showsUpToNow ? Self.makeNewsModel()
            : Self.makeModel(showsLongProgramme: showsLongProgramme, showsLoopRun: showsLoopRun,
                             benchmarksPagingDuration: benchmarksPagingDuration)
        let initialID = showsUpToNow ? "global-edmonton" : "channel-0"
        _model = State(initialValue: model)
        _selectedID = State(initialValue: initialID)
        _selectedRow = State(initialValue: .init(channelID: initialID))
        _timeAnchor = State(initialValue: showsUpToNow ? Self.newsStart : Self.now)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Now") { nowRequest += 1 }
                    .accessibilityIdentifier("guide-now")
                if showsHorizontalRoute {
                    PrototypeGlassHeading(inputs: .init(
                        headingTitle: "My Channels", headingCount: "8", isHeadingOpen: false,
                        openHeading: {}, focusScope: nil, navigation: .init(
                            focus: $headingFocused, openSidebar: { sidebar?.requestOpen() },
                            requestPlate: { plateRequest = $0 }
                        ),
                        isPlaying: false, now: model.now, isFavorite: false,
                        toggleFavorite: {}, info: {}
                    ))
                }
                if showsUpToNow { Text(verbatim: "Canada · News") }
                Spacer()
                Text(focusedProgram?.title ?? selectedID ?? "No focus")
                    .accessibilityIdentifier("guide-focus-probe")
                if showsLoopRun || showsUpToNow {
                    Text(verbatim: hasFocus ? selectedID ?? "No row" : "No focus")
                        .accessibilityIdentifier("guide-channel-probe")
                }
                if showsUpToNow {
                    Text(verbatim: focusedProgram?.id ?? "No programme")
                        .accessibilityIdentifier("guide-programme-id-probe")
                }
                if benchmarksPagingDuration {
                    let pixels = UIScreen.main.currentMode?.size ?? UIScreen.main.nativeBounds.size
                    let minutes = Int(PrototypeLayout.viewportSeconds(for: Self.fixtureWidth) / 60)
                    let motion = UIAccessibility.isReduceMotionEnabled ? "reduced" : "default"
                    Text(verbatim: "\(minutes) / \(Int(pixels.width)) / \(Int(pixels.height)) / \(motion)")
                        .monospacedDigit()
                        .accessibilityIdentifier("guide-paging-geometry-probe")
                }
                if showsLongProgramme || showsLoopRun || showsUpToNow || benchmarksPagingDuration {
                    // The owner gets the shared timeline offset after scrolling settles.
                    // Don't add a SwiftUI dependency on each animation frame.
                    // The tvOS browser fills its container without the touch guide's insets.
                    let viewport = Int(PrototypeLayout.timelineWidth(for: Self.fixtureWidth).rounded())
                    Text(verbatim: "\(Int(timelineOffset.rounded())) / \(viewport)")
                        .monospacedDigit()
                        .accessibilityIdentifier("guide-offset-probe")
                }
            }
            .focusSection()
            PrototypeBrowser(
                model: model, imports: imports,
                selectedID: $selectedID, selectedRowID: $selectedRow,
                railActive: $railActive, focusedProgram: $focusedProgram, hasFocus: $hasFocus,
                topRequest: 0, nowRequest: nowRequest,
                guideOffset: $guideOffset, timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
                restoreFocusRequest: 1, isPresented: true, isRestoringFocus: restoring,
                restoresPlaybackFocus: true, watchOrigin: .init(channelID: showsUpToNow ? "global-edmonton" : "channel-0"),
                focusRestored: { _ in restoring = false },
                tune: { _ in }, details: { _ in }, openControls: {}, openSources: {},
                openGuideTime: {}, openToolbar: {}, isLoading: false, loadFailed: false, reload: {},
                leadingExit: showsHorizontalRoute ? { headingFocused = true } : nil,
                plateRequest: showsHorizontalRoute ? $plateRequest : nil
            )
        }
        .frame(width: Self.fixtureWidth, height: 840)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, benchmarksPagingDuration ? .leftToRight : layoutDirection)
    }

    private static func makeNewsModel() -> LiveTVPrototypeModel {
        let stations = [
            ("global-calgary", "Global News Calgary"),
            ("global-edmonton", "Global News Edmonton"),
            ("cbc-windsor", "CBC Windsor"),
            ("city-toronto", "City News Toronto ON")
        ]
        let channels = stations.enumerated().map { index, station in
            LiveTVPrototypeChannel(id: station.0, number: index + 1, name: station.1, category: "News",
                                   symbol: "tv", accent: index, source: .plozz, tagline: "")
        }
        let model = LiveTVPrototypeModel(now: newsNow, channels: channels)
        let start = newsStart
        func programme(_ id: String, _ channelID: String, _ title: String, _ from: Int, _ to: Int) -> LiveTVPrototypeProgram {
            .init(id: id, channelID: channelID, title: title, subtitle: "",
                  start: start.addingTimeInterval(Double(from * 60)), end: start.addingTimeInterval(Double(to * 60)))
        }
        do {
            try model.replacePrograms([
                programme("elsbeth-live", "global-calgary", "Elsbeth", 0, 52),
                programme("cupertino-later", "global-calgary", "Cupertino", 52, 142),
                programme("cbc-live", "cbc-windsor", "CBC News Windsor", 0, 39),
                programme("cbc-later", "cbc-windsor", "CBC Night News", 39, 142)
            ])
        } catch { preconditionFailure("Invalid news guide fixture: \(error)") }
        return model
    }

    private static func makeModel(
        showsLongProgramme: Bool, showsLoopRun: Bool, benchmarksPagingDuration: Bool
    ) -> LiveTVPrototypeModel {
        let loopRows = 2...15 // More contiguous loops than fit in the viewport.
        let channels = (0..<(showsLoopRun ? 22 : 8)).map { index in
            LiveTVPrototypeChannel(
                id: "channel-\(index)", number: index, name: "Channel \(index)", category: "Plozz",
                symbol: "tv", accent: index % 6, source: .plozz, tagline: "",
                loopTitle: showsLoopRun && loopRows.contains(index) ? "Loop \(index)" : nil
            )
        }
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        var programs: [LiveTVPrototypeProgram] = []
        for row in 0..<(channels.count - 1) where channels[row].loopTitle == nil {
            let currentEnd: TimeInterval = !showsLongProgramme && !benchmarksPagingDuration && (row == 0 || row == 4) ? 7_200 : 600
            programs.append(
                LiveTVPrototypeProgram(
                    id: "current-\(row)", channelID: channels[row].id, title: "Current \(row)", subtitle: "",
                    start: now.addingTimeInterval(-300), end: now.addingTimeInterval(currentEnd)
                )
            )
            // In the horizontal variant, row 2 has one 4.5-hour programme
            // (2.25 viewports), then a half-hour listing. All other rows use
            // half-hour listings with a short final slot at the six-hour seam.
            let boundaries: [TimeInterval]
            if benchmarksPagingDuration {
                // Regular rows provide half-hour landmarks across the entire replay.
                // Row 2 replaces +03:00...+15:00 with one continuous listing.
                let halfHours = Array(stride(from: TimeInterval(1_800), through: 18 * 3_600, by: 1_800))
                boundaries = [currentEnd] + halfHours.filter {
                    row != longProgrammeRow || $0 <= 3 * 3_600 || $0 >= 15 * 3_600
                }
            } else if showsLongProgramme {
                let firstNormal = row == longProgrammeRow ? currentEnd + 16_200 : currentEnd
                boundaries = (row == longProgrammeRow ? [currentEnd] : [])
                    + Array(stride(from: firstNormal, to: 21_600, by: 1_800)) + [21_600]
            } else {
                boundaries = [currentEnd, currentEnd + 1_800, currentEnd + 3_600, 21_600]
            }
            for index in 0..<(boundaries.count - 1) {
                let isPagingProgramme = benchmarksPagingDuration && row == longProgrammeRow
                    && boundaries[index] == 3 * 3_600
                programs.append(LiveTVPrototypeProgram(
                    id: isPagingProgramme ? "paging-marathon" : "future-\(row)-\(index)",
                    channelID: channels[row].id,
                    title: isPagingProgramme ? "Paging Marathon" : "Future \(row).\(index + 1)", subtitle: "",
                    start: now.addingTimeInterval(boundaries[index]),
                    end: now.addingTimeInterval(boundaries[index + 1])
                ))
            }
            if benchmarksPagingDuration { continue }
            // Hourly listings past the guide's first six hours.
            for hour in 0..<42 {
                programs.append(LiveTVPrototypeProgram(
                    id: "later-\(row)-\(hour)", channelID: channels[row].id,
                    title: "Later \(row).\(hour + 1)", subtitle: "",
                    start: now.addingTimeInterval(21_600 + Double(hour) * 3_600),
                    end: now.addingTimeInterval(21_600 + Double(hour + 1) * 3_600)
                ))
            }
        }
        do { try model.replacePrograms(programs) }
        catch { preconditionFailure("Invalid guide fixture: \(error)") }
        return model
    }
}

/// Production pinned sidebar and heading around the same offline guide fixture.
struct GuideHorizontalRouteFixture: View {
    @State private var selection = NavigationRailDestination.liveTV
    @State private var chrome = NavigationChromeModel()
    @State private var profile = Profile(name: "Viewer")

    var body: some View {
        NavigationRailShell(
            profile: profile, entries: [], destinations: [.home, .liveTV, .settings],
            selection: $selection, onOpenProfileSwitcher: {}, chrome: chrome,
            content: GuideNavigationFixture(showsLongProgramme: true, showsHorizontalRoute: true),
            contentDestination: .liveTV
        )
    }
}
