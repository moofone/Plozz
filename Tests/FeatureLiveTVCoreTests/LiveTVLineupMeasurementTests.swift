import CoreModels
import Darwin
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// What Your Lineup saves at import, on the provider export (`channels-ca-us-full.json`, 14,191 rows, Canada and the United States only)
/// and the same rows repeated to the mockup's 56,761-row subscription. Skipped unless `PLOZZ_MATCH_EXPORT` is set (export it as
/// `TEST_RUNNER_PLOZZ_MATCH_EXPORT`). Lines `LINEUP …` are appended to the file named by `PLOZZ_LINEUP_REPORT`.
/// "before" is the whole list loaded (no lineup); "after" is `LiveTVLineup.standard` (the export holds no UK rows; other
/// countries are absent from it, so the saving here is the floor: a real subscription also drops every other country).
@MainActor
final class LiveTVLineupMeasurementTests: XCTestCase {
    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    private func resident() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    /// Copy 0 is the export. With `otherCountries`, copies 1… rewrite the two-letter country of every name and group prefix
    /// ("US|", "CA EN:") to DE, FR, IN… so the list has the shape of a many-country subscription (a synthetic stand-in: the
    /// export itself holds only Canada and the United States).
    private func rows(_ path: String, repeating copies: Int, otherCountries: Bool = false) throws -> [LiveTVPrototypeChannel] {
        struct Row: Decodable { let name: String; let groups: [String]?; let number: Int }
        let decoded = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let others = ["DE", "FR", "IN", "TR", "NL", "IT", "ES", "PL"]
        func recoded(_ text: String, _ copy: Int) -> String {
            guard otherCountries, copy > 0, text.count > 3 else { return text }
            let head = text.prefix(2)
            guard head.allSatisfy(\.isUppercase), [" ", ":", "|"].contains(text[text.index(text.startIndex, offsetBy: 2)]) else { return text }
            return others[(copy - 1) % others.count] + text.dropFirst(2)
        }
        return (0..<copies).flatMap { copy in
            decoded.enumerated().map { index, row in
                let groups = row.groups?.map { recoded($0, copy) }
                return LiveTVPrototypeChannel(
                    id: "e\(copy)-\(index)", number: copy * 100_000 + row.number, name: recoded(row.name, copy), category: groups?.first ?? "Live",
                    symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: groups)
            }
        }
    }

    func testLineupOnTheProviderExport() async throws {
        guard let path = environment("PLOZZ_MATCH_EXPORT") else { throw XCTSkip("Set PLOZZ_MATCH_EXPORT to measure.") }
        let clock = ContinuousClock()
        for (copies, synthetic) in [(1, false), (4, false), (4, true)] {
            let all = try rows(path, repeating: copies, otherCountries: synthetic)
            var result = LiveTVLineupFilter.apply(.standard, to: all)
            let filterTime = clock.measure { result = LiveTVLineupFilter.apply(.standard, to: all) }
            // Before/after through the import's next stages: the catalogue build (naming, tags, organisation, categories, rows).
            let before = LiveTVPrototypeModel(channels: [])
            let buildBefore = await clock.measure { await before.prepareCatalog(channels: all) }
            let after = LiveTVPrototypeModel(channels: [])
            let buildAfter = await clock.measure { await after.prepareCatalog(channels: result.kept) }
            try before.replaceChannels(all)
            try after.replaceChannels(result.kept)
            let memoryAll = resident()
            let top = result.inventory.codeCounts.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            let line = "LINEUP synthetic=\(synthetic) top=[\(top)] rows=\(all.count) kept=\(result.kept.count) leftOut=\(result.leftOut.count) filter=\(filterTime) " +
                "catalogueBefore=\(buildBefore) catalogueAfter=\(buildAfter) channelsBefore=\(before.channels.count) channelsAfter=\(after.channels.count) " +
                "residentAfterBoth=\(memoryAll) inventoryGroups=\(result.inventory.groups.count) places=\(result.inventory.codeCounts.count)\n"
            if let report = environment("PLOZZ_LINEUP_REPORT") {
                let handle = FileHandle(forWritingAtPath: report) ?? { FileManager.default.createFile(atPath: report, contents: nil); return FileHandle(forWritingAtPath: report)! }()
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try handle.close()
            }
            XCTAssertLessThan(result.kept.count, all.count)
            XCTAssertLessThan(filterTime, .seconds(5))
        }
    }
}
