import Foundation
#if DEBUG && canImport(os)
import os
#endif

/// Times Back between the full-screen picture and the guide: from the press to the destination's
/// first committed frame. The views mark both ends; nothing here touches layout, focus or playback.
/// The acceptance target is a median under 100 ms and a worst case under 150 ms over ten presses.
@MainActor
public final class BackLatencyProbe {
    public enum Transition: String, Sendable, CaseIterable {
        case playerToGuide, guideToPlayer
    }

    public static let shared = BackLatencyProbe()
    public static let medianTarget: Duration = .milliseconds(100)
    public static let worstTarget: Duration = .milliseconds(150)

    private let now: @MainActor () -> ContinuousClock.Instant
    private var pending: (transition: Transition, at: ContinuousClock.Instant)?
    private var recorded: [Transition: [Duration]] = [:]
    #if DEBUG && canImport(os)
    private let signposter = OSSignposter(subsystem: "com.plozz.livetv", category: "BackLatency")
    #endif

    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// The Back press was received.
    public func pressed(_ transition: Transition) {
        pending = (transition, now())
        #if DEBUG && canImport(os)
        signposter.emitEvent("BackPressed", "\(transition.rawValue, privacy: .public)")
        #endif
    }

    /// The destination's first frame was committed. Returns the press-to-frame time, or nil when
    /// no press of this transition is pending (a guide that appeared for another reason).
    @discardableResult
    public func presented(_ transition: Transition) -> Duration? {
        guard let pending, pending.transition == transition else { return nil }
        self.pending = nil
        let elapsed = pending.at.duration(to: now())
        recorded[transition, default: []].append(elapsed)
        #if DEBUG
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
        HandoffDiagnostics.emit(
            "LIVE_TV event=backLatency transition=\(transition.rawValue) ms=\(Int(milliseconds.rounded())) "
                + "samples=\(samples(transition).count)")
        #if canImport(os)
        signposter.emitEvent("GuidePresented", "\(transition.rawValue, privacy: .public)")
        #endif
        #endif
        return elapsed
    }

    public func samples(_ transition: Transition) -> [Duration] { recorded[transition] ?? [] }

    public func median(_ transition: Transition) -> Duration? {
        let sorted = samples(transition).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public func worst(_ transition: Transition) -> Duration? { samples(transition).max() }

    public func meetsTarget(_ transition: Transition) -> Bool {
        guard let median = median(transition), let worst = worst(transition) else { return false }
        return median < Self.medianTarget && worst < Self.worstTarget
    }

    public func reset() {
        pending = nil
        recorded = [:]
    }
}
