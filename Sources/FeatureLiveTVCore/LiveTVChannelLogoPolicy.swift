import Foundation

extension LiveTVPrototypeChannel {
    /// The single seam for the image Live TV draws for a channel: the user's override, else the TMDB match, else the Wikidata/Commons
    /// match, else the guide's XMLTV icon when it is measured crisp and not a placeholder, else `nil` and the channel's name is drawn
    /// as text. The playlist provider's own `logoURL` is never drawn; a Plozz channel keeps its own artwork. Resolved by the shared
    /// `LiveTVChannelLogoService`; `LiveTVPrototypeModel.effectiveLogoURL(for:)` adds the matches its current run has published.
    public var displayedLogoURL: URL? { LiveTVChannelLogoService.shared.displayedLogoURL(for: self) }
}
