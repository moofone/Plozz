#if canImport(UIKit)
import CoreUI
import FeatureLiveTVCore
import Foundation
import Observation
import SwiftUI

/// What the sync writer decided a guide row draws for one channel.
public struct LiveTVGuideStationMarkPresentation: Equatable, Sendable {
    /// The prepared-artwork identity (logo URL and the provider's dark-background flag); `nil` when the channel has no logo.
    public let identity: ThemedChannelLogoIdentity?
    /// The place printed under a logo shared by regional feeds.
    public let regionLabel: String?
    /// The sport symbol an event channel with no logo shows.
    public let sportsGlyphSymbol: String?

    public init(identity: ThemedChannelLogoIdentity?, regionLabel: String?, sportsGlyphSymbol: String?) {
        self.identity = identity
        self.regionLabel = regionLabel
        self.sportsGlyphSymbol = sportsGlyphSymbol
    }
}

/// Channel-keyed memory of the sync writer's committed presentations, read by guide rows with one dictionary lookup under a lock.
///
/// Rows never derive a logo, region label or glyph themselves for a channel of a covered source: the writer commits them with the
/// artwork. ``revoke()`` (profile, account or authorization change) clears everything and invalidates any commit already in flight.
public final class LiveTVGuideStationMarkIndex: Observable, @unchecked Sendable {
    public static let shared = LiveTVGuideStationMarkIndex()

    private let lock = NSLock()
    private var entries: [String: LiveTVGuideStationMarkPresentation] = [:]
    private var channelIDsByAccount: [String: Set<String>] = [:]
    private var sourceIDsByAccount: [String: Set<String>] = [:]
    private var revision = 0
    private var artworkGeneration = 0
    private let registrar = ObservationRegistrar()

    public init() {}

    /// Bumps when prepared artwork was added to the cache; rows that read a presentation observe it and redraw once.
    public var generation: Int { lock.withLock { artworkGeneration } }

    /// Called by the sync writer after a batch of logos was prepared, so visible rows that drew a name now draw the logo.
    public func artworkDidChange() {
        registrar.withMutation(of: self, keyPath: \.generation) { lock.withLock { artworkGeneration &+= 1 } }
    }

    /// Taken before a writer run starts; a commit made under an older value is dropped.
    public var currentRevision: Int { lock.withLock { revision } }

    public func presentation(forChannelID id: String) -> LiveTVGuideStationMarkPresentation? {
        registrar.access(self, keyPath: \.generation)
        return lock.withLock { entries[id] }
    }

    /// Whether a committed run has covered `sourceID`, so a channel of it with no entry is known to have no logo.
    public func covers(sourceID: String?) -> Bool {
        registrar.access(self, keyPath: \.generation)
        guard let sourceID else { return false }
        return lock.withLock { sourceIDsByAccount.values.contains { $0.contains(sourceID) } }
    }

    public func hasCommitted(accountID: String) -> Bool {
        lock.withLock { sourceIDsByAccount[accountID] != nil }
    }

    /// Replaces everything held for `accountID`. Returns `false` (and changes nothing) when `revision` is stale.
    @discardableResult
    public func commit(
        accountID: String, sourceIDs: Set<String>, presentations: [String: LiveTVGuideStationMarkPresentation], revision expected: Int
    ) -> Bool {
        // Rows that already read an older presentation (or none) must redraw, so the commit is a mutation observers see.
        registrar.withMutation(of: self, keyPath: \.generation) {
            lock.withLock {
                guard revision == expected else { return false }
                for id in channelIDsByAccount[accountID] ?? [] { entries[id] = nil }
                for (id, presentation) in presentations { entries[id] = presentation }
                channelIDsByAccount[accountID] = Set(presentations.keys)
                sourceIDsByAccount[accountID] = sourceIDs
                artworkGeneration &+= 1
                return true
            }
        }
    }

    public func revoke() {
        lock.withLock {
            revision &+= 1
            entries.removeAll()
            channelIDsByAccount.removeAll()
            sourceIDsByAccount.removeAll()
        }
    }
}

/// What a guide row reads for one channel, with no work beyond lookups.
enum LiveTVGuideStationMarkRead: Equatable {
    /// Not a synced channel: the row keeps its own logo path.
    case unsynced
    /// Synced, no logo and no glyph, or the logo is not prepared yet: the channel name is drawn.
    case name
    case glyph(String)
    case logo(ThemedChannelLogoIdentity, regionLabel: String?)
}

/// The index and prepared-artwork cache rows read; injectable so a test supplies its own.
struct LiveTVGuideStationMarks {
    var index: LiveTVGuideStationMarkIndex = .shared
    var cache: ThemedChannelLogoArtworkCache = .shared

    func read(_ channel: LiveTVPrototypeChannel) -> LiveTVGuideStationMarkRead {
        guard channel.source == .iptv else { return .unsynced }
        guard let presentation = index.presentation(forChannelID: channel.id) else {
            return index.covers(sourceID: channel.configuredSourceID) ? .name : .unsynced
        }
        if let symbol = presentation.sportsGlyphSymbol { return .glyph(symbol) }
        guard let identity = presentation.identity, cache.contains(identity) else { return .name }
        return .logo(identity, regionLabel: presentation.regionLabel)
    }
}

private struct LiveTVGuideStationMarksKey: EnvironmentKey {
    static let defaultValue = LiveTVGuideStationMarks()
}

extension EnvironmentValues {
    var liveTVGuideStationMarks: LiveTVGuideStationMarks {
        get { self[LiveTVGuideStationMarksKey.self] }
        set { self[LiveTVGuideStationMarksKey.self] = newValue }
    }
}
#endif
