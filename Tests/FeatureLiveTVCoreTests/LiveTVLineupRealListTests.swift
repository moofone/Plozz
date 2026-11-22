import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// The prefix table of a real provider list, by channel name. Skipped unless `PLOZZ_LINEUP_NAMES` names a tab-separated file of
/// `id<TAB>name` (export it as `TEST_RUNNER_PLOZZ_LINEUP_NAMES`); the table is written to `PLOZZ_LINEUP_REPORT`.
/// Also proves every country and region chip keeps exactly its counted rows when it alone is selected.
@MainActor
final class LiveTVLineupRealListTests: XCTestCase {
    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    func testEveryChipOfARealListKeepsItsCountedRowsAndThePrefixTableIsReported() throws {
        guard let path = environment("PLOZZ_LINEUP_NAMES") else { throw XCTSkip("Set PLOZZ_LINEUP_NAMES to run on a real list.") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let rows = text.split(separator: "\n").compactMap { line -> LiveTVPrototypeChannel? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return LiveTVPrototypeChannel(
                id: String(parts[0]), number: 0, name: String(parts[1]), category: "Live", symbol: "tv", accent: 0, source: .iptv, tagline: "")
        }
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        let state = LiveTVLineupState(store: nil)
        state.record(inventory: result.inventory, leftOut: [])
        var report = ["rows\t\(rows.count)\tkept\t\(result.kept.count)", "GB\t\(result.inventory.codeCounts["GB"] ?? 0)"]
        for (key, count) in result.summary.prefixCounts.sorted(by: { ($1.value, $0.key.prefix) < ($0.value, $1.key.prefix) }) {
            report.append("\(key.prefix)\t\(key.kind)\t\(count)")
        }
        let chips = state.sections().filter { $0.kind == .countries || $0.kind == .regions }.flatMap(\.chips)
        var failures: [String] = []
        for chip in chips {
            let only = LiveTVLineup(
                placeIDs: [chip.id], removedGroupIDs: Set(result.inventory.groups.map(\.id)), keepsFavouritesAndRecents: false,
                keepsLiveEvents: false, searchesLeftOut: false)
            let kept = LiveTVLineupFilter.apply(only, to: rows).kept.count
            report.append("chip\t\(chip.id)\t\(chip.title)\t\(chip.count)\t\(kept)")
            if kept == 0 || kept != chip.count { failures.append("\(chip.title) counts \(chip.count), keeps \(kept)") }
        }
        if let out = environment("PLOZZ_LINEUP_REPORT") { try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertGreaterThan(chips.count, 30)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
}
