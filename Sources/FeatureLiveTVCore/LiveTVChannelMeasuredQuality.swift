import CoreModels
import Foundation

extension LiveTVPrototypeChannel {
    /// The store key of this channel's measured resolution: its playlist source and channel ID.
    public var qualityKey: (sourceID: String, channelID: String) { (playlistSourceID ?? source.rawValue, id) }

    /// The resolution label measured while the channel played (the most common steady state of its last five plays), or `nil`.
    public func measuredResolution(in store: LiveChannelMeasuredQualityStore = .shared) -> LiveChannelResolutionLabel? {
        store.label(sourceID: qualityKey.sourceID, channelID: qualityKey.channelID)
    }

    /// The tag texts to show on the hero and panel: the measured label in place of the name's `HD`/`FHD`/`UHD`/`4K` claim.
    public func displayedTagTexts(in store: LiveChannelMeasuredQualityStore = .shared) -> [String] {
        IPTVChannelTag.displayTexts(for: tags, measured: measuredResolution(in: store))
    }

    /// The guide plate's quality word: `4K` or `8K` as claimed, removed when the channel was measured below 2000 lines.
    public func guideQualityBadgeText(in store: LiveChannelMeasuredQualityStore = .shared) -> String? {
        IPTVChannelTag.guideBadge(in: tags, measured: measuredResolution(in: store))?.badgeText
    }
}
