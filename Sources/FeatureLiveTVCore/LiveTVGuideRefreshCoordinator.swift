import CoreModels
import CoreNetworking
import Foundation
import Observation

/// What one shared refresh did, for the interval timer's pacing and for the post-refresh hook.
public struct LiveTVGuideRefreshResult: Sendable, Equatable {
    /// The earliest due date reported by any account.
    public var nextDue: Date?
    /// At least one account's refresh threw; saved listings were retained.
    public var failed = false
    /// Accounts that asked a server about at least one saved guide in this run.
    public var transferredAccountIDs: [String] = []
    /// Accounts whose refresh threw. Their listings were retained, so this run is not a complete picture of them
    /// and must never be used to prune anything.
    public var failedAccountIDs: [String] = []
    /// Inputs committed since the previous delivered result, per account id, from the shared refresh itself.
    /// Only accounts with changes appear; an unchanged validation (304 or an identical body) adds nothing.
    public var committedInputs: [String: SavedGuideCommittedInputs] = [:]
    /// True only when every account's refresh finished without error.
    public var isComplete: Bool { !failed && failedAccountIDs.isEmpty }
    public init(
        nextDue: Date? = nil, failed: Bool = false, transferredAccountIDs: [String] = [],
        failedAccountIDs: [String] = [], committedInputs: [String: SavedGuideCommittedInputs] = [:]
    ) {
        self.nextDue = nextDue
        self.failed = failed
        self.transferredAccountIDs = transferredAccountIDs
        self.failedAccountIDs = failedAccountIDs
        self.committedInputs = committedInputs
    }
}

/// The accounts one profile may refresh, and whether it may do so now. Replaced as a whole.
public struct LiveTVGuideRefreshScope {
    public var accountIDs: [String]
    public var authorizationID: String
    public var isAuthorized: Bool
    public var isForeground: Bool
    public var resolver: LiveTVServerProviderResolver

    public init(
        accountIDs: [String], authorizationID: String, isAuthorized: Bool, isForeground: Bool = true,
        resolver: @escaping LiveTVServerProviderResolver
    ) {
        self.accountIDs = accountIDs
        self.authorizationID = authorizationID
        self.isAuthorized = isAuthorized
        self.isForeground = isForeground
        self.resolver = resolver
    }
}

/// The one admission point for saved-guide refreshes of the active profile: the interval timer and the
/// Settings "Sync Now" button both go through it, so overlapping requests share one run (one provider
/// operation per account) and one awaited post-refresh hook.
///
/// A manual request neither changes the stored interval nor touches the timer's schedule or failure
/// history; the provider still applies its own refusal and backoff. A change of accounts, authorization
/// or foreground state retires the run: its result is discarded and its hook does not fire.
@MainActor @Observable
public final class LiveTVGuideRefreshCoordinator: SavedGuideRefreshControlling {
    public private(set) var isRefreshing = false
    public var isAvailable: Bool {
        scope.isAuthorized && scope.isForeground && !scope.accountIDs.isEmpty
    }

    /// Awaited once per shared run, after its transfers and before any waiter resumes. The parent uses it
    /// to prepare changed inputs durably (for example change-driven channel artwork). Not called for a run
    /// that was retired or cancelled.
    @ObservationIgnored public var didRefresh: (@MainActor (LiveTVGuideRefreshResult) async -> Void)?

    private var scope: LiveTVGuideRefreshScope
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var flight: Flight?
    /// Committed inputs reported by a provider during a run whose result was then discarded; delivered with the next
    /// run of the same accounts and authorization, dropped when either changes.
    @ObservationIgnored private var undelivered: [String: SavedGuideCommittedInputs] = [:]
    /// The most recently retired run's task. The next run waits for it to finish handing over what it received.
    @ObservationIgnored private var retiredTask: Task<Void, Never>?

    private final class Flight {
        let generation: Int
        var manualRequested: Bool
        /// A manual request owns the run: waiters leaving (Settings dismissed) must not cancel it.
        var pinned: Bool
        var task: Task<Void, Never>?
        var predecessor: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<LiveTVGuideRefreshResult?, Never>] = [:]
        init(generation: Int, manual: Bool) {
            self.generation = generation
            manualRequested = manual
            pinned = manual
        }
    }

    public init(scope: LiveTVGuideRefreshScope = .init(
        accountIDs: [], authorizationID: "", isAuthorized: false, resolver: { _ in nil }
    )) {
        self.scope = scope
    }

    /// Adopts the current scope. A different account set, authorization, or loss of authorization or the
    /// foreground retires the running refresh.
    public func configure(_ new: LiveTVGuideRefreshScope) {
        let changed = new.accountIDs != scope.accountIDs || new.authorizationID != scope.authorizationID
        if changed { undelivered = [:] }
        scope = new
        if changed || !isAvailable { retire() }
    }

    /// The scope's account set and authorization the coordinator currently runs under.
    public var currentAccountIDs: [String] { scope.accountIDs }
    public var currentAuthorizationID: String { scope.authorizationID }

    public func requestManualRefresh() {
        guard let flight = admit(.manual) else { return }
        flight.pinned = true
    }

    /// Joins or starts the shared run. Nil when unavailable, retired, or cancelled. Cancelling the caller only
    /// detaches it; the run is cancelled when no waiter is left and no manual request owns it.
    public func refresh(_ trigger: SavedGuideRefreshTrigger) async -> LiveTVGuideRefreshResult? {
        guard let flight = admit(trigger) else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                flight.waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.detach(id, from: flight) }
        }
    }

    private func admit(_ trigger: SavedGuideRefreshTrigger) -> Flight? {
        guard isAvailable else { return nil }
        if let flight, flight.generation == generation {
            if trigger == .manual { flight.manualRequested = true }
            return flight
        }
        let flight = Flight(generation: generation, manual: trigger == .manual)
        self.flight = flight
        isRefreshing = true
        flight.predecessor = retiredTask
        flight.task = Task(priority: .utility) { await self.perform(flight) }
        return flight
    }

    private func detach(_ id: UUID, from flight: Flight) {
        flight.waiters.removeValue(forKey: id)?.resume(returning: nil)
        if flight.waiters.isEmpty, !flight.pinned { flight.task?.cancel() }
    }

    private func retire() {
        generation += 1
        guard let flight else { return }
        self.flight = nil
        isRefreshing = false
        flight.task?.cancel()
        retiredTask = flight.task
        for waiter in flight.waiters.values { waiter.resume(returning: nil) }
        flight.waiters.removeAll()
    }

    private func isCurrent(_ flight: Flight) -> Bool {
        self.flight === flight && flight.generation == generation && isAvailable && !Task.isCancelled
    }

    private func perform(_ flight: Flight) async {
        var result = LiveTVGuideRefreshResult()
        var scheduledWithoutTransfer: [String] = []
        // A retired run may still be returning inputs its provider already handed over; let it park them first.
        await flight.predecessor?.value
        flight.predecessor = nil
        let accountIDs = scope.accountIDs
        let authorizationID = scope.authorizationID
        // Providers hand over each change once, so a discarded run must not lose what it received.
        func discard() {
            guard scope.accountIDs == accountIDs, scope.authorizationID == authorizationID else { return }
            for (id, inputs) in result.committedInputs { undelivered[id] = undelivered[id]?.merged(with: inputs) ?? inputs }
        }
        // Pass 0 follows demand as it arrives. A manual request that arrived after an account was
        // decided as scheduled rechecks only the accounts that asked no server (not due) in pass 1.
        for pass in 0..<2 {
            let ids = pass == 0 ? accountIDs : scheduledWithoutTransfer
            if pass == 1 { scheduledWithoutTransfer = []; guard flight.manualRequested else { break } }
            for id in ids {
                guard isCurrent(flight) else { discard(); return finish(flight, nil) }
                // Resolved again for every account: only the current profile's authorized accounts.
                guard let context = scope.resolver(id), context.kind == .iptv else { continue }
                let trigger: SavedGuideRefreshTrigger = flight.manualRequested ? .manual : .scheduled
                do {
                    if let report = try await context.provider.refreshSavedLiveTVGuide(trigger: trigger) {
                        if let due = report.nextDue { result.nextDue = min(result.nextDue ?? due, due) }
                        if report.transferredGuides > 0 { result.transferredAccountIDs.append(id) }
                        if !report.committedInputs.isEmpty {
                            result.committedInputs[id] = result.committedInputs[id]?.merged(with: report.committedInputs)
                                ?? report.committedInputs
                        }
                        if pass == 0, trigger == .scheduled, report.transferredGuides == 0 {
                            scheduledWithoutTransfer.append(id)
                        }
                    }
                } catch {
                    guard isCurrent(flight) else { discard(); return finish(flight, nil) }
                    result.failed = true
                    result.failedAccountIDs.append(id)
                    PlozzLog.app.error("Saved guide refresh failed; saved listings retained")
                }
            }
        }
        guard isCurrent(flight) else { discard(); return finish(flight, nil) }
        for (id, inputs) in undelivered {
            result.committedInputs[id] = inputs.merged(with: result.committedInputs[id] ?? SavedGuideCommittedInputs())
        }
        undelivered = [:]
        if let didRefresh { await didRefresh(result) }
        if isCurrent(flight) { finish(flight, result) } else { discard(); finish(flight, nil) }
    }

    private func finish(_ flight: Flight, _ result: LiveTVGuideRefreshResult?) {
        if self.flight === flight {
            self.flight = nil
            isRefreshing = false
        }
        let waiters = flight.waiters
        flight.waiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: result) }
    }
}
