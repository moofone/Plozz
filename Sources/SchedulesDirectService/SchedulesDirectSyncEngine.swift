import Foundation

/// What one sync did, for Settings and tests.
public struct SchedulesDirectSyncReport: Equatable, Sendable {
    public var stationCount = 0
    public var stationsCapped = false
    public var lineupsDownloaded = 0
    public var schedulesDownloaded = 0
    public var programsDownloaded = 0
}

/// status → lineups (only when `modified` changed) → schedule md5s → changed
/// schedules only → programs whose md5 changed. Phase 1 syncs every station of the
/// user's lineups, capped; there is no IPTV matching yet and no artwork.
struct SchedulesDirectSyncEngine: Sendable {
    static let maxIDsPerRequest = 5000

    let session: SchedulesDirectSession
    let cacheStore: SchedulesDirectGuideCacheStore
    let accountKey: String
    let clock: SchedulesDirectClock

    func run() async throws -> (report: SchedulesDirectSyncReport, account: SchedulesDirectAccountSnapshot) {
        var report = SchedulesDirectSyncReport()
        let now = clock.now()
        var cache = cacheStore.load(accountKey: accountKey)

        let status = try await session.json(SchedulesDirectStatus.self, .init(method: .get, path: "/status"))
        if status.reportsOffline {
            let date = await session.governor.recordBackPressure(serverWait: 3600)
            throw SchedulesDirectError.notBefore(date)
        }
        if let expiry = status.accountExpiry, expiry < now {
            let attention = SchedulesDirectAttention(
                reason: .accountExpired, message: "The Schedules Direct membership has expired.", code: 4001
            )
            await session.governor.recordAttention(attention)
            cacheStore.purge(accountKey: accountKey)
            throw SchedulesDirectError.needsAttention(attention)
        }

        let activeLineups = (status.lineups ?? []).filter { $0.isDeleted != true }
        let activeIDs = Set(activeLineups.map(\.lineup))
        for stale in cache.lineupModified.keys where !activeIDs.contains(stale) {
            cache.lineupModified[stale] = nil
            cache.lineupStations[stale] = nil
        }
        for entry in activeLineups where entry.modified == nil || cache.lineupModified[entry.lineup] != entry.modified {
            let detail = try await session.json(
                SchedulesDirectLineupDetail.self,
                .init(method: .get, path: "/lineups/\(Self.pathComponent(entry.lineup))")
            )
            for station in detail.stations ?? [] { cache.stations[station.stationID] = station }
            let mapped = (detail.map ?? []).map(\.stationID)
            cache.lineupStations[entry.lineup] = Self.unique(mapped.isEmpty ? (detail.stations ?? []).map(\.stationID) : mapped)
            cache.lineupModified[entry.lineup] = entry.modified ?? detail.metadata?.modified ?? ""
            report.lineupsDownloaded += 1
        }

        var ordered: [String] = []
        var seen: Set<String> = []
        for entry in activeLineups {
            for id in cache.lineupStations[entry.lineup] ?? [] where seen.insert(id).inserted { ordered.append(id) }
        }
        let cap = cacheStore.limits.maxStations
        if ordered.count > cap {
            ordered = Array(ordered.prefix(cap))
            report.stationsCapped = true
        }
        cache.stationOrder = ordered
        let keep = Set(ordered)
        cache.days = cache.days.filter { keep.contains($0.key) }
        cache.stations = cache.stations.filter { keep.contains($0.key) }
        report.stationCount = ordered.count

        let dates = Self.dates(now: now, limits: cacheStore.limits)
        var changed: [String: [String]] = [:]
        if !ordered.isEmpty {
            for chunk in Self.chunks(ordered) {
                let body = try JSONEncoder().encode(chunk.map { SchedulesDirectScheduleRequest(stationID: $0, date: dates) })
                let hashes = try await session.json(
                    [String: [String: SchedulesDirectScheduleHash]].self,
                    .init(method: .post, path: "/schedules/md5", body: body)
                )
                for station in chunk {
                    for day in dates {
                        guard let hash = hashes[station]?[day], (hash.code ?? 0) == 0, let md5 = hash.md5 else { continue }
                        if cache.days[station]?[day]?.md5 != md5 { changed[station, default: []].append(day) }
                    }
                }
            }
        }

        var freshPrograms: Set<String> = []
        let changedStations = ordered.filter { changed[$0] != nil }
        for chunk in Self.chunks(changedStations) {
            let body = try JSONEncoder().encode(chunk.map { SchedulesDirectScheduleRequest(stationID: $0, date: changed[$0] ?? []) })
            let days = try await session.json([SchedulesDirectScheduleDay].self, .init(method: .post, path: "/schedules", body: body))
            for day in days {
                guard (day.code ?? 0) == 0, let station = day.stationID, keep.contains(station),
                      let start = day.metadata?.startDate ?? day.programs?.first.map({ String($0.airDateTime.prefix(10)) })
                else { continue }
                let programs = day.programs ?? []
                cache.days[station, default: [:]][start] = SchedulesDirectCachedDay(md5: day.metadata?.md5, programs: programs)
                report.schedulesDownloaded += 1
                for program in programs where cache.programs[program.programID]?.md5 != program.md5 {
                    freshPrograms.insert(program.programID)
                }
            }
        }

        for chunk in Self.chunks(freshPrograms.sorted()) {
            let body = try JSONEncoder().encode(chunk)
            let programs = try await session.json([SchedulesDirectProgram].self, .init(method: .post, path: "/programs", body: body))
            for program in programs where (program.code ?? 0) == 0 {
                cache.programs[program.programID] = program
                report.programsDownloaded += 1
            }
        }

        do { try cacheStore.save(cache, accountKey: accountKey, now: now) }
        catch { throw SchedulesDirectError.storage }

        var account = cacheStore.loadAccount(accountKey: accountKey) ?? SchedulesDirectAccountSnapshot()
        account.expires = status.accountExpiry
        account.maxLineups = status.account?.maxLineups ?? account.maxLineups
        cacheStore.saveAccount(account, accountKey: accountKey)
        return (report, account)
    }

    static func dates(now: Date, limits: SchedulesDirectCacheLimits) -> [String] {
        let calendar = SchedulesDirectDates.utcCalendar
        var day = calendar.startOfDay(for: now.addingTimeInterval(-limits.pastWindow))
        let last = calendar.startOfDay(for: now.addingTimeInterval(limits.futureWindow))
        var result: [String] = []
        while day <= last, result.count < 8 {
            result.append(SchedulesDirectDates.utcDay(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func chunks<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: maxIDsPerRequest).map {
            Array(values[$0..<min($0 + maxIDsPerRequest, values.count)])
        }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func pathComponent(_ lineup: String) -> String {
        lineup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lineup
    }
}
