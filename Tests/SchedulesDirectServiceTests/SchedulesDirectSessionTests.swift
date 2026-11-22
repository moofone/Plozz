import XCTest
import CoreModels
@testable import SchedulesDirectService

final class SchedulesDirectSessionTests: XCTestCase {
    private func signedIn(_ fixture: SchedulesDirectFixture) async throws -> SchedulesDirectService {
        fixture.stubLogin()
        let service = fixture.service()
        try await service.signIn(username: "Alice", password: "secret-pw")
        return service
    }

    func testEveryRequestCarriesTheCentralUserAgentAndTokenIsReused() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{\"code\":0,\"lineups\":[]}")
        _ = try await service.refreshLineups()
        _ = try await service.refreshLineups()
        XCTAssertEqual(fixture.http.count(suffix: "/token"), 1, "one token per account, reused")
        XCTAssertTrue(fixture.http.sent.allSatisfy { $0.headers["User-Agent"] == "Plozz/9.9 (tvOS)" })
        XCTAssertTrue(fixture.http.sent.filter { !$0.path.hasSuffix("/token") }.allSatisfy { $0.headers["token"] == "tok-1" })
        let body = try XCTUnwrap(fixture.http.bodies(suffix: "/token").first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["password"] as? String, SchedulesDirectCredentials.sha1Hex("secret-pw"))
        XCTAssertNil(json["newToken"])
    }

    func testExpiredTokenIsRenewedButOnlyAfterExpiry() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{\"code\":0,\"lineups\":[]}")
        fixture.time.advance(3600)
        _ = try await service.refreshLineups()
        XCTAssertEqual(fixture.http.count(suffix: "/token"), 1)
        fixture.time.advance(23 * 3600)  // inside the 5 minute renewal margin of the 24 h expiry
        _ = try await service.refreshLineups()
        XCTAssertEqual(fixture.http.count(suffix: "/token"), 2)
    }

    func testTokenIsSharedAcrossProfilesOfTheSameAccount() async throws {
        let fixture = SchedulesDirectFixture()
        _ = try await signedIn(fixture)
        let other = fixture.service(namespace: "kid")
        try await other.signIn(username: "alice", password: "secret-pw")
        XCTAssertEqual(fixture.http.count(suffix: "/token"), 1)
    }

    func testAccountErrorsStopPersistAndNeverRetryAfterRelaunch() async throws {
        for code in [4003, 4004, 4005, 4007, 4009, 4010, 4011, 1050] {
            let fixture = SchedulesDirectFixture()
            let service = try await signedIn(fixture)
            fixture.http.stub("/lineups", "{\"code\":\(code),\"message\":\"stop \(code)\"}")
            do { _ = try await service.refreshLineups(); XCTFail("\(code) should stop") }
            catch SchedulesDirectError.needsAttention(let attention) {
                XCTAssertEqual(attention.code, code)
                XCTAssertEqual(attention.message, "stop \(code)")
            }
            let before = fixture.http.requestCount
            fixture.relaunch()
            let relaunched = fixture.service()
            do { _ = try await relaunched.refreshLineups(); XCTFail() } catch SchedulesDirectError.needsAttention {}
            do { _ = try await relaunched.syncNow(); XCTFail() } catch SchedulesDirectError.needsAttention {}
            XCTAssertEqual(fixture.http.requestCount, before, "no request after relaunch for \(code)")
            let state = await relaunched.state()
            XCTAssertEqual(state.attention?.code, code)
            XCTAssertEqual(state.syncBlock, .needsAttention)
        }
    }

    func testHTMLBodyIsBackPressureNotRetriedForLong() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "<html>502 Bad Gateway</html>")
        var attempts = 0
        do { _ = try await service.refreshLineups() } catch SchedulesDirectError.notBefore { attempts = fixture.http.count(suffix: "/lineups") }
        XCTAssertEqual(attempts, 3, "max 3 attempts, then a persisted not-before")
        fixture.relaunch()
        let before = fixture.http.requestCount
        do { _ = try await fixture.service().refreshLineups(); XCTFail() } catch SchedulesDirectError.notBefore {}
        XCTAssertEqual(fixture.http.requestCount, before)
    }

    func testRetryAfterIsHonouredAndPersisted() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{}", status: 429, headers: ["Retry-After": "7200"])
        do { _ = try await service.refreshLineups(); XCTFail() }
        catch SchedulesDirectError.notBefore(let date) {
            XCTAssertGreaterThanOrEqual(date.timeIntervalSince(fixture.time.now), 7200)
        }
        XCTAssertEqual(fixture.http.count(suffix: "/lineups"), 1, "a long Retry-After is not retried inside the sync")
        fixture.time.advance(7201)
        fixture.http.replace("/lineups", "{\"code\":0,\"lineups\":[]}")
        _ = try await service.refreshLineups()
    }

    func testShortRetryAfterIsRetriedWithinTheAttemptLimit() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{}", status: 503, headers: ["Retry-After": "5"])
        fixture.http.stub("/lineups", "{\"code\":0,\"lineups\":[]}")
        _ = try await service.refreshLineups()
        XCTAssertEqual(fixture.http.count(suffix: "/lineups"), 2)
        XCTAssertTrue(fixture.time.sleeps.contains { $0 >= 5 })
    }

    func testScheduleQueuedAndServerBusyCodesBackOff() async throws {
        for (code, body) in [(7100, "{\"code\":7100,\"message\":\"queued\",\"retryTime\":3000}"), (6001, "{\"code\":6001,\"message\":\"busy\"}"), (3001, "{\"code\":3001}")] {
            let fixture = SchedulesDirectFixture()
            let service = try await signedIn(fixture)
            fixture.http.stub("/lineups", body)
            do { _ = try await service.refreshLineups(); XCTFail("\(code)") }
            catch SchedulesDirectError.notBefore(let date) {
                let wait = date.timeIntervalSince(fixture.time.now)
                XCTAssertGreaterThanOrEqual(wait, code == 7100 ? 3000 : 800, "\(code)")
            }
            XCTAssertEqual(fixture.http.count(suffix: "/lineups"), code == 7100 ? 1 : 3, "\(code)")
        }
    }

    func testExpiredTokenCodeRefreshesOnceThenStops() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{\"code\":4006,\"message\":\"expired\"}")
        fixture.http.stub("/lineups", "{\"code\":0,\"lineups\":[]}")
        _ = try await service.refreshLineups()
        XCTAssertEqual(fixture.http.count(suffix: "/token"), 2)
    }

    func testInvalidLoginIsNotSaved() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.http.stub("/token", "{\"code\":4003,\"message\":\"Invalid user\"}")
        let service = fixture.service()
        do { try await service.signIn(username: "alice", password: "wrong"); XCTFail() } catch SchedulesDirectError.needsAttention {}
        XCTAssertTrue(fixture.secure.values.isEmpty)
        let state = await service.state()
        XCTAssertFalse(state.isSignedIn)
    }

    func testReconnectAsksForANewTokenAndClearsTheStop() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{\"code\":4009,\"message\":\"too many\"}")
        do { _ = try await service.refreshLineups() } catch {}
        try await service.reconnect()
        let body = try XCTUnwrap(fixture.http.bodies(suffix: "/token").last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["newToken"] as? Bool, true)
        let state = await service.state()
        XCTAssertNil(state.attention)
    }

    func testRequestLedgerNeverExceedsTwentyPerHourAcrossCalls() async throws {
        let fixture = SchedulesDirectFixture()
        let service = try await signedIn(fixture)
        fixture.http.stub("/lineups", "{\"code\":0,\"lineups\":[]}")
        var refused = false
        for _ in 0..<40 {
            do { _ = try await service.refreshLineups() } catch SchedulesDirectError.budgetExceeded { refused = true; break }
        }
        XCTAssertTrue(refused)
        XCTAssertLessThanOrEqual(fixture.http.requestCount, 20)
    }
}
