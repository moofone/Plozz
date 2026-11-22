import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

public struct LiveTVGuideIndexState: Codable, Sendable {
    let generation: UUID
    let projection: String
    /// What the lineup alone contributed to `projection` (its guided channels and the language), saved with the index. A
    /// saved index whose lineup is unchanged but whose rules or parser version differ may still answer while it is indexed
    /// again; one saved without it (or for another lineup) may not.
    var lineupKey: String? = nil
    let digest: String
    let lowerBound: Date
    let upperBound: Date
    var expiresAt: Date
    var cacheMetadata: XMLTVGuideCacheMetadata? = nil
    /// Set on read (never saved) when the saved feed held no programmes at all: an empty feed is asked again after
    /// `XMLTVGuideCacheMetadata.emptyResultMaximumAge`. Nil for every feed that has programmes.
    var emptyFeedRetryAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case generation, projection, lineupKey, digest, lowerBound, upperBound, expiresAt, cacheMetadata
    }

    func contains(_ range: DateInterval) -> Bool {
        range.start >= lowerBound && range.end <= upperBound
    }

    /// Whether the saved listings may be read without asking the server again. Saved listings never lapse by age
    /// (fetch once, refetch only on a refresh the user asks for or the profile's automatic update); only an empty feed
    /// is asked again, and a window the listings no longer cover is a miss in `contains`.
    func isReusable(at now: Date) -> Bool {
        emptyFeedRetryAt.map { now < $0 } ?? true
    }

    /// When an automatic update next falls due. Shorter lifetimes stated by the server are
    /// honoured when listings are requested, not by updating in the background more often.
    func updateDue(interval: TimeInterval) -> Date {
        cacheMetadata?.checkedAt.addingTimeInterval(interval) ?? expiresAt
    }
}

enum LiveTVGuideIndexError: Error { case generationChanged }

/// One account/authorization's XMLTV documents. The cache owns synchronous SQLite
/// work; this actor stays available to cancel or invalidate an in-flight import.
public actor LiveTVGuideIndex {
    public typealias Download = @Sendable () async throws -> XMLTVDownloadedDocument
    public typealias Revalidate = @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    private let cache: LiveTVIndexedCache
    private let language: String?
    private let clock: @Sendable () -> Date
    private let updateInterval: @Sendable () -> TimeInterval?
    private var epoch = UUID()
    private var closed = false
    private var invalidating = false
    private var validated: [URL: UUID] = [:]
    private var requiresValidation = false
    private var cachedProjection: (revision: String, value: String)?
    private var flight: Flight?
    /// Committed guide changes not yet reported by `refreshSaved`, so an import done for a foreground request is not lost.
    private var unreportedChanges: [URL: SavedGuideSourceChange] = [:]
    private var transientTasks: [UUID: Task<[LiveTVPrototypeProgram], any Error>] = [:]
    private var admissionWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Guides whose saved index is being built again behind reads that were answered from the older one.
    private var reindexTasks: [URL: Task<Void, Never>] = [:]

    private enum Resolution: Sendable {
        case indexed(LiveTVGuideIndexState)
        /// A new index was committed; `change` says what differed from the previous commit.
        case imported(LiveTVGuideIndexState, change: SavedGuideSourceChange)
        case transient(Data)
    }

    private struct Flight {
        let id: UUID
        let url: URL
        let projection: String
        let epoch: UUID
        /// Started by a manual refresh: skipped the reuse check and went to the server.
        let forced: Bool
        let task: Task<Void, Never>
        let progress: GuideProgressRelay
        var cancelling = false
        var waiters: [UUID: CheckedContinuation<Resolution, any Error>] = [:]
    }

    public init(
        cache: LiveTVIndexedCache, preferredLanguage: String? = LanguageMatch.deviceLanguageCode,
        clock: @escaping @Sendable () -> Date = Date.init,
        updateInterval: @escaping @Sendable () -> TimeInterval? = { nil }
    ) {
        self.cache = cache
        language = preferredLanguage
        self.clock = clock
        self.updateInterval = updateInterval
    }

    #if DEBUG
    func waitForWaitersForTesting(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while (flight?.waiters.count ?? 0) < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
    func waitForReindexForTesting() async {
        while let task = reindexTasks.values.first { await task.value }
    }
    func waitForAdmissionForTesting() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while admissionWaiters.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    }
    #endif

    public func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, download: @escaping Download
    ) async throws -> [LiveTVPrototypeProgram] {
        try await programs(from: url, catalog: catalog, channels: channels, range: range) { _ in
            .document(try await download())
        }
    }

    /// `trustsGuideIDs`: the lineup and this guide come from the same provider account, so
    /// a channel's guide ID alone decides its listings.
    public func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, trustsGuideIDs: Bool = false, revalidate: @escaping Revalidate
    ) async throws -> [LiveTVPrototypeProgram] {
        try await programs(
            from: url, catalog: catalog, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs,
            forcing: false, revalidate: revalidate
        )
    }

    /// `forcing` skips the reuse check once, so a saved guide is asked of the server even when it is not due.
    /// It changes no stored setting and invalidates nothing.
    func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, trustsGuideIDs: Bool, forcing: Bool, answersFromOlderIndex: Bool = true,
        revalidate: @escaping Revalidate
    ) async throws -> [LiveTVPrototypeProgram] {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000, catalog.count <= 100_000 else { throw LiveTVCacheError.invalidRange }
        let projection = try Self.projection(catalog, language: language)
        let sourceID = Self.sourceID(url)
        while true {
            try Task.checkCancellation()
            guard !closed, !invalidating else { throw CancellationError() }
            let requestEpoch = epoch
            if answersFromOlderIndex, !forcing,
               let older = try await olderIndexAnswer(
                url: url, projection: projection, catalog: catalog, range: range, channels: channels,
                trustsGuideIDs: trustsGuideIDs, requestEpoch: requestEpoch
               ) {
                reindexInBackground(url: url, catalog: catalog, range: range, revalidate: revalidate)
                return older
            }
            let resolution = try await resolution(
                url: url, catalog: catalog, projection: projection, range: range, forcing: forcing,
                download: revalidate
            )
            try Task.checkCancellation()
            guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
            switch resolution {
            case .indexed(let state), .imported(let state, _):
                guard state.contains(range) else { continue }
                do {
                    let result = try await cache.indexedAccountPrograms(
                        sourceID: sourceID, sourceURL: url, generation: state.generation,
                        channels: channels, range: range, trustsGuideIDs: trustsGuideIDs
                    )
                    try Task.checkCancellation()
                    guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
                    return result
                } catch LiveTVGuideIndexError.generationChanged { continue }
            case .transient(let data):
                let language = language
                let transientID = UUID()
                let progress = ServerLiveTVGuideProgress.report
                let task = Task.detached(priority: .utility) {
                    try ServerLiveTVGuideProgress.$report.withValue(progress) {
                        let parser = LiveTVXMLTVParser(
                            provider: LiveTVGuideSource.provider(for: url), preferredLanguage: language
                        )
                        return try parser.accountPrograms(
                            data: data, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs
                        )
                    }
                }
                transientTasks[transientID] = task
                defer { transientTasks.removeValue(forKey: transientID) }
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
                return result
            }
        }
    }

    /// The listings of a saved index that was built for another lineup or under older matcher rules, when it still covers
    /// `range`. A launch never waits for the whole guide to be parsed again: the older index answers (its stations are the
    /// ones the old lineup kept) and `reindexInBackground` builds the current one. Nil when there is nothing usable to read.
    private func olderIndexAnswer(
        url: URL, projection: String, catalog: [LiveTVPrototypeChannel], range: DateInterval,
        channels: [LiveTVPrototypeChannel], trustsGuideIDs: Bool, requestEpoch: UUID
    ) async throws -> [LiveTVPrototypeProgram]? {
        guard !requiresValidation || validated[url] == epoch, !LiveTVGuideSnapshotWriter.stationDumpOwed() else { return nil }
        let sourceID = Self.sourceID(url)
        guard let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url),
              saved.projection != projection, saved.contains(range), saved.isReusable(at: clock()),
              let savedLineup = saved.lineupKey,
              savedLineup == (try Self.lineupKey(catalog, language: language)) else { return nil }
        do {
            let result = try await cache.indexedAccountPrograms(
                sourceID: sourceID, sourceURL: url, generation: saved.generation,
                channels: channels, range: range, trustsGuideIDs: trustsGuideIDs
            )
            try Task.checkCancellation()
            guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The older index cannot be read (replaced meanwhile, or an older layout): the normal path builds the current one.
            try Task.checkCancellation()
            return nil
        }
    }

    private func reindexInBackground(
        url: URL, catalog: [LiveTVPrototypeChannel], range: DateInterval, revalidate: @escaping Revalidate
    ) {
        guard reindexTasks[url] == nil, !closed, !invalidating else { return }
        reindexTasks[url] = Task(priority: .utility) {
            _ = try? await self.programs(
                from: url, catalog: catalog, channels: [], range: range, trustsGuideIDs: false, forcing: false,
                answersFromOlderIndex: false, revalidate: revalidate
            )
            self.reindexTasks[url] = nil
        }
    }

    /// Answers from a fresh saved index without starting or joining a download.
    /// `nil` means only a source that can load the guide can answer. The lineup is
    /// read only once a saved index could answer, so a miss costs no catalogue load.
    /// A supplied revision must change whenever the catalog's matching fields change.
    /// Without one, every lookup validates the full lineup.
    public func cachedPrograms(
        from url: URL, channels: [LiveTVPrototypeChannel], range: DateInterval,
        trustsGuideIDs: Bool = false, catalogRevision: String? = nil,
        catalog: @Sendable () async throws -> [LiveTVPrototypeChannel]
    ) async throws -> [LiveTVPrototypeProgram]? {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000 else { throw LiveTVCacheError.invalidRange }
        try Task.checkCancellation()
        guard !closed, !invalidating else { throw CancellationError() }
        // An explicit refresh must reach the provider before saved rows are trusted again.
        guard !requiresValidation || validated[url] == epoch else { return nil }
        // DEBUG station dump owed: the saved guide must not answer before the XMLTV has been read once.
        guard !LiveTVGuideSnapshotWriter.stationDumpOwed() else { return nil }
        let requestEpoch = epoch
        let sourceID = Self.sourceID(url)
        let now = clock()
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var result: [LiveTVPrototypeProgram]?
        if let state = saved, state.contains(range), state.isReusable(at: now) {
            let projection: String
            if let catalogRevision, let cachedProjection, cachedProjection.revision == catalogRevision {
                projection = cachedProjection.value
            } else {
                let lineup = try await catalog()
                guard lineup.count <= 100_000 else { throw LiveTVCacheError.invalidRange }
                projection = try Self.projection(lineup, language: language)
                try Task.checkCancellation()
                guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
                if let catalogRevision { cachedProjection = (catalogRevision, projection) }
            }
            if state.projection == projection {
                do {
                    result = try await cache.indexedAccountPrograms(
                        sourceID: sourceID, sourceURL: url, generation: state.generation,
                        channels: channels, range: range, trustsGuideIDs: trustsGuideIDs
                    )
                } catch LiveTVGuideIndexError.generationChanged { result = nil }
            }
        }
        // A miss is still an answer: it must not outlive cancellation or an invalidation.
        try Task.checkCancellation()
        guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
        return result
    }

    /// Brings a guide that is already saved for `url` up to date once it is older than the
    /// chosen update interval. Returns when it next falls due, or nil when automatic updates
    /// are off or nothing is saved; a guide is never downloaded here for the first time.
    public func updateSaved(
        from url: URL, catalog: @Sendable () async throws -> [LiveTVPrototypeChannel],
        revalidate: @escaping Revalidate
    ) async throws -> Date? {
        try await refreshSaved(from: url, catalog: catalog, trigger: .scheduled, revalidate: revalidate).nextDue
    }

    /// `updateSaved` for either trigger. The only difference is the due gate: `.manual` asks the server about a saved
    /// guide that is not due, or when automatic updates are off (`nextDue` is then nil). A guide that was never saved
    /// is still never downloaded here, and the guide's own refusal and backoff rules are not bypassed.
    public func refreshSaved(
        from url: URL, catalog: @Sendable () async throws -> [LiveTVPrototypeChannel],
        trigger: SavedGuideRefreshTrigger, revalidate: @escaping Revalidate
    ) async throws -> SavedGuideRefreshReport {
        let interval = updateInterval()
        guard !closed, trigger == .manual || interval != nil else {
            return SavedGuideRefreshReport(nextDue: nil, transferredGuides: 0, committedInputs: takeUnreportedChanges(url))
        }
        let sourceID = Self.sourceID(url)
        guard let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url) else {
            return SavedGuideRefreshReport(nextDue: nil, transferredGuides: 0, committedInputs: takeUnreportedChanges(url))
        }
        let now = clock()
        if trigger == .scheduled, let interval {
            let due = saved.updateDue(interval: interval)
            if now < due {
                return SavedGuideRefreshReport(nextDue: due, transferredGuides: 0, committedInputs: takeUnreportedChanges(url))
            }
        }
        _ = try await programs(
            from: url, catalog: try await catalog(), channels: [],
            range: DateInterval(start: now, duration: 6 * 3_600), trustsGuideIDs: false,
            forcing: true, revalidate: revalidate
        )
        var next: Date?
        if let interval {
            next = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)?.updateDue(interval: interval)
        }
        return SavedGuideRefreshReport(nextDue: next, transferredGuides: 1, committedInputs: takeUnreportedChanges(url))
    }

    /// Reported only on a successful return; a throw or cancellation leaves the change for the next refresh.
    private func takeUnreportedChanges(_ url: URL) -> SavedGuideCommittedInputs {
        guard let change = unreportedChanges.removeValue(forKey: url) else { return SavedGuideCommittedInputs() }
        return SavedGuideCommittedInputs(guideChanges: [change])
    }

    /// The debug snapshot's guide half for the saved guide at `url` (`LiveTVGuideSnapshot`); nil when none is saved.
    public func snapshotRecords(from url: URL, range: DateInterval) async throws -> [LiveTVGuideSnapshot.GuideRecord]? {
        guard !closed else { return nil }
        return try await cache.guideSnapshotRecords(sourceID: Self.sourceID(url), sourceURL: url, range: range)
    }

    public func invalidate() async {
        epoch = UUID()
        cachedProjection = nil
        // An invalidation follows a credential or authorization change: unreported changes belong to the old one.
        unreportedChanges.removeAll()
        requiresValidation = true
        validated.removeAll()
        invalidating = true
        let task = flight?.task
        let transient = Array(transientTasks.values)
        let reindexing = Array(reindexTasks.values)
        flight?.cancelling = true
        task?.cancel()
        for task in transient { task.cancel() }
        for task in reindexing { task.cancel() }
        await task?.value
        for task in transient { _ = await task.result }
        for task in reindexing { await task.value }
        invalidating = false
    }

    public func cancel() async {
        closed = true
        await invalidate()
    }

    private func resolution(
        url: URL, catalog: [LiveTVPrototypeChannel], projection: String,
        range: DateInterval, forcing: Bool, download: @escaping Revalidate
    ) async throws -> Resolution {
        while let existing = flight,
              existing.url != url || existing.projection != projection || existing.cancelling
                || (forcing && !existing.forced) {
            try await waitForAdmission()
            try Task.checkCancellation()
            guard !closed, !invalidating else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard !closed, !invalidating else { throw CancellationError() }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flight == nil {
                    let id = UUID()
                    let requestEpoch = epoch
                    let force = forcing || (requiresValidation && validated[url] != epoch)
                    let cache = cache
                    let language = language
                    let progress = GuideProgressRelay()
                    let task = Task(priority: .utility) {
                        let result: Result<Resolution, any Error>
                        do {
                            result = .success(try await ServerLiveTVGuideProgress.$report.withValue(progress.send) {
                                try await Self.resolve(
                                    url: url, catalog: catalog, projection: projection, range: range,
                                    cache: cache, language: language, force: force, now: self.clock(),
                                    download: download
                                )
                            })
                        } catch { result = .failure(error) }
                        self.finish(id: id, epoch: requestEpoch, result: result)
                    }
                    flight = Flight(
                        id: id, url: url, projection: projection, epoch: requestEpoch, forced: force, task: task,
                        progress: progress
                    )
                }
                flight?.waiters[waiterID] = continuation
                if let report = ServerLiveTVGuideProgress.report {
                    flight?.progress.add(waiterID, report)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = flight?.waiters.removeValue(forKey: id) else { return }
        flight?.progress.remove(id)
        continuation.resume(throwing: CancellationError())
        if flight?.waiters.isEmpty == true {
            flight?.cancelling = true
            flight?.task.cancel()
        }
    }

    private func waitForAdmission() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                admissionWaiters[id] = continuation
            }
        } onCancel: { Task { await self.cancelAdmission(id) } }
    }

    private func cancelAdmission(_ id: UUID) {
        admissionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, epoch requestEpoch: UUID, result: Result<Resolution, any Error>) {
        guard let current = flight, current.id == id else { return }
        flight = nil
        let admissions = admissionWaiters.values
        admissionWaiters.removeAll()
        for continuation in admissions { continuation.resume() }
        let admitted = !closed && !invalidating && epoch == requestEpoch && !current.cancelling
        if admitted, case .success = result { validated[current.url] = epoch }
        // Committed in the cache whoever is still waiting; reported once by `refreshSaved` unless invalidated first.
        if !closed, !invalidating, epoch == requestEpoch, case .success(.imported(_, let change)) = result {
            let stations = Set(unreportedChanges[current.url]?.changedStationIDs ?? []).union(change.changedStationIDs)
            unreportedChanges[current.url] = SavedGuideSourceChange(
                sourceKey: change.sourceKey, contentRevision: change.contentRevision, changedStationIDs: stations.sorted()
            )
        }
        for continuation in current.waiters.values {
            if admitted { continuation.resume(with: result) }
            else { continuation.resume(throwing: CancellationError()) }
        }
    }

    private static func resolve(
        url: URL, catalog: [LiveTVPrototypeChannel], projection: String, range: DateInterval,
        cache: LiveTVIndexedCache, language: String?, force: Bool, now: Date,
        download: Revalidate
    ) async throws -> Resolution {
        let sourceID = sourceID(url)
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var eligible = saved.flatMap { $0.projection == projection && $0.contains(range) ? $0 : nil }
        let dumpOwed = LiveTVGuideSnapshotWriter.stationDumpOwed()
        if !force, !dumpOwed, let eligible, eligible.isReusable(at: now) {
            PlozzLog.networking.info("IPTV_INDEX outcome=reused")
            return .indexed(eligible)
        }
        let reason = saved == nil ? "none" : saved?.projection != projection ? "lineupChanged"
            : saved?.contains(range) != true ? "window" : force ? "forced" : "emptyFeed"
        PlozzLog.networking.info("IPTV_INDEX outcome=download reason=\(reason)")
        // Only validate a representation that can answer this exact projection
        // and window. A 304 cannot supply stations/intervals we never indexed.
        let previous = dumpOwed ? nil : eligible?.cacheMetadata.flatMap { $0.hasValidator ? $0 : nil }
        var downloaded = try await download(previous)
        if case .notModified(let metadata) = downloaded {
            guard var validated = eligible, let previous, metadata.responseURL == previous.responseURL else {
                throw LiveTVSourceImportError.invalidResponse
            }
            if metadata.permitsPersistence {
                try Task.checkCancellation()
                validated.expiresAt = metadata.expiresAt
                validated.cacheMetadata = metadata
                try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, state: validated)
                PlozzLog.networking.info("IPTV_INDEX outcome=notModified")
                return .indexed(validated)
            }
            // A 304 no-store revokes the saved representation. Obtain a full
            // response instead of publishing success from a deleted index.
            let revoke = Task.detached(priority: .utility) {
                try await cache.removeDownloadedGuide(sourceID: sourceID, sourceURL: url)
            }
            try await revoke.value
            try Task.checkCancellation()
            eligible = nil
            downloaded = try await download(nil)
        }
        guard case .document(let response) = downloaded else {
            throw LiveTVSourceImportError.invalidResponse
        }
        ServerLiveTVGuideProgress.report?(.init(stage: .readingGuide))
        // A no-store replacement revokes persistence even when its XML is bad.
        if !response.permitsPersistence {
            let revoke = Task.detached(priority: .utility) {
                try await cache.removeDownloadedGuide(sourceID: sourceID, sourceURL: url)
            }
            try await revoke.value
            try Task.checkCancellation()
            return .transient(response.data)
        }
        try Task.checkCancellation()
        var hasher = SHA256()
        for offset in stride(from: 0, to: response.data.count, by: 65_536) {
            try Task.checkCancellation()
            hasher.update(data: response.data.subdata(in: offset..<min(response.data.count, offset + 65_536)))
        }
        let digest = LiveTVIdentityDigest.hex(hasher.finalize())
        if !dumpOwed, var eligible, eligible.digest == digest {
            eligible.expiresAt = response.expiresAt
            eligible.cacheMetadata = response.cacheMetadata
            try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, state: eligible)
            PlozzLog.networking.info("IPTV_INDEX outcome=unchanged")
            return .indexed(eligible)
        }
        let state = LiveTVGuideIndexState(
            generation: UUID(), projection: projection, lineupKey: try Self.lineupKey(catalog, language: language),
            digest: digest,
            lowerBound: range.start.addingTimeInterval(-86_400),
            upperBound: range.start.addingTimeInterval(7 * 86_400), expiresAt: response.expiresAt,
            cacheMetadata: response.cacheMetadata
        )
        let before = try await cache.savedGuideStations(sourceID: sourceID, sourceURL: url)
        let imported = try await cache.importGuide(
            data: response.data, sourceID: sourceID, channels: catalog,
            provider: LiveTVGuideSource.provider(for: url), now: range.start,
            sourceURL: url, preferredLanguage: language, indexState: state
        )
        PlozzLog.networking.info("IPTV_INDEX outcome=imported channels=\(catalog.count)")
        let previousStations = before.map(stationFingerprints) ?? [:]
        let currentStations = stationFingerprints(imported)
        let changed = Set(previousStations.keys).union(currentStations.keys)
            .filter { previousStations[$0] != currentStations[$0] }.sorted()
        return .imported(state, change: SavedGuideSourceChange(
            sourceKey: sourceID, contentRevision: digest, changedStationIDs: changed
        ))
    }

    /// A digest of each station's names and icon address, so a change is detected without keeping or logging the icon URL.
    private static func stationFingerprints(_ guide: LiveTVGuideImport) -> [String: String] {
        guide.guideChannels.reduce(into: [:]) { result, station in
            let icon = guide.guideIcons[station.key]?.absoluteString ?? ""
            result[station.key] = LiveTVIdentityDigest.hex(SHA256.hash(
                data: Data((station.value + [icon]).joined(separator: "\u{1F}").utf8)
            ))
        }
    }

    static func sourceID(_ url: URL) -> String {
        LiveTVIdentityDigest.hex(SHA256.hash(data: Data(url.absoluteString.utf8)))
    }

    /// The lineup's own part of the projection: its guided channels and the language, not the matcher rules or parser version.
    static func lineupKey(_ catalog: [LiveTVPrototypeChannel], language: String?) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try JSONEncoder().encode(["account-xmltv-lineup-v1", language]))
        for channel in catalog.filter({ $0.guideID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
            .sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            hasher.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        return LiveTVIdentityDigest.hex(hasher.finalize())
    }

    /// The saved projection names the matcher's rules (`LiveTVGuideStationIndex.rulesFingerprint`): the stations a saved guide
    /// retains are the ones those rules pick for the lineup, so a rules change re-indexes it once. Each guide address has its own
    /// saved index that retains by the lineup alone, so adding or removing another guide never makes this one stale.
    private static func projection(_ catalog: [LiveTVPrototypeChannel], language: String?) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try JSONEncoder().encode([
            "account-xmltv-stations-v3", String(LiveTVXMLTVParser.cacheVersion), LiveTVGuideStationIndex.rulesFingerprint, language
        ]))
        // Only a channel with a guide ID can be given listings. Leaving the others out keeps
        // a saved guide usable when a provider renames its event channels through the day.
        let guided = catalog.filter {
            $0.guideID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        for channel in guided.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            hasher.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        return LiveTVIdentityDigest.hex(hasher.finalize())
    }
}

/// Foreground consumers can join a quiet background import without downloading again.
private final class GuideProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ServerLiveTVGuideProgress?
    private var handlers: [UUID: ServerLiveTVGuideProgress.Handler] = [:]

    func add(_ id: UUID, _ handler: @escaping ServerLiveTVGuideProgress.Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
        // Consumers enqueue only; serialize replay with updates so old progress cannot win.
        if let latest { handler(latest) }
    }

    func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    func send(_ progress: ServerLiveTVGuideProgress) {
        lock.lock()
        defer { lock.unlock() }
        latest = progress
        for callback in handlers.values { callback(progress) }
    }
}
