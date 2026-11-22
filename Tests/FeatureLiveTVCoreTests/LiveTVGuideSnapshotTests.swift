import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// `-PlozzLiveTVMetadataAudit` also writes the raw input of the parsing (`LiveTVGuideSnapshot`, schema 1).
final class LiveTVGuideSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rows() -> [ServerLiveTVChannel] {
        [
            ServerLiveTVChannel(
                id: "n1", name: "UK: BBC One HD", number: "101", imageURL: URL(string: "https://logos.example/bbc.png?token=zzz"),
                groups: ["UK| ENTERTAINMENT"], guideID: "BBCOne.uk", guideName: "BBC One", guideCountry: "UK"),
            ServerLiveTVChannel(id: "n2", name: "DE: Das Erste", groups: ["DE| GERMANY"], guideID: "http://epg.example/id?key=abc"),
            ServerLiveTVChannel(id: "n3", name: "FR: Radio France", isRadio: true, groups: ["FR| RADIO"]),
            ServerLiveTVChannel(id: "n4", name: "http://user:secret@host.example/live/9.ts", groups: ["Link https://host.example/x?token=abc123"])
        ]
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testChannelsHoldEveryRowReadBeforeTheCutAndTheManifestCountsThem() throws {
        let file = directory.appendingPathComponent("audit.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audit = LiveTVLineupAudit(source: "server", file: file, snapshotDirectory: directory)
        let result = LiveTVLineupFilter.apply(.standard, to: rows(), audit: audit)
        XCTAssertLessThan(result.kept.count, 4, "the lineup cut some rows")
        let channels = try LiveTVGuideSnapshot.decodeLines(LiveTVGuideSnapshot.Channel.self, from: read(LiveTVGuideSnapshot.channelsFileName))
        XCTAssertEqual(channels.count, 4, "kept and dropped rows alike")
        let uk = try XCTUnwrap(channels.first { $0.name == "UK: BBC One HD" })
        XCTAssertEqual(uk.number, "101")
        XCTAssertEqual(uk.groups, ["UK| ENTERTAINMENT"])
        XCTAssertEqual(uk.epgID, "BBCOne.uk")
        XCTAssertEqual(uk.tvgName, "BBC One")
        XCTAssertEqual(uk.country, "UK")
        XCTAssertEqual(uk.kind, "linear")
        XCTAssertFalse(uk.isAdult)
        XCTAssertTrue(try XCTUnwrap(channels.first { $0.name == "FR: Radio France" }).isRadio)
        let manifest = try LiveTVGuideSnapshot.makeDecoder().decode(
            LiveTVGuideSnapshot.Manifest.self, from: Data(read(LiveTVGuideSnapshot.manifestFileName).utf8))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.sourceKind, "server")
        XCTAssertEqual(manifest.channelCount, 4)
    }

    func testGuideHoldsXMLTVChannelsAndTheNext48HoursOfProgrammes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func programme(_ id: String, hours: Double, title: String, art: String? = nil) -> LiveTVPrototypeProgram {
            LiveTVPrototypeProgram(
                id: id, channelID: "c1", title: title, subtitle: "Pilot", start: now.addingTimeInterval(hours * 3_600),
                end: now.addingTimeInterval((hours + 1) * 3_600),
                details: LiveTVProgramDetails(
                    description: "see http://x.example", episode: "S1E2", categories: ["News"], artworkURL: art.flatMap(URL.init(string:))))
        }
        let programmes = [
            programme("a", hours: 1, title: "Now soon", art: "https://img.example/a.jpg"), programme("b", hours: 47, title: "Late"),
            programme("c", hours: 49, title: "Too far"), programme("d", hours: -3, title: "Long over")
        ]
        LiveTVGuideSnapshotWriter.writeGuide(
            guideChannels: ["BBCOne.uk": ["BBC One", "BBC 1 http://x.example"]], programmes: programmes, now: now, directory: directory)
        let records = try LiveTVGuideSnapshot.decodeLines(LiveTVGuideSnapshot.GuideRecord.self, from: read(LiveTVGuideSnapshot.guideFileName))
        XCTAssertEqual(records.filter { $0.type == "channel" }.map(\.id), ["BBCOne.uk"])
        XCTAssertEqual(records.first { $0.type == "channel" }?.displayNames, ["BBC One", "BBC 1 [url]"])
        let shown = records.filter { $0.type == "programme" }
        XCTAssertEqual(shown.map(\.title), ["Now soon", "Late"], "only programmes starting in the 48 hours from now")
        XCTAssertEqual(shown[0].subTitle, "Pilot")
        XCTAssertEqual(shown[0].categories, ["News"])
        XCTAssertEqual(shown[0].episode, "S1E2")
        XCTAssertEqual(shown[0].channel, "c1")
        let manifest = try LiveTVGuideSnapshot.makeDecoder().decode(
            LiveTVGuideSnapshot.Manifest.self, from: Data(read(LiveTVGuideSnapshot.manifestFileName).utf8))
        XCTAssertEqual(manifest.programmeCount, 2)
        XCTAssertEqual(manifest.guideChannelCount, 1)
    }

    func testNoUrlTokenOrCredentialIsEverWritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let audit = LiveTVLineupAudit(source: "server", file: directory.appendingPathComponent("audit.jsonl"), snapshotDirectory: directory)
        _ = LiveTVLineupFilter.apply(.standard, to: rows(), audit: audit)
        LiveTVGuideSnapshotWriter.writeGuide(
            guideChannels: ["https://epg.example/c?token=1": ["www.example.com News"]],
            programmes: [LiveTVPrototypeProgram(
                id: "p", channelID: "https://host.example/live/1", title: "Show http://a.example", subtitle: "", start: now.addingTimeInterval(60),
                end: now.addingTimeInterval(3_600), details: LiveTVProgramDetails(artworkURL: URL(string: "https://img.example/x.jpg")))],
            now: now, directory: directory)
        for file in [LiveTVGuideSnapshot.channelsFileName, LiveTVGuideSnapshot.guideFileName, LiveTVGuideSnapshot.manifestFileName] {
            let text = try read(file).lowercased()
            for forbidden in ["http", "://", "secret", "token", "abc123", "key=abc", "host.example", "www.", ".example"] {
                XCTAssertFalse(text.contains(forbidden), "\(file) must not hold \(forbidden)")
            }
        }
    }

    func testOffUnlessTheLaunchArgumentIsSet() {
        XCTAssertNil(LiveTVGuideSnapshotWriter.launchDirectory(arguments: ["Plozz"]))
        XCTAssertNotNil(LiveTVGuideSnapshotWriter.launchDirectory(arguments: ["Plozz", "-PlozzLiveTVMetadataAudit"]))
    }
}
