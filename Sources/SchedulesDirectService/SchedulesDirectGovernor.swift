import Foundation

/// Injectable time source so the governor and limiter are deterministic in tests.
public struct SchedulesDirectClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = SchedulesDirectClock()
}

/// Hard request limits per account. Schedules Direct blocks the IP of clients
/// that ignore its limits, so these are deliberately far below its own.
public struct SchedulesDirectLimits: Sendable, Equatable {
    public var requestsPerHour = 20
    public var requestsPerDay = 100
    public var maxConcurrentRequests = 2
    public var maxAttemptsPerRequest = 3
    /// Back-pressure waits up to this long are retried inside the same sync.
    public var maxInSyncRetryWait: TimeInterval = 60
    public var minimumSyncInterval: TimeInterval = 3600
    public var automaticSyncInterval: TimeInterval = 24 * 3600
    public var firstBackoff: TimeInterval = 15 * 60
    public var maximumBackoff: TimeInterval = 6 * 3600
    public var circuitBreakerFailures = 3

    public init() {}
}

/// The persisted per-account safety state.
struct SchedulesDirectGovernorState: Codable, Equatable, Sendable {
    var requestTimes: [Date] = []
    var notBefore: Date?
    var attention: SchedulesDirectAttention?
    var consecutiveBackPressure = 0
    var lastSyncAttempt: Date?
    var lastSyncSuccess: Date?
    var lastSyncStationCount: Int?
    var lastSyncFailed = false
    var installMinuteOfDay: Int
}

/// Per-account request ledger, back-pressure and attention gate. One instance per
/// account per process (see ``SchedulesDirectAccounts``); state survives relaunch.
actor SchedulesDirectGovernor {
    private static let stateFile = "governor.json"

    private let accountKey: String
    private let storage: SchedulesDirectStorage
    private let clock: SchedulesDirectClock
    private let limits: SchedulesDirectLimits
    private let jitter: @Sendable () -> Double
    private var state: SchedulesDirectGovernorState

    init(
        accountKey: String, storage: SchedulesDirectStorage, clock: SchedulesDirectClock,
        limits: SchedulesDirectLimits, jitter: @escaping @Sendable () -> Double
    ) {
        self.accountKey = accountKey
        self.storage = storage
        self.clock = clock
        self.limits = limits
        self.jitter = jitter
        self.state = storage.read(SchedulesDirectGovernorState.self, name: Self.stateFile, accountKey: accountKey)
            ?? SchedulesDirectGovernorState(installMinuteOfDay: Int.random(in: 0..<1440))
    }

    var snapshot: SchedulesDirectGovernorState { state }

    // MARK: Admission

    /// Throws unless another request may be sent now; records it in the ledger.
    func admitRequest() throws {
        let now = clock.now()
        try checkOpen(now: now)
        prune(now: now)
        let lastHour = state.requestTimes.filter { now.timeIntervalSince($0) < 3600 }
        if lastHour.count >= limits.requestsPerHour, let oldest = lastHour.min() {
            throw SchedulesDirectError.budgetExceeded(resumesAt: oldest.addingTimeInterval(3600))
        }
        if state.requestTimes.count >= limits.requestsPerDay, let oldest = state.requestTimes.min() {
            throw SchedulesDirectError.budgetExceeded(resumesAt: oldest.addingTimeInterval(24 * 3600))
        }
        state.requestTimes.append(now)
        persist()
    }

    /// Whether anything may be sent at all (attention / not-before), without spending budget.
    func checkOpen(now: Date? = nil) throws {
        let now = now ?? clock.now()
        if let attention = state.attention { throw SchedulesDirectError.needsAttention(attention) }
        if let notBefore = state.notBefore, notBefore > now { throw SchedulesDirectError.notBefore(notBefore) }
    }

    func recordSuccess() {
        guard state.consecutiveBackPressure != 0 || state.notBefore != nil else { return }
        state.consecutiveBackPressure = 0
        state.notBefore = nil
        persist()
    }

    func recordAttention(_ attention: SchedulesDirectAttention) {
        state.attention = attention
        persist()
    }

    func clearAttention() {
        state.attention = nil
        persist()
    }

    /// Persists a "not before" time for exhausted back-pressure; returns it.
    @discardableResult
    func recordBackPressure(serverWait: TimeInterval?) -> Date {
        let now = clock.now()
        state.consecutiveBackPressure += 1
        let exponent = Double(min(state.consecutiveBackPressure - 1, 10))
        var wait = min(limits.firstBackoff * pow(2, exponent), limits.maximumBackoff)
        wait += wait * 0.1 * min(max(jitter(), 0), 1)
        if state.consecutiveBackPressure >= limits.circuitBreakerFailures {
            wait = max(wait, limits.maximumBackoff)
        }
        wait = max(wait, serverWait ?? 0)
        let date = now.addingTimeInterval(wait)
        state.notBefore = date
        persist()
        return date
    }

    // MARK: Sync schedule

    func beginSync() throws {
        let now = clock.now()
        try checkOpen(now: now)
        if let last = state.lastSyncAttempt, now.timeIntervalSince(last) < limits.minimumSyncInterval {
            throw SchedulesDirectError.syncTooSoon(last.addingTimeInterval(limits.minimumSyncInterval))
        }
        state.lastSyncAttempt = now
        persist()
    }

    func finishSync(stationCount: Int?) {
        if let stationCount {
            state.lastSyncSuccess = clock.now()
            state.lastSyncStationCount = stationCount
            state.lastSyncFailed = false
        } else {
            state.lastSyncFailed = true
        }
        persist()
    }

    /// Automatic syncs run at most daily, at a per-install minute of the day, and
    /// never on a cold start with a fresh cache.
    func automaticSyncDue() -> Bool {
        let now = clock.now()
        guard state.attention == nil, (state.notBefore ?? .distantPast) <= now else { return false }
        if let attempt = state.lastSyncAttempt, now.timeIntervalSince(attempt) < limits.minimumSyncInterval {
            return false
        }
        guard let last = state.lastSyncSuccess else { return true }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < limits.automaticSyncInterval { return false }
        let calendar = SchedulesDirectDates.utcCalendar
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // Due once the install's minute has passed, or when more than a day and a half stale.
        return minuteOfDay >= state.installMinuteOfDay || elapsed > limits.automaticSyncInterval * 1.5
    }

    /// Sign-out: attention and sync record go away; the ledger and not-before stay
    /// so signing out and in again cannot be used to dodge the limits.
    func resetForSignOut() {
        state.attention = nil
        state.lastSyncSuccess = nil
        state.lastSyncStationCount = nil
        state.lastSyncFailed = false
        persist()
    }

    private func prune(now: Date) {
        state.requestTimes.removeAll { now.timeIntervalSince($0) >= 24 * 3600 }
    }

    private func persist() {
        _ = try? storage.write(state, name: Self.stateFile, accountKey: accountKey)
    }
}

/// Token-bucket limiter with a concurrency cap. Cancellation-safe: waiters poll.
actor SchedulesDirectRequestLimiter {
    private let maxConcurrent: Int
    private let capacity: Double
    private let refillInterval: TimeInterval
    private let clock: SchedulesDirectClock
    private var tokens: Double
    private var lastRefill: Date
    private var inFlight = 0

    init(maxConcurrent: Int, burst: Int = 2, refillInterval: TimeInterval = 1, clock: SchedulesDirectClock) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.capacity = Double(max(1, burst))
        self.refillInterval = refillInterval
        self.clock = clock
        self.tokens = Double(max(1, burst))
        self.lastRefill = clock.now()
    }

    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            refill()
            if inFlight < maxConcurrent, tokens >= 1 {
                tokens -= 1
                inFlight += 1
                return
            }
            let wait = tokens >= 1 ? 0.05 : max(0.05, (1 - tokens) * refillInterval)
            try await clock.sleep(wait)
        }
    }

    func release() {
        inFlight = max(0, inFlight - 1)
    }

    private func refill() {
        let now = clock.now()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed / refillInterval)
        lastRefill = now
    }
}
