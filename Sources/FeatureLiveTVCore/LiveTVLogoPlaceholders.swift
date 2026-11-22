import Foundation

/// A logo URL that one playlist source uses for many unrelated channels.
public struct LiveTVPlaceholderLogo: Hashable, Sendable {
    public let sourceID: String
    public let url: URL
}

/// Finds guide (XMLTV) icons that are placeholders (a country flag, a provider brand, a generic TV icon) rather than a
/// channel's logo. The playlist provider's own logos are never drawn, so they are not read here.
///
/// A URL used by channels with three or more different brand keys within one playlist source is a
/// placeholder. Counting brand keys, not raw names, keeps a real logo shared by one brand's regional
/// variants (CBC Calgary and CBC Edmonton are both "CBC"). One dictionary pass over the catalogue.
public enum LiveTVLogoPlaceholders {
    public static let minimumBrandKeys = 3

    /// The channel name with prefix, quality words, decorations and trailing city removed, folded for comparison.
    public static func brandKey(_ name: String) -> String {
        LiveTVTMDbLogoMatcher.normalized(LiveTVTMDbLogoMatcher.alternateKey(droppingTrailingCountryCode(name)))
    }

    /// Regional editions of one channel carry a country code ("7th Heaven DK", "7th Heaven NO"): one brand, not three.
    private static let countryCodes: Set<String> = [
        "DK", "NO", "SE", "FI", "IS", "UK", "US", "CA", "DE", "FR", "ES", "IT", "NL", "BE", "PL", "PT", "AT", "CH", "IE", "AU", "NZ"
    ]

    private static func droppingTrailingCountryCode(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count >= 3, let last = words.last, countryCodes.contains(String(last)) else { return name }
        return words.dropLast().joined(separator: " ")
    }

    public static func placeholders(in channels: [LiveTVPrototypeChannel]) -> Set<LiveTVPlaceholderLogo> {
        placeholders(in: channels.lazy.flatMap { channel -> [(sourceID: String, url: URL, name: String)] in
            guard channel.source != .plozz, !channel.isSectionMarker else { return [] }
            return channel.guideLogoURL.map { [(channel.playlistSourceID ?? channel.source.rawValue, $0, channel.name)] } ?? []
        })
    }

    /// The same rule over bare (source, logo URL, channel name) triples, in catalogue order.
    static func placeholders<Entries: Sequence>(
        in entries: Entries
    ) -> Set<LiveTVPlaceholderLogo> where Entries.Element == (sourceID: String, url: URL, name: String) {
        var brands: [LiveTVPlaceholderLogo: Set<String>] = [:]
        var placeholders = Set<LiveTVPlaceholderLogo>()
        for entry in entries where !entry.name.hasPrefix("#") {
            let brand = brandKey(entry.name)
            guard !brand.isEmpty else { continue }
            let logo = LiveTVPlaceholderLogo(sourceID: entry.sourceID, url: entry.url)
            if placeholders.contains(logo) { continue }
            var seen = brands[logo, default: []]
            if seen.insert(brand).inserted {
                if seen.count >= minimumBrandKeys {
                    placeholders.insert(logo)
                    brands[logo] = nil
                } else {
                    brands[logo] = seen
                }
            }
        }
        return placeholders
    }
}
