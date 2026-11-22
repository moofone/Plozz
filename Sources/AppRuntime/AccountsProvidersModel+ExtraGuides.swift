import CoreModels
import FeatureLiveTVCore
import Foundation
import ProviderIPTV

extension AccountsProvidersModel {
    /// The Settings model for extra guides: IPTV accounts only; saving rebuilds that account's provider.
    public func makeExtraGuidesModel(
        guideSaved: @escaping @MainActor (_ accountID: String) -> Void = { _ in }
    ) -> LiveTVExtraGuidesModel {
        LiveTVExtraGuidesModel(
            load: { [weak self] in self?.extraGuideEntries(accountID: $0) },
            save: { [weak self] accountID, urls in
                guard let self else { return }
                try self.saveExtraGuides(accountID: accountID, urls: urls)
                guideSaved(accountID)
            }
        )
    }

    func extraGuideEntries(accountID: String) -> [LiveTVExtraGuidesModel.Entry]? {
        guard let account = accounts.first(where: { $0.id == accountID }), account.server.provider == .iptv,
              let token = accountStore.token(for: accountID),
              let credential = try? IPTVCredential.decode(token) else { return nil }
        return IPTVExtraGuideStatusStore.shared
            .statuses(for: credential.identity, urls: credential.extraGuideURLs)
            .map {
                LiveTVExtraGuidesModel.Entry(
                    url: $0.url, loadedAt: $0.loadedAt, channelCount: $0.channelCount, couldNotLoad: $0.couldNotLoad
                )
            }
    }

    func saveExtraGuides(accountID: String, urls: [URL]) throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw AppError.notFound }
        try accountStore.replaceIPTVExtraGuides(expected: account, urls: urls)
        if let token = accountStore.token(for: accountID), let credential = try? IPTVCredential.decode(token) {
            IPTVExtraGuideStatusStore.shared.retain(urls, for: credential.identity)
        }
        registry.invalidate(accountID: accountID)
        reloadAccounts()
    }

    /// DEBUG only: `-PlozzLiveTVExtraGuideURL <url>` adds that address as an extra guide of the IPTV account (the active
    /// profile's when it has one) through the Settings model, then starts the normal guide refresh. The address is never logged.
    public func applyLaunchExtraGuide(
        model: LiveTVExtraGuidesModel, arguments: [String] = ProcessInfo.processInfo.arguments,
        guideSaved: @MainActor (_ accountID: String) -> Void
    ) {
        #if DEBUG
        guard let flag = arguments.firstIndex(of: "-PlozzLiveTVExtraGuideURL"), arguments.indices.contains(flag + 1) else { return }
        let iptv = accounts.filter { $0.server.provider == .iptv }
        guard let account = iptv.first(where: { activeAccountIDs.contains($0.id) }) ?? iptv.first else { return }
        let address = arguments[flag + 1]
        if let present = model.entries(accountID: account.id), present.contains(where: { $0.url.absoluteString == address }) { return }
        if model.add(address: address, accountID: account.id) { guideSaved(account.id) }
        #endif
    }
}
