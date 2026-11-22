import Foundation

public struct LiveTVGuideSlot: Identifiable, Equatable, Sendable {
    public let program: LiveTVPrototypeProgram?
    public let start: Date
    public let end: Date

    public var id: String {
        "\(program?.id ?? "gap"):\(start.timeIntervalSince1970)"
    }
}

public enum LiveTVGuideTimeline {
    /// Clip overlaps and retain empty intervals so every row shares the same clock.
    public static func slots(
        programs: [LiveTVPrototypeProgram],
        from start: Date,
        to end: Date
    ) -> [LiveTVGuideSlot] {
        guard start < end else { return [] }
        var cursor = start
        var result: [LiveTVGuideSlot] = []
        let ordered = programs.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        for program in ordered where program.start < end && program.end > cursor {
            let clippedStart = max(cursor, program.start)
            let clippedEnd = min(end, program.end)
            guard clippedStart < clippedEnd else { continue }
            if clippedStart > cursor {
                result.append(LiveTVGuideSlot(program: nil, start: cursor, end: clippedStart))
            }
            result.append(LiveTVGuideSlot(program: program, start: clippedStart, end: clippedEnd))
            cursor = clippedEnd
        }
        if cursor < end {
            result.append(LiveTVGuideSlot(program: nil, start: cursor, end: end))
        }
        return result
    }

    /// The slots as drawn: a slot shorter than `minimumDuration` would be a cell thinner than its own corner radii, so it is
    /// absorbed by a neighbour. An empty interval is taken in by the programme before it; a programme that is only a sliver
    /// (the window clips it, or it is short) hands its time to the programme after it, which then starts earlier than its listing.
    /// Every other slot, and the span the slots cover, is unchanged.
    public static func slots(
        programs: [LiveTVPrototypeProgram], from start: Date, to end: Date, minimumDuration: TimeInterval
    ) -> [LiveTVGuideSlot] {
        absorbingSlivers(in: slots(programs: programs, from: start, to: end), minimumDuration: minimumDuration)
    }

    /// How much programme time `minimumSlotWidth` points span on a timeline `timelineWidth` points wide showing
    /// `viewportSeconds`; zero (no absorbing) until the timeline has been measured.
    public static func minimumDuration(
        viewportSeconds: TimeInterval, timelineWidth: Double, minimumSlotWidth: Double
    ) -> TimeInterval {
        guard timelineWidth > 0, minimumSlotWidth > 0, viewportSeconds > 0 else { return 0 }
        return viewportSeconds * minimumSlotWidth / timelineWidth
    }

    static func absorbingSlivers(in slots: [LiveTVGuideSlot], minimumDuration: TimeInterval) -> [LiveTVGuideSlot] {
        guard slots.count > 1, minimumDuration > 0 else { return slots }
        var drawn: [LiveTVGuideSlot] = []
        var carriedStart: Date?
        for (index, slot) in slots.enumerated() {
            let current = carriedStart.map { LiveTVGuideSlot(program: slot.program, start: $0, end: slot.end) } ?? slot
            carriedStart = nil
            if current.end.timeIntervalSince(current.start) < minimumDuration {
                if current.program == nil, let last = drawn.last {
                    drawn[drawn.count - 1] = LiveTVGuideSlot(program: last.program, start: last.start, end: current.end)
                    continue
                }
                if index < slots.count - 1 {
                    carriedStart = current.start
                    continue
                }
                if let last = drawn.last {
                    drawn[drawn.count - 1] = LiveTVGuideSlot(program: last.program, start: last.start, end: current.end)
                    continue
                }
            }
            drawn.append(current)
        }
        return drawn
    }
}
