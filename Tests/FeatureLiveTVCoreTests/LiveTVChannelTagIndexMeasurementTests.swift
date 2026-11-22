import CoreModels
import Darwin
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// What the tag index adds to a catalogue build, on the provider export (`channels-ca-us-full.json`, 14,191 rows) and the same
/// rows repeated to the mockup's 56,761-channel subscription. Skipped unless `PLOZZ_MATCH_EXPORT` is set (export it as
/// `TEST_RUNNER_PLOZZ_MATCH_EXPORT` through `tools/run-tests.sh`). Lines `TAGINDEX …` are appended to the file named by `PLOZZ_TAG_INDEX_REPORT`.
@MainActor
final class LiveTVChannelTagIndexMeasurementTests: XCTestCase {
    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private func rows(_ path: String, repeating copies: Int) throws -> [LiveTVPrototypeChannel] {
        struct Row: Decodable { let name: String; let groups: [String]?; let number: Int }
        let decoded = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return (0..<copies).flatMap { copy in
            decoded.enumerated().map { index, row in
                LiveTVPrototypeChannel(
                    id: "e\(copy)-\(index)", number: copy * 100_000 + row.number, name: row.name, category: row.groups?.first ?? "Live",
                    symbol: "tv", accent: 0, source: .iptv, tagline: "", groups: row.groups)
            }
        }
    }

    func testTagIndexCostOnTheProviderExport() async throws {
        guard let path = environment("PLOZZ_MATCH_EXPORT") else { throw XCTSkip("Set PLOZZ_MATCH_EXPORT to measure.") }
        for copies in [1, 4] {
            let lineup = try rows(path, repeating: copies)
            // The whole background build (naming, organisation, categories, filtering, guide rows and the index), as the app runs it.
            let model = LiveTVPrototypeModel(channels: [])
            let clock = ContinuousClock()
            let whole = await clock.measure { await model.prepareCatalog(channels: lineup) }
            // The index alone, on the same named channels.
            try model.replaceChannels(lineup)
            let named = model.channels
            var best = Duration.seconds(100)
            var built = LiveTVChannelTagIndex.empty
            let before = residentBytes()
            for _ in 0..<5 {
                let t = clock.measure { built = LiveTVChannelTagIndex.build(channels: named, measuredResolution: { _ in nil }) }
                best = min(best, t)
            }
            let after = residentBytes()
            let entries = built.storedTagIDs.reduce(0) { $0 + built.count(ofStoredTag: $1) }
            let postingBytes = entries * MemoryLayout<Int32>.size
            let line = ("TAGINDEX channels=\(named.count) wholeBuild=\(whole) indexBest=\(best) tags=\(built.storedTagIDs.count) entries=\(entries) " +
                  "postingBytes=\(postingBytes) residentDelta=\(after - before)\n")
            if let report = environment("PLOZZ_TAG_INDEX_REPORT") {
                let handle = FileHandle(forWritingAtPath: report) ?? { FileManager.default.createFile(atPath: report, contents: nil); return FileHandle(forWritingAtPath: report)! }()
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try handle.close()
            }
            XCTAssertGreaterThan(entries, named.count / 2)
            XCTAssertLessThan(best, .seconds(5))
        }
    }
}
