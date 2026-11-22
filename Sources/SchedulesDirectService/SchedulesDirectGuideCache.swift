import Foundation

struct SchedulesDirectCachedDay: Codable, Equatable, Sendable {
    var md5: String?
    var programs: [SchedulesDirectScheduleProgram]
}

/// The on-device guide copy: `now − 6 h … now + 72 h`, capped in size.
struct SchedulesDirectGuideCache: Codable, Equatable, Sendable {
    var lineupModified: [String: String] = [:]
    var lineupStations: [String: [String]] = [:]
    var stationOrder: [String] = []
    var stations: [String: SchedulesDirectStation] = [:]
    /// stationID → UTC day → schedule.
    var days: [String: [String: SchedulesDirectCachedDay]] = [:]
    var programs: [String: SchedulesDirectProgram] = [:]
    var savedAt: Date?
}

/// What Settings shows without touching the network.
public struct SchedulesDirectAccountSnapshot: Codable, Equatable, Sendable {
    public var expires: Date?
    public var maxLineups: Int?
    public var lineups: [SchedulesDirectAccountLineup]
    public var changesRemaining: Int?

    public init(expires: Date? = nil, maxLineups: Int? = nil, lineups: [SchedulesDirectAccountLineup] = [], changesRemaining: Int? = nil) {
        self.expires = expires
        self.maxLineups = maxLineups
        self.lineups = lineups
        self.changesRemaining = changesRemaining
    }
}

struct SchedulesDirectCacheLimits: Sendable, Equatable {
    var pastWindow: TimeInterval = 6 * 3600
    var futureWindow: TimeInterval = 72 * 3600
    var maxBytes = 50 * 1024 * 1024
    var maxStations = 500
}

struct SchedulesDirectGuideCacheStore: Sendable {
    static let cacheFile = "guide-cache.json"
    static let accountFile = "account.json"

    let storage: SchedulesDirectStorage
    let limits: SchedulesDirectCacheLimits

    func load(accountKey: String) -> SchedulesDirectGuideCache {
        storage.read(SchedulesDirectGuideCache.self, name: Self.cacheFile, accountKey: accountKey)
            ?? SchedulesDirectGuideCache()
    }

    func loadAccount(accountKey: String) -> SchedulesDirectAccountSnapshot? {
        storage.read(SchedulesDirectAccountSnapshot.self, name: Self.accountFile, accountKey: accountKey)
    }

    func saveAccount(_ snapshot: SchedulesDirectAccountSnapshot, accountKey: String) {
        _ = try? storage.write(snapshot, name: Self.accountFile, accountKey: accountKey)
    }

    /// Prunes to the window, enforces the size cap, then writes. Returns the stored cache.
    @discardableResult
    func save(_ cache: SchedulesDirectGuideCache, accountKey: String, now: Date) throws -> SchedulesDirectGuideCache {
        var cache = prune(cache, now: now)
        cache.savedAt = now
        var data = try JSONEncoder.sdStorage.encode(cache)
        if data.count > limits.maxBytes {
            cache = enforceCap(cache)
            data = try JSONEncoder.sdStorage.encode(cache)
        }
        _ = try storage.write(cache, name: Self.cacheFile, accountKey: accountKey)
        return cache
    }

    /// Sign-out, account expiry and profile deletion: the guide copy goes away.
    func purge(accountKey: String) {
        storage.remove(name: Self.cacheFile, accountKey: accountKey)
        storage.remove(name: Self.accountFile, accountKey: accountKey)
    }

    func prune(_ cache: SchedulesDirectGuideCache, now: Date) -> SchedulesDirectGuideCache {
        var cache = cache
        let start = now.addingTimeInterval(-limits.pastWindow)
        let end = now.addingTimeInterval(limits.futureWindow)
        var kept: Set<String> = []
        for (station, days) in cache.days {
            var newDays: [String: SchedulesDirectCachedDay] = [:]
            for (day, entry) in days {
                let programs = entry.programs.filter { program in
                    guard let air = SchedulesDirectDates.parse(program.airDateTime) else { return false }
                    let finish = air.addingTimeInterval(TimeInterval(program.duration ?? 0))
                    return finish > start && air < end
                }
                if !programs.isEmpty || Self.dayOverlaps(day, start: start, end: end) {
                    newDays[day] = SchedulesDirectCachedDay(md5: entry.md5, programs: programs)
                    programs.forEach { kept.insert($0.programID) }
                }
            }
            cache.days[station] = newDays.isEmpty ? nil : newDays
        }
        cache.programs = cache.programs.filter { kept.contains($0.key) }
        return cache
    }

    private func enforceCap(_ input: SchedulesDirectGuideCache) -> SchedulesDirectGuideCache {
        var cache = input
        while !cache.stationOrder.isEmpty {
            guard let size = try? JSONEncoder.sdStorage.encode(cache).count, size > limits.maxBytes else { break }
            let drop = max(1, cache.stationOrder.count / 10)
            let dropped = cache.stationOrder.suffix(drop)
            cache.stationOrder.removeLast(min(drop, cache.stationOrder.count))
            for station in dropped {
                cache.days[station] = nil
                cache.stations[station] = nil
            }
            var referenced: Set<String> = []
            for days in cache.days.values { for day in days.values { day.programs.forEach { referenced.insert($0.programID) } } }
            cache.programs = cache.programs.filter { referenced.contains($0.key) }
        }
        return cache
    }

    private static func dayOverlaps(_ day: String, start: Date, end: Date) -> Bool {
        let calendar = SchedulesDirectDates.utcCalendar
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let dayStart = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return false }
        return dayStart.addingTimeInterval(86_400) > start && dayStart < end
    }
}
