#if canImport(UIKit)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import Foundation

/// Prepares both theme variants of Live TV channel logos when a saved-guide refresh commits new inputs, so display only ever
/// looks them up (``ThemedChannelLogoArtworkCache``).
///
/// Input is the shared refresh's verified `committedInputs` per account, never `transferredAccountIDs`. For each such account the
/// committed saved lineup is read through the provider's already-saved catalogue (no fetch, no credentials), the affected channels
/// are resolved to the logo Live TV would draw (override, TMDB, Wikidata) and each distinct logo is restored from the prepared store
/// or downloaded once through the shared logo store and built. A refresh that committed nothing submits no work at all.
///
/// The first time an account is seen after launch nothing is reported as changed (the provider only baselines), so that run
/// restores every drawn logo that is already persisted, then downloads and prepares each one that was never prepared, once, in bounded
/// concurrent batches; the guide is told after each batch. A failed logo is not retried until the next launch or a changed refresh.
public actor LiveTVSyncArtworkWriter {
    /// What one run submitted. All zero when nothing was submitted.
    public struct Summary: Equatable, Sendable {
        public var built = 0
        public var restored = 0
        public var unavailable = 0
        public var submitted: Int { built + restored + unavailable }
        public init() {}
    }

    public struct Scope: Sendable {
        public let accountIDs: [String]
        public let resolver: LiveTVServerProviderResolver
        /// The profile's current Live TV sources, read when a run needs them.
        public let sources: @Sendable () -> [LiveTVServerSource]
        /// False once the profile, authorization or foreground state the run started under is gone.
        public let isCurrent: @MainActor @Sendable () -> Bool

        public init(
            accountIDs: [String], resolver: @escaping LiveTVServerProviderResolver,
            sources: @escaping @Sendable () -> [LiveTVServerSource], isCurrent: @escaping @MainActor @Sendable () -> Bool
        ) {
            self.accountIDs = accountIDs
            self.resolver = resolver
            self.sources = sources
            self.isCurrent = isCurrent
        }
    }

    private let cache: ThemedChannelLogoArtworkCache
    private let logoService: LiveTVChannelLogoService
    private let logoData: @Sendable (URL) async -> Data?
    private let stationMarks: LiveTVGuideStationMarkIndex
    private var bootstrapped = Set<String>()
    /// Logos whose download or decode failed this launch; not retried by a bootstrap, only by a changed refresh (Sync Now) or the next launch.
    private var failed = Set<ThemedChannelLogoIdentity>()

    public init(
        cache: ThemedChannelLogoArtworkCache = .shared, logoService: LiveTVChannelLogoService = .shared,
        logoData: @escaping @Sendable (URL) async -> Data? = { await LiveTVLogoImageStore.shared.data(for: $0) },
        stationMarks: LiveTVGuideStationMarkIndex = .shared
    ) {
        self.stationMarks = stationMarks
        self.cache = cache
        self.logoService = logoService
        self.logoData = logoData
    }

    /// Forgets which accounts were bootstrapped; called when the profile or authorization changes.
    public func reset() { bootstrapped.removeAll() }

    @discardableResult
    public func publish(_ result: LiveTVGuideRefreshResult, scope: Scope, retriesFailedLogos: Bool = false) async -> Summary {
        var summary = Summary()
        // A commit made under an older revision (the profile, accounts or authorization changed since) is dropped by the index.
        let revision = stationMarks.currentRevision
        for accountID in scope.accountIDs.sorted() {
            guard !Task.isCancelled, await scope.isCurrent() else { return summary }
            let committed = result.committedInputs[accountID].flatMap { $0.isEmpty ? nil : $0 }
            guard let context = await scope.resolver(accountID), context.kind == .iptv else { continue }
            let bootstrapKey = accountID + "\u{1F}" + context.authorizationID
            // A revoked index must be refilled even though this writer already bootstrapped the account.
            let needsBootstrap = !bootstrapped.contains(bootstrapKey) || !stationMarks.hasCommitted(accountID: accountID)
            // A delivered refresh (Sync Now or a scheduled run) retries the launch's failed logos once, even when it changed nothing.
            let retriesFailed = retriesFailedLogos && !failed.isEmpty && !needsBootstrap && committed == nil
            guard committed != nil || needsBootstrap || retriesFailed else { continue }
            guard let snapshot = try? await context.provider.cachedLiveTVCatalog() else { continue }
            let sources = scope.sources()
            let plans = LiveTVSyncArtworkPlanner.channelPlans(
                channels: snapshot.channels, sources: sources, accountID: accountID, kind: context.kind, logoService: logoService)
            var lineup: [LiveTVSyncArtworkCandidate] = []
            if needsBootstrap || committed != nil {
                // Every logo this lineup draws is kept by the caches from here on.
                lineup = LiveTVSyncArtworkPlanner.candidates(
                    channels: snapshot.channels, onlyChannelIDs: nil, sources: sources, accountID: accountID,
                    kind: context.kind, logoService: logoService, limit: Int.max)
                cache.require(lineup.map { .init(identity: Self.identity($0), variants: $0.variants) })
            }
            if needsBootstrap {
                let all = lineup
                // Persisted logos first (each probed once) and the marks committed, so the guide draws them at once; then the
                // never-prepared ones fill in.
                guard let unprepared = await restore(all, scope: scope, into: &summary) else { return summary }
                guard await commitStationMarks(plans, accountID: accountID, sources: sources, revision: revision, scope: scope) else {
                    return summary
                }
                guard await download(unprepared, skipFailed: true, scope: scope, into: &summary) else { return summary }
                bootstrapped.insert(bootstrapKey)
            }
            if let committed {
                let affected = LiveTVSyncArtworkPlanner.affectedChannelIDs(in: snapshot.channels, committed: committed)
                let changed = LiveTVSyncArtworkPlanner.candidates(
                    channels: snapshot.channels, onlyChannelIDs: affected, sources: sources, accountID: accountID,
                    kind: context.kind, logoService: logoService, limit: Int.max)
                guard await submit(changed, downloads: true, skipFailed: needsBootstrap, scope: scope, into: &summary) else { return summary }
                guard await commitStationMarks(plans, accountID: accountID, sources: sources, revision: revision, scope: scope) else {
                    return summary
                }
            } else if retriesFailed {
                let retry = LiveTVSyncArtworkPlanner.candidates(
                    channels: snapshot.channels, onlyChannelIDs: nil, sources: sources, accountID: accountID,
                    kind: context.kind, logoService: logoService, limit: Int.max
                ).filter { failed.contains(Self.identity($0)) }
                guard await submit(retry, downloads: true, scope: scope, into: &summary) else { return summary }
            }
        }
        return summary
    }

    /// Publishes the channel-keyed presentations the guide rows read. Returns false when the run was cancelled or its scope retired.
    private func commitStationMarks(
        _ plans: [LiveTVSyncArtworkChannelPlan], accountID: String, sources: [LiveTVServerSource], revision: Int, scope: Scope
    ) async -> Bool {
        guard !Task.isCancelled, await scope.isCurrent() else { return false }
        var presentations: [String: LiveTVGuideStationMarkPresentation] = [:]
        for plan in plans {
            presentations[plan.channelID] = LiveTVGuideStationMarkPresentation(
                identity: plan.candidate.map {
                    ThemedChannelLogoIdentity(url: $0.url, providerRequestsDarkBackground: $0.providerRequestsDarkBackground)
                },
                regionLabel: plan.regionLabel, sportsGlyphSymbol: plan.sportsGlyphSymbol)
        }
        let sourceIDs = Set(sources.filter { $0.accountID == accountID && $0.isEnabled }.map(\.id))
        stationMarks.commit(accountID: accountID, sourceIDs: sourceIDs, presentations: presentations, revision: revision)
        return true
    }

    /// Logos prepared at once: bounds concurrent downloads and decodes, and is the granularity at which rows learn of new artwork.
    static let batchSize = 24
    static let concurrentDownloads = 6

    /// Restores and then downloads, for a changed refresh's candidates.
    private func submit(
        _ candidates: [LiveTVSyncArtworkCandidate], downloads: Bool, skipFailed: Bool = false, scope: Scope,
        into summary: inout Summary
    ) async -> Bool {
        guard let unprepared = await restore(candidates, scope: scope, into: &summary) else { return false }
        return downloads ? await download(unprepared, skipFailed: skipFailed, scope: scope, into: &summary) : true
    }

    /// Restores every candidate that is already persisted (cheap, sequential; each is probed on disk once) and returns the ones that
    /// are not, or `nil` when the run was cancelled or its scope retired.
    private func restore(
        _ candidates: [LiveTVSyncArtworkCandidate], scope: Scope, into summary: inout Summary
    ) async -> [LiveTVSyncArtworkCandidate]? {
        let cache = cache
        var unprepared: [LiveTVSyncArtworkCandidate] = []
        var restoredAny = false
        for (index, candidate) in candidates.enumerated() {
            if index % 64 == 0 { guard !Task.isCancelled, await scope.isCurrent() else { return nil } }
            let identity = Self.identity(candidate)
            if cache.contains(identity) { continue }
            let restored = await Task.detached(priority: .utility) {
                cache.restoreFromStore(identity: identity, variants: candidate.variants)
            }.value
            if restored { summary.restored += 1; restoredAny = true } else { unprepared.append(candidate) }
        }
        if restoredAny { stationMarks.artworkDidChange() }
        return unprepared
    }

    /// Downloads and prepares `pending` in bounded concurrent batches, telling the guide after each batch. Returns false when the run
    /// was cancelled or its scope retired; nothing is published after that point.
    private func download(
        _ candidates: [LiveTVSyncArtworkCandidate], skipFailed: Bool, scope: Scope, into summary: inout Summary
    ) async -> Bool {
        let pending = skipFailed ? candidates.filter { !failed.contains(Self.identity($0)) } : candidates
        var start = 0
        while start < pending.count {
            guard !Task.isCancelled, await scope.isCurrent() else { return false }
            let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
            start += batch.count
            let outcomes = await prepare(batch)
            // Re-checked after the downloads: a retired scope must not publish.
            guard !Task.isCancelled, await scope.isCurrent() else { return false }
            for (candidate, outcome) in outcomes {
                switch outcome {
                case .built: summary.built += 1; failed.remove(Self.identity(candidate))
                case .restoredFromStore: summary.restored += 1
                case .unavailable: summary.unavailable += 1; failed.insert(Self.identity(candidate))
                }
            }
            stationMarks.artworkDidChange()
        }
        return true
    }

    private static func identity(_ candidate: LiveTVSyncArtworkCandidate) -> ThemedChannelLogoIdentity {
        ThemedChannelLogoIdentity(url: candidate.url, providerRequestsDarkBackground: candidate.providerRequestsDarkBackground)
    }

    /// Downloads (through the shared permanent store) and builds one batch with at most ``concurrentDownloads`` in flight.
    private func prepare(
        _ batch: [LiveTVSyncArtworkCandidate]
    ) async -> [(LiveTVSyncArtworkCandidate, ThemedChannelLogoArtworkCache.WriteOutcome)] {
        let cache = cache, logoData = logoData
        return await withTaskGroup(of: (LiveTVSyncArtworkCandidate, ThemedChannelLogoArtworkCache.WriteOutcome).self) { group in
            var results: [(LiveTVSyncArtworkCandidate, ThemedChannelLogoArtworkCache.WriteOutcome)] = []
            var next = 0
            func addNext() {
                guard next < batch.count else { return }
                let candidate = batch[next]
                next += 1
                group.addTask {
                    let identity = Self.identity(candidate)
                    let urls = candidate.variants.map { Array($0.prefix(5)) } ?? [candidate.url]
                    var data: [URL: Data] = [:]
                    for url in urls {
                        if Task.isCancelled { return (candidate, .unavailable) }
                        if let bytes = await logoData(url) { data[url] = bytes }
                    }
                    let fetched = data
                    return await Task.detached(priority: .utility) { () -> (LiveTVSyncArtworkCandidate, ThemedChannelLogoArtworkCache.WriteOutcome) in
                        if let variants = candidate.variants {
                            return (candidate, cache.storeNetworkLogo(identity: identity, variants: variants, knownUnprepared: true, variantData: { fetched[$0] }))
                        }
                        return (candidate, cache.store(identity: identity, knownUnprepared: true, logoData: { fetched[candidate.url] }))
                    }.value
                }
            }
            for _ in 0..<Self.concurrentDownloads { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
    }
}
#endif
