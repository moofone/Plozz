#if canImport(SwiftUI)
import Foundation
import Observation
import SchedulesDirectService

/// Drives the Schedules Direct settings screens. All behaviour (governor, limits,
/// sync) lives in `SchedulesDirectService`; this only maps results to UI state.
@MainActor
@Observable
final class SchedulesDirectSettingsModel {
    enum Failure: Equatable {
        case featureDisabled, signInFailed, accountAttention(String), notBefore(Date), budget(Date)
        case syncTooSoon(Date), noWiFi, lineupLimit, lineupChanges, network, storage, generic
    }

    struct Country: Identifiable, Hashable {
        let code: String
        let regionCode: String
        var id: String { code }
        var name: String { Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode }
    }

    static let countries: [Country] = [
        .init(code: "USA", regionCode: "US"), .init(code: "CAN", regionCode: "CA"), .init(code: "GBR", regionCode: "GB"),
        .init(code: "AUS", regionCode: "AU"), .init(code: "IRL", regionCode: "IE"), .init(code: "DEU", regionCode: "DE"),
        .init(code: "FRA", regionCode: "FR"), .init(code: "ESP", regionCode: "ES"), .init(code: "ITA", regionCode: "IT"),
        .init(code: "NLD", regionCode: "NL"), .init(code: "MEX", regionCode: "MX"), .init(code: "BRA", regionCode: "BR")
    ]

    @ObservationIgnored private let service: SchedulesDirectService
    private(set) var state: SchedulesDirectState
    private(set) var isWorking = false
    private(set) var failure: Failure?
    private(set) var headends: [SchedulesDirectHeadend] = []
    private(set) var didSearch = false

    init(service: SchedulesDirectService) {
        self.service = service
        self.state = SchedulesDirectState(isEnabled: service.isEnabled, lastSyncFailed: false)
    }

    var isEnabled: Bool { service.isEnabled }

    func reload() async { state = await service.state() }

    func signIn(username: String, password: String) async -> Bool {
        await run { try await self.service.signIn(username: username, password: password) }
    }

    func signOut() async { _ = await run { try await self.service.signOut() } }
    func reconnect() async { _ = await run { try await self.service.reconnect() } }
    func syncNow() async { _ = await run { _ = try await self.service.syncNow() } }

    func searchHeadends(country: String, postalCode: String) async {
        didSearch = false
        headends = []
        _ = await run { self.headends = try await self.service.headends(country: country, postalCode: postalCode) }
        didSearch = failure == nil
    }

    func add(lineup: String) async -> Bool {
        await run { _ = try await self.service.addLineup(lineup) }
    }

    func remove(lineup: String) async { _ = await run { _ = try await self.service.removeLineup(lineup) } }

    func refreshLineups() async { _ = await run { _ = try await self.service.refreshLineups() } }

    func clearFailure() { failure = nil }

    private func run(_ operation: @escaping () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await operation()
            await reload()
            return true
        } catch {
            failure = Self.failure(for: error)
            await reload()
            return false
        }
    }

    static func failure(for error: Error) -> Failure {
        guard let error = error as? SchedulesDirectError else {
            return error is CancellationError ? .generic : .network
        }
        switch error {
        case .featureDisabled: return .featureDisabled
        case .notSignedIn: return .signInFailed
        case let .needsAttention(attention):
            return attention.reason == .invalidCredentials ? .signInFailed : .accountAttention(attention.message)
        case let .notBefore(date): return .notBefore(date)
        case let .budgetExceeded(date): return .budget(date)
        case let .syncTooSoon(date): return .syncTooSoon(date)
        case .networkNotAllowed: return .noWiFi
        case .lineupLimitReached: return .lineupLimit
        case .lineupChangesExhausted: return .lineupChanges
        case .transport: return .network
        case .storage: return .storage
        case .request: return .generic
        }
    }
}
#endif
