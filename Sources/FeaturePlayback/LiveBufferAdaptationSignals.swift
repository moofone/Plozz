import CoreModels
import Foundation

/// Turns the player's per-tick buffering state into the two signals the adaptive live buffer learns
/// from: a qualifying stall (once per episode) and batches of stable playback seconds.
/// Startup waits, user pauses and seeks must be filtered out by the caller before they reach `isStalling`.
struct LiveBufferAdaptationSignals {
    struct Output: Equatable {
        var stalled = false
        var stableSeconds: TimeInterval = 0
    }

    static let stableBatchSeconds: TimeInterval = 60
    /// A sleep or suspend gap must not count as watched time.
    static let maximumTickSeconds: TimeInterval = 2

    private var stallStartedAt: TimeInterval?
    private var stallReported = false
    private var lastStableTickAt: TimeInterval?
    private var pendingStableSeconds: TimeInterval = 0

    mutating func observe(isStalling: Bool, isStablePlaying: Bool, at uptime: TimeInterval) -> Output {
        var output = Output()
        if isStalling {
            lastStableTickAt = nil
            let started = stallStartedAt ?? uptime
            stallStartedAt = started
            if !stallReported, uptime - started >= LiveBufferAdaptation.minimumStallSeconds {
                stallReported = true
                pendingStableSeconds = 0
                output.stalled = true
            }
            return output
        }
        stallStartedAt = nil
        stallReported = false
        guard isStablePlaying else {
            lastStableTickAt = nil
            return output
        }
        if let last = lastStableTickAt {
            pendingStableSeconds += min(max(0, uptime - last), Self.maximumTickSeconds)
        }
        lastStableTickAt = uptime
        if pendingStableSeconds >= Self.stableBatchSeconds {
            output.stableSeconds = pendingStableSeconds
            pendingStableSeconds = 0
        }
        return output
    }

    /// The watched seconds not yet reported, for the end of a session.
    mutating func flush() -> TimeInterval {
        defer { self = LiveBufferAdaptationSignals() }
        return pendingStableSeconds
    }
}
