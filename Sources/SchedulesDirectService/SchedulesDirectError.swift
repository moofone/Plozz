import Foundation
import CoreModels

/// Why Schedules Direct traffic is stopped until the user acts.
public struct SchedulesDirectAttention: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case invalidCredentials, accountLocked, accessDisabled, applicationDisabled
        case tooManyLogins, tooManyAddresses, clientUpgradeRequired, accountExpired
        case accountInactive, protocolViolation, unexpectedResponse
    }

    public var reason: Reason
    /// Schedules Direct's own message (or a fixed description); never a secret.
    public var message: String
    public var code: Int?

    public init(reason: Reason, message: String, code: Int? = nil) {
        self.reason = reason
        self.message = message
        self.code = code
    }
}

/// Typed failure for every Schedules Direct operation.
public enum SchedulesDirectError: Error, Equatable, Sendable {
    case featureDisabled
    case notSignedIn
    /// Account or protocol problem. Traffic is stopped and persisted as
    /// attention; nothing retries until the user reconnects or signs in again.
    case needsAttention(SchedulesDirectAttention)
    /// Server back-pressure; nothing may be sent before `date`.
    case notBefore(Date)
    /// The per-account ledger refuses another request until `resumesAt`.
    case budgetExceeded(resumesAt: Date)
    /// A sync ran too recently.
    case syncTooSoon(Date)
    /// iOS only: not on Wi-Fi or Ethernet.
    case networkNotAllowed
    case lineupLimitReached(message: String)
    case lineupChangesExhausted(message: String)
    /// An item-level API error that does not endanger the account.
    case request(code: Int, message: String)
    case transport(AppError)
    case storage
}

/// What a Schedules Direct response code means for the governor.
enum SchedulesDirectCodeClass: Equatable {
    case ok
    case tokenExpired
    case backPressure
    case attention(SchedulesDirectAttention.Reason)
    case lineupLimit
    case lineupChanges
    case item
}

enum SchedulesDirectErrorCodes {
    static func classify(_ code: Int) -> SchedulesDirectCodeClass {
        switch code {
        case 0: return .ok
        case 4006, 1010: return .tokenExpired
        case 3000, 3001, 6001, 7100: return .backPressure
        case 4003, 4002: return .attention(.invalidCredentials)
        case 4004: return .attention(.accountLocked)
        case 4005: return .attention(.accessDisabled)
        case 4007: return .attention(.applicationDisabled)
        case 4009, 1050: return .attention(.tooManyLogins)
        case 4010: return .attention(.tooManyAddresses)
        case 4011: return .attention(.clientUpgradeRequired)
        case 4001: return .attention(.accountExpired)
        case 4008: return .attention(.accountInactive)
        case 1003, 1005, 1001, 1006, 1011, 1012: return .attention(.protocolViolation)
        case 4101: return .lineupLimit
        case 4100: return .lineupChanges
        case 2000...2999, 4102, 6000, 7000...7099, 7101...7999: return .item
        default: return .attention(.unexpectedResponse)
        }
    }
}
