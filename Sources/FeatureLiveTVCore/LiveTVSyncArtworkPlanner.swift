import CoreModels
import Foundation

/// One logo the sync-time artwork writer should have prepared: the URL Live TV would draw, the provider's dark-background flag,
/// and the network-logo variants when the URL is a matched network's default (`nil` for a plain logo).
public struct LiveTVSyncArtworkCandidate: Hashable, Sendable {
    public let url: URL
    public let providerRequestsDarkBackground: Bool
    public let variants: [URL]?

    public init(url: URL, providerRequestsDarkBackground: Bool, variants: [URL]? = nil) {
        self.url = url
        self.providerRequestsDarkBackground = providerRequestsDarkBackground
        self.variants = variants
    }
}

/// What the guide row needs for one channel of a committed lineup, decided at sync time so the row never derives it:
/// the logo it draws, the place printed under a logo shared by regional feeds, and the sport glyph an event channel with no logo shows.
public struct LiveTVSyncArtworkChannelPlan: Hashable, Sendable {
    /// The display channel id (`LiveTVServerCatalog.channelID`), one per enabled source of the account.
    public let channelID: String
    public let sourceID: String
    public let candidate: LiveTVSyncArtworkCandidate?
    public let regionLabel: String?
    public let sportsGlyphSymbol: String?
}

/// Decides which logos a committed saved lineup would draw, with the same authority as display: ``LiveTVChannelLogoService``
/// (the user's override, TMDB, Wikidata). It reads only rows the caller already took from the committed catalogue and
/// stored choices; it never fetches and never matches names itself.
public enum LiveTVSyncArtworkPlanner {
    /// The provider-local channel ids whose logo may have changed: the lineup ids the receipt names plus every channel whose
    /// provider guide identity (`guideID`) is one of the changed guide stations. `nil` means every channel (initial bootstrap).
    public static func affectedChannelIDs(
        in channels: [ServerLiveTVChannel], committed: SavedGuideCommittedInputs
    ) -> Set<String> {
        var ids = Set(committed.changedLineupChannelIDs)
        let stations = Set(committed.guideChanges.flatMap(\.changedStationIDs))
        if !stations.isEmpty {
            for channel in channels {
                if let guideID = channel.guideID, stations.contains(guideID) { ids.insert(channel.id) }
            }
        }
        return ids
    }

    /// One plan per channel per enabled source of `accountID`, with the same logo authority as ``candidates`` (override, TMDB, Wikidata).
    /// A region label appears only on a logo that two or more regional channels of the account share, as `LiveTVPrototypeModel.regionLabel` does.
    public static func channelPlans(
        channels: [ServerLiveTVChannel], sources: [LiveTVServerSource], accountID: String,
        kind: LiveTVPrototypeSource, logoService: LiveTVChannelLogoService
    ) -> [LiveTVSyncArtworkChannelPlan] {
        let enabled = logoService.isTMDbEnabled
        var drafts: [(id: String, sourceID: String, url: URL?, candidate: LiveTVSyncArtworkCandidate?, region: String?, glyph: String?)] = []
        var regionalCounts: [URL: Int] = [:]
        for source in sources where source.accountID == accountID && source.isEnabled {
            for (index, channel) in channels.enumerated() {
                if index.isMultiple(of: 500), Task.isCancelled { return [] }
                let prototype = displayChannel(channel, index: index, source: source, kind: kind)
                guard !prototype.isSectionMarker else { continue }
                let url = logoService.displayedLogoURL(for: prototype, tmdbEnabled: enabled)
                let candidate = url.map {
                    LiveTVSyncArtworkCandidate(
                        url: $0, providerRequestsDarkBackground: prototype.logoNeedsDarkBackground,
                        variants: LiveTVNetworkLogoRegistry.shared.variants(for: $0))
                }
                let region = LiveTVChannelRegion.region(for: prototype)
                if let url, region != nil { regionalCounts[url, default: 0] += 1 }
                drafts.append((prototype.id, source.id, url, candidate, region, sportsGlyph(for: prototype, hasLogo: url != nil, logoService: logoService)))
            }
        }
        return drafts.map { draft in
            let label = draft.url.flatMap { (regionalCounts[$0] ?? 0) >= 2 ? draft.region : nil }
            return LiveTVSyncArtworkChannelPlan(
                channelID: draft.id, sourceID: draft.sourceID, candidate: draft.candidate,
                regionLabel: label, sportsGlyphSymbol: draft.glyph)
        }
    }

    /// The row display builds for a provider channel of `source`, so the plan reads the same logo authority display does.
    private static func displayChannel(
        _ channel: ServerLiveTVChannel, index: Int, source: LiveTVServerSource, kind: LiveTVPrototypeSource
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: LiveTVServerCatalog.channelID(source: source, nativeID: channel.id),
            number: Int(channel.number ?? "") ?? index + 1,
            name: channel.name, category: channel.groups.first ?? (channel.isRadio ? "Radio" : "Live TV"),
            symbol: channel.isRadio ? "radio" : "tv", accent: index % 6, source: kind,
            tagline: "", guideID: channel.guideID, guideName: channel.guideName,
            configuredSourceID: source.id, country: channel.guideCountry, groups: channel.groups
        )
    }

    /// `LiveTVPrototypeModel.sportsGlyphSymbol` with no crests and no matched broadcaster logo, which is all a sync run can know.
    private static func sportsGlyph(
        for channel: LiveTVPrototypeChannel, hasLogo: Bool, logoService: LiveTVChannelLogoService
    ) -> String? {
        let groups = channel.groups ?? []
        guard !logoService.store.hasOverride(LiveTVChannelLogoKey(channel: channel)),
              LiveTVChannelKind.isEvent(name: channel.name, groups: groups) else { return nil }
        switch LiveTVSportsComposition.compose(name: channel.name, groups: groups) {
        case .glyph(let glyph): return glyph.symbolName
        case .leagueBadge(let league) where !hasLogo: return league.glyphSymbolName
        default: return nil
        }
    }

    /// Candidates for `channels` (restricted to `onlyChannelIDs` when given), de-duplicated and capped at `limit`. A channel is
    /// published once per enabled configured source of `accountID`, under the same id display derives.
    public static func candidates(
        channels: [ServerLiveTVChannel], onlyChannelIDs: Set<String>?, sources: [LiveTVServerSource], accountID: String,
        kind: LiveTVPrototypeSource, logoService: LiveTVChannelLogoService, limit: Int
    ) -> [LiveTVSyncArtworkCandidate] {
        let enabled = logoService.isTMDbEnabled
        let ownSources = sources.filter { $0.accountID == accountID && $0.isEnabled }
        var seen = Set<LiveTVSyncArtworkCandidate>()
        var result: [LiveTVSyncArtworkCandidate] = []
        for source in ownSources {
            for (index, channel) in channels.enumerated() {
                if let only = onlyChannelIDs, !only.contains(channel.id) { continue }
                if index.isMultiple(of: 500), Task.isCancelled { return result }
                let prototype = displayChannel(channel, index: index, source: source, kind: kind)
                guard !prototype.isSectionMarker,
                      let url = logoService.displayedLogoURL(for: prototype, tmdbEnabled: enabled) else { continue }
                let candidate = LiveTVSyncArtworkCandidate(
                    url: url, providerRequestsDarkBackground: prototype.logoNeedsDarkBackground,
                    variants: LiveTVNetworkLogoRegistry.shared.variants(for: url)
                )
                if seen.insert(candidate).inserted {
                    result.append(candidate)
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }
}
