import CoreModels
import CoreNetworking
import Foundation

/// Keeps programme guides that are already saved on the device current while the app is
/// open, so Live TV opens on listings it does not have to wait for.
///
/// Each pass asks an account only whether its saved guide is due; the provider contacts
/// its server at most once per chosen interval, never per channel, and never downloads a
/// guide the profile has not used before.
public enum LiveTVGuideAutoUpdate {
    /// Launch belongs to Home; the first check waits until it has settled.
    public static let startDelay: TimeInterval = 60
    static let minimumWait: TimeInterval = 300
    static let firstRetry: TimeInterval = 900

    /// The timer for callers with only a resolver. Runs through a private coordinator, so it behaves exactly as before.
    @MainActor
    public static func run(
        accountIDs: [String], interval: TimeInterval, resolver: @escaping LiveTVServerProviderResolver,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        guard interval > 0, !accountIDs.isEmpty else { return }
        let coordinator = LiveTVGuideRefreshCoordinator(scope: .init(
            accountIDs: accountIDs, authorizationID: "", isAuthorized: true, resolver: resolver
        ))
        await run(coordinator: coordinator, interval: interval, now: now, sleep: sleep)
    }

    /// The timer over a shared coordinator: each pass joins or starts the same run a manual request would, so the two
    /// never overlap. The timer keeps its own failure count; a manual request never resets it or its next wake.
    @MainActor
    public static func run(
        coordinator: LiveTVGuideRefreshCoordinator, interval: TimeInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        guard interval > 0 else { return }
        do {
            try await sleep(startDelay)
            var failures = 0
            while true {
                try Task.checkCancellation()
                let result = await coordinator.refresh(.scheduled)
                try Task.checkCancellation()
                // Retired (profile, accounts, authorization or foreground changed): the owner restarts the timer.
                guard let result else { return }
                if result.failed { PlozzLog.app.error("Automatic guide update failed; saved listings retained") }
                try await sleep(wait(
                    next: result.nextDue, failed: result.failed, failures: &failures, interval: interval, now: now()
                ))
            }
        } catch {
            // Cancelled: the profile, accounts, setting, or foreground state changed.
        }
    }

    static func wait(
        next: Date?, failed: Bool, failures: inout Int, interval: TimeInterval, now: Date
    ) -> TimeInterval {
        let wanted: TimeInterval
        if failed {
            failures += 1
            wanted = firstRetry * pow(2, Double(min(failures, 6) - 1))
        } else {
            failures = 0
            wanted = next.map { $0.timeIntervalSince(now) } ?? interval
        }
        return min(interval, max(minimumWait, wanted))
    }
}
