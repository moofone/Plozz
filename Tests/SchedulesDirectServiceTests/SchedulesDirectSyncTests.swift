import XCTest
import CoreModels
@testable import SchedulesDirectService

final class SchedulesDirectSyncTests: XCTestCase {
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func lineupJSON(stationCount: Int, modified: String = "2030-01-01T00:00:00Z") -> String {
        let stations = (1...stationCount).map { "{\"stationID\":\"S\($0)\",\"name\":\"Station \($0)\",\"callsign\":\"C\($0)\"}" }
        let map = (1...stationCount).map { "{\"stationID\":\"S\($0)\",\"channel\":\"\($0)\"}" }
        return "{\"map\":[\(map.joined(separator: ","))],\"stations\":[\(stations.joined(separator: ","))],\"metadata\":{\"lineup\":\"USA-OTA-60030\",\"modified\":\"\(modified)\"}}"
    }

    /// md5 response: every station, every day in the window, with the given hash.
    private func md5JSON(_ fixture: SchedulesDirectFixture, stations: Int, md5: String) -> String {
        let dates = SchedulesDirectSyncEngine.dates(now: fixture.time.now, limits: SchedulesDirectCacheLimits())
        let perDay = dates.map { "\"\($0)\":{\"code\":0,\"md5\":\"\(md5)\"}" }.joined(separator: ",")
        return "{" + (1...stations).map { "\"S\($0)\":{\(perDay)}" }.joined(separator: ",") + "}"
    }

    private func scheduleJSON(_ fixture: SchedulesDirectFixture, stations: Int, md5: String, only: Int? = nil) -> String {
        let dates = SchedulesDirectSyncEngine.dates(now: fixture.time.now, limits: SchedulesDirectCacheLimits())
        let items = (only.map { [$0] } ?? Array(1...stations)).flatMap { station in
            dates.enumerated().map { index, day -> String in
                let air = iso(fixture.time.now.addingTimeInterval(TimeInterval(index * 3600 - 3600)))
                return "{\"stationID\":\"S\(station)\",\"programs\":[{\"programID\":\"EP\(station)\(index)\",\"airDateTime\":\"\(air)\",\"duration\":3600,\"md5\":\"p\(md5)\"}],\"metadata\":{\"startDate\":\"\(day)\",\"md5\":\"\(md5)\"}}"
            }
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func programsJSON(stations: Int, dayCount: Int, md5: String) -> String {
        let items = (1...stations).flatMap { s in (0..<dayCount).map { "{\"programID\":\"EP\(s)\($0)\",\"titles\":[{\"title120\":\"Show \(s)\"}],\"md5\":\"p\(md5)\"}" } }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func prime(_ fixture: SchedulesDirectFixture, stations: Int, md5: String = "m1") {
        let days = SchedulesDirectSyncEngine.dates(now: fixture.time.now, limits: SchedulesDirectCacheLimits()).count
        fixture.http.replace("/lineups/USA-OTA-60030", lineupJSON(stationCount: stations))
        fixture.http.replace("/schedules/md5", md5JSON(fixture, stations: stations, md5: md5))
        fixture.http.replace("/schedules", scheduleJSON(fixture, stations: stations, md5: md5))
        fixture.http.replace("/programs", programsJSON(stations: stations, dayCount: days, md5: md5))
    }

    func testFirstSyncDownloadsEverythingThenAnUnchangedSyncDownloadsNothing() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 3)
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        let first = try await service.syncNow()
        XCTAssertEqual(first.stationCount, 3)
        XCTAssertEqual(first.lineupsDownloaded, 1)
        XCTAssertGreaterThan(first.schedulesDownloaded, 0)
        XCTAssertGreaterThan(first.programsDownloaded, 0)

        fixture.time.advance(2 * 3600)
        let schedulesBefore = fixture.http.count(suffix: "/20141201/schedules")
        let programsBefore = fixture.http.count(suffix: "/programs")
        let lineupBefore = fixture.http.count(suffix: "/lineups/USA-OTA-60030")
        fixture.http.replace("/schedules/md5", md5JSON(fixture, stations: 3, md5: "m1"))
        let second = try await service.syncNow()
        XCTAssertEqual(second.lineupsDownloaded, 0, "lineup unchanged: not downloaded again")
        XCTAssertEqual(second.schedulesDownloaded, 0)
        XCTAssertEqual(second.programsDownloaded, 0)
        XCTAssertEqual(fixture.http.count(suffix: "/20141201/schedules"), schedulesBefore)
        XCTAssertEqual(fixture.http.count(suffix: "/programs"), programsBefore)
        XCTAssertEqual(fixture.http.count(suffix: "/lineups/USA-OTA-60030"), lineupBefore)
    }

    func testOnlyChangedSchedulesAndProgramsAreDownloaded() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 2)
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        _ = try await service.syncNow()
        fixture.time.advance(2 * 3600)

        // Only station S2 changes (every day).
        let dates = SchedulesDirectSyncEngine.dates(now: fixture.time.now, limits: SchedulesDirectCacheLimits())
        let perDay1 = dates.map { "\"\($0)\":{\"code\":0,\"md5\":\"m1\"}" }.joined(separator: ",")
        let perDay2 = dates.map { "\"\($0)\":{\"code\":0,\"md5\":\"m2\"}" }.joined(separator: ",")
        fixture.http.replace("/schedules/md5", "{\"S1\":{\(perDay1)},\"S2\":{\(perDay2)}}")
        fixture.http.replace("/schedules", scheduleJSON(fixture, stations: 2, md5: "m2", only: 2))
        fixture.http.replace("/programs", programsJSON(stations: 2, dayCount: dates.count, md5: "m2"))
        let report = try await service.syncNow()
        let requested = try XCTUnwrap(fixture.http.bodies(suffix: "/20141201/schedules").last)
        let stationsAsked = (try JSONSerialization.jsonObject(with: requested) as? [[String: Any]])?.compactMap { $0["stationID"] as? String }
        XCTAssertEqual(stationsAsked, ["S2"], "only the changed station is requested")
        XCTAssertGreaterThan(report.schedulesDownloaded, 0)
        let programIDs = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fixture.http.bodies(suffix: "/programs").last)) as? [String])
        XCTAssertTrue(programIDs.allSatisfy { $0.hasPrefix("EP2") }, "programs only for the changed schedule")
    }

    func testChangedLineupModifiedRedownloadsLineupOnly() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 2)
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        _ = try await service.syncNow()
        fixture.time.advance(2 * 3600)
        fixture.http.replace("/status", fixture.statusJSON(lineups: "[{\"lineup\":\"USA-OTA-60030\",\"modified\":\"2031-02-02T00:00:00Z\"}]"))
        let report = try await service.syncNow()
        XCTAssertEqual(report.lineupsDownloaded, 1)
    }

    func testStationCapAndBatchSizeAreRespected() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        fixture.http.replace("/lineups/USA-OTA-60030", lineupJSON(stationCount: 520))
        fixture.http.replace("/schedules/md5", "{}")
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        let report = try await service.syncNow()
        XCTAssertEqual(report.stationCount, 500)
        XCTAssertTrue(report.stationsCapped)
        let body = try XCTUnwrap(fixture.http.bodies(suffix: "/schedules/md5").first)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [Any])?.count, 500)
        XCTAssertEqual(SchedulesDirectSyncEngine.chunks(Array(0..<5001)).map(\.count), [5000, 1])
    }

    func testSyncDatesCoverSixHoursBackToSeventyTwoHoursAhead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        let dates = SchedulesDirectSyncEngine.dates(now: now, limits: SchedulesDirectCacheLimits())
        XCTAssertEqual(dates, ["2027-01-15", "2027-01-16", "2027-01-17", "2027-01-18"])
    }

    func testCachePrunesOutsideTheWindowAndEnforcesTheSizeCap() throws {
        let fixture = SchedulesDirectFixture()
        let now = fixture.time.now
        var cache = SchedulesDirectGuideCache()
        func program(_ id: String, offset: TimeInterval) -> SchedulesDirectScheduleProgram {
            SchedulesDirectScheduleProgram(programID: id, airDateTime: iso(now.addingTimeInterval(offset)), duration: 1800, md5: "x")
        }
        cache.stationOrder = ["S1"]
        cache.days["S1"] = ["2027-01-15": SchedulesDirectCachedDay(md5: "a", programs: [
            program("OLD", offset: -8 * 3600), program("NOW", offset: 0), program("LATE", offset: 80 * 3600)
        ])]
        cache.programs = ["OLD": .init(programID: "OLD"), "NOW": .init(programID: "NOW"), "LATE": .init(programID: "LATE")]
        let store = SchedulesDirectGuideCacheStore(storage: fixture.storage, limits: SchedulesDirectCacheLimits())
        let saved = try store.save(cache, accountKey: "k", now: now)
        XCTAssertEqual(saved.days["S1"]?["2027-01-15"]?.programs.map(\.programID), ["NOW"])
        XCTAssertEqual(Set(saved.programs.keys), ["NOW"])

        var tiny = SchedulesDirectCacheLimits()
        tiny.maxBytes = 2_000
        var big = SchedulesDirectGuideCache()
        for index in 0..<50 {
            let id = "S\(index)"
            big.stationOrder.append(id)
            big.stations[id] = SchedulesDirectStation(stationID: id, name: String(repeating: "n", count: 40))
            big.days[id] = ["2027-01-15": SchedulesDirectCachedDay(md5: "a", programs: [program("P\(index)", offset: 0)])]
            big.programs["P\(index)"] = .init(programID: "P\(index)")
        }
        let capped = try SchedulesDirectGuideCacheStore(storage: fixture.storage, limits: tiny).save(big, accountKey: "k2", now: now)
        XCTAssertLessThan(capped.stationOrder.count, 50)
        let file = fixture.root.appendingPathComponent("k2/guide-cache.json")
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? .max
        XCTAssertLessThanOrEqual(size, tiny.maxBytes)
    }

    func testSignOutPurgesCacheTokenAndCredentialsButKeepsTheLedger() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 2)
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        _ = try await service.syncNow()
        let key = SchedulesDirectCredentials(username: "alice", password: "pw").accountKey
        let directory = fixture.root.appendingPathComponent(key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("guide-cache.json").path))
        try await service.signOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("guide-cache.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("account.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("governor.json").path))
        XCTAssertTrue(fixture.secure.values.isEmpty, "credentials and token removed from the Keychain store")
        let state = await service.state()
        XCTAssertFalse(state.isSignedIn)
    }

    func testExpiredAccountStopsAndPurgesTheCache() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 1)
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        _ = try await service.syncNow()
        fixture.time.advance(2 * 3600)
        fixture.http.replace("/status", "{\"code\":0,\"account\":{\"expires\":\"2020-01-01T00:00:00Z\"},\"lineups\":[]}")
        do { _ = try await service.syncNow(); XCTFail() }
        catch SchedulesDirectError.needsAttention(let attention) { XCTAssertEqual(attention.reason, .accountExpired) }
        let key = SchedulesDirectCredentials(username: "alice", password: "pw").accountKey
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(key).appendingPathComponent("guide-cache.json").path))
    }

    func testProfileDeletionPurgesCredentialsAndCache() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        prime(fixture, stations: 1)
        let service = fixture.service(namespace: "kid")
        try await service.signIn(username: "alice", password: "pw")
        _ = try await service.syncNow()
        await service.purgeProfile()
        let state = await service.state()
        XCTAssertFalse(state.isSignedIn)
        let key = SchedulesDirectCredentials(username: "alice", password: "pw").accountKey
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(key).appendingPathComponent("guide-cache.json").path))
    }

    func testSyncRefusesOffWiFiOnIOSPolicy() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        fixture.networkAllowed = false
        let restricted = fixture.service()
        let before = fixture.http.requestCount
        do { _ = try await restricted.syncNow(); XCTFail() } catch SchedulesDirectError.networkNotAllowed {}
        XCTAssertEqual(fixture.http.requestCount, before)
    }

    func testLineupLimitIsEnforcedBeforeAnyRequest() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        let service = fixture.service()
        try await service.signIn(username: "alice", password: "pw")
        let key = SchedulesDirectCredentials(username: "alice", password: "pw").accountKey
        let store = SchedulesDirectGuideCacheStore(storage: fixture.storage, limits: SchedulesDirectCacheLimits())
        store.saveAccount(SchedulesDirectAccountSnapshot(maxLineups: 4, lineups: (1...4).map { .init(lineup: "L\($0)") }), accountKey: key)
        let before = fixture.http.requestCount
        do { _ = try await service.addLineup("USA-OTA-60030"); XCTFail() } catch SchedulesDirectError.lineupLimitReached {}
        XCTAssertEqual(fixture.http.requestCount, before)
    }
}
