import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVPlaybackLifecycleTests: XCTestCase {
    func testClientDisconnectCancelsAnUpstreamStalledBeforeHeadersOrBody() async throws {
        for beforeHeaders in [true, false] {
            let source = try IPTVTestHTTPServer { _ in
                .init(
                    data: Data(repeating: 0x47, count: 131_072),
                    headerDelay: beforeHeaders ? .seconds(30) : .zero,
                    delay: beforeHeaders ? .zero : .seconds(30)
                )
            }
            let origin = try await source.start()
            addTeardownBlock { await source.stop() }
            let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let request = Task { try await session.data(from: url) }
            try await waitUntil { await source.activeRequestCount == 1 }

            request.cancel()
            _ = await request.result
            try await waitUntil { await source.activeRequestCount == 0 }
            await proxy.stop()
        }
    }

    func testLiveBodyReachesTheClientBeforeA64KiBChunkAccumulates() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(
                data: Data(repeating: 0x47, count: 262_144),
                delay: .milliseconds(150),
                chunkSize: 4_096
            )
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let (bytes, _) = try await session.bytes(from: url)
        var iterator = bytes.makeAsyncIterator()
        let first = try await iterator.next()
        let sentWhenFirstByteArrived = await source.bodyBytesSent

        XCTAssertNotNil(first)
        XCTAssertLessThan(sentWhenFirstByteArrived, 65_536)
        await proxy.stop()
    }

    func testRootEvidenceRecordsTheFirstUpstreamByteTime() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 8_192), delay: .milliseconds(100), chunkSize: 4_096)
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(from: url)

        let root = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url)?.evidence.root)
        let firstByte = try XCTUnwrap(root.firstByteMilliseconds)
        XCTAssertGreaterThanOrEqual(firstByte, 50)
        XCTAssertLessThanOrEqual(firstByte, root.elapsedMilliseconds)
        XCTAssertTrue(root.isValid)
        await proxy.stop()
    }

    func testLiveRootProbesNeverOpenTwoUpstreamStreamsAtOnce() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 131_072), delay: .seconds(30))
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let firstSession = URLSession(configuration: .ephemeral)
        let secondSession = URLSession(configuration: .ephemeral)
        defer { firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel() }
        let first = Task { try await firstSession.data(from: url) }
        try await waitUntil { await source.requestCount == 1 }
        let second = Task { try await secondSession.data(from: url) }
        try await Task.sleep(for: .milliseconds(200))
        let beforeCancellation = await source.requestCount
        XCTAssertEqual(beforeCancellation, 1)

        first.cancel()
        _ = await first.result
        try await waitUntil { await source.requestCount == 2 }
        let peak = await source.peakActiveRequestCount
        XCTAssertEqual(peak, 1)
        second.cancel()
        _ = await second.result
        await proxy.stop()
        try await waitUntil { await source.activeRequestCount == 0 }
    }

    func testConcurrentStopsDrainTheStreamAndQueuedRootRequests() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 131_072), delay: .seconds(30))
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = Task { try await session.data(from: url) }
        try await waitUntil { await source.requestCount == 1 }
        let second = Task { try await session.data(from: url) }
        let start = ContinuousClock.now
        async let stopOne: Void = proxy.stop()
        async let stopTwo: Void = proxy.stop()
        _ = await (stopOne, stopTwo)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        _ = await (first.result, second.result)
        try await waitUntil { await source.activeRequestCount == 0 }
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url))
        let count = await source.requestCount
        XCTAssertEqual(count, 1)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "The owned upstream request did not reach the expected lifecycle state.")
    }
}
