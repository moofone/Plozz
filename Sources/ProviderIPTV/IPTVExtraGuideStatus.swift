import Foundation
import os

/// What the last read of one extra guide (`IPTVCredential.extraGuideURLs`) came to.
public struct IPTVExtraGuideStatus: Sendable, Equatable {
    public let url: URL
    /// When the guide was last read successfully.
    public var loadedAt: Date?
    /// Channels of the lineup this guide supplied listings for in its last successful read.
    public var channelCount: Int?
    /// The last attempt failed; the guide is asked again after a back-off.
    public var couldNotLoad: Bool

    public init(url: URL, loadedAt: Date? = nil, channelCount: Int? = nil, couldNotLoad: Bool = false) {
        self.url = url
        self.loadedAt = loadedAt
        self.channelCount = channelCount
        self.couldNotLoad = couldNotLoad
    }
}

/// Per-source status of extra guides for Settings, keyed by the credential's catalogue identity. Held in memory only.
public final class IPTVExtraGuideStatusStore: Sendable {
    public static let shared = IPTVExtraGuideStatusStore()
    private let values = OSAllocatedUnfairLock<[UUID: [URL: IPTVExtraGuideStatus]]>(initialState: [:])

    public init() {}

    public func statuses(for sourceIdentity: UUID, urls: [URL]) -> [IPTVExtraGuideStatus] {
        let saved = values.withLock { $0[sourceIdentity] ?? [:] }
        return urls.map { saved[$0] ?? IPTVExtraGuideStatus(url: $0) }
    }

    func recordLoaded(_ url: URL, source: UUID, channels: Int?, at date: Date = Date()) {
        update(url, source: source) {
            $0.loadedAt = date
            if let channels { $0.channelCount = channels }
            $0.couldNotLoad = false
        }
    }

    func recordFailure(_ url: URL, source: UUID) {
        update(url, source: source) { $0.couldNotLoad = true }
    }

    /// Forgets guides no longer configured.
    public func retain(_ urls: [URL], for sourceIdentity: UUID) {
        values.withLock { all in
            let keep = Set(urls)
            guard var saved = all[sourceIdentity] else { return }
            saved = saved.filter { keep.contains($0.key) }
            all[sourceIdentity] = saved.isEmpty ? nil : saved
        }
    }

    private func update(_ url: URL, source: UUID, _ change: (inout IPTVExtraGuideStatus) -> Void) {
        values.withLock { all in
            var status = all[source]?[url] ?? IPTVExtraGuideStatus(url: url)
            change(&status)
            all[source, default: [:]][url] = status
        }
    }
}
