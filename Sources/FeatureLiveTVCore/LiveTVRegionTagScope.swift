import Foundation

/// Which Region tags the tag picker offers for the countries picked so far. Places only make sense inside a country, so with no
/// country picked there is no Region section; with one or more, only the places carried by channels of those countries.
/// A region the draft already has stays offered (and selected) whatever the countries say, so a saved choice is never hidden.
public enum LiveTVRegionTagScope {
    /// - Parameters:
    ///   - carriedRegionTags: the Region tags at least one channel of the lineup carries, in catalogue order.
    ///   - selectedTagIDs: every tag picked in the draft.
    ///   - placesCarried: the Region tag identifiers carried by channels of one country tag (called once per picked country).
    public static func offeredRegionTags(
        carriedRegionTags: [LiveTVFilterTag], selectedTagIDs: [String], placesCarried: (_ countryTagID: String) -> Set<String>
    ) -> [LiveTVFilterTag] {
        let countryIDs = Set(LiveTVFilterTagCatalog.tags(in: .countryRegion).map(\.id))
        let selected = Set(selectedTagIDs)
        var inScope = Set<String>()
        for country in selectedTagIDs where countryIDs.contains(country) { inScope.formUnion(placesCarried(country)) }
        let carried = Set(carriedRegionTags.map(\.id))
        let stale = LiveTVFilterTagCatalog.tags(in: .region).filter { selected.contains($0.id) && !carried.contains($0.id) }
        return (carriedRegionTags + stale)
            .filter { inScope.contains($0.id) || selected.contains($0.id) }
            .sorted { regionOrder[$0.id, default: 0] < regionOrder[$1.id, default: 0] }
    }

    private static let regionOrder: [String: Int] = Dictionary(
        uniqueKeysWithValues: LiveTVFilterTagCatalog.tags(in: .region).enumerated().map { ($1.id, $0) })
}
