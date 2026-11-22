import Foundation
import MetadataKit

/// Matches the team names of an event title to the teams of one league on Wikidata. A name matches when it equals a team's label or
/// English alias exactly (case, accents and punctuation ignored), or the league's alias table maps it to such a name. Two different teams
/// that tie stay unmatched.
struct LiveTVSportsCrestMatcher: Sendable {
    private let league: LiveTVSportsLeague
    private let byName: [String: Set<Int>]
    private let entries: [WikidataLogoEntry]

    init(league: LiveTVSportsLeague, entries: [WikidataLogoEntry]) {
        self.league = league
        self.entries = entries
        var byName: [String: Set<Int>] = [:]
        for (index, entry) in entries.enumerated() {
            for name in [entry.label] + entry.altLabels {
                byName[LiveTVSportsTeamAliases.normalize(name), default: []].insert(index)
            }
        }
        self.byName = byName
    }

    func team(named written: String) -> WikidataLogoEntry? {
        let key = LiveTVSportsTeamAliases.normalize(written)
        guard !key.isEmpty else { return nil }
        var found = byName[key] ?? []
        if let full = LiveTVSportsTeamAliases.table(for: league)[key] {
            found.formUnion(byName[LiveTVSportsTeamAliases.normalize(full)] ?? [])
        }
        return found.count == 1 ? found.first.map { entries[$0] } : nil
    }
}

extension LiveTVChannelLogoService {
    /// The team crest of each team named by each event, in title order (`nil` where no crest may be drawn): the team's Wikidata logo (P154)
    /// when its Commons file has an allowed licence. Leagues are looked up one at a time, and `publish` receives each league's crests as
    /// soon as they are known. Nothing is stored when Wikidata cannot answer, so the next run asks again.
    public func resolveCrests(
        _ events: [(key: LiveTVChannelLogoKey, event: LiveTVSportsEvent)],
        publish: @Sendable ([LiveTVChannelLogoKey: [URL?]]) async -> Void
    ) async {
        var byLeague: [LiveTVSportsLeague: [(key: LiveTVChannelLogoKey, event: LiveTVSportsEvent)]] = [:]
        for item in events where item.event.teams.count >= 2 { byLeague[item.event.league, default: []].append(item) }
        for league in byLeague.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if Task.isCancelled { return }
            let entries = await wikidata.teams(league: league.wikidataItem)
            guard !entries.isEmpty else { continue }
            let matcher = LiveTVSportsCrestMatcher(league: league, entries: entries)
            var allowed: [String: Bool] = [:]
            var result: [LiveTVChannelLogoKey: [URL?]] = [:]
            for item in byLeague[league] ?? [] {
                var crests: [URL?] = []
                for name in item.event.teams.prefix(2) {
                    guard let team = matcher.team(named: name) else { crests.append(nil); continue }
                    if allowed[team.file] == nil { allowed[team.file] = await wikidata.allowedLicence(forFile: team.file) != nil }
                    crests.append(allowed[team.file] == true ? WikidataLogoDirectory.imageURL(file: team.file) : nil)
                }
                if crests.contains(where: { $0 != nil }) { result[item.key] = crests }
            }
            if !result.isEmpty, !Task.isCancelled { await publish(result) }
        }
    }
}
