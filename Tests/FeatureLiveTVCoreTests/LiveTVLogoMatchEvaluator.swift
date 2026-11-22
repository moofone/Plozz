import Foundation
#if canImport(FeatureLiveTVCore)
import MetadataKit
@testable import FeatureLiveTVCore
#endif

/// Offline evaluation of the logo layers against the provider's real lineup export. Pure code with no XCTest dependency, so
/// the same file is compiled by the evaluation test and by a standalone command-line driver.
///
/// Layers, in the order the app applies them: curated table, TMDB network, Wikidata, XMLTV guide icon,
/// then the channel's name as text. The playlist provider's own logo is not a layer: it is never drawn, so such a channel counts as text. 24/7 single-show loops use a show-title logo instead of a network.
struct LiveTVLogoMatchEvaluator {
    struct Row: Decodable {
        let name: String
        let groups: [String]
        let logoKey: String?
        let hasLogo: Bool
        let guideID: String?
        /// The channel's declared country. Set only when an evaluation chooses to give the matcher one.
        var country: String? = nil
        /// iptv-org's `tvg-id` (`CTV2Atlantic.ca@SD`). Ground truth for precision only; the matcher never sees it.
        var tvgID: String? = nil
    }

    /// What TMDB says about a network (its origin country and whether it has a logo), fetched once for the networks the matcher proposes.
    struct NetworkDetail: Codable {
        let name: String
        let origin: String?
        let hasLogo: Bool
        /// Pixel size of the image the app would choose (an SVG rendition first, as `TMDbNetworkLogoClient.bestLogo`).
        var width: Int? = nil
        var height: Int? = nil
    }

    enum Layer: String, CaseIterable {
        case curated = "Curated table", tmdb = "TMDB network", showLogo = "TMDB show logo", wikidata = "Wikidata"
        case xmltv = "XMLTV icon", text = "Text plate", event = "Event slot"
    }

    struct Result {
        let row: Row
        let source: String
        let kind: LiveTVChannelKind
        let brand: String
        let layer: Layer
        let matchedName: String?
        let rule: LiveTVTMDbMatchRule?
        /// The match used an assumed origin (the network's details were not available).
        let provisional: Bool
        let tie: [String]
        /// Size of the chosen image; `nil` when it was not measured.
        let size: LiveTVLogoSize?
    }

    struct Inputs {
        var networks: [TMDbNetworkEntry]
        var wikidata: [String: [WikidataLogoEntry]] = [:]
        var details: [Int: NetworkDetail]?
        /// Normalised show title to whether TMDB has a title logo for it.
        var showLogos: [String: Bool] = [:]
        /// Commons raster files' pixel sizes (an SVG needs none).
        var fileSizes: [String: LiveTVLogoSize] = [:]
    }

    struct Evaluation {
        var results: [Result]
        var elapsed: Duration
        var missingDetailIDs: Set<Int>
    }

    static func source(of row: Row, country: String?) -> String {
        if let tvgID = row.tvgID { return LiveTVIPTVOrgPlaylist.countryCode(tvgID: tvgID) }
        if row.name.hasPrefix("CA EN") { return "CA EN" }
        if row.name.hasPrefix("CA FR") { return "CA FR" }
        return country == "CA" ? "CA other" : "US"
    }

    static func evaluate(rows: [Row], inputs: Inputs) -> Evaluation {
        let tmdb = LiveTVTMDbLogoMatcher(networks: inputs.networks)
        let wikidataMatchers = inputs.wikidata.mapValues(LiveTVWikidataLogoMatcher.init(entries:))
        var missing = Set<Int>()

        struct Decision { let layer: Layer; let name: String?; let rule: LiveTVTMDbMatchRule?; let provisional: Bool; let tie: [String]; var size: LiveTVLogoSize? = nil }
        var memo: [String: Decision] = [:]
        var results: [Result] = []
        results.reserveCapacity(rows.count)
        let started = ContinuousClock.now
        for (index, row) in rows.enumerated() {
            let query = LiveTVTMDbChannelQuery(name: row.name, groups: row.groups, country: row.country)
            let country = LiveTVTMDbLogoMatcher.country(for: query)
            let kind = LiveTVChannelKind.classify(name: row.name, groups: row.groups)
            let brand = LiveTVLogoPlaceholders.brandKey(row.name)
            var decision: Decision
            let memoKey = row.name + "\u{1F}" + row.groups.joined(separator: "\u{1E}") + "\u{1F}" + (country ?? "")
            if let hit = memo[memoKey] {
                decision = hit
            } else {
                decision = Decision(layer: .text, name: nil, rule: nil, provisional: false, tie: [])
                if kind == .event {
                    decision = Decision(layer: .event, name: nil, rule: nil, provisional: false, tie: [])
                } else if kind == .showLoop,
                          let title = LiveTVChannelKind.showLoopTitle(name: row.name, groups: row.groups),
                          inputs.showLogos[LiveTVTMDbLogoMatcher.normalized(title)] == true {
                    decision = Decision(layer: .showLogo, name: title, rule: nil, provisional: false, tie: [])
                } else if let entry = LiveTVTMDbLogoMatcher.curatedEntry(for: query), entry.tmdbNetworkID == nil, let qid = entry.wikidataQID {
                    decision = Decision(layer: .curated, name: qid, rule: .curated, provisional: false, tie: [], size: Self.wikidataSize(qid: qid, inputs: inputs))
                } else {
                    let outcome = networkOutcome(query: query, country: country, tmdb: tmdb, inputs: inputs, missing: &missing)
                    if let chosen = outcome.chosen {
                        let curated = chosen.rule == .curated
                        decision = Decision(layer: curated ? .curated : .tmdb, name: chosen.networkName, rule: chosen.rule,
                                            provisional: outcome.provisional, tie: [],
                                            size: inputs.details?[chosen.networkID].flatMap { d in d.width.flatMap { w in d.height.map { .raster(width: w, height: $0) } } })
                        // Quality-aware choice: a TMDB image measured below the panel's size loses to a crisp Wikidata logo of the same channel.
                        if let size = decision.size, !LiveTVLogoQuality.isCrisp(size, for: .hero),
                           let country, let entry = wikidataMatchers[country]?.match(query, country: country),
                           let wikiSize = Self.fileSize(entry.file, inputs: inputs), LiveTVLogoQuality.isCrisp(wikiSize, for: .hero) {
                            decision = Decision(layer: .wikidata, name: entry.label, rule: nil, provisional: false, tie: [], size: wikiSize)
                        }
                    } else if let country, let matcher = wikidataMatchers[country], let entry = matcher.match(query, country: country) {
                        decision = Decision(layer: .wikidata, name: entry.label, rule: nil, provisional: false, tie: [], size: Self.fileSize(entry.file, inputs: inputs))
                    } else if let entry = LiveTVTMDbLogoMatcher.curatedEntry(for: query, descriptors: true), entry.wikidataQID != nil {
                        decision = Decision(layer: .curated, name: entry.wikidataQID, rule: .curated, provisional: false, tie: [], size: entry.wikidataQID.flatMap { Self.wikidataSize(qid: $0, inputs: inputs) })
                    } else {
                        decision = Decision(layer: .text, name: nil, rule: nil, provisional: false, tie: outcome.tie)
                    }
                }
                memo[memoKey] = decision
            }
            // The playlist provider's own logo is never drawn, so a channel with no other logo is a text plate.
            let layer = decision.layer
            results.append(Result(
                row: row, source: source(of: row, country: country), kind: kind, brand: brand, layer: layer,
                matchedName: decision.name, rule: decision.rule, provisional: decision.provisional,
                tie: decision.tie, size: decision.size
            ))
        }
        return Evaluation(results: results, elapsed: ContinuousClock.now - started, missingDetailIDs: missing)
    }

    static func fileSize(_ file: String, inputs: Inputs) -> LiveTVLogoSize? {
        file.lowercased().hasSuffix(".svg") ? .vector : inputs.fileSizes[file]
    }

    static func wikidataSize(qid: String, inputs: Inputs) -> LiveTVLogoSize? {
        for entries in inputs.wikidata.values {
            if let entry = entries.first(where: { $0.qid == qid }) { return fileSize(entry.file, inputs: inputs) }
        }
        return nil
    }

    /// TMDB candidates for the query, resolved with each network's real origin country and logo when the details are known, or
    /// with the channel's own country assumed when they are not (`provisional`).
    private static func networkOutcome(
        query: LiveTVTMDbChannelQuery, country: String?, tmdb: LiveTVTMDbLogoMatcher, inputs: Inputs, missing: inout Set<Int>
    ) -> (chosen: LiveTVTMDbCandidate?, provisional: Bool, tie: [String]) {
        var candidates = tmdb.candidates(for: query)
        guard !candidates.isEmpty else { return (nil, false, []) }
        var provisional = false
        var origins: [Int: String?] = [:]
        if let details = inputs.details {
            candidates = candidates.filter { candidate in
                guard let detail = details[candidate.networkID] else {
                    missing.insert(candidate.networkID)
                    origins[candidate.networkID] = .some(country)
                    provisional = true
                    return true
                }
                origins[candidate.networkID] = .some(detail.origin)
                return detail.hasLogo && LiveTVTMDbLogoMatcher.normalized(detail.name) == LiveTVTMDbLogoMatcher.normalized(candidate.networkName)
            }
        } else {
            provisional = true
            for candidate in candidates { origins[candidate.networkID] = .some(country) }
        }
        if let chosen = LiveTVTMDbLogoMatcher.select(from: candidates, originCountries: origins, channelCountry: country) {
            return (chosen, provisional, [])
        }
        let tied = Set(candidates.map { LiveTVTMDbLogoMatcher.collapsedKey($0.networkName) })
        return (nil, provisional, tied.count > 1 ? tied.sorted() : [])
    }
}
