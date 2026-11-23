import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Canadian identification and guide statistics over a real provider snapshot. Skipped unless `PLOZZ_COVERAGE_CHANNELS` (the
/// snapshot's `channels.jsonl`) and `PLOZZ_GUIDE_JSONL` (its saved guide) are set; `PLOZZ_CA_STATS_REPORT` receives a summary
/// and `PLOZZ_CA_STATS_ROWS` one line per Canadian row (names, groups and station ids only; nothing reads a URL).
@MainActor
final class LiveTVCanadaStatsTests: XCTestCase {
    private func value(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] ?? environment["TEST_RUNNER_" + key]
    }

    func testCanadianIdentificationAndGuideStatistics() throws {
        guard let channelsPath = value("PLOZZ_COVERAGE_CHANNELS"), let guidePath = value("PLOZZ_GUIDE_JSONL") else {
            throw XCTSkip("Set PLOZZ_COVERAGE_CHANNELS and PLOZZ_GUIDE_JSONL to measure a real list.")
        }
        var rows: [LiveTVPrototypeChannel] = []
        for line in try String(contentsOfFile: channelsPath, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["stableID"] as? String, let name = object["name"] as? String else { continue }
            let groups = object["groups"] as? [String] ?? []
            rows.append(LiveTVPrototypeChannel(
                id: id, number: 0, name: name, category: groups.first ?? "", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                guideID: object["epgID"] as? String, groups: groups))
        }
        var stations: [String: [String]] = [:]
        var listed = Set<String>()
        for line in try String(contentsOfFile: guidePath, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "channel", let id = object["id"] as? String { stations[id] = object["displayNames"] as? [String] ?? [] }
            if object["type"] as? String == "programme", let id = object["channel"] as? String { listed.insert(id) }
        }

        // Every row the classifier places in Canada, before and after the standard lineup filter.
        var classifier = LiveTVLineupClassifier()
        let canadian = rows.filter { LiveTVGuideStationIndex.country(of: $0, classifier: &classifier) == "CA" }
        let kept = LiveTVLineupFilter.apply(.standard, to: rows).kept
        let keptIDs = Set(kept.map(\.id))
        let coverage = LiveTVGuideCoverage.measure(channels: kept, stations: stations, stationsWithListings: listed)
        let linearIDs = Set(coverage.linearRows.map(\.id))
        let canadianKept = canadian.filter { keptIDs.contains($0.id) }
        let canadianLinear = canadian.filter { linearIDs.contains($0.id) }

        // Identification, read as the app reads a row.
        let model = LiveTVPrototypeModel(channels: canadianKept)
        let index = LiveTVGuideStationIndex(guideChannels: stations)
        let networkIDs = Set(LiveTVFilterTagCatalog.tags(in: .network).map(\.id))
        var withLanguage = 0, withRegion = 0, withNetwork = 0, withTags = 0
        var languages: [String: Int] = [:], kinds: [String: Int] = [:]
        var facts: [String: (display: String, language: String, region: String, network: String, kind: String)] = [:]
        for row in canadianKept {
            guard let named = model.channel(id: row.id) else { continue }
            let language = named.language ?? ""
            let region = LiveTVChannelRegion.region(for: row) ?? ""
            let network = LiveTVChannelTagIndex.storedTagIDs(of: named).filter(networkIDs.contains).sorted().joined(separator: " ")
            let kind = LiveTVChannelKind.classify(name: row.name, groups: row.categories, stations: index, country: "CA").rawValue
            if !language.isEmpty { withLanguage += 1 }
            if !region.isEmpty { withRegion += 1 }
            if !network.isEmpty { withNetwork += 1 }
            if !named.tags.isEmpty { withTags += 1 }
            languages[language.isEmpty ? "-" : language, default: 0] += 1
            kinds[kind, default: 0] += 1
            facts[row.id] = (named.name, language, region, network, kind)
        }

        // Guide: the provider's id trusted (as the full-lineup import matches), and by name only (as a window read does for a
        // guide the app does not count as the lineup's own).
        let readable = stations.filter { listed.contains($0.key) }
        let trusted = LiveTVGuideMatcher().matching(channels: canadianLinear, guideChannels: readable, trustsGuideIDs: true).assignments
        let untrusted = LiveTVGuideMatcher().matching(channels: canadianLinear, guideChannels: readable, trustsGuideIDs: false).assignments
        let withID = canadianLinear.filter { ($0.guideID ?? "").isEmpty == false }
        let idListed = withID.filter { listed.contains($0.guideID ?? "") }
        let lostWithoutTrust = canadianLinear.filter { trusted[$0.id] != nil && untrusted[$0.id] == nil }

        func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "-" : String(format: "%.1f%%", Double(part) * 100 / Double(whole)) }
        var report = [
            "snapshot rows\t\(rows.count)",
            "CA rows (classifier)\t\(canadian.count)",
            "CA rows kept by the standard lineup\t\(canadianKept.count)",
            "CA linear channels\t\(canadianLinear.count)",
            "",
            "identification (kept rows)",
            "  with language\t\(withLanguage)\t\(pct(withLanguage, canadianKept.count))",
            "  languages\t" + languages.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "),
            "  with region\t\(withRegion)\t\(pct(withRegion, canadianKept.count))",
            "  with network tag\t\(withNetwork)\t\(pct(withNetwork, canadianKept.count))",
            "  with badges/tags\t\(withTags)\t\(pct(withTags, canadianKept.count))",
            "  kinds\t" + kinds.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "),
            "",
            "guide (linear CA channels)",
            "  provider id present\t\(withID.count)\t\(pct(withID.count, canadianLinear.count))",
            "  provider id has listings\t\(idListed.count)\t\(pct(idListed.count, canadianLinear.count))",
            "  guide matched, ids trusted\t\(trusted.count)\t\(pct(trusted.count, canadianLinear.count))",
            "  guide matched, names only\t\(untrusted.count)\t\(pct(untrusted.count, canadianLinear.count))",
            "  matched only when ids are trusted\t\(lostWithoutTrust.count)",
            "  coverage line\t" + coverage.logLine
        ]
        for row in lostWithoutTrust.prefix(60) {
            let group = row.groups?.first ?? ""
            let station = trusted[row.id]?.guideChannelID ?? ""
            report.append("  only-trusted\t\(row.name)\t\(group)\t\(station)")
        }

        // The rows the guide shows around CBC Toronto in `CA| GENERAL EN`, matched as one batch as the app's window read does.
        let screen = ["CBC MONTREAL", "CBC NEWS NETWORK", "CBC OTTAWA", "CBC REGINA", "CBC ST. JOHN'S", "CBC TORONTO",
                      "CBC VANCOUVER", "CBC WINDSOR", "CBC WINNIPEG", "CBC YELLOWKNIFE", "CITYTV MONTREAL", "CITYTV TORONTO"]
        let batch = screen.compactMap { name in
            canadianKept.first { $0.groups?.first == "CA| GENERAL EN" && $0.name.uppercased().contains(name) }
        }
        let batchMatches = LiveTVGuideMatcher().matching(channels: batch, guideChannels: stations, trustsGuideIDs: true).assignments
        report.append("")
        report.append("screen batch (\(batch.count) rows, whole guide, ids trusted)")
        for row in batch {
            let station = batchMatches[row.id]?.guideChannelID ?? "-"
            let hasListings = listed.contains(station) ? "listed" : "no-listings"
            report.append("  \(row.name)\tepg=\(row.guideID ?? "-")\tstation=\(station)\t\(hasListings)")
        }
        let text = report.joined(separator: "\n")
        print("CA-STATS\n" + text)
        if let out = value("PLOZZ_CA_STATS_REPORT") { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        if let out = value("PLOZZ_CA_STATS_ROWS") {
            var lines = ["name\tgroup\tdisplay\tlanguage\tregion\tnetwork\tkind\tlinear\tepgID\ttrusted\tnamesOnly"]
            for row in canadianKept {
                let fact = facts[row.id]
                var cells: [String] = [row.name, row.groups?.first ?? ""]
                cells += [fact?.display ?? "", fact?.language ?? "", fact?.region ?? "", fact?.network ?? "", fact?.kind ?? ""]
                cells.append(linearIDs.contains(row.id) ? "1" : "0")
                cells.append(row.guideID ?? "")
                cells.append(trusted[row.id]?.guideChannelID ?? "")
                cells.append(untrusted[row.id]?.guideChannelID ?? "")
                lines.append(cells.joined(separator: "\t"))
            }
            try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(canadianLinear.count, 0)
        XCTAssertGreaterThanOrEqual(trusted.count, untrusted.count)
    }
}
