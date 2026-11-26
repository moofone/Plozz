import CoreModels
import FeatureLiveTVCore
import Foundation

extension AccountsProvidersModel {
    /// Settings model for per-provider Xtream live stream format; saving rebuilds that account's provider.
    public func makeLiveTVStreamFormatModel() -> LiveTVStreamFormatModel {
        LiveTVStreamFormatModel(
            load: { [weak self] in self?.liveStreamFormat(accountID: $0) },
            save: { [weak self] accountID, format in
                guard let self else { return }
                try self.saveLiveStreamFormat(accountID: accountID, format: format)
            }
        )
    }

    func liveStreamFormat(accountID: String) -> IPTVCredential.LiveStreamFormat? {
        guard let account = accounts.first(where: { $0.id == accountID }), account.server.provider == .iptv,
              let token = accountStore.token(for: accountID),
              let credential = try? IPTVCredential.decode(token),
              credential.mode == .xtream else { return nil }
        return credential.liveStreamFormat
    }

    func saveLiveStreamFormat(accountID: String, format: IPTVCredential.LiveStreamFormat) throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw AppError.notFound }
        try accountStore.replaceIPTVLiveStreamFormat(expected: account, format: format)
        registry.invalidate(accountID: accountID)
        reloadAccounts()
    }
}
