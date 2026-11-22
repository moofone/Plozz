import Foundation
import Observation

/// The guide's one clock: where the window starts, when it moves, and what each
/// programme is relative to "now". Everything time-dependent reads
/// `LiveTVPrototypeModel.now`; nothing captures a date when a view is built.
public enum LiveTVGuideClock {
    /// The ruler's slot: the window starts on a :00 or :30.
    public static let slot: TimeInterval = 1_800
    /// A key press this recent holds the window still, so the guide never moves under a press.
    public static let idleBeforeAdvance: TimeInterval = 8
    /// The longest the "n m left" label may go without a tick.
    public static let labelRefresh: TimeInterval = 30
    /// The window's shift animation; reduced motion shifts without one.
    public static let shiftAnimationDuration: TimeInterval = 0.35

    /// When a return from the full-screen picture recomputes the guide's time-dependent state.
    public enum ReturnCatchUp: Equatable, Sendable {
        /// The clock is within one label refresh and in the same slot: the guide shows at once and
        /// the recompute follows in the next turn, off the Back-to-first-frame path.
        case deferred
        /// The labels are due or the window start moved: recompute before the guide shows, because
        /// focus restoration reads the window.
        case immediate
    }

    /// `now` floored to the local half hour at or before it (10:22 → 10:00). The floor follows the
    /// zone's wall clock, so quarter-hour zones and the days of a DST change keep :00/:30 slots.
    /// `autoupdatingCurrent` follows a zone change without a restart.
    public static func windowStart(for now: Date, in timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: now))
        let local = now.timeIntervalSince1970 + offset
        return Date(timeIntervalSince1970: (local / slot).rounded(.down) * slot - offset)
    }

    /// The next :00 or :30 strictly after `date`.
    public static func nextSlotBoundary(after date: Date, in timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        windowStart(for: date, in: timeZone).addingTimeInterval(slot)
    }

    /// Where a guide the viewer scrolled right (`offset` > 0) sits after the window start moves to
    /// `newAnchor`: the moment at its left edge stays, so the focused programme doesn't move or snap
    /// back to now. A scroll smaller than the shift can't keep it and rests at the new start.
    public static func timelineAfterShift(
        anchor: Date, offset: CGFloat, newAnchor: Date, pointsPerSecond: CGFloat
    ) -> (anchor: Date, offset: CGFloat) {
        let shift = CGFloat(newAnchor.timeIntervalSince(anchor)) * pointsPerSecond
        return (newAnchor, max(0, offset - shift))
    }
}

/// The guide window's mutable state, apart from the model's other tracked state.
@MainActor
@Observable
final class LiveTVGuideClockState {
    var windowStart = Date(timeIntervalSince1970: 0)
    var lastInteraction: Date?
}

/// How a programme reads against the clock.
public enum LiveTVProgramPhase: Equatable, Sendable {
    case ended, onNow, upcoming

    public init(program: LiveTVPrototypeProgram, now: Date) {
        if program.end <= now { self = .ended }
        else if program.start <= now { self = .onNow }
        else { self = .upcoming }
    }
}

/// What the guide hero offers for the focused programme. Ended programmes have no way to
/// play: the hero says "Ended" and keeps Favorite and Details.
public struct LiveTVHeroActions: Equatable, Sendable {
    public enum Primary: Equatable, Sendable {
        /// Watch, or Resume while this channel is the one playing.
        case watch(resumes: Bool)
        /// A future programme: the button plays the channel without a label.
        case upcoming
        case none
    }

    public let primary: Primary
    public let showsMultiview: Bool
    public let showsEndedLabel: Bool

    /// - Parameters:
    ///   - program: the focused programme, nil when the channel has no guide.
    ///   - isPlayingChannel: the focused channel is the one playing.
    public init(program: LiveTVPrototypeProgram?, isPlayingChannel: Bool, now: Date) {
        switch program.map({ LiveTVProgramPhase(program: $0, now: now) }) {
        case .ended:
            primary = .none
            showsMultiview = false
            showsEndedLabel = true
        case .upcoming:
            primary = .upcoming
            // Mockup `heroButtons`: a programme not on yet can only be remembered or its channel watched; nothing to add to Multiview.
            showsMultiview = false
            showsEndedLabel = false
        case .onNow, nil:
            // Resume only while the playing channel's current programme is the focused one.
            primary = .watch(resumes: isPlayingChannel)
            // Mockup `heroButtons`: the channel already playing is not offered to Multiview again.
            showsMultiview = !isPlayingChannel
            showsEndedLabel = false
        }
    }
}

/// What Select does on a programme cell.
public enum LiveTVGuideCellSelection: Equatable, Sendable {
    case tune, details, nothing

    /// - Parameter picksChannel: the guide is choosing channels (Multiview), where any cell picks its channel.
    public static func action(for program: LiveTVPrototypeProgram, now: Date, picksChannel: Bool) -> Self {
        if picksChannel { return .tune }
        switch LiveTVProgramPhase(program: program, now: now) {
        case .onNow: return .tune
        case .upcoming: return .details
        case .ended: return .nothing
        }
    }
}

extension LiveTVPrototypeModel {
    /// Records a key press at the model's clock, which holds the window still until the guide is idle.
    public func noteGuideInteraction() {
        lastGuideInteraction = now
    }

    /// True while the window is behind `now`'s half hour but a recent key press holds it.
    public var guideWindowAdvanceIsDeferred: Bool {
        guideWindowStart < LiveTVGuideClock.windowStart(for: now) && !isGuideIdle
    }

    /// Moves the window to `now`'s half hour unless a key press is recent. True when it moved.
    /// Called by every clock update, so catching up after a long absence is one pass.
    @discardableResult
    func advanceGuideWindowIfIdle() -> Bool {
        let target = LiveTVGuideClock.windowStart(for: now)
        guard target > guideWindowStart, isGuideIdle else { return false }
        guideClockState.windowStart = target
        return true
    }

    /// The user asked for "now" (Now, search): the window moves immediately.
    public func alignGuideWindowToNow() {
        guideClockState.windowStart = LiveTVGuideClock.windowStart(for: now)
    }

    private var isGuideIdle: Bool {
        guard let last = lastGuideInteraction else { return true }
        return now.timeIntervalSince(last) >= LiveTVGuideClock.idleBeforeAdvance
    }

    /// When the clock should next tick: the earliest of the next :00/:30 (or the end of a
    /// deferral), a programme boundary on `channelIDs`, and the label refresh. Never polls faster than needed.
    public func nextClockDeadline(channelIDs: [String]) -> Date {
        var next = now.addingTimeInterval(LiveTVGuideClock.labelRefresh)
        let slotBoundary = LiveTVGuideClock.nextSlotBoundary(after: now)
        next = min(next, slotBoundary)
        if guideWindowStart < LiveTVGuideClock.windowStart(for: now), let last = lastGuideInteraction {
            let release = last.addingTimeInterval(LiveTVGuideClock.idleBeforeAdvance)
            if release > now { next = min(next, release) }
        }
        for channelID in Set(channelIDs) {
            for program in programs(for: channelID, from: now, hours: 1) {
                if program.start > now { next = min(next, program.start) }
                if program.end > now { next = min(next, program.end) }
            }
        }
        return next
    }

    /// After the window moved: the programme on `channelID` that focus should move to, or nil
    /// when the focused one is still in the window. A programme that ended before the window
    /// starts hands focus to the channel's current programme; the row never changes.
    public func programToFocusAfterWindowShift(focusedProgramID: String, channelID: String) -> LiveTVPrototypeProgram? {
        let programs = self.programs(for: channelID, from: guideWindowStart.addingTimeInterval(-6 * 3_600), hours: 12)
        guard let focused = programs.first(where: { $0.id == focusedProgramID }),
              focused.end <= guideWindowStart else { return nil }
        return currentProgram(for: channelID)
    }
}
