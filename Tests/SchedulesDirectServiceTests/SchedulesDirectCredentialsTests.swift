import XCTest
import CoreModels
@testable import SchedulesDirectService

final class SchedulesDirectCredentialsTests: XCTestCase {
    func testPasswordIsLowercaseSHA1Hex() {
        XCTAssertEqual(SchedulesDirectCredentials.sha1Hex("password"), "5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8")
        let hash = SchedulesDirectCredentials(username: " Alice ", password: "PassWord").passwordHash
        XCTAssertEqual(hash.count, 40)
        XCTAssertEqual(hash, hash.lowercased())
    }

    func testStoredCredentialsNeverContainPlaintextPassword() throws {
        let secure = SchedulesDirectMemorySecureStore()
        let store = SchedulesDirectCredentialStore(secureStore: secure, namespace: "p1")
        try store.save(SchedulesDirectCredentials(username: "alice", password: "hunter2-plain"))
        XCTAssertEqual(store.load()?.username, "alice")
        XCTAssertTrue(secure.values.values.allSatisfy { !$0.contains("hunter2-plain") })
        XCTAssertNil(SchedulesDirectCredentialStore(secureStore: secure, namespace: "p2").load(), "per profile")
        try store.clear()
        XCTAssertNil(store.load())
    }

    func testAccountKeyIsCaseInsensitiveAndHidesUsername() {
        let lower = SchedulesDirectCredentials(username: "alice", password: "a")
        let upper = SchedulesDirectCredentials(username: "ALICE", password: "b")
        XCTAssertEqual(lower.accountKey, upper.accountKey)
        XCTAssertFalse(lower.accountKey.contains("alice"))
        XCTAssertFalse("\(lower)".contains(lower.passwordHash))
    }
}
