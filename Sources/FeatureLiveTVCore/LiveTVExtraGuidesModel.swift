import CoreModels
import Foundation
import Observation

/// The extra XMLTV guides a user added to an IPTV account (Settings → Live TV → source → Extra Guides).
/// They fill channels the provider's own guide has no listings for; they never replace it.
/// The model owns the list rules; the app supplies how an account's list is read and saved.
@MainActor
@Observable
public final class LiveTVExtraGuidesModel {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let url: URL
        public let loadedAt: Date?
        public let channelCount: Int?
        public let couldNotLoad: Bool
        public var id: String { url.absoluteString }

        public init(url: URL, loadedAt: Date? = nil, channelCount: Int? = nil, couldNotLoad: Bool = false) {
            self.url = url
            self.loadedAt = loadedAt
            self.channelCount = channelCount
            self.couldNotLoad = couldNotLoad
        }
    }

    public enum Issue: Equatable, Sendable {
        case invalidAddress, duplicate, tooMany, couldNotSave

        public var message: LocalizedStringResource {
            switch self {
            case .invalidAddress: "Enter a web address starting with http:// or https://."
            case .duplicate: "This guide is already added."
            case .tooMany: "No more guides can be added."
            case .couldNotSave: "The guide couldn't be saved. Please try again."
            }
        }
    }

    /// The account's guides with their status; nil when the account has no extra guides (it is not an IPTV account).
    public typealias Load = @MainActor (_ accountID: String) -> [Entry]?
    public typealias Save = @MainActor (_ accountID: String, _ urls: [URL]) throws -> Void

    public static let maximumGuides = 31

    public private(set) var issue: Issue?
    private var revision = 0
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let save: Save

    public init(load: @escaping Load, save: @escaping Save) {
        self.load = load
        self.save = save
    }

    /// Nil when extra guides do not apply to the account.
    public func entries(accountID: String) -> [Entry]? {
        _ = revision
        return load(accountID)
    }

    /// Adds the guide at `address`. The address is trimmed; only http and https web addresses are accepted.
    @discardableResult
    public func add(address: String, accountID: String) -> Bool {
        guard let current = entries(accountID: accountID) else { return false }
        guard let url = LiveTVPlaylistSource.sourceURL(from: address) else { return fail(.invalidAddress) }
        guard !current.contains(where: { $0.url == url }) else { return fail(.duplicate) }
        guard current.count < Self.maximumGuides else { return fail(.tooMany) }
        return commit(current.map(\.url) + [url], accountID: accountID)
    }

    @discardableResult
    public func remove(_ url: URL, accountID: String) -> Bool {
        guard let current = entries(accountID: accountID) else { return false }
        return commit(current.map(\.url).filter { $0 != url }, accountID: accountID)
    }

    public func clearIssue() { issue = nil }

    public func refresh() { revision += 1 }

    private func commit(_ urls: [URL], accountID: String) -> Bool {
        do {
            try save(accountID, urls)
            issue = nil
            revision += 1
            return true
        } catch {
            return fail(.couldNotSave)
        }
    }

    private func fail(_ issue: Issue) -> Bool {
        self.issue = issue
        return false
    }
}
