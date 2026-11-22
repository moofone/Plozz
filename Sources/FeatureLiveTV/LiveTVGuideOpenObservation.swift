#if DEBUG && os(tvOS)
import FeatureLiveTVCore
import SwiftUI
import UIKit

/// Test-only observation of when the real glass guide first mounts a channel plate and a programme title.
/// Absent (nil) outside tests; it reads, never changes, what the rows draw.
struct LiveTVGuideOpenObserver {
    var plateAppeared: @MainActor (LiveTVPrototypeChannel, LiveTVGuideStationMarkRead) -> Void
    var programmeAppeared: @MainActor (LiveTVPrototypeProgram) -> Void
}

private struct LiveTVGuideOpenObserverKey: EnvironmentKey {
    static let defaultValue: LiveTVGuideOpenObserver? = nil
}

extension EnvironmentValues {
    var liveTVGuideOpenObserver: LiveTVGuideOpenObserver? {
        get { self[LiveTVGuideOpenObserverKey.self] }
        set { self[LiveTVGuideOpenObserverKey.self] = newValue }
    }
}

/// Observes the actual hosted cells after a natural native layout pass, not the requested offset.
struct LiveTVGuideViewportObserver {
    struct HostedCell {
        let channelID: String
        let cell: UICollectionViewCell
    }

    let didLayout: @MainActor (UICollectionView, Int, [HostedCell]) -> Void
}

private struct LiveTVGuideViewportObserverKey: EnvironmentKey {
    static let defaultValue: LiveTVGuideViewportObserver? = nil
}

extension EnvironmentValues {
    var liveTVGuideViewportObserver: LiveTVGuideViewportObserver? {
        get { self[LiveTVGuideViewportObserverKey.self] }
        set { self[LiveTVGuideViewportObserverKey.self] = newValue }
    }
}

private struct ObservesGuidePlate: ViewModifier {
    let channel: LiveTVPrototypeChannel
    @Environment(\.liveTVGuideOpenObserver) private var observer
    @Environment(\.liveTVGuideStationMarks) private var stationMarks

    func body(content: Content) -> some View {
        content.onAppear { observer?.plateAppeared(channel, stationMarks.read(channel)) }
    }
}

private struct ObservesGuideProgramme: ViewModifier {
    let program: LiveTVPrototypeProgram
    @Environment(\.liveTVGuideOpenObserver) private var observer

    func body(content: Content) -> some View {
        content.onAppear { observer?.programmeAppeared(program) }
    }
}

extension View {
    func observesGuidePlate(_ channel: LiveTVPrototypeChannel) -> some View {
        modifier(ObservesGuidePlate(channel: channel))
    }

    func observesGuideProgramme(_ program: LiveTVPrototypeProgram) -> some View {
        modifier(ObservesGuideProgramme(program: program))
    }
}
#endif
