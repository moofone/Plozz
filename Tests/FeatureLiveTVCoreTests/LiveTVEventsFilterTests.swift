import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVEventsFilterTests: XCTestCase {
    private func channel(_ id: String, _ number: Int, _ name: String, group: String = "CA| NEWS") -> LiveTVPrototypeChannel {
        .init(id: id, number: number, name: name, category: group, symbol: "tv", accent: 0, source: .iptv,
              tagline: "", streamURL: URL(string: "https://example.test/\(id).m3u8"), groups: [group])
    }

    private func model() -> LiveTVPrototypeModel {
        let future = { (hours: Int) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date().addingTimeInterval(TimeInterval(hours) * 3_600))
        }
        return LiveTVPrototypeModel(channels: [
            channel("cbc", 1, "CA EN: CBC CALGARY HD"),
            channel("ppv-name", 2, "PPV Movies 1", group: "CA| MOVIES"),
            channel("idle-b", 11, "- NO EVENT STREAMING - | CA: SPORTSNET PPV 2", group: "CA| SPORTSNET PPV"),
            channel("late", 12, "(A 002) | Late Game (\(future(5)))", group: "CA| VICTORY+ PPV"),
            channel("idle-a", 10, ":TSN+  109", group: "CA| TSN+ PPV"),
            channel("soon", 13, "(A 001) | Soon Game (\(future(1)))", group: "CA| VICTORY+ PPV"),
            channel("pack", 14, "CA EN: ROGERS SUPER SPORTS PACK 1 HD", group: "CA| ROGERS SUPER SPORTS PACK EN")
        ])
    }

    func testAllChannelsCountsAndSearchExcludeEventSlots() {
        let model = model()
        XCTAssertEqual(model.visibleChannels.map(\.id), ["cbc", "ppv-name"])
        XCTAssertEqual(model.browseSummary.totalCount, 2)
        model.query = "game"
        XCTAssertTrue(model.visibleChannels.isEmpty, "Search never reaches event slots outside Events")
        model.query = "sportsnet"
        XCTAssertTrue(model.visibleChannels.isEmpty)
    }

    func testEventsFilterOrdersActiveByStartThenIdleSlots() {
        let model = model()
        model.category = LiveTVEventSlotClassifier.filterName
        XCTAssertTrue(model.showsEvents)
        XCTAssertEqual(model.visibleChannels.map(\.id), ["soon", "late"], "idle slots and bundles with no event are placeholders")
        XCTAssertEqual(model.activeEventCount, 2)
    }

    func testActiveSlotHasASyntheticThreeHourProgramme() throws {
        let model = model()
        let soon = try XCTUnwrap(model.channel(id: "soon"))
        let start = try XCTUnwrap(soon.eventSlot?.start)
        let programs = model.programs(for: "soon", from: start.addingTimeInterval(-3_600), hours: 6)
        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs.first?.title, "Soon Game")
        XCTAssertEqual(programs.first?.start, start)
        XCTAssertEqual(programs.first?.end, start.addingTimeInterval(3 * 3_600))
        XCTAssertTrue(model.programs(for: "idle-a", from: .now, hours: 6).isEmpty)
        XCTAssertTrue(model.programs(for: "soon", from: start.addingTimeInterval(4 * 3_600), hours: 1).isEmpty)
    }

    func testIdleSlotsCannotBePlayed() {
        let model = model()
        model.tune("idle-a")
        XCTAssertNil(model.playingChannelID)
        model.tune("soon")
        XCTAssertEqual(model.playingChannelID, "soon")
    }

    func testEventsSelectionIsNotPersistedAsACategory() {
        let model = model()
        model.category = LiveTVEventSlotClassifier.filterName
        model.resetFilters()
        XCTAssertFalse(model.showsEvents)
    }

    func testEventsFilterWithNoActiveEventsStillOpens() {
        let model = LiveTVPrototypeModel(channels: [
            channel("idle", 1, ":TSN+  109", group: "CA| TSN+ PPV"), channel("cbc", 2, "CBC")
        ])
        model.category = LiveTVEventSlotClassifier.filterName
        XCTAssertEqual(model.activeEventCount, 0)
        XCTAssertTrue(model.visibleChannels.isEmpty, "an idle slot is a placeholder and never listed")
    }

    func testChannelUpDownInEventsSkipsIdleSlotsAndWrapsWithinActiveEvents() {
        let model = model()
        model.category = LiveTVEventSlotClassifier.filterName
        let sequence = LiveTVChannelSequence(channels: model.visibleChannels)
        XCTAssertEqual(sequence.neighbor(of: "soon", offset: 1, visibleChannels: model.visibleChannels), "late")
        XCTAssertEqual(sequence.neighbor(of: "late", offset: 1, visibleChannels: model.visibleChannels), "soon",
                       "Wraps past idle-a, idle-b and pack back to the first active event")
        XCTAssertEqual(sequence.neighbor(of: "soon", offset: -1, visibleChannels: model.visibleChannels), "late")
        XCTAssertEqual(sequence.neighbor(of: "late", offset: -1, visibleChannels: model.visibleChannels), "soon")
    }

    func testChannelUpDownInEventsStaysPutWhenNoEventIsActive() {
        let model = LiveTVPrototypeModel(channels: [
            channel("idle-a", 1, ":TSN+  109", group: "CA| TSN+ PPV"),
            channel("idle-b", 2, ":Flo College  39", group: "CA| FLO PPV")
        ])
        model.category = LiveTVEventSlotClassifier.filterName
        let sequence = LiveTVChannelSequence(channels: model.visibleChannels)
        XCTAssertNil(sequence.neighbor(of: "idle-a", offset: 1, visibleChannels: model.visibleChannels))
        XCTAssertNil(sequence.neighbor(of: "idle-b", offset: -1, visibleChannels: model.visibleChannels))
        XCTAssertNil(sequence.neighbor(of: nil, offset: 1, visibleChannels: model.visibleChannels))
    }

    func testChannelUpDownOutsideEventsIsUnchangedForRegularChannels() {
        let model = model()
        let sequence = LiveTVChannelSequence(channels: model.visibleChannels)
        XCTAssertEqual(sequence.neighbor(of: "cbc", offset: 1, visibleChannels: model.visibleChannels), "ppv-name")
        XCTAssertEqual(sequence.neighbor(of: "cbc", offset: -1, visibleChannels: model.visibleChannels), "ppv-name")
    }

    private func sourceChannel(_ id: String, _ number: Int, _ name: String, source: String) -> LiveTVPrototypeChannel {
        .init(id: id, number: number, name: name, category: "CA| PPV", symbol: "tv", accent: 0, source: .iptv,
              tagline: "", streamURL: URL(string: "https://example.test/\(id).m3u8"), playlistSourceID: source,
              groups: ["CA| PPV"])
    }

    private func wallClock(_ stamp: String, in zone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: stamp)!
    }

    /// The stamps are upcoming (an ended event leaves the catalog); the title's `ET` clock agrees with the stamp in Eastern time.
    func testEachSourceReadsItsStampsInItsOwnInferredZone() throws {
        let eastern = TimeZone(identifier: "America/New_York")!
        let game = LiveTVEventStamp.upcoming(in: eastern, seconds: 15)
        var channels = (1...5).map {
            sourceChannel("east-\($0)", $0, "(A 00\($0)) | Game \($0) \(game.clock) ET (\(game.stamp))", source: "east")
        }
        channels.append(sourceChannel("viewer", 6, "(B 001) | Local Game (\(game.stamp))", source: "other"))
        let model = LiveTVPrototypeModel(channels: channels)
        XCTAssertEqual(
            try XCTUnwrap(model.channel(id: "east-1")?.eventSlot?.start), wallClock(game.stamp, in: eastern))
        XCTAssertEqual(
            try XCTUnwrap(model.channel(id: "viewer")?.eventSlot?.start), wallClock(game.stamp, in: .current),
            "A source with no zone evidence uses the viewer's zone")
    }

    func testSourceWithTooFewZoneNamesUsesTheViewersZone() throws {
        let game = LiveTVEventStamp.upcoming(in: TimeZone(identifier: "America/New_York")!, seconds: 15)
        let channels = (1...4).map {
            sourceChannel("e\($0)", $0, "(A 00\($0)) | Game \($0) \(game.clock) ET (\(game.stamp))", source: "few")
        }
        let model = LiveTVPrototypeModel(channels: channels)
        XCTAssertEqual(
            try XCTUnwrap(model.channel(id: "e1")?.eventSlot?.start), wallClock(game.stamp, in: .current))
    }
}
