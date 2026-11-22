#if DEBUG && os(tvOS)
import Foundation

/// Test-only monotonic checkpoints for the cached Live TV open. `begin` is set by the hosted test just before selection;
/// each checkpoint keeps only its first occurrence, so per-row work never logs. Absent from release builds.
public enum LiveTVOpenTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var begin: ContinuousClock.Instant?
    nonisolated(unsafe) private static var marks: [(name: String, at: ContinuousClock.Instant)] = []

    public static func start(at instant: ContinuousClock.Instant) {
        lock.withLock { begin = instant; marks = [] }
    }

    public static func mark(_ name: String) {
        let now = ContinuousClock.now
        lock.withLock {
            guard begin != nil, !marks.contains(where: { $0.name == name }) else { return }
            marks.append((name, now))
        }
    }

    /// Checkpoints in occurrence order with milliseconds since `begin`.
    public static func snapshot() -> [(name: String, milliseconds: Double)] {
        lock.withLock {
            guard let begin else { return [] }
            return marks.map { mark in
                let parts = (mark.at - begin).components
                return (mark.name, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
            }
        }
    }
}

@inline(__always) func openTrace(_ name: String) { LiveTVOpenTrace.mark(name) }
#else
@inline(__always) func openTrace(_ name: String) {}
#endif
