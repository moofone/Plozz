import Foundation
import MetadataKit

/// Matches channel names to Wikidata items using the same rules as the TMDB matcher (normalised
/// name, alias table, stripped alternate name), against each item's label and English aliases.
/// A country is mandatory: the list is already one country's, so every item counts as that
/// country. Two different items that tie stay unmatched.
struct LiveTVWikidataLogoMatcher: Sendable {
    private let entries: [WikidataLogoEntry]
    private let names: LiveTVTMDbLogoMatcher
    /// Pseudo network ID (a name's index) to the entry it came from.
    private let owners: [Int: Int]

    init(entries: [WikidataLogoEntry]) {
        self.entries = entries
        var pseudo: [TMDbNetworkEntry] = []
        var owners: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() {
            for name in [entry.label] + entry.altLabels {
                owners[pseudo.count] = index
                pseudo.append(TMDbNetworkEntry(id: pseudo.count, name: name))
            }
        }
        self.names = LiveTVTMDbLogoMatcher(networks: pseudo, usesCuratedTMDbIDs: false)
        self.owners = owners
    }

    func match(_ query: LiveTVTMDbChannelQuery, country: String) -> WikidataLogoEntry? {
        var best: [Int: LiveTVTMDbCandidate] = [:]
        for candidate in names.candidates(for: query) {
            guard let owner = owners[candidate.networkID] else { continue }
            if let existing = best[owner], existing.confidence >= candidate.confidence { continue }
            best[owner] = LiveTVTMDbCandidate(
                networkID: owner, networkName: candidate.networkName,
                confidence: candidate.confidence, rule: candidate.rule
            )
        }
        let countries = Dictionary(uniqueKeysWithValues: best.keys.map { ($0, Optional(country)) })
        guard let selected = LiveTVTMDbLogoMatcher.select(
            from: Array(best.values), originCountries: countries, channelCountry: country
        ) else { return nil }
        let entry = entries[selected.networkID]
        // A match through an alias whose logo file names the item's own, different brand is another channel's logo.
        return Self.fileNamesAnotherBrand(file: entry.file, label: entry.label, matchedName: selected.networkName) ? nil : entry
    }

    /// True when the item was matched through a name other than its label (a former name or alias: "Animal Planet" on the item
    /// "CTV Wild Channel") and its Commons file is named after the label rather than the matched name ("CTV Wild Channel Logo.png").
    /// The logo then belongs to the item's present brand, not to the channel that was asked for.
    static func fileNamesAnotherBrand(file: String, label: String, matchedName: String) -> Bool {
        let matched = compact(matchedName), labelKey = compact(label)
        guard !matched.isEmpty, !labelKey.isEmpty, matched != labelKey, !labelKey.contains(matched) else { return false }
        var stem = file
        if let dot = stem.lastIndex(of: ".") { stem = String(stem[..<dot]) }
        let fileKey = compact(stem)
        return !fileKey.contains(matched) && fileKey.contains(labelKey)
    }

    private static func compact(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
