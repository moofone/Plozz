import Foundation
@testable import FeatureLiveTVCore

/// The iptv-org evaluation report: per-country rates and precision against the `tvg-id` name, which the matcher never sees.
extension LiveTVLogoMatchEvaluator {
    enum Agreement: String { case agrees, disagrees, unverifiable }

    /// Does the matched brand's name agree with the name inside the channel's `tvg-id`? Compared as collapsed keys: one contains the other
    /// (three letters or more), or they share their first six letters.
    static func agreement(_ result: Result) -> Agreement {
        guard let tvgID = result.row.tvgID, let matched = result.matchedName, [.tmdb, .wikidata].contains(result.layer) || (result.layer == .curated && !matched.hasPrefix("Q")) else { return .unverifiable }
        let identity = LiveTVTMDbLogoMatcher.collapsedKey(LiveTVIPTVOrgPlaylist.idName(tvgID: tvgID))
        let brand = LiveTVTMDbLogoMatcher.collapsedKey(matched)
        guard identity.count >= 3, brand.count >= 3 else { return .unverifiable }
        if identity.contains(brand) || brand.contains(identity) { return .agrees }
        return identity.prefix(6) == brand.prefix(6) ? .agrees : .disagrees
    }

    static func iptvReport(_ evaluation: Evaluation, label: String, peakMemoryMB: Double) -> String {
        let results = evaluation.results
        func pct(_ value: Int, of total: Int) -> String { String(format: "%d (%.1f%%)", value, total == 0 ? 0 : Double(value) * 100 / Double(total)) }
        var out = "## \(label)\n\n\(results.count) channels. Match time (names to decisions) \(evaluation.elapsed); peak resident memory of the whole run \(String(format: "%.0f", peakMemoryMB)) MB.\n\n"
        let kinds = Dictionary(grouping: results, by: \.kind).mapValues(\.count)
        out += "Kinds: " + kinds.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ") + "\n\n"
        let matchedLayers: Set<Layer> = [.curated, .tmdb, .showLogo, .wikidata]
        let linear = results.filter { $0.kind == .linear }
        out += "| Country | Linear | TMDB/curated/Wikidata | Text plate (provider logos are never drawn) | Agree | Disagree |\n|---|---|---|---|---|---|\n"
        let byCountry = Dictionary(grouping: linear, by: \.source)
        let ordered = byCountry.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        let shown = Set(ordered.prefix(10).map(\.key)).union(["CA", "US"])
        for (country, items) in ordered where shown.contains(country) {
            let agreements = items.map(agreement)
            out += "| \(country) | \(items.count) | \(pct(items.filter { matchedLayers.contains($0.layer) }.count, of: items.count)) | \(pct(items.filter { $0.layer == .text }.count, of: items.count)) | \(agreements.filter { $0 == .agrees }.count) | \(agreements.filter { $0 == .disagrees }.count) |\n"
        }
        let all = linear.map(agreement)
        let agree = all.filter { $0 == .agrees }.count, disagree = all.filter { $0 == .disagrees }.count
        out += "\nAll countries, linear: \(pct(linear.filter { matchedLayers.contains($0.layer) }.count, of: linear.count)) matched; \(pct(linear.filter { $0.layer == .text }.count, of: linear.count)) text plate (the provider's own logo is never drawn). "
        out += "Of \(agree + disagree) matches whose brand name can be compared with the tvg-id: \(agree) agree, \(disagree) disagree (\(String(format: "%.1f", Double(agree) * 100 / Double(max(agree + disagree, 1))))% agreement).\n\n"
        out += "### Disagreements (name-based; each needs a manual look)\n\n| Channel | tvg-id | Matched brand | Rule |\n|---|---|---|---|\n"
        for result in linear where agreement(result) == .disagrees {
            out += "| \(result.row.name.replacingOccurrences(of: "|", with: "/")) | \(result.row.tvgID ?? "") | \(result.matchedName ?? "") | \(result.rule.map { "\($0)" } ?? "-") |\n"
        }
        return out
    }
}
