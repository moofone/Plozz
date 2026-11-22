import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// `-PlozzLiveTVMetadataAudit` (DEBUG): one JSON line per row read, before the lineup cut.
final class LiveTVLineupAuditTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
    }

    private func rows() -> [ServerLiveTVChannel] {
        [
            ServerLiveTVChannel(id: "stream-9001", name: "UK: BBC One HD", number: "101", groups: ["UK| ENTERTAINMENT"]),
            ServerLiveTVChannel(id: "stream-9002", name: "AFR: Africa Info", groups: ["AFR| AFRICA VIP"]),
            ServerLiveTVChannel(id: "stream-9003", name: "http://user:secret@host.example/live/abc.ts", number: "7", groups: ["Link https://host.example/x?token=abc123"]),
            ServerLiveTVChannel(id: "stream-9004", name: "US: ESPN 4K", groups: ["US| SPORTS"]),
            ServerLiveTVChannel(id: "stream-9005", name: "DE: Das Erste", groups: ["DE| GERMANY"])
        ]
    }

    private func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testOneLinePerReadRowWithVerdictRuleAndTagsOfKeptRows() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = LiveTVLineupAudit(source: "iptv", file: url)
        _ = LiveTVLineupFilter.apply(.standard, to: rows(), audit: audit)
        let all = try lines(url)
        let header = try XCTUnwrap(all.first)
        XCTAssertEqual(header["read"] as? String, "iptv")
        XCTAssertEqual(header["rows"] as? Int, 5)
        let byName = Dictionary(uniqueKeysWithValues: all.dropFirst().compactMap { line in (line["name"] as? String).map { ($0, line) } })
        XCTAssertEqual(all.count, 6, "a header and one line per row read, kept or not")
        let uk = try XCTUnwrap(byName["UK: BBC One HD"])
        XCTAssertEqual(uk["group"] as? String, "UK| ENTERTAINMENT")
        XCTAssertEqual(uk["number"] as? String, "101")
        XCTAssertEqual(uk["country"] as? String, "GB")
        XCTAssertEqual(uk["verdict"] as? String, "kept")
        XCTAssertEqual(uk["reason"] as? String, "country")
        XCTAssertNotNil(uk["rule"] as? String)
        XCTAssertNotNil(uk["tags"] as? [String: Any], "kept rows carry their derived tags")
        let africa = try XCTUnwrap(byName["AFR: Africa Info"])
        XCTAssertEqual(africa["region"] as? String, "region.africa")
        XCTAssertEqual(africa["verdict"] as? String, "dropped")
        XCTAssertNil(africa["tags"])
        let espn = try XCTUnwrap(byName["US: ESPN 4K"])
        let tags = try XCTUnwrap(espn["tags"] as? [String: [String]])
        XCTAssertTrue(tags.values.joined().contains("4K"), "\(tags)")
        XCTAssertEqual(byName["DE: Das Erste"]?["verdict"] as? String, "dropped")
    }

    func testNeverWritesAUrlTokenOrStreamId() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = LiveTVLineupFilter.apply(.standard, to: rows(), audit: LiveTVLineupAudit(source: "iptv", file: url))
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        for forbidden in ["http", "://", "secret", "token", "abc123", "stream-900", "host.example", "www."] {
            XCTAssertFalse(text.contains(forbidden), "the audit file must not hold \(forbidden)")
        }
        XCTAssertTrue(text.contains("[url]"))
    }

    func testTheFileStopsAtItsCap() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let many = (0..<2000).map { ServerLiveTVChannel(id: "i\($0)", name: "US: Channel number \($0)", groups: ["US| NEWS"]) }
        _ = LiveTVLineupFilter.apply(.standard, to: many, audit: LiveTVLineupAudit(source: "iptv", file: url, byteCap: 20_000))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 20_000)
        XCTAssertGreaterThan(size, 5_000)
        let last = try XCTUnwrap(try lines(url).last)
        XCTAssertEqual(last["truncated"] as? Bool, true)
    }

    func testOffUnlessTheLaunchArgumentIsSet() {
        XCTAssertNil(LiveTVLineupAudit(source: "iptv", arguments: ["Plozz"]))
        XCTAssertNotNil(LiveTVLineupAudit(source: "iptv", arguments: ["Plozz", "-PlozzLiveTVMetadataAudit"]))
    }
}
