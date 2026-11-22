import Foundation
import CoreModels
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A Schedules Direct login. The password is stored only as the lowercase SHA1
/// hex digest the API requires; the plaintext never leaves ``init(username:password:)``.
public struct SchedulesDirectCredentials: Codable, Equatable, Sendable, CustomStringConvertible {
    public let username: String
    public let passwordHash: String

    public init(username: String, password: String) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passwordHash = Self.sha1Hex(password)
    }

    public init(username: String, passwordHash: String) {
        self.username = username
        self.passwordHash = passwordHash
    }

    /// Stable identifier for the account (not reversible to the username). The
    /// token, the request ledger and the guide cache are shared by every profile
    /// that signs in with the same account.
    public var accountKey: String {
        String(Self.sha1Hex(username.lowercased()).prefix(20))
    }

    public var description: String { "SchedulesDirectCredentials(redacted)" }

    public static func sha1Hex(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-profile credential storage in the Keychain (`SecureStoring`; production
/// uses `KeychainStore`, which writes `…AfterFirstUnlockThisDeviceOnly`).
public struct SchedulesDirectCredentialStore: Sendable {
    private let secureStore: any SecureStoring
    private let namespace: String?

    public init(secureStore: any SecureStoring, namespace: String?) {
        self.secureStore = secureStore
        self.namespace = namespace
    }

    private var key: String {
        if let namespace, !namespace.isEmpty { return "schedulesdirect.credentials.\(namespace)" }
        return "schedulesdirect.credentials"
    }

    public func load() -> SchedulesDirectCredentials? {
        guard let json = secureStore.string(for: key) else { return nil }
        return try? JSONDecoder().decode(SchedulesDirectCredentials.self, from: Data(json.utf8))
    }

    public func save(_ credentials: SchedulesDirectCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try secureStore.setString(String(decoding: data, as: UTF8.self), for: key)
    }

    public func clear() throws {
        try secureStore.removeValue(for: key)
    }
}

struct SchedulesDirectStoredToken: Codable, Equatable, Sendable {
    let token: String
    let expires: Date
}

/// The one token per account, shared by every profile using that account.
struct SchedulesDirectTokenStore: Sendable {
    let secureStore: any SecureStoring

    private func key(_ accountKey: String) -> String { "schedulesdirect.token.\(accountKey)" }

    func load(accountKey: String) -> SchedulesDirectStoredToken? {
        guard let json = secureStore.string(for: key(accountKey)) else { return nil }
        return try? JSONDecoder().decode(SchedulesDirectStoredToken.self, from: Data(json.utf8))
    }

    func save(_ token: SchedulesDirectStoredToken, accountKey: String) throws {
        let data = try JSONEncoder().encode(token)
        try secureStore.setString(String(decoding: data, as: UTF8.self), for: key(accountKey))
    }

    func clear(accountKey: String) throws {
        try secureStore.removeValue(for: key(accountKey))
    }
}
