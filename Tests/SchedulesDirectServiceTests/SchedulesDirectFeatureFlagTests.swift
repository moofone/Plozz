import XCTest
import CoreModels
import CoreNetworking
@testable import SchedulesDirectService

final class SchedulesDirectFeatureFlagTests: XCTestCase {
    func testFlagOffMakesNoNetworkCallsAndTouchesNoState() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.flags = RuntimeFeatureFlags(enabled: [])
        let service = fixture.service()
        XCTAssertFalse(service.isEnabled)
        let state = await service.state()
        XCTAssertFalse(state.isEnabled)
        for operation in [
            { try await service.signIn(username: "alice", password: "pw") },
            { _ = try await service.syncNow() },
            { _ = try await service.syncIfDue() },
            { try await service.reconnect() },
            { _ = try await service.headends(country: "USA", postalCode: "60030") },
            { _ = try await service.addLineup("x") },
            { try await service.signOut() }
        ] as [@Sendable () async throws -> Void] {
            do { try await operation(); XCTFail("must refuse") } catch SchedulesDirectError.featureDisabled {}
        }
        XCTAssertEqual(fixture.http.requestCount, 0)
        XCTAssertTrue(fixture.secure.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testReleaseDefaultsKeepTheFlagOff() {
        XCTAssertFalse(RuntimeFeatureFlags.productionDefault.isEnabled(.schedulesDirect))
        #if !DEBUG
        XCTAssertFalse(RuntimeFeatureFlags.buildDefault.isEnabled(.schedulesDirect))
        #else
        XCTAssertTrue(RuntimeFeatureFlags.buildDefault.isEnabled(.schedulesDirect))
        #endif
    }

    func testCredentialsTokensAndHashesNeverAppearInLogs() async throws {
        let fixture = SchedulesDirectFixture()
        fixture.stubLogin()
        fixture.http.stub("/lineups", "{\"code\":4004,\"message\":\"locked\"}")
        let service = fixture.service()
        try await service.signIn(username: "alice-user", password: "plain-secret-pw")
        do { _ = try await service.refreshLineups() } catch {}
        let log = PlozzLog.recentLogText(limit: 500)
        XCTAssertFalse(log.contains("plain-secret-pw"))
        XCTAssertFalse(log.contains(SchedulesDirectCredentials.sha1Hex("plain-secret-pw")))
        XCTAssertFalse(log.contains("tok-1"))
        XCTAssertFalse(log.contains("alice-user"))
    }
}
