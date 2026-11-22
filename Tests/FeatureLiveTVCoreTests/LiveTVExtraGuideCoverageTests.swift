import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Extra guides in the coverage log and in the Settings model.
@MainActor
final class LiveTVExtraGuideCoverageTests: XCTestCase {
    private func channel(_ id: String, _ name: String, group: String, guideID: String? = nil) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: group, symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: guideID, groups: [group])
    }

    func testExtraGuideOnlyCountsRowsTheProviderGuideHasNoListingsFor() {
        let rows = [
            channel("amc", "US: AMC HD", group: "US| ENTERTAINMENT"),
            channel("wgn", "US: ESPN HD", group: "US| ENTERTAINMENT"),
            channel("none", "US: Nothing Anywhere", group: "US| ENTERTAINMENT")
        ]
        let provider = ["AMC.us": ["AMC"]]
        let extra = ["AMC.us": ["AMC"], "ESPN.us": ["ESPN"]]
        let coverage = LiveTVGuideCoverage.measure(
            channels: rows, stations: provider, stationsWithListings: ["AMC.us"],
            extraStations: extra, extraStationsWithListings: ["AMC.us", "ESPN.us"]
        )
        XCTAssertEqual(coverage.matched, 2)
        XCTAssertEqual(coverage.sources["name"], 1, "AMC keeps the provider's match")
        XCTAssertEqual(coverage.extraGuideRows, 1, "Only ESPN comes from the extra guide")
        XCTAssertTrue(coverage.logLine.contains("name-foreign-feed:0,extra:1 channels="), coverage.logLine)
    }

    func testCoverageLineIsUnchangedWithoutAnExtraGuide() {
        let rows = [channel("amc", "US: AMC HD", group: "US| ENTERTAINMENT")]
        let coverage = LiveTVGuideCoverage.measure(channels: rows, stations: ["AMC.us": ["AMC"]])
        XCTAssertNil(coverage.extraGuideRows)
        XCTAssertTrue(coverage.logLine.contains("name-foreign-feed:0 channels="), coverage.logLine)
        XCTAssertFalse(coverage.logLine.contains("extra"))
    }

    func testExtraGuideStationWithoutListingsIsNoMatch() {
        let rows = [channel("wgn", "US: ESPN HD", group: "US| ENTERTAINMENT")]
        let coverage = LiveTVGuideCoverage.measure(
            channels: rows, stations: [:], extraStations: ["ESPN.us": ["ESPN"]], extraStationsWithListings: []
        )
        XCTAssertEqual(coverage.matched, 0)
        XCTAssertEqual(coverage.extraGuideRows, 0)
    }

    // MARK: Extra-guide name rules: the provider guide's own resolver, every guard kept

    private func extraFill(_ row: LiveTVPrototypeChannel, extra: [String: [String]]) -> Int? {
        LiveTVGuideCoverage.measure(
            channels: [row], stations: [:], extraStations: extra, extraStationsWithListings: Set(extra.keys)
        ).extraGuideRows
    }

    func testIdlessRowWithACallSignFillsFromTheExtraGuide() {
        let row = channel("wtxf", "US: FOX (WTXF) PHILADELPHIA HD", group: "US| LOCAL")
        XCTAssertEqual(extraFill(row, extra: ["WTXF.us": ["FOX (WTXF) Philadelphia, PA HD"]]), 1)
    }

    func testRowWhoseGuideIDContradictsItsNameIsNotFilledByThatStation() {
        let row = channel("wales", "UK: BBC ONE WALES 4K", group: "UK| ENTERTAINMENT", guideID: "BBCOneNorthWest.uk")
        XCTAssertEqual(extraFill(row, extra: ["BBCOneNorthWest.uk": ["BBC One North West"]]), 0)
    }

    func testNameTwoExtraStationsClaimFillsNothing() {
        let row = channel("sport", "US: SPORT", group: "US| SPORTS")
        XCTAssertEqual(extraFill(row, extra: ["Sport1.us": ["Sport"], "Sport2.us": ["Sport"]]), 0)
        XCTAssertEqual(extraFill(row, extra: ["Sport1.us": ["Sport"]]), 1, "the same name with one claimant does fill")
    }

    func testTimeShiftedAndWestRowsNeverTakeABaseStation() {
        let plusOne = channel("e4", "UK: E4 +1", group: "UK| ENTERTAINMENT")
        XCTAssertEqual(extraFill(plusOne, extra: ["E4.uk": ["E4"]]), 0)
        let west = channel("hbow", "US: HBO WEST HD", group: "US| MOVIES")
        XCTAssertEqual(extraFill(west, extra: ["HBO.us": ["HBO"]]), 0)
        let east = channel("hbo", "US: HBO HD", group: "US| MOVIES")
        XCTAssertEqual(extraFill(east, extra: ["HBO.us": ["HBO"]]), 1)
    }

    /// Skipped unless `PLOZZ_EXTRA_GUIDE_CHANNELS` (a lineup snapshot's `channels.jsonl`), `PLOZZ_EXTRA_GUIDE_PROVIDER` (its `guide.jsonl`),
    /// `PLOZZ_EXTRA_GUIDE_PROVIDER_LISTINGS` (its `guide-ids-with-programmes.txt`), `PLOZZ_EXTRA_GUIDE_STATIONS` (an extra guide's stations
    /// as `channel` records, one JSON per line) and `PLOZZ_EXTRA_GUIDE_LISTINGS` (its station ids with programmes) are set.
    /// Writes the coverage lines with and without the extra guide to `PLOZZ_EXTRA_GUIDE_REPORT`. Names only; nothing reads a URL.
    func testRealListFillFromAnExtraGuide() throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard let channelsPath = value("PLOZZ_EXTRA_GUIDE_CHANNELS"), let providerPath = value("PLOZZ_EXTRA_GUIDE_PROVIDER"),
              let providerListings = value("PLOZZ_EXTRA_GUIDE_PROVIDER_LISTINGS"), let extraPath = value("PLOZZ_EXTRA_GUIDE_STATIONS"),
              let extraListings = value("PLOZZ_EXTRA_GUIDE_LISTINGS") else {
            throw XCTSkip("Set the PLOZZ_EXTRA_GUIDE_* files to measure a real list.")
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
        func stations(_ path: String) throws -> [String: [String]] {
            var result: [String: [String]] = [:]
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "channel", let id = object["id"] as? String else { continue }
                result[id] = object["displayNames"] as? [String] ?? []
            }
            return result
        }
        func ids(_ path: String) throws -> Set<String> {
            Set(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init))
        }
        let kept = LiveTVLineupFilter.apply(.standard, to: rows).kept
        let provider = try stations(providerPath)
        let providerWith = try ids(providerListings)
        let alone = LiveTVGuideCoverage.measure(channels: kept, stations: provider, stationsWithListings: providerWith)
        let merged = LiveTVGuideCoverage.measure(
            channels: kept, stations: provider, stationsWithListings: providerWith,
            extraStations: try stations(extraPath), extraStationsWithListings: try ids(extraListings))
        var report = ["provider only\t" + alone.logLine, "with extra guide\t" + merged.logLine,
                      "extraFilled\t\(merged.extraGuideRows ?? 0)\tof unmatched\t\(alone.unmatched.count)"]
        var classifier = LiveTVLineupClassifier()
        var byCountry: [String: Int] = [:]
        for channel in alone.unmatched where !merged.unmatched.contains(where: { $0.id == channel.id }) {
            if case .country(let code) = classifier.placement(of: channel) { byCountry[code, default: 0] += 1 }
        }
        report.append("filledByCountry\t" + byCountry.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))
        if let out = value("PLOZZ_EXTRA_GUIDE_REPORT") { try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertGreaterThanOrEqual(merged.matched, alone.matched)
        XCTAssertGreaterThan(merged.linear, 0)
    }

    // MARK: Settings model

    func testModelAddsTrimmedWebAddressesAndRejectsBadDuplicateAndExcessEntries() throws {
        var saved: [String: [URL]] = ["iptv": []]
        let model = LiveTVExtraGuidesModel(
            load: { id in saved[id].map { $0.map { .init(url: $0) } } },
            save: { id, urls in saved[id] = urls }
        )
        XCTAssertNil(model.entries(accountID: "plex"), "Not an IPTV account")
        XCTAssertTrue(model.add(address: "  https://guide.example/guide.xml.gz \n", accountID: "iptv"))
        XCTAssertEqual(saved["iptv"], [try XCTUnwrap(URL(string: "https://guide.example/guide.xml.gz"))],
                       "http on a LAN address is accepted")
        XCTAssertFalse(model.add(address: "https://guide.example/guide.xml.gz", accountID: "iptv"))
        XCTAssertEqual(model.issue, .duplicate)
        for bad in ["", "guide.xml", "ftp://host/a.xml", "https://user:pw@host/a.xml"] {
            XCTAssertFalse(model.add(address: bad, accountID: "iptv"), bad)
            XCTAssertEqual(model.issue, .invalidAddress, bad)
        }
        XCTAssertEqual(saved["iptv"]?.count, 1)
        XCTAssertTrue(model.remove(try XCTUnwrap(saved["iptv"]?.first), accountID: "iptv"))
        XCTAssertEqual(saved["iptv"], [])
        for index in 0..<LiveTVExtraGuidesModel.maximumGuides {
            XCTAssertTrue(model.add(address: "https://example.test/\(index).xml", accountID: "iptv"))
        }
        XCTAssertFalse(model.add(address: "https://example.test/over.xml", accountID: "iptv"))
        XCTAssertEqual(model.issue, .tooMany)
    }

    func testModelKeepsListUnchangedAndReportsWhenSavingFails() {
        struct Failure: Error {}
        let model = LiveTVExtraGuidesModel(load: { _ in [] }, save: { _, _ in throw Failure() })
        XCTAssertFalse(model.add(address: "https://example.test/a.xml", accountID: "iptv"))
        XCTAssertEqual(model.issue, .couldNotSave)
    }
}
