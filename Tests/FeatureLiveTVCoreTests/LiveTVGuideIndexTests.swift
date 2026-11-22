import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideIndexTests: XCTestCase {
    func testForegroundWaiterReceivesExistingFlightProgressAndParserStageTotals() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task {
            try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
                ServerLiveTVGuideProgress.report?(.init(stage: .downloading, completed: 50, total: 100))
                return try await download.get()
            }
        }
        await download.waitUntilStarted()
        let events = Mutex<[ServerLiveTVGuideProgress]>([])
        let second = Task {
            try await ServerLiveTVGuideProgress.$report.withValue({ value in events.withLock { $0.append(value) } }) {
                try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
                    XCTFail("Joining a guide must not download again.")
                    return try await download.get()
                }
            }
        }
        await index.waitForWaitersForTesting(2)
        XCTAssertEqual(events.withLock { $0.first }, .init(stage: .downloading, completed: 50, total: 100))
        await download.release()
        _ = try await first.value
        _ = try await second.value
        let progress = events.withLock { $0 }
        XCTAssertTrue(progress.contains(.init(stage: .readingGuide, completed: 2)))
        XCTAssertTrue(progress.contains(.init(stage: .preparingListings, completed: 2, total: 2)))
        XCTAssertEqual(progress.last?.stage, .saving)
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    private let url = URL(string: "https://fixture.test/guide.xml")!
    private let now = Date(timeIntervalSince1970: 100)
    private var range: DateInterval { DateInterval(start: now, duration: 400) }

    private func channel(_ id: String, guideID: String = "news", name: String = "News") -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: "Live TV", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", guideID: guideID
        )
    }

    private func document(title: String = "Bulletin", newsName: String = "News") -> Data {
        Data("""
        <tv><channel id="news"><display-name>\(newsName)</display-name></channel>
        <programme channel="news" start="19700101000140 +0000" stop="19700101000820 +0000">
        <title>\(title)</title><desc>Synopsis</desc></programme>
        <channel id="sport"><display-name>Sport</display-name></channel>
        <programme channel="sport" start="19700101000140 +0000" stop="19700101000820 +0000">
        <title>Match</title></programme></tv>
        """.utf8)
    }

    private func response(_ data: Data, expires: Date = .distantFuture, persists: Bool = true) -> XMLTVDownloadedDocument {
        .init(data: data, expiresAt: expires, permitsPersistence: persists)
    }

    private func httpMetadata(
        headers: [String: String] = ["ETag": "\"v1\""], status: Int = 200,
        previous: XMLTVGuideCacheMetadata? = nil, at time: Date? = nil
    ) throws -> XMLTVGuideCacheMetadata {
        try XMLTVGuideCacheMetadata(
            response: XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)),
            previous: previous, now: time ?? now
        )
    }

    private func httpDocument(
        _ metadata: XMLTVGuideCacheMetadata, title: String = "Bulletin", newsName: String = "News"
    ) -> XMLTVDownloadedDocument {
        .init(data: document(title: title, newsName: newsName), expiresAt: metadata.expiresAt,
              permitsPersistence: metadata.permitsPersistence, cacheMetadata: metadata)
    }

    func testSavedListingsAreReadWithoutADownloadAndNeverLapseByAge() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(
            cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { 3_600 }
        )
        let channels = [channel("a")]
        let nothingSaved = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertNil(nothingSaved)
        let saved = httpDocument(try httpMetadata())
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { saved }

        let stored = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertEqual(stored?.map(\.title), ["Bulletin"])
        let otherLineup = [channel("b", guideID: "sport", name: "Sport")]
        let mismatched = try await index.cachedPrograms(
            from: url, channels: otherLineup, range: range
        ) { otherLineup }
        XCTAssertNil(mismatched, "Listings indexed for another lineup cannot answer for this one")

        clock.withLock { $0 = now.addingTimeInterval(3_601) }
        let overdue = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertEqual(overdue?.map(\.title), ["Bulletin"], "Saved listings are final: reading them never waits on a server check")

        clock.withLock { $0 = now }
        await index.invalidate()
        let invalidated = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertNil(invalidated, "A requested refresh is not answered from the saved copy")
    }

    /// STARTUP-10S / owner policy: saved listings never expire on read. The chosen interval (and a lifetime the server
    /// stated) only decide when the scheduled update asks the server, never whether a screen can read the saved guide.
    func testChosenUpdateIntervalDecidesOnlyWhenTheScheduledUpdateChecksAgainNeverAForegroundRead() async throws {
        // (chosen interval, response headers, age before the check falls due, age after)
        let cases: [(TimeInterval?, [String: String], TimeInterval, TimeInterval)] = [
            (3_600, ["ETag": "\"v1\""], 3_599, 3_601),
            (86_400, ["ETag": "\"v1\""], 13 * 3_600, 86_401),
            (86_400, ["ETag": "\"v1\"", "Cache-Control": "max-age=3600"], 3_599, 86_401),
            (nil, ["ETag": "\"v1\""], 12 * 3_600 - 1, 12 * 3_600 + 1)
        ]
        for (interval, headers, earlyAge, lateAge) in cases {
            let fixture = try CacheFixture()
            defer { fixture.removeOwnedFiles() }
            let clock = Mutex(now)
            let index = LiveTVGuideIndex(
                cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { interval }
            )
            let channels = [channel("a")]
            let original = try httpMetadata(headers: headers)
            let saved = httpDocument(original)
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { saved }
            for age in [earlyAge, lateAge] {
                clock.withLock { $0 = now.addingTimeInterval(age) }
                let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
                    XCTFail("A foreground read never asks the server (age \(age), interval \(String(describing: interval)))")
                    throw URLError(.badServerResponse)
                }
                XCTAssertEqual(rows.map(\.title), ["Bulletin"])
            }
            let checked = now.addingTimeInterval(lateAge)
            let unchanged = try httpMetadata(headers: headers, status: 304, previous: original, at: checked)
            let attempts = Mutex(0)
            _ = try await index.updateSaved(from: url, catalog: { channels }) { _ in
                attempts.withLock { $0 += 1 }
                return .notModified(unchanged)
            }
            XCTAssertEqual(attempts.withLock { $0 }, interval == nil ? 0 : 1, "interval \(String(describing: interval))")
        }
    }

    func testAutomaticUpdateOnlyTouchesAGuideThatIsSavedAndDue() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let interval = Mutex<TimeInterval?>(3_600)
        let index = LiveTVGuideIndex(
            cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { interval.withLock { $0 } }
        )
        let channels = [channel("a")]
        let url = url
        let neverSaved = try await index.updateSaved(from: url, catalog: { channels }) { _ in
            XCTFail("A guide is never downloaded for the first time in the background")
            throw URLError(.badServerResponse)
        }
        XCTAssertNil(neverSaved)

        let original = try httpMetadata()
        let saved = httpDocument(original)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { saved }
        let notDue = try await index.updateSaved(from: url, catalog: {
            XCTFail("A guide that is not due is not even compared with the lineup")
            return channels
        }) { _ in
            XCTFail("A guide that is not due is left alone")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(notDue, original.checkedAt.addingTimeInterval(3_600))

        interval.withLock { $0 = nil }
        clock.withLock { $0 = now.addingTimeInterval(7_200) }
        let off = try await index.updateSaved(from: url, catalog: { channels }) { _ in
            XCTFail("Automatic updates are off")
            throw URLError(.badServerResponse)
        }
        XCTAssertNil(off)

        interval.withLock { $0 = 3_600 }
        let checked = now.addingTimeInterval(7_200)
        let unchanged = try httpMetadata(status: 304, previous: original, at: checked)
        let attempts = Mutex(0)
        let due = try await index.updateSaved(from: url, catalog: { channels }) { previous in
            XCTAssertEqual(previous, original)
            attempts.withLock { $0 += 1 }
            return .notModified(unchanged)
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertEqual(due, checked.addingTimeInterval(3_600))
    }

    func testManualRefreshBypassesOnlyTheDueGateOfASavedGuide() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let interval = Mutex<TimeInterval?>(3_600)
        let index = LiveTVGuideIndex(
            cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { interval.withLock { $0 } }
        )
        let channels = [channel("a")]
        let url = url
        let neverSaved = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            XCTFail("A guide that was never saved is not downloaded by a manual refresh")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(neverSaved, SavedGuideRefreshReport(nextDue: nil, transferredGuides: 0))

        let original = try httpMetadata()
        let firstDocument = httpDocument(original)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { firstDocument }
        // Not due: the scheduled trigger leaves it alone, the manual one asks the server once.
        let scheduled = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .scheduled) { _ in
            XCTFail("A guide that is not due is left alone by the timer")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(scheduled.transferredGuides, 0)
        let manualAt = now.addingTimeInterval(60)
        clock.withLock { $0 = manualAt }
        let attempts = Mutex(0)
        let confirmed = try httpMetadata(status: 304, previous: original, at: manualAt)
        let manual = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { previous in
            XCTAssertEqual(previous, original)
            attempts.withLock { $0 += 1 }
            return .notModified(confirmed)
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertEqual(manual, SavedGuideRefreshReport(nextDue: manualAt.addingTimeInterval(3_600), transferredGuides: 1))

        // Automatic updates off: the timer does nothing, a manual refresh still validates and reports no due date.
        interval.withLock { $0 = nil }
        clock.withLock { $0 = now.addingTimeInterval(7_200) }
        let off = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .scheduled) { _ in
            XCTFail("Automatic updates are off")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(off, SavedGuideRefreshReport(nextDue: nil, transferredGuides: 0))
        let offAt = now.addingTimeInterval(7_200)
        let offConfirmed = try httpMetadata(status: 304, previous: confirmed, at: offAt)
        let offManual = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { previous in
            attempts.withLock { $0 += 1 }
            XCTAssertEqual(previous, confirmed)
            return .notModified(offConfirmed)
        }
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(offManual, SavedGuideRefreshReport(nextDue: nil, transferredGuides: 1))
        XCTAssertNil(interval.withLock { $0 }, "A manual refresh never changes the interval")
    }

    func testCommittedInputsAreEmptyForUnchangedValidationAndNameThePersistedChangeOnce() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(
            cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { 3_600 }
        )
        let channels = [channel("a")]
        let url = url
        let original = try httpMetadata()
        let first = httpDocument(original)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { first }
        // The first foreground import is a committed input nobody has been told about yet: a not-due pass delivers it once.
        let seed = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .scheduled) { _ in
            XCTFail("Not due")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(seed.committedInputs.guideChanges.count, 1)

        // 304: nothing changed, and nothing is pending any more.
        clock.withLock { $0 = now.addingTimeInterval(60) }
        let confirmed = try httpMetadata(status: 304, previous: original, at: now.addingTimeInterval(60))
        let notModified = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            .notModified(confirmed)
        }
        XCTAssertEqual(notModified.transferredGuides, 1)
        XCTAssertTrue(notModified.committedInputs.isEmpty)

        // 200 with a byte-identical body: nothing changed.
        clock.withLock { $0 = now.addingTimeInterval(120) }
        let identicalDocument = httpDocument(
            try httpMetadata(headers: ["ETag": "\"v2\""], at: now.addingTimeInterval(120))
        )
        let identical = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            .document(identicalDocument)
        }
        XCTAssertEqual(identical.transferredGuides, 1)
        XCTAssertTrue(identical.committedInputs.isEmpty)

        // 200 with only a programme changed: reported with a new revision and no station change.
        clock.withLock { $0 = now.addingTimeInterval(180) }
        let programmeDocument = httpDocument(
            try httpMetadata(headers: ["ETag": "\"v3\""], at: now.addingTimeInterval(180)), title: "Late Bulletin"
        )
        let programme = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            .document(programmeDocument)
        }
        let programmeChange = try XCTUnwrap(programme.committedInputs.guideChanges.first)
        XCTAssertEqual(programme.committedInputs.guideChanges.count, 1)
        XCTAssertTrue(programmeChange.changedStationIDs.isEmpty)
        XCTAssertEqual(programmeChange.sourceKey, LiveTVGuideIndex.sourceID(url))
        XCTAssertFalse(programmeChange.sourceKey.contains("fixture"))

        // 200 with a renamed station: the station is named, and it is reported once.
        clock.withLock { $0 = now.addingTimeInterval(240) }
        let renamedMetadata = try httpMetadata(headers: ["ETag": "\"v4\""], at: now.addingTimeInterval(240))
        let renamedDocument = httpDocument(renamedMetadata, title: "Late Bulletin", newsName: "News HD")
        let renamed = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            .document(renamedDocument)
        }
        let renamedChange = try XCTUnwrap(renamed.committedInputs.guideChanges.first)
        XCTAssertEqual(renamedChange.changedStationIDs, ["news"])
        XCTAssertNotEqual(renamedChange.contentRevision, programmeChange.contentRevision)

        // A later unchanged validation reports nothing: the receipt is not replayed.
        clock.withLock { $0 = now.addingTimeInterval(300) }
        let again = try httpMetadata(status: 304, previous: renamedMetadata, at: now.addingTimeInterval(300))
        let replay = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
            .notModified(again)
        }
        XCTAssertTrue(replay.committedInputs.isEmpty)
    }

    func testFailedRefreshDoesNotReportAndForegroundImportIsReportedByTheNextRefresh() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(
            cache: fixture.cache, clock: { clock.withLock { $0 } }, updateInterval: { 3_600 }
        )
        let channels = [channel("a")]
        let url = url
        let original = try httpMetadata()
        let first = httpDocument(original)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { first }
        let firstChange = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .scheduled) { _ in
            XCTFail("Not due")
            throw URLError(.badServerResponse)
        }
        // The first foreground import is a committed input nobody has been told about yet.
        XCTAssertEqual(firstChange.committedInputs.guideChanges.count, 1)

        clock.withLock { $0 = now.addingTimeInterval(60) }
        do {
            _ = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { _ in
                throw URLError(.timedOut)
            }
            XCTFail("A failed refresh must not return a report")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }

        // A foreground request commits a changed guide; the scheduled gate then reports it without a transfer.
        clock.withLock { $0 = now.addingTimeInterval(120) }
        let changedMetadata = try httpMetadata(headers: ["ETag": "\"v2\""], at: now.addingTimeInterval(120))
        let changed = httpDocument(changedMetadata, newsName: "News HD")
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true) { _ in
            .document(changed)
        }
        let report = try await index.refreshSaved(from: url, catalog: { channels }, trigger: .scheduled) { _ in
            XCTFail("Not due")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(report.transferredGuides, 0)
        XCTAssertEqual(report.committedInputs.guideChanges.first?.changedStationIDs, ["news"])
    }

    func testTemporarilyEmptyFeedRetriesOnDemandAcrossRestorationAndRevalidation() async throws {
        for status in [200, 304] {
            for lifetime: TimeInterval in [30, 60] {
                try await verifyEmptyFeedRecovery(status: status, lifetime: lifetime)
            }
        }
    }

    private func verifyEmptyFeedRecovery(status: Int, lifetime: TimeInterval) async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let channels = [channel("a")]
        let headers = lifetime == 30 ? ["ETag": "\"v1\"", "Cache-Control": "max-age=30"] : ["ETag": "\"v1\""]
        let original = try httpMetadata(headers: headers)
        let empty = XMLTVDownloadedDocument(
            data: Data("<tv/>".utf8), expiresAt: original.expiresAt, permitsPersistence: true, cacheMetadata: original
        )
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { empty }
        let restored = LiveTVGuideIndex(cache: fixture.reopen(), clock: { clock.withLock { $0 } })
        clock.withLock { $0 = original.checkedAt.addingTimeInterval(lifetime - 1) }
        _ = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            XCTFail("Empty recovery is bounded, not a download on every navigation")
            throw URLError(.badServerResponse)
        }
        let checked = original.checkedAt.addingTimeInterval(lifetime)
        clock.withLock { $0 = checked }
        let unchanged = try httpMetadata(headers: headers, status: status, previous: original, at: checked)
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let attempts = Mutex(0)
        _ = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, original)
            attempts.withLock { $0 += 1 }
            return status == 304 ? .notModified(unchanged) : .document(.init(
                data: empty.data, expiresAt: unchanged.expiresAt, permitsPersistence: true, cacheMetadata: unchanged
            ))
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(before?.generation, after?.generation)
        clock.withLock { $0 = checked.addingTimeInterval(lifetime) }
        let updated = httpDocument(try httpMetadata(at: checked.addingTimeInterval(lifetime)))
        let rows = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, unchanged)
            return .document(updated)
        }
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
    }

    func testPopulatedFeedDoesNotRefetchEarlyForUnmatchedChannelsOrUnpopulatedWindows() async throws {
        let cases = [
            ([channel("missing", guideID: "missing", name: "Unmatched")], range),
            ([channel("a")], DateInterval(start: now.addingTimeInterval(2 * 86_400), duration: 400))
        ]
        for (channels, requestedRange) in cases {
            let fixture = try CacheFixture()
            defer { fixture.removeOwnedFiles() }
            let clock = Mutex(now)
            let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
            let metadata = try httpMetadata()
            let populated = httpDocument(metadata)
            let first = try await index.programs(from: url, catalog: channels, channels: channels, range: requestedRange) {
                populated
            }
            XCTAssertTrue(first.isEmpty)
            clock.withLock { $0 = metadata.checkedAt.addingTimeInterval(60) }
            let second = try await index.programs(from: url, catalog: channels, channels: channels, range: requestedRange) { _ in
                XCTFail("A populated feed is not due simply because this query has no matches")
                throw URLError(.badServerResponse)
            }
            XCTAssertTrue(second.isEmpty)
        }
    }

    func testRestoredIndexRevalidatesAtTwelveHoursWithoutRebuildingOrDownloadingWhileFresh() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let restored = LiveTVGuideIndex(cache: fixture.reopen(), clock: { clock.withLock { $0 } })
        clock.withLock { $0 = metadata.checkedAt.addingTimeInterval(43_199) }
        let fresh = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            XCTFail("Navigation and restored instances must reuse fresh parsed rows")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(fresh.map(\.title), ["Bulletin"])
        let checked = metadata.checkedAt.addingTimeInterval(43_200)
        clock.withLock { $0 = checked }
        let stale = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            XCTFail("A foreground read never revalidates a saved guide by age")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(stale, fresh)
        let updated = try httpMetadata(headers: ["ETag": "\"v2\""], status: 304, previous: metadata, at: checked)
        _ = try await restored.refreshSaved(from: url, catalog: { channels }, trigger: .manual) { prior in
            XCTAssertEqual(prior, metadata)
            return .notModified(updated)
        }
        let rows = stale
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(rows, fresh)
        XCTAssertEqual(before?.generation, after?.generation)
        XCTAssertEqual(after?.cacheMetadata, updated)
        XCTAssertEqual(after?.expiresAt, updated.expiresAt)
    }

    func testManualRefreshCanRevalidateFreshIndexAnd200ReplacesItsListingsAndValidators() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let time = now
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { time })
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        await index.invalidate()
        let updated = httpDocument(try httpMetadata(headers: ["ETag": "\"v2\""]), title: "New bulletin")
        let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, metadata)
            return .document(updated)
        }
        XCTAssertEqual(rows.map(\.title), ["New bulletin"])
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(state?.cacheMetadata?.etag, "\"v2\"")
    }

    func testIncompatibleProjectionOrWindowNeverSendsValidators() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = httpDocument(try httpMetadata())
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let expanded = channels + [channel("b", guideID: "sport", name: "Sport")]
        let rows = try await index.programs(from: url, catalog: expanded, channels: expanded, range: range) { previous in
            XCTAssertNil(previous)
            return .document(initial)
        }
        XCTAssertEqual(Set(rows.map(\.title)), ["Bulletin", "Match"])
        let future = DateInterval(start: now.addingTimeInterval(8 * 86_400), duration: 400)
        _ = try await index.programs(from: url, catalog: expanded, channels: expanded, range: future) { previous in
            XCTAssertNil(previous)
            return .document(initial)
        }
    }

    func test304WithoutEligibleRepresentationFailsInsteadOfPublishingEmptySuccess() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata(status: 304)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
                .notModified(metadata)
            }
            XCTFail("304 cannot stand in for missing rows")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidResponse) }
        let saved = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(saved)
    }

    func test304NoStoreRevokesIndexBeforeUnconditionalReplacement() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let noStore = try httpMetadata(headers: ["Cache-Control": "no-store"], status: 304, previous: metadata)
        let calls = Mutex(0)
        let cache = fixture.cache
        let url = url
        let rows = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
        ) { previous in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                XCTAssertNotNil(previous)
                return .notModified(noStore)
            }
            XCTAssertNil(previous)
            let saved = try await cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
            XCTAssertNil(saved)
            return .document(initial)
        }
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testFailedConditionalRequestPreservesSavedMetadataAndListingsButReportsFailure() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        let old = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let sourceID = LiveTVGuideIndex.sourceID(url)
        let saved = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let state = try XCTUnwrap(saved)
        do {
            _ = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
            ) { previous in
                XCTAssertEqual(previous, metadata)
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Stale rows must not mask a failed refresh")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let after = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let retained = try await fixture.cache.indexedAccountPrograms(
            sourceID: sourceID, sourceURL: url, generation: state.generation, channels: channels, range: range
        )
        XCTAssertEqual(after?.cacheMetadata, metadata)
        XCTAssertEqual(after?.expiresAt, state.expiresAt)
        XCTAssertEqual(retained, old)
    }

    func testCancelled304NoStoreStillRevokesPersistence() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let noStore = try httpMetadata(headers: ["Cache-Control": "no-store"], status: 304, previous: metadata)
        do {
            _ = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
            ) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .notModified(noStore)
            }
            XCTFail("Cancellation must not return stale success")
        } catch { XCTAssertTrue(error is CancellationError) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }

    func testCachedProgramsAnswerFromAValidatedIndexRegardlessOfAge() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        let channels = [channel("a"), channel("b", guideID: "sport", name: "Sport")]
        let lineupReads = Mutex(0)
        let unsaved = try await index.cachedPrograms(from: url, channels: channels, range: range) {
            lineupReads.withLock { $0 += 1 }
            return channels
        }
        XCTAssertNil(unsaved, "Nothing is saved yet; only a loading source can answer.")
        XCTAssertEqual(lineupReads.withLock { $0 }, 0, "A miss must not cost a read of the whole lineup.")
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: [channels[0]], range: range) { initial }

        let restored = LiveTVGuideIndex(cache: fixture.reopen(), clock: { clock.withLock { $0 } })
        let saved = try await restored.cachedPrograms(from: url, channels: [channels[1]], range: range) {
            channels.reversed()
        }
        XCTAssertEqual(saved?.map(\.title), ["Match"], "Another batch reads the saved rows without a download.")
        let otherLineup = try await restored.cachedPrograms(from: url, channels: [channels[0]], range: range) {
            [channels[0]]
        }
        XCTAssertNil(otherLineup, "Rows indexed for another lineup cannot answer.")

        clock.withLock { $0 = metadata.checkedAt.addingTimeInterval(43_200) }
        let aged = try await restored.cachedPrograms(from: url, channels: channels, range: range) {
            lineupReads.withLock { $0 += 1 }
            return channels
        }
        XCTAssertEqual(aged?.map(\.title).sorted(), ["Bulletin", "Match"])

        clock.withLock { $0 = now }
        await restored.invalidate()
        let refreshed = try await restored.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertNil(refreshed, "An explicit refresh must reach the provider before saved rows are trusted.")
        _ = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            .document(initial)
        }
        let validated = try await restored.cachedPrograms(from: url, channels: channels, range: range) { channels }
        XCTAssertEqual(validated?.map(\.title).sorted(), ["Bulletin", "Match"])
    }

    func testCachedBatchesValidateLargeLineupOncePerCommittedRevision() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let now = now
        let download = response(document())
        let channels = [channel("a"), channel("b", guideID: "sport", name: "Sport")]
        let catalog = channels + (0..<19_998).map {
            channel("extra-\($0)", guideID: "extra-\($0)", name: "Channel \($0)")
        }
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { now })
        _ = try await index.programs(from: url, catalog: catalog, channels: channels, range: range) {
            download
        }
        let decodesBefore = await fixture.cache.guideDocumentDecodesForTesting
        let uncachedReads = Mutex(0)
        let revisionReads = Mutex(0)
        for batch in 0..<5 {
            let requested = [channels[batch % channels.count]]
            let expected = try await index.cachedPrograms(from: url, channels: requested, range: range) {
                uncachedReads.withLock { $0 += 1 }
                return catalog
            }
            let actual = try await index.cachedPrograms(
                from: url, channels: requested, range: range, catalogRevision: "committed-1"
            ) {
                revisionReads.withLock { $0 += 1 }
                return catalog
            }
            XCTAssertFalse(try XCTUnwrap(actual).isEmpty)
            XCTAssertEqual(actual, expected)
        }
        XCTAssertEqual(uncachedReads.withLock { $0 }, 5)
        XCTAssertEqual(revisionReads.withLock { $0 }, 1)
        let decodesAfter = await fixture.cache.guideDocumentDecodesForTesting
        XCTAssertEqual(decodesAfter, decodesBefore, "Repeat lookup must reuse the decoded station document")

        let changed = try await index.cachedPrograms(
            from: url, channels: channels, range: range, catalogRevision: "committed-2"
        ) {
            revisionReads.withLock { $0 += 1 }
            return [channels[0]]
        }
        XCTAssertNil(changed, "A different committed lineup cannot reuse the previous projection.")
        XCTAssertEqual(revisionReads.withLock { $0 }, 2)

        await index.invalidate()
        _ = try await index.programs(from: url, catalog: catalog, channels: channels, range: range) {
            download
        }
        _ = try await index.cachedPrograms(
            from: url, channels: channels, range: range, catalogRevision: "committed-1"
        ) {
            revisionReads.withLock { $0 += 1 }
            return catalog
        }
        XCTAssertEqual(revisionReads.withLock { $0 }, 3)
    }

    func testDifferentBatchesReuseOneIndexAndRestoreAcrossInstances() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", guideID: "sport", name: "Sport")]
        let download = DownloadCounter(response(document()))
        let first = try await index.programs(
            from: url, catalog: channels, channels: [channels[0]], range: range, download: { await download.get() }
        )
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let reopened = LiveTVGuideIndex(cache: fixture.reopen())
        let second = try await reopened.programs(
            from: url, catalog: channels.reversed(), channels: [channels[1]], range: range,
            download: { await download.get() }
        )
        let current = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(first.map(\.title), ["Bulletin"])
        XCTAssertEqual(second.map(\.title), ["Match"])
        XCTAssertEqual(state?.generation, current?.generation)
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testMatchingAndAiringIdentityEqualLegacyForDifferentRequestSubsets() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", name: "Different station"), channel("c", guideID: "sport", name: "Sport")]
        let data = document()
        let response = response(data)
        for requested in [[channels[0]], [channels[1]], Array(channels.prefix(2)), channels] {
            let actual = try await index.programs(
                from: url, catalog: channels, channels: requested, range: range, download: { response }
            )
            let expected = try LiveTVXMLTVParser().parseXML(data: data, channels: requested, now: now)
                .programs.filter { $0.start < range.end && $0.end > range.start }
            XCTAssertEqual(Set(actual.map(\.id)), Set(expected.map(\.id)))
            XCTAssertEqual(Set(actual.map(\.channelID)), Set(expected.map(\.channelID)))
        }
    }

    func testNameMatchingPriorityUsesRequestedSetNotFullCatalog() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("exact", guideID: "news.us"), channel("name", guideID: "NEWS.us")]
        let data = Data("""
        <tv><channel id="news.us"><display-name>News</display-name></channel>
        <programme channel="news.us" start="19700101000140" stop="19700101000820"><title>News</title></programme></tv>
        """.utf8)
        let response = response(data)
        for requested in [[channels[0]], [channels[1]], channels] {
            let actual = try await index.programs(
                from: url, catalog: channels, channels: requested, range: range, download: { response }
            )
            let expected = try LiveTVXMLTVParser().parseXML(data: data, channels: requested, now: now)
            XCTAssertEqual(Set(actual.map(\.id)), Set(expected.programs.map(\.id)))
        }

    }

    func testAccountQueryDoesNotTruncateAtUIWindowLimit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = (0..<1_000).map { channel("variant-\($0)") }
        let programmes = (0..<25).map {
            "<programme channel=\"news\" start=\"19700101000140\" stop=\"19700101000820\"><title>Show \($0)</title></programme>"
        }.joined()
        let body = response(Data(("<tv>" + programmes + "</tv>").utf8))
        let rows = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { body }
        )
        XCTAssertEqual(rows.count, 25_000)
        XCTAssertEqual(Set(rows.map(\.channelID)), Set(channels.map(\.id)))
    }

    func testLanguageChangeRebuildsLocalizedIndex() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        let body = response(Data("""
        <tv><programme channel="news" start="19700101000140" stop="19700101000820">
        <title lang="en">English</title><title lang="fr">French</title></programme></tv>
        """.utf8))
        let english = LiveTVGuideIndex(cache: fixture.cache, preferredLanguage: "en")
        let first = try await english.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
        let french = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: "fr")
        let second = try await french.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
        XCTAssertEqual(first.map(\.title), ["English"])
        XCTAssertEqual(second.map(\.title), ["French"])
    }

    func testValidEmptyGuideIsReusableWithoutInventingListings() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let download = DownloadCounter(response(Data("<tv/>".utf8)))
        for _ in 0..<2 {
            let rows = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, download: { await download.get() }
            )
            XCTAssertTrue(rows.isEmpty)
        }
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testPreviousParserEmptyIndexIsRebuiltForShortenedDates() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        let data = Data("""
        <tv><programme channel="news" start="19700101" stop="1970010101"><title>Recovered listing</title></programme></tv>
        """.utf8)
        // Reproduce the pre-versioned projection and an empty, unexpired index
        // left by the old parser after it skipped these valid timestamps.
        var legacy = SHA256()
        legacy.update(data: try JSONEncoder().encode(["account-xmltv-stations-v1", nil] as [String?]))
        for channel in channels {
            legacy.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        let oldState = LiveTVGuideIndexState(
            generation: UUID(), projection: hex(legacy.finalize()), digest: hex(SHA256.hash(data: data)),
            lowerBound: .distantPast, upperBound: .distantFuture, expiresAt: .distantFuture
        )
        _ = try await fixture.cache.importGuide(
            data: Data("<tv/>".utf8), sourceID: LiveTVGuideIndex.sourceID(url), channels: channels,
            provider: nil, now: now, sourceURL: url, preferredLanguage: nil, indexState: oldState
        )
        let index = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let download = DownloadCounter(response(data))
        let programs = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { await download.get() }
        )
        XCTAssertEqual(programs.map(\.title), ["Recovered listing"])
        XCTAssertEqual(programs.first?.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(programs.first?.end, Date(timeIntervalSince1970: 3_600))
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    /// The stations a saved guide retains come from the matcher's rules, so a guide saved under other rules is read again once
    /// (a parent had to delete the cache by hand to see call-sign matches).
    func testAGuideSavedUnderOtherMatcherRulesIsIndexedAgainOnce() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        let data = Data("""
        <tv><programme channel="news" start="19700101" stop="1970010101"><title>Listing</title></programme></tv>
        """.utf8)
        func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        func projection(rules: String) throws -> String {
            var hasher = SHA256()
            hasher.update(data: try JSONEncoder().encode([
                "account-xmltv-stations-v3", String(LiveTVXMLTVParser.cacheVersion), rules, nil
            ] as [String?]))
            for channel in channels {
                hasher.update(data: try JSONEncoder().encode(
                    [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
                ))
            }
            return hex(hasher.finalize())
        }
        func save(rules: String, into cache: LiveTVIndexedCache) async throws {
            let state = LiveTVGuideIndexState(
                generation: UUID(), projection: try projection(rules: rules), digest: hex(SHA256.hash(data: Data("<tv/>".utf8))),
                lowerBound: .distantPast, upperBound: .distantFuture, expiresAt: .distantFuture
            )
            _ = try await cache.importGuide(
                data: Data("<tv/>".utf8), sourceID: LiveTVGuideIndex.sourceID(url), channels: channels,
                provider: nil, now: now, sourceURL: url, preferredLanguage: nil, indexState: state
            )
        }
        let current = LiveTVGuideStationIndex.rulesFingerprint
        try await save(rules: current, into: fixture.cache)
        let reused = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let unchanged = DownloadCounter(response(data))
        _ = try await reused.programs(from: url, catalog: channels, channels: channels, range: range, download: { await unchanged.get() })
        let unchangedCount = await unchanged.count
        XCTAssertEqual(unchangedCount, 0, "A guide saved under the current rules is reused")

        try await save(rules: "an-older-rules-version", into: fixture.cache)
        let stale = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let changed = DownloadCounter(response(data))
        let rows = try await stale.programs(from: url, catalog: channels, channels: channels, range: range, download: { await changed.get() })
        XCTAssertEqual(rows.map(\.title), ["Listing"])
        let changedCount = await changed.count
        XCTAssertEqual(changedCount, 1, "A guide saved under other rules is downloaded and indexed again")
        let again = DownloadCounter(response(data))
        _ = try await stale.programs(from: url, catalog: channels, channels: channels, range: range, download: { await again.get() })
        let againCount = await again.count
        XCTAssertEqual(againCount, 0, "…and only once")
    }

    /// STARTUP-10S: a saved guide for the SAME lineup that was indexed under older matcher rules still answers at once; the
    /// current index is built behind the read, once. A guide saved for another lineup is never answered from.
    func testAGuideSavedUnderOlderRulesAnswersAtOnceWhileTheCurrentIndexIsBuiltInTheBackground() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        func saveUnderOlderRules(_ title: String, lineup: [LiveTVPrototypeChannel]) async throws {
            let data = Data("""
            <tv><programme channel="news" start="19700101000140" stop="19700101000820"><title>\(title)</title></programme></tv>
            """.utf8)
            let state = LiveTVGuideIndexState(
                generation: UUID(), projection: "projection-of-older-rules",
                lineupKey: try LiveTVGuideIndex.lineupKey(lineup, language: nil), digest: hex(SHA256.hash(data: data)),
                lowerBound: .distantPast, upperBound: .distantFuture, expiresAt: .distantFuture
            )
            _ = try await fixture.cache.importGuide(
                data: data, sourceID: LiveTVGuideIndex.sourceID(url), channels: lineup,
                provider: nil, now: now, sourceURL: url, preferredLanguage: nil, indexState: state
            )
        }
        try await saveUnderOlderRules("Saved", lineup: channels)
        let current = Data("""
        <tv><programme channel="news" start="19700101000140" stop="19700101000820"><title>Current</title></programme></tv>
        """.utf8)
        let currentDocument = response(current)
        let release = Mutex(false)
        let downloads = Mutex(0)
        let index = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let served = try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
            downloads.withLock { $0 += 1 }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            return currentDocument
        }
        XCTAssertEqual(served.map(\.title), ["Saved"], "the older index answers without waiting for the download")
        release.withLock { $0 = true }
        await index.waitForReindexForTesting()
        XCTAssertEqual(downloads.withLock { $0 }, 1, "the current index is built once, behind the read")
        let after = try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
            XCTFail("indexed under the current rules: no further download")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(after.map(\.title), ["Current"])

        // Another lineup: the older index says nothing about the new channels, so nothing is answered from it.
        try await saveUnderOlderRules("Saved", lineup: channels)
        let changed = channels + [channel("b", guideID: "sport", name: "Sport")]
        let other = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let counter = DownloadCounter(currentDocument)
        let rows = try await other.programs(from: url, catalog: changed, channels: changed, range: range) { await counter.get() }
        XCTAssertEqual(rows.map(\.title), ["Current"])
        let count = await counter.count
        XCTAssertEqual(count, 1, "a changed lineup is indexed before it answers")
    }

    func testIndexedQueryEnforcesLanguageEpisodeAndRatingTextBudget() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = (0..<1_000).map { channel("variant-\($0)") }
        let text = String(repeating: "x", count: 16_384)
        let data = Data("""
        <tv><programme channel="news" start="19700101000140" stop="19700101000820">
        <title>News</title><language>\(text)</language><episode-num>\(text)</episode-num>
        <rating><value>\(text)</value></rating></programme></tv>
        """.utf8)
        let body = response(data)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
            XCTFail("All retained programme text must count toward the output budget.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .guideTooLarge) }
        do {
            _ = try await index.cachedPrograms(from: url, channels: channels, range: range) { channels }
            XCTFail("Saved reads must enforce the same text budget")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .guideTooLarge) }
    }

    func testQueuedDifferentSourceCanCancelWithoutWaitingForCurrentImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let otherURL = try XCTUnwrap(URL(string: "https://fixture.test/other.xml"))
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await download.waitUntilStarted()
        let second = Task { try await index.programs(
            from: otherURL, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await index.waitForAdmissionForTesting()
        second.cancel()
        do { _ = try await second.value; XCTFail("Queued consumer must cancel promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await download.release()
        let rows = try await first.value
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testExplicitlyRevalidatingUnchangedBodyKeepsGeneration() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let download = DownloadCounter(response(document(), expires: .distantPast))
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { await download.get() })
        let first = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        _ = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
        ) { _ in .document(await download.get()) }
        let second = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let count = await download.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(first?.generation, second?.generation)
    }

    func testFailedReplacementKeepsCommittedRowsAndDoesNotAdvanceFreshness() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document(), expires: .distantPast)
        let old = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        let sourceID = LiveTVGuideIndex.sourceID(url)
        let saved = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let state = try XCTUnwrap(saved)
        let invalid = response(Data("<tv><programme".utf8))
        do {
            _ = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
            ) { _ in .document(invalid) }
            XCTFail("Malformed replacement must fail.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        let current = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let retained = try await fixture.cache.indexedAccountPrograms(
            sourceID: sourceID, sourceURL: url, generation: state.generation, channels: channels, range: range
        )
        XCTAssertEqual(state.generation, current?.generation)
        XCTAssertEqual(state.expiresAt, current?.expiresAt)
        XCTAssertEqual(retained, old)
    }

    func testNoStoreRevokesPersistedRowsEvenWhenReplacementIsMalformed() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document(), expires: .distantPast)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        let invalid = response(Data("<tv>".utf8), persists: false)
        do {
            _ = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, trustsGuideIDs: false, forcing: true
            ) { _ in .document(invalid) }
            XCTFail("Invalid no-store body must fail.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }

    func testNoStoreNeverCreatesAnIndexAndUsesRequestedChannelsOnly() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", name: "Different station")]
        let download = DownloadCounter(response(document(), persists: false))
        for requested in channels {
            let rows = try await index.programs(
                from: url, catalog: channels, channels: [requested], range: range, download: { await download.get() }
            )
            XCTAssertEqual(rows.map(\.channelID), [requested.id])
        }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let count = await download.count
        XCTAssertNil(state)
        XCTAssertEqual(count, 2)
    }

    func testManualInvalidationBypassesFreshnessAndTeardownRejectsAdmission() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document())
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        await index.invalidate()
        let updated = response(document(title: "Updated"))
        let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { updated })
        XCTAssertEqual(rows.map(\.title), ["Updated"])
        await index.cancel()
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
            XCTFail("Closed index must reject work.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRenamingOrAddingChannelsWithoutAGuideIDKeepsTheSavedGuide() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        func event(_ id: String, _ name: String) -> LiveTVPrototypeChannel {
            LiveTVPrototypeChannel(
                id: id, number: 0, name: name, category: "Live TV", symbol: "tv",
                accent: 0, source: .iptv, tagline: "", guideID: nil
            )
        }
        let download = DownloadCounter(response(document()))
        let morning = [channel("a"), event("e1", "NEXT | Final | 19:45")]
        _ = try await index.programs(from: url, catalog: morning, channels: morning, range: range, download: { await download.get() })
        let evening = [channel("a"), event("e1", "NO EVENT STREAMING"), event("e2", "LIVE | Replay")]
        let rows = try await index.programs(from: url, catalog: evening, channels: evening, range: range, download: { await download.get() })
        XCTAssertEqual(rows.map(\.channelID), ["a"])
        var count = await download.count
        XCTAssertEqual(count, 1, "Event channels cannot have listings, so they must not force a download")
        let cached = try await index.cachedPrograms(from: url, channels: [evening[0]], range: range) {
            [evening[0]]
        }
        XCTAssertEqual(cached, rows, "Whole lineup and guided subset have the same v2 projection")

        let renamed = [channel("a", name: "News HD")] + evening.dropFirst()
        _ = try await index.programs(from: url, catalog: renamed, channels: renamed, range: range, download: { await download.get() })
        count = await download.count
        XCTAssertEqual(count, 2, "A change to a channel that has a guide ID still rebuilds")
    }

    func testAccountGuideFindsListingsFiledUnderAnotherSpellingOfTheGuideIDOnce() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        func show(_ station: String, _ title: String) -> String {
            "<programme channel=\"\(station)\" start=\"19700101000140 +0000\" stop=\"19700101000820 +0000\"><title>\(title)</title></programme>"
        }
        // "Alibi.uk" is declared twice with listings under one spelling only; "bbc1.uk" has
        // listings under both.
        let xml = Data(("<tv><channel id=\"Alibi.uk\"><display-name>Alibi</display-name></channel>"
            + "<channel id=\"alibi.uk\"><display-name>Alibi</display-name></channel>"
            + "<channel id=\"BBC1.uk\"><display-name>BBC One</display-name></channel>"
            + "<channel id=\"bbc1.uk\"><display-name>BBC One</display-name></channel>"
            + show("alibi.uk", "Drama") + show("BBC1.uk", "Own") + show("bbc1.uk", "Other") + "</tv>").utf8)
        let lineup = [
            channel("hd", guideID: "Alibi.uk", name: "UK: ALIBI HD"),
            channel("4k", guideID: "Alibi.uk", name: "UK: ALIBI 4K"),
            channel("one", guideID: "BBC1.uk", name: "UK: BBC ONE")
        ]
        let trusted = try await index.programs(
            from: url, catalog: lineup, channels: lineup, range: range, trustsGuideIDs: true
        ) { _ in .document(self.response(xml)) }
        XCTAssertEqual(
            trusted.map { $0.channelID + "=" + $0.title }.sorted(), ["4k=Drama", "hd=Drama", "one=Own"]
        )
        let cached = try await index.cachedPrograms(
            from: url, channels: lineup, range: range, trustsGuideIDs: true
        ) { lineup }
        XCTAssertEqual(cached, trusted)
        await index.invalidate()
        let noStore = response(xml, persists: false)
        let transient = try await index.programs(
            from: url, catalog: lineup, channels: lineup, range: range, trustsGuideIDs: true
        ) { _ in .document(noStore) }
        XCTAssertEqual(transient, trusted, "Empty own spelling falls back; populated own spelling never mixes")
        let saved = response(xml)
        _ = try await index.programs(from: url, catalog: lineup, channels: [], range: range) { saved }
        let strict = try await index.cachedPrograms(from: url, channels: lineup, range: range) { lineup }
        XCTAssertEqual(strict?.map(\.channelID), ["one"], "Other guides keep the stricter rule")
    }

    func testSavedAndNoStoreTrustedGuidesHaveIdenticalListings() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let lineup = [channel("hd", name: "Different"), channel("4k", name: "Another")]
        let xml = Data("""
        <tv><channel id="NEWS"><display-name>Station</display-name></channel>
        <channel id="news"><display-name>Station</display-name></channel>
        <programme channel="NEWS" start="19700101000140" stop="19700101000820"><title>Fallback</title></programme>
        <programme channel="news" start="19700101000140" stop="19700101000820"><title>Own</title></programme></tv>
        """.utf8)
        let stored = response(xml)
        let saved = try await index.programs(
            from: url, catalog: lineup, channels: lineup, range: range, trustsGuideIDs: true
        ) { _ in .document(stored) }
        await index.invalidate()
        let noStore = response(xml, persists: false)
        let transient = try await index.programs(
            from: url, catalog: lineup, channels: lineup, range: range, trustsGuideIDs: true
        ) { _ in .document(noStore) }
        XCTAssertEqual(saved, transient)
        XCTAssertEqual(saved.map(\.title), ["Own", "Own"])
    }

    func testCachedMissesSkipCatalogAndEmptyProbeSkipsListings() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        let lineup = [channel("a")]
        let reads = Mutex(0)
        let catalog: @Sendable () async throws -> [LiveTVPrototypeChannel] = {
            reads.withLock { $0 += 1 }; return lineup
        }
        let unsaved = try await index.cachedPrograms(from: url, channels: [], range: range, catalog: catalog)
        XCTAssertNil(unsaved)
        let body = response(document(), expires: now.addingTimeInterval(3_600))
        _ = try await index.programs(from: url, catalog: lineup, channels: [], range: range) { body }
        let outside = DateInterval(start: now.addingTimeInterval(10 * 86_400), duration: 3_600)
        let missing = try await index.cachedPrograms(from: url, channels: [], range: outside, catalog: catalog)
        XCTAssertNil(missing)
        XCTAssertEqual(reads.withLock { $0 }, 0)
        clock.withLock { $0 = now.addingTimeInterval(3_601) }
        let empty = try await index.cachedPrograms(from: url, channels: [], range: range, catalog: catalog)
        XCTAssertEqual(empty, [])
        await index.cancel()
        do {
            _ = try await index.cachedPrograms(from: url, channels: [], range: range, catalog: catalog)
            XCTFail("Closed misses must throw cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testGuideWindowKeepsTwentyThousandProgrammeLimit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let lineup = [channel("a")]
        let shows = (0..<20_001).map {
            "<programme channel=\"news\" start=\"19700101000140\" stop=\"19700101000820\"><title>Show \($0)</title></programme>"
        }.joined()
        let body = response(Data(("<tv>" + shows + "</tv>").utf8))
        _ = try await index.programs(from: url, catalog: lineup, channels: [], range: range) { body }
        let rows = try await fixture.cache.programs(
            sourceID: LiveTVGuideIndex.sourceID(url), channelIDs: ["news"], range: range,
            limit: 30_000, sourceURL: url
        )
        XCTAssertEqual(rows.count, 20_000)
    }

    func testCachedRequestAndRetainedProgrammeLimits() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let lineup = (0..<2_000).map { channel("variant-\($0)") }
        do {
            _ = try await index.cachedPrograms(from: url, channels: lineup + [channel("extra")], range: range) {
                XCTFail("Oversized request must not read the lineup"); return lineup
            }
            XCTFail("Request limit must be enforced even on a miss")
        } catch { XCTAssertEqual(error as? LiveTVCacheError, .invalidRange) }
        let shows = (0..<126).map {
            "<programme channel=\"news\" start=\"19700101000140\" stop=\"19700101000820\"><title>Show \($0)</title></programme>"
        }.joined()
        let body = response(Data(("<tv>" + shows + "</tv>").utf8))
        _ = try await index.programs(from: url, catalog: lineup, channels: [], range: range) { body }
        do {
            _ = try await index.cachedPrograms(from: url, channels: lineup, range: range) { lineup }
            XCTFail("Fan-out must respect the retained programme limit")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .guideTooLarge) }
    }

    func testProjectionAndRetentionChangesRebuildInsteadOfReturningFalseEmptyCoverage() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let firstChannels = [channel("a")]
        let expanded = firstChannels + [channel("b", guideID: "sport", name: "Sport")]
        let download = DownloadCounter(response(document()))
        _ = try await index.programs(from: url, catalog: firstChannels, channels: firstChannels, range: range, download: { await download.get() })
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let rows = try await index.programs(from: url, catalog: expanded, channels: [expanded[1]], range: range, download: { await download.get() })
        let changed = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(rows.map(\.title), ["Match"])
        XCTAssertNotEqual(before?.generation, changed?.generation)
        let future = DateInterval(start: now.addingTimeInterval(8 * 86_400), duration: 400)
        _ = try await index.programs(from: url, catalog: expanded, channels: expanded, range: future, download: { await download.get() })
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNotEqual(changed?.generation, after?.generation)
        let count = await download.count
        XCTAssertEqual(count, 3)
    }

    func testCancellingOneWaiterDoesNotCancelAnotherConsumersImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await download.waitUntilStarted()
        let second = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await index.waitForWaitersForTesting(2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter must fail promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await download.release()
        let rows = try await second.value
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidationCancelsAndDrainsInFlightImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let started = expectation(description: "Download began")
        let task = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range,
            download: {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        ) }
        await fulfillment(of: [started], timeout: 2)
        await index.invalidate()
        do { _ = try await task.value; XCTFail("Invalidated worker must not publish.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }
}

private actor DownloadCounter {
    var count = 0
    let response: XMLTVDownloadedDocument
    init(_ response: XMLTVDownloadedDocument) { self.response = response }
    func get() -> XMLTVDownloadedDocument { count += 1; return response }
}

private actor HeldDownload {
    var count = 0
    let response: XMLTVDownloadedDocument
    var started: CheckedContinuation<Void, Never>?
    var releaseContinuation: CheckedContinuation<Void, Never>?
    init(_ response: XMLTVDownloadedDocument) { self.response = response }
    func get() async throws -> XMLTVDownloadedDocument {
        count += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return response
    }
    func waitUntilStarted() async {
        if count == 0 { await withCheckedContinuation { started = $0 } }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}
