import Foundation
@testable import MetadataKit
import XCTest
@testable import FeatureLiveTVCore

/// Offline evaluation of the logo layers against the provider's real lineup export (`LiveTVLogoMatchEvaluator`).
///
/// Skipped unless `PLOZZ_MATCH_EXPORT` (`channels-ca-us-full.json`) and `PLOZZ_TMDB_NETWORKS` (TMDB's keyless network export) are
/// set. Optional: `PLOZZ_TMDB_DETAILS` (origin country and logo of each proposed network), `PLOZZ_FILE_SIZES` (Commons raster pixel sizes), `PLOZZ_SHOW_LOGOS` (which 24/7 show titles
/// have a TMDB logo), `PLOZZ_WIKIDATA_SNAPSHOT` (country-keyed Wikidata bindings) and `PLOZZ_MATCH_REPORT` (Markdown output).
/// Run through `tools/run-tests.sh` with the variables exported as `TEST_RUNNER_PLOZZ_…`.
final class LiveTVLogoMatchEvaluationTests: XCTestCase {
    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    func testEvaluateLayersOnTheProviderExport() throws {
        guard let exportPath = environment("PLOZZ_MATCH_EXPORT"), let networksPath = environment("PLOZZ_TMDB_NETWORKS") else {
            throw XCTSkip("Set PLOZZ_MATCH_EXPORT and PLOZZ_TMDB_NETWORKS to run the evaluation.")
        }
        let rows = try LiveTVLogoMatchEvaluator.loadRows(exportPath)
        XCTAssertGreaterThan(rows.count, 10_000)
        var inputs = LiveTVLogoMatchEvaluator.Inputs(networks: try LiveTVLogoMatchEvaluator.loadNetworks(networksPath))
        XCTAssertGreaterThan(inputs.networks.count, 1_000)
        inputs.details = environment("PLOZZ_TMDB_DETAILS").flatMap(LiveTVLogoMatchEvaluator.loadDetails)
        inputs.showLogos = environment("PLOZZ_SHOW_LOGOS").map(LiveTVLogoMatchEvaluator.loadShowLogos) ?? [:]
        inputs.fileSizes = environment("PLOZZ_FILE_SIZES").map(LiveTVLogoMatchEvaluator.loadFileSizes) ?? [:]
        inputs.wikidata = environment("PLOZZ_WIKIDATA_SNAPSHOT").flatMap(LiveTVLogoMatchEvaluator.loadWikidata) ?? [:]

        let evaluation = LiveTVLogoMatchEvaluator.evaluate(rows: rows, inputs: inputs)
        let report = LiveTVLogoMatchEvaluator.report(evaluation, rowCount: rows.count)
        if let path = environment("PLOZZ_MATCH_REPORT") { try report.write(toFile: path, atomically: true, encoding: .utf8) }
        XCTAssertLessThan(evaluation.elapsed, .seconds(30), "matching 14,000 channels must stay interactive")
        XCTAssertFalse(evaluation.results.isEmpty)
        // No event or loop row may take a network logo: events are not channels and loops show a show's logo.
        for result in evaluation.results where result.kind == .event { XCTAssertEqual(result.layer, .event, result.row.name) }
    }

    /// A second provider: a local copy of the iptv-org public playlist (test data, never bundled). Skipped unless `PLOZZ_IPTV_ORG_M3U`
    /// and `PLOZZ_TMDB_NETWORKS` are set. `tvg-id` and `tvg-logo` are never matcher input; the `tvg-id` is read only to judge precision.
    func testEvaluateLayersOnTheIPTVOrgPlaylist() throws {
        guard let m3uPath = environment("PLOZZ_IPTV_ORG_M3U"), let networksPath = environment("PLOZZ_TMDB_NETWORKS") else {
            throw XCTSkip("Set PLOZZ_IPTV_ORG_M3U and PLOZZ_TMDB_NETWORKS to run the iptv-org evaluation.")
        }
        var inputs = LiveTVLogoMatchEvaluator.Inputs(networks: try LiveTVLogoMatchEvaluator.loadNetworks(networksPath))
        inputs.details = environment("PLOZZ_TMDB_DETAILS").flatMap(LiveTVLogoMatchEvaluator.loadDetails)
        inputs.wikidata = environment("PLOZZ_WIKIDATA_SNAPSHOT").flatMap(LiveTVLogoMatchEvaluator.loadWikidata) ?? [:]
        var report = "# iptv-org evaluation\n\n"
        for withCountry in [false, true] {
            let rows = try LiveTVIPTVOrgPlaylist.rows(path: m3uPath, withCountry: withCountry)
            XCTAssertGreaterThan(rows.count, 5_000)
            let evaluation = LiveTVLogoMatchEvaluator.evaluate(rows: rows, inputs: inputs)
            XCTAssertLessThan(evaluation.elapsed, .seconds(30), "matching 11,500 channels must stay interactive")
            report += LiveTVLogoMatchEvaluator.iptvReport(
                evaluation, label: withCountry ? "Country from the tvg-id suffix (upper bound)" : "No country given", peakMemoryMB: 0
            ) + "\n"
        }
        if let path = environment("PLOZZ_MATCH_REPORT") { try report.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
