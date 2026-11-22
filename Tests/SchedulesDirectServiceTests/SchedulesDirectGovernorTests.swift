import XCTest
@testable import SchedulesDirectService

final class SchedulesDirectGovernorTests: XCTestCase {
    private func governor(_ fixture: SchedulesDirectFixture) -> SchedulesDirectGovernor {
        SchedulesDirectGovernor(
            accountKey: "acct", storage: fixture.storage, clock: fixture.time.clock,
            limits: fixture.limits, jitter: { 0 }
        )
    }

    func testHourlyLedgerCapsRequestsAtTwenty() async throws {
        let fixture = SchedulesDirectFixture()
        let governor = governor(fixture)
        for _ in 0..<20 { try await governor.admitRequest() }
        do {
            try await governor.admitRequest()
            XCTFail("21st request in an hour must be refused")
        } catch SchedulesDirectError.budgetExceeded(let resumesAt) {
            XCTAssertEqual(resumesAt, fixture.time.now.addingTimeInterval(3600))
        }
        fixture.time.advance(3601)
        try await governor.admitRequest()
    }

    func testDailyLedgerCapsRequestsAtOneHundred() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.limits.requestsPerHour = 1000
        let tight = SchedulesDirectGovernor(
            accountKey: "busy", storage: fixture.storage, clock: fixture.time.clock, limits: fixture.limits, jitter: { 0 }
        )
        for _ in 0..<100 { try await tight.admitRequest() }
        do {
            try await tight.admitRequest()
            XCTFail("101st request in a day must be refused")
        } catch SchedulesDirectError.budgetExceeded {}
    }

    func testLedgerAndNotBeforeSurviveRelaunch() async throws {
        let fixture = SchedulesDirectFixture()
        let first = governor(fixture)
        for _ in 0..<20 { try await first.admitRequest() }
        let date = await first.recordBackPressure(serverWait: 7200)
        XCTAssertGreaterThanOrEqual(date.timeIntervalSince(fixture.time.now), 7200)
        let second = governor(fixture)  // relaunch: same files
        do { try await second.admitRequest(); XCTFail("not-before must persist") }
        catch SchedulesDirectError.notBefore(let persisted) { XCTAssertEqual(persisted, date) }
    }

    func testBackoffGrowsExponentiallyAndCircuitOpens() async {
        let fixture = SchedulesDirectFixture()
        let governor = governor(fixture)
        let first = await governor.recordBackPressure(serverWait: nil).timeIntervalSince(fixture.time.now)
        let second = await governor.recordBackPressure(serverWait: nil).timeIntervalSince(fixture.time.now)
        let third = await governor.recordBackPressure(serverWait: nil).timeIntervalSince(fixture.time.now)
        XCTAssertEqual(first, 900)
        XCTAssertEqual(second, 1800)
        XCTAssertEqual(third, fixture.limits.maximumBackoff, "third consecutive failure opens the circuit")
    }

    func testSyncIsLimitedToOncePerHour() async throws {
        let fixture = SchedulesDirectFixture()
        let governor = governor(fixture)
        try await governor.beginSync()
        do { try await governor.beginSync(); XCTFail("second sync within the hour") }
        catch SchedulesDirectError.syncTooSoon {}
        fixture.time.advance(3601)
        try await governor.beginSync()
    }

    func testAutomaticSyncIsDailyAndNotOnFreshColdStart() async throws {
        let fixture = SchedulesDirectFixture()
        let governor = governor(fixture)
        let neverSynced = await governor.automaticSyncDue()
        XCTAssertTrue(neverSynced)
        try await governor.beginSync()
        await governor.finishSync(stationCount: 3)
        fixture.time.advance(2 * 3600)
        let fresh = await governor.automaticSyncDue()
        XCTAssertFalse(fresh, "a fresh cache is not refreshed on cold start")
        fixture.time.advance(60 * 3600)
        let stale = await governor.automaticSyncDue()
        XCTAssertTrue(stale)
    }

    func testLimiterNeverRunsMoreThanTwoRequestsAtOnce() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        fixture.http.latency = 0.05
        fixture.http.stub("/probe", "{\"code\":0}")
        let session = SchedulesDirectSession(
            credentials: SchedulesDirectCredentials(username: "a", password: "b"), storage: fixture.storage,
            tokenStore: SchedulesDirectTokenStore(secureStore: fixture.secure), http: fixture.http,
            clock: fixture.time.clock,
            limits: fixture.limits, userAgent: "Plozz/9.9 (tvOS)", jitter: { 0 }
        )
        _ = try await session.token()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await session.send(.init(method: .get, path: "/probe")) } }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(fixture.http.peakConcurrency, 2)
        XCTAssertEqual(fixture.http.count(suffix: "/probe"), 6)
    }
}
