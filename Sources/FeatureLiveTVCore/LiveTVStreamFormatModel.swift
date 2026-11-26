import CoreModels
import Foundation
import Observation

/// Per-provider Xtream live stream format preference (Settings → Live TV → source → Live stream format).
@MainActor
@Observable
public final class LiveTVStreamFormatModel {
    public typealias Load = @MainActor (_ accountID: String) -> IPTVCredential.LiveStreamFormat?
    public typealias Save = @MainActor (_ accountID: String, _ format: IPTVCredential.LiveStreamFormat) throws -> Void

    private var revision = 0
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let save: Save

    public init(load: @escaping Load, save: @escaping Save) {
        self.load = load
        self.save = save
    }

    /// Nil when the account is not an Xtream IPTV provider.
    public func liveStreamFormat(accountID: String) -> IPTVCredential.LiveStreamFormat? {
        _ = revision
        return load(accountID)
    }

    @discardableResult
    public func setLiveStreamFormat(_ format: IPTVCredential.LiveStreamFormat, accountID: String) -> Bool {
        guard liveStreamFormat(accountID: accountID) != nil else { return false }
        do {
            try save(accountID, format)
            revision += 1
            return true
        } catch {
            return false
        }
    }

    public func refresh() { revision += 1 }
}
