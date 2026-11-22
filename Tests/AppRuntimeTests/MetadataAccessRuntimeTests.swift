import CoreModels
import MetadataKit
import XCTest
@testable import AppRuntime

final class MetadataAccessRuntimeTests: XCTestCase {
    private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
        var storage: [String: String] = [:]
        func setString(_ value: String, for key: String) throws { storage[key] = value }
        func string(for key: String) -> String? { storage[key] }
        func readString(for key: String) throws -> String? { storage[key] }
        func removeValue(for key: String) throws { storage[key] = nil }
    }

    func testTheUserKeyOverridesTheBundledAccessAndIsReadOnEveryCall() throws {
        let secure = MemorySecureStore()
        let keys = TMDBUserKeyStore(secureStore: secure)
        let base = MetadataProviderConfig(tmdb: .directToken("bundled"))

        XCTAssertEqual(MetadataAccessRuntime.currentConfig(base: base, keyStore: keys).tmdb, .directToken("bundled"))
        try keys.save("  user-key  ")
        XCTAssertEqual(MetadataAccessRuntime.currentConfig(base: base, keyStore: keys).tmdb, .userToken("user-key"))
        try keys.remove()
        XCTAssertEqual(MetadataAccessRuntime.currentConfig(base: base, keyStore: keys).tmdb, .directToken("bundled"))
    }
}
