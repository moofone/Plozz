import Foundation
import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// Measures team-crest coverage of the provider export's league events against live Wikidata/Commons. Skipped unless
/// `PLOZZ_CREST_EXPORT` (the provider export JSON) and `PLOZZ_CREST_REPORT` (Markdown output path) are set, as
/// `TEST_RUNNER_PLOZZ_…` through `tools/run-tests.sh`. It makes real requests, paced by the directory (one per 0.4 s here).
final class LiveTVSportsCrestCoverageReport: XCTestCase {
    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    func testCrestCoverageOnTheProviderExport() async throws {
        guard let exportPath = environment("PLOZZ_CREST_EXPORT"), let reportPath = environment("PLOZZ_CREST_REPORT") else {
            throw XCTSkip("Set PLOZZ_CREST_EXPORT and PLOZZ_CREST_REPORT to run the crest coverage measurement.")
        }
        let rows = try LiveTVLogoMatchEvaluator.loadRows(exportPath)
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("crest-coverage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let wikidata = WikidataLogoDirectory(
            fileURL: directoryURL.appendingPathComponent("wikidata.json"),
            sleep: { _ in try? await Task.sleep(for: .milliseconds(400)) })

        var events: [LiveTVSportsLeague: [LiveTVSportsEvent]] = [:]
        for row in rows where LiveTVChannelKind.isEvent(name: row.name, groups: row.groups) {
            if let event = LiveTVSportsEventParser.parse(row.name, groups: row.groups), event.teams.count >= 2 {
                events[event.league, default: []].append(event)
            }
        }

        var report = "# Team-crest coverage (Wikidata/Commons only)\n\nExport rows: \(rows.count). Two-team league events are counted; "
            + "a crest counts when the team matches exactly (name or alias within the league, ties unmatched) and its Commons file's licence is on the allow-list.\n\n"
            + "| League | Events | Teams on Wikidata with logo | Event team slots | Matched | Matched, licence allowed | Events with 2 crests | Events with ≥1 crest |\n|---|---|---|---|---|---|---|---|\n"
        var disallowed: [String] = []
        var unmatched: [String] = []
        for league in LiveTVSportsLeague.allCases {
            let list = events[league] ?? []
            guard !list.isEmpty else { report += "| \(league.rawValue) | 0 | – | – | – | – | – | – |\n"; continue }
            let entries = await wikidata.teams(league: league.wikidataItem)
            let matcher = LiveTVSportsCrestMatcher(league: league, entries: entries)
            var allowed: [String: String?] = [:]
            var slots = 0, matched = 0, drawable = 0, two = 0, any = 0
            var unmatchedCounts: [String: Int] = [:]
            var disallowedFiles: [String: (team: String, licence: String, count: Int)] = [:]
            for event in list {
                var drawn = 0
                for name in event.teams.prefix(2) {
                    slots += 1
                    guard let team = matcher.team(named: name) else { unmatchedCounts[name, default: 0] += 1; continue }
                    matched += 1
                    if allowed[team.file] == nil {
                        let licence = await wikidata.licence(forFile: team.file)
                        allowed[team.file] = licence.flatMap { WikidataLogoDirectory.isAllowed(licence: $0) ? $0 : nil }
                        if allowed[team.file]! == nil {
                            disallowedFiles[team.file] = (team.label, licence ?? "(none)", 0)
                        }
                    }
                    if allowed[team.file]! != nil { drawable += 1; drawn += 1 } else { disallowedFiles[team.file]?.count += 1 }
                }
                if drawn == 2 { two += 1 }
                if drawn >= 1 { any += 1 }
            }
            report += "| \(league.rawValue) | \(list.count) | \(entries.count) | \(slots) | \(matched) | \(drawable) | \(two) | \(any) |\n"
            for (file, info) in disallowedFiles.sorted(by: { $0.value.team < $1.value.team }) {
                disallowed.append("- \(league.rawValue): **\(info.team)** — `\(file)` — \(info.licence) (\(info.count) event slots)")
            }
            for (name, count) in unmatchedCounts.sorted(by: { $0.value > $1.value }).prefix(8) {
                unmatched.append("- \(league.rawValue): \(name) (\(count))")
            }
        }
        report += "\n## Teams whose Commons logo is under a disallowed (or missing) licence\n\n" + (disallowed.isEmpty ? "none\n" : disallowed.joined(separator: "\n") + "\n")
        report += "\n## Most frequent unmatched team names per league (no Wikidata team with a logo, or a tie)\n\n" + unmatched.joined(separator: "\n") + "\n"
        report += "\n## Every league's teams with a Wikidata logo: licence outcome (all files, not only teams in the export)\n\n"
        report += "| League | Teams with logo | Allowed | Disallowed or no licence | Alias-table clubs with no Wikidata logo (or a tie) |\n|---|---|---|---|---|\n"
        var allDisallowed: [String] = []
        for league in LiveTVSportsLeague.allCases where ![.ncaab, .ncaaf, .wta].contains(league) {
            let entries = await wikidata.teams(league: league.wikidataItem)
            var ok = 0
            for entry in entries {
                let licence = await wikidata.licence(forFile: entry.file)
                if licence.map(WikidataLogoDirectory.isAllowed(licence:)) == true { ok += 1 } else {
                    allDisallowed.append("- \(league.rawValue): **\(entry.label)** — `\(entry.file)` — \(licence ?? "(none)")")
                }
            }
            let matcher = LiveTVSportsCrestMatcher(league: league, entries: entries)
            let missing = Set(LiveTVSportsTeamAliases.table(for: league).values).filter { matcher.team(named: $0) == nil }.sorted()
            report += "| \(league.rawValue) | \(entries.count) | \(ok) | \(entries.count - ok) | \(missing.isEmpty ? "–" : missing.joined(separator: ", ")) |\n"
        }
        report += "\n### Disallowed or unlicensed logos\n\n" + (allDisallowed.isEmpty ? "none\n" : allDisallowed.joined(separator: "\n") + "\n")
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}
