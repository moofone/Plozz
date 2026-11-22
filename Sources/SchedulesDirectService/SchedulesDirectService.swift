import Foundation
import CoreModels
import CoreNetworking
#if canImport(Network)
import Network
#endif

/// Everything Settings needs to draw the Schedules Direct screen.
public struct SchedulesDirectState: Equatable, Sendable {
    public enum SyncBlock: Equatable, Sendable {
        case notBefore(Date)
        case budgetExceeded(Date)
        case syncTooSoon(Date)
        case needsAttention
        case networkNotAllowed
    }

    public var isEnabled: Bool
    public var username: String?
    public var attention: SchedulesDirectAttention?
    public var account: SchedulesDirectAccountSnapshot?
    public var lastSyncSuccess: Date?
    public var lastSyncStationCount: Int?
    public var lastSyncFailed: Bool
    public var syncBlock: SyncBlock?

    public init(
        isEnabled: Bool, username: String? = nil, attention: SchedulesDirectAttention? = nil,
        account: SchedulesDirectAccountSnapshot? = nil, lastSyncSuccess: Date? = nil,
        lastSyncStationCount: Int? = nil, lastSyncFailed: Bool = false, syncBlock: SyncBlock? = nil
    ) {
        self.isEnabled = isEnabled
        self.username = username
        self.attention = attention
        self.account = account
        self.lastSyncSuccess = lastSyncSuccess
        self.lastSyncStationCount = lastSyncStationCount
        self.lastSyncFailed = lastSyncFailed
        self.syncBlock = syncBlock
    }

    public var isSignedIn: Bool { username != nil }

    static let disabled = SchedulesDirectState(isEnabled: false, lastSyncFailed: false)
}

/// Facade over the Schedules Direct account: sign-in, lineups and sync, for one
/// profile namespace. Mirrors `SeerService`: shared logic here, thin app shells.
///
/// Gated by `RuntimeFeatureFlag.schedulesDirect`: with the flag off every call
/// returns or throws ``SchedulesDirectError/featureDisabled`` before any network,
/// Keychain or file access.
public final class SchedulesDirectService: @unchecked Sendable {
    private let namespace: String?
    private let featureFlags: RuntimeFeatureFlags
    private let storage: SchedulesDirectStorage
    private let credentialStore: SchedulesDirectCredentialStore
    private let tokenStore: SchedulesDirectTokenStore
    private let http: any HTTPClient
    private let clock: SchedulesDirectClock
    private let limits: SchedulesDirectLimits
    private let userAgent: String
    private let jitter: @Sendable () -> Double
    private let isNetworkAllowed: @Sendable () async -> Bool
    private let cacheStore: SchedulesDirectGuideCacheStore
    static let maxLineups = 4

    public init(
        namespace: String?,
        secureStore: any SecureStoring,
        http: any HTTPClient = URLSessionHTTPClient(),
        storage: SchedulesDirectStorage = .applicationSupport(),
        featureFlags: RuntimeFeatureFlags = .buildDefault,
        clock: SchedulesDirectClock = .system,
        limits: SchedulesDirectLimits = SchedulesDirectLimits(),
        userAgent: String = SchedulesDirectEnvironment.userAgent(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        isNetworkAllowed: @escaping @Sendable () async -> Bool = SchedulesDirectNetworkPolicy.allowsSync
    ) {
        self.namespace = namespace
        self.featureFlags = featureFlags
        self.storage = storage
        self.credentialStore = SchedulesDirectCredentialStore(secureStore: secureStore, namespace: namespace)
        self.tokenStore = SchedulesDirectTokenStore(secureStore: secureStore)
        self.http = http
        self.clock = clock
        self.limits = limits
        self.userAgent = userAgent
        self.jitter = jitter
        self.isNetworkAllowed = isNetworkAllowed
        self.cacheStore = SchedulesDirectGuideCacheStore(storage: storage, limits: SchedulesDirectCacheLimits())
    }

    public var isEnabled: Bool { featureFlags.isEnabled(.schedulesDirect) }

    // MARK: State

    public func state() async -> SchedulesDirectState {
        guard isEnabled else { return .disabled }
        guard let credentials = credentialStore.load() else {
            return SchedulesDirectState(isEnabled: true, lastSyncFailed: false)
        }
        let snapshot = await session(for: credentials).governor.snapshot
        let now = clock.now()
        var block: SchedulesDirectState.SyncBlock?
        if snapshot.attention != nil {
            block = .needsAttention
        } else if let notBefore = snapshot.notBefore, notBefore > now {
            block = .notBefore(notBefore)
        } else if let last = snapshot.lastSyncAttempt, now.timeIntervalSince(last) < limits.minimumSyncInterval {
            block = .syncTooSoon(last.addingTimeInterval(limits.minimumSyncInterval))
        } else if snapshot.requestTimes.filter({ now.timeIntervalSince($0) < 3600 }).count >= limits.requestsPerHour {
            block = .budgetExceeded(now.addingTimeInterval(3600))
        }
        return SchedulesDirectState(
            isEnabled: true, username: credentials.username, attention: snapshot.attention,
            account: cacheStore.loadAccount(accountKey: credentials.accountKey),
            lastSyncSuccess: snapshot.lastSyncSuccess, lastSyncStationCount: snapshot.lastSyncStationCount,
            lastSyncFailed: snapshot.lastSyncFailed, syncBlock: block
        )
    }

    // MARK: Account

    /// Validates the login with one token request and one status call, then saves
    /// only the username and password hash. Nothing is stored when validation fails.
    public func signIn(username: String, password: String) async throws {
        try requireEnabled()
        let credentials = SchedulesDirectCredentials(username: username, password: password)
        guard !credentials.username.isEmpty, !password.isEmpty else {
            throw SchedulesDirectError.needsAttention(.init(reason: .invalidCredentials, message: "Enter a username and password."))
        }
        if let previous = credentialStore.load(), previous.accountKey != credentials.accountKey {
            purgeAccount(previous)
        }
        let session = await session(for: credentials)
        await session.update(credentials: credentials)
        await session.governor.clearAttention()
        _ = try await session.token()
        let status = try await session.json(SchedulesDirectStatus.self, .init(method: .get, path: "/status"))
        var account = cacheStore.loadAccount(accountKey: credentials.accountKey) ?? SchedulesDirectAccountSnapshot()
        account.expires = status.accountExpiry
        account.maxLineups = status.account?.maxLineups
        cacheStore.saveAccount(account, accountKey: credentials.accountKey)
        do { try credentialStore.save(credentials) } catch { throw SchedulesDirectError.storage }
    }

    /// Removes the credentials, the token and the cached guide. The request ledger
    /// stays so signing out and in again cannot dodge the limits.
    public func signOut() async throws {
        try requireEnabled()
        guard let credentials = credentialStore.load() else { return }
        try? credentialStore.clear()
        purgeAccount(credentials)
        await session(for: credentials).governor.resetForSignOut()
    }

    /// Explicit "Reconnect": clears the stop and asks for a brand-new token.
    public func reconnect() async throws {
        try requireEnabled()
        let credentials = try requireCredentials()
        let session = await session(for: credentials)
        await session.governor.clearAttention()
        _ = try await session.token(forceNew: true)
    }

    /// Profile deletion: drops this profile's credentials and, because the cache
    /// belongs to the account, the cached guide as well.
    public func purgeProfile() async {
        guard isEnabled, let credentials = credentialStore.load() else { return }
        try? credentialStore.clear()
        purgeAccount(credentials)
    }

    // MARK: Lineups

    public func headends(country: String, postalCode: String) async throws -> [SchedulesDirectHeadend] {
        try requireEnabled()
        let session = try await activeSession()
        return try await session.json(
            [SchedulesDirectHeadend].self,
            .init(method: .get, path: "/headends", query: [
                URLQueryItem(name: "country", value: country.uppercased()),
                URLQueryItem(name: "postalcode", value: postalCode.replacingOccurrences(of: " ", with: "").uppercased())
            ])
        )
    }

    public func refreshLineups() async throws -> SchedulesDirectAccountSnapshot {
        try requireEnabled()
        let credentials = try requireCredentials()
        let session = await session(for: credentials)
        let response = try await session.json(SchedulesDirectAccountLineupsResponse.self, .init(method: .get, path: "/lineups"))
        var account = cacheStore.loadAccount(accountKey: credentials.accountKey) ?? SchedulesDirectAccountSnapshot()
        account.lineups = (response.lineups ?? []).filter { $0.isDeleted != true }
        cacheStore.saveAccount(account, accountKey: credentials.accountKey)
        return account
    }

    @discardableResult
    public func addLineup(_ lineup: String) async throws -> SchedulesDirectAccountSnapshot {
        try requireEnabled()
        let credentials = try requireCredentials()
        if let known = cacheStore.loadAccount(accountKey: credentials.accountKey),
           known.lineups.count >= min(known.maxLineups ?? Self.maxLineups, Self.maxLineups) {
            throw SchedulesDirectError.lineupLimitReached(message: "The account already has the maximum number of lineups.")
        }
        let session = await session(for: credentials)
        let response = try await session.json(
            SchedulesDirectLineupChangeResponse.self,
            .init(method: .put, path: "/lineups/\(SchedulesDirectSyncEngine.pathComponent(lineup))")
        )
        var account = try await refreshLineups()
        account.changesRemaining = response.changesRemaining
        cacheStore.saveAccount(account, accountKey: credentials.accountKey)
        return account
    }

    @discardableResult
    public func removeLineup(_ lineup: String) async throws -> SchedulesDirectAccountSnapshot {
        try requireEnabled()
        let credentials = try requireCredentials()
        let session = await session(for: credentials)
        let response = try await session.json(
            SchedulesDirectLineupChangeResponse.self,
            .init(method: .delete, path: "/lineups/\(SchedulesDirectSyncEngine.pathComponent(lineup))")
        )
        var account = cacheStore.loadAccount(accountKey: credentials.accountKey) ?? SchedulesDirectAccountSnapshot()
        account.lineups.removeAll { $0.lineup == lineup }
        account.changesRemaining = response.changesRemaining ?? account.changesRemaining
        cacheStore.saveAccount(account, accountKey: credentials.accountKey)
        return account
    }

    // MARK: Sync

    /// "Sync Now". Respects the governor: refuses (with the reason) when a stop,
    /// back-off, the hourly sync interval or the request budget forbids it.
    @discardableResult
    public func syncNow() async throws -> SchedulesDirectSyncReport {
        try requireEnabled()
        let credentials = try requireCredentials()
        guard await isNetworkAllowed() else { throw SchedulesDirectError.networkNotAllowed }
        let session = await session(for: credentials)
        try await session.governor.beginSync()
        let engine = SchedulesDirectSyncEngine(
            session: session, cacheStore: cacheStore, accountKey: credentials.accountKey, clock: clock
        )
        do {
            let (report, _) = try await engine.run()
            await session.governor.finishSync(stationCount: report.stationCount)
            return report
        } catch {
            await session.governor.finishSync(stationCount: nil)
            throw error
        }
    }

    /// The scheduled path: syncs only when ``SchedulesDirectGovernor/automaticSyncDue()``
    /// says so (daily, per-install minute, never on a cold start with a fresh cache).
    @discardableResult
    public func syncIfDue() async throws -> SchedulesDirectSyncReport? {
        try requireEnabled()
        let credentials = try requireCredentials()
        guard await session(for: credentials).governor.automaticSyncDue() else { return nil }
        return try await syncNow()
    }

    // MARK: Plumbing

    private func requireEnabled() throws {
        guard isEnabled else { throw SchedulesDirectError.featureDisabled }
    }

    private func requireCredentials() throws -> SchedulesDirectCredentials {
        guard let credentials = credentialStore.load() else { throw SchedulesDirectError.notSignedIn }
        return credentials
    }

    private func activeSession() async throws -> SchedulesDirectSession {
        await session(for: try requireCredentials())
    }

    private func session(for credentials: SchedulesDirectCredentials) async -> SchedulesDirectSession {
        let session = SchedulesDirectAccounts.shared.session(
            root: storage.root, credentials: credentials
        ) {
            SchedulesDirectSession(
                credentials: credentials, storage: self.storage, tokenStore: self.tokenStore, http: self.http,
                clock: self.clock, limits: self.limits, userAgent: self.userAgent, jitter: self.jitter
            )
        }
        await session.update(credentials: credentials)
        return session
    }

    private func purgeAccount(_ credentials: SchedulesDirectCredentials) {
        cacheStore.purge(accountKey: credentials.accountKey)
        try? tokenStore.clear(accountKey: credentials.accountKey)
    }
}

/// One session (token, governor, limiter) per account per process, shared by every
/// profile that uses the account.
final class SchedulesDirectAccounts: @unchecked Sendable {
    static let shared = SchedulesDirectAccounts()
    private let lock = NSLock()
    private var sessions: [String: SchedulesDirectSession] = [:]

    func session(
        root: URL, credentials: SchedulesDirectCredentials, make: () -> SchedulesDirectSession
    ) -> SchedulesDirectSession {
        let key = root.path + "|" + credentials.accountKey
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[key] { return existing }
        let created = make()
        sessions[key] = created
        return created
    }

    /// Simulates a relaunch in tests: the persisted governor state is reloaded from disk.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll()
    }
}

/// iOS syncs only on Wi-Fi or Ethernet; tvOS is always allowed.
public enum SchedulesDirectNetworkPolicy {
    public static func allowsSync() async -> Bool {
        #if os(iOS) && canImport(Network)
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let gate = OneShot(continuation)
            monitor.pathUpdateHandler = { path in
                let allowed = path.status == .satisfied
                    && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                    && !path.isExpensive
                monitor.cancel()
                gate.resume(allowed)
            }
            monitor.start(queue: DispatchQueue(label: "com.plozz.schedulesdirect.path"))
        }
        #else
        return true
        #endif
    }

    #if os(iOS) && canImport(Network)
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
    #endif
}
