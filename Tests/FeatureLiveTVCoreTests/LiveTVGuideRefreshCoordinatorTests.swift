import CoreModels
import Foundation
import Synchronization
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVGuideRefreshCoordinatorTests: XCTestCase {
    private actor Provider: ServerLiveTVProviding {
        private(set) var triggers: [SavedGuideRefreshTrigger] = []
        private var gated: Bool
        private var gate: CheckedContinuation<Void, Never>?
        private let transferred: [Int]
        private let due: Date?
        private let inputs: SavedGuideCommittedInputs
        private let fails: Bool
        private let honorsCancellation: Bool

        init(
            gated: Bool = true, transferred: [Int] = [1], due: Date? = nil,
            inputs: SavedGuideCommittedInputs = .init(), fails: Bool = false, honorsCancellation: Bool = true
        ) {
            self.honorsCancellation = honorsCancellation
            self.gated = gated
            self.transferred = transferred
            self.due = due
            self.inputs = inputs
            self.fails = fails
        }

        func liveTVAvailability() async throws -> ServerLiveTVAvailability {
            .init(status: .available, channelCount: 1, supportsGuide: true)
        }
        func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }
        func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
        func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease { throw CancellationError() }

        func refreshSavedLiveTVGuide(trigger: SavedGuideRefreshTrigger) async throws -> SavedGuideRefreshReport? {
            triggers.append(trigger)
            let call = triggers.count
            if gated { await withCheckedContinuation { gate = $0 } }
            if honorsCancellation { try Task.checkCancellation() }
            if fails { throw URLError(.timedOut) }
            return SavedGuideRefreshReport(
                nextDue: due, transferredGuides: transferred[min(call, transferred.count) - 1],
                committedInputs: call == 1 ? inputs : .init()
            )
        }

        func waitUntilStarted() async {
            var spins = 0
            while triggers.isEmpty, spins < 10_000 { await Task.yield(); spins += 1 }
        }
        func release() {
            gated = false
            gate?.resume()
            gate = nil
        }
    }

    private func coordinator(
        _ provider: Provider, authorizationID: String = "a", isAuthorized: Bool = true
    ) -> LiveTVGuideRefreshCoordinator {
        LiveTVGuideRefreshCoordinator(scope: .init(
            accountIDs: ["iptv"], authorizationID: authorizationID, isAuthorized: isAuthorized,
            resolver: { id in .init(accountID: id, authorizationID: authorizationID, kind: .iptv, provider: provider) }
        ))
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    func testCommittedInputsAreDeliveredPerAccountAndAFailedRunIsNotComplete() async {
        let change = SavedGuideCommittedInputs(
            lineupRevision: "r1", changedLineupChannelIDs: ["c1"],
            guideChanges: [.init(sourceKey: "s", contentRevision: "d", changedStationIDs: ["x"])]
        )
        let provider = Provider(gated: false, inputs: change)
        let coordinator = coordinator(provider)
        let delivered = await coordinator.refresh(.scheduled)
        XCTAssertEqual(delivered?.committedInputs, ["iptv": change])
        XCTAssertEqual(delivered?.isComplete, true)
        let second = await coordinator.refresh(.scheduled)
        XCTAssertEqual(second?.committedInputs, [:], "A receipt is delivered once")

        let failing = self.coordinator(Provider(gated: false, fails: true))
        let failedRun = await failing.refresh(.scheduled)
        XCTAssertEqual(failedRun?.failedAccountIDs, ["iptv"])
        XCTAssertEqual(failedRun?.isComplete, false)
        XCTAssertEqual(failedRun?.committedInputs, [:])
    }

    func testRetiredRunKeepsItsInputsForTheNextRunOfTheSameAccounts() async {
        let change = SavedGuideCommittedInputs(changedLineupChannelIDs: ["c1"])
        // The provider returns its report even though the run was cancelled: the hand-over already happened.
        let provider = Provider(inputs: change, honorsCancellation: false)
        let coordinator = coordinator(provider)
        let hookCalls = Mutex(0)
        coordinator.didRefresh = { _ in hookCalls.withLock { $0 += 1 } }
        let retired = Task { await coordinator.refresh(.scheduled) }
        await provider.waitUntilStarted()
        // Losing the foreground retires the run while the provider has already handed its inputs over.
        coordinator.configure(.init(
            accountIDs: ["iptv"], authorizationID: "a", isAuthorized: true, isForeground: false,
            resolver: { id in .init(accountID: id, authorizationID: "a", kind: .iptv, provider: provider) }
        ))
        await provider.release()
        let retiredResult = await retired.value
        XCTAssertNil(retiredResult)
        coordinator.configure(.init(
            accountIDs: ["iptv"], authorizationID: "a", isAuthorized: true,
            resolver: { id in .init(accountID: id, authorizationID: "a", kind: .iptv, provider: provider) }
        ))
        let next = await coordinator.refresh(.scheduled)
        XCTAssertEqual(next?.committedInputs, ["iptv": change])
        XCTAssertEqual(hookCalls.withLock { $0 }, 1)
        let triggers = await provider.triggers
        XCTAssertEqual(triggers, [.scheduled, .scheduled])
    }

    func testRetiredRunDoesNotCarryItsInputsToANewAuthorization() async {
        let provider = Provider(inputs: SavedGuideCommittedInputs(changedLineupChannelIDs: ["c1"]), honorsCancellation: false)
        let coordinator = coordinator(provider)
        let retired = Task { await coordinator.refresh(.scheduled) }
        await provider.waitUntilStarted()
        coordinator.configure(.init(
            accountIDs: ["iptv"], authorizationID: "b", isAuthorized: true,
            resolver: { id in .init(accountID: id, authorizationID: "b", kind: .iptv, provider: provider) }
        ))
        await provider.release()
        let retiredResult = await retired.value
        XCTAssertNil(retiredResult)
        let next = await coordinator.refresh(.scheduled)
        XCTAssertEqual(next?.committedInputs, [:], "Inputs of the old authorization are never delivered")
    }

    func testTimerThenManualShareOneProviderOperationAndOneAwaitedHook() async {
        let provider = Provider()
        let coordinator = coordinator(provider)
        var events: [String] = []
        coordinator.didRefresh = { result in
            events.append("hook-start")
            for _ in 0..<20 { await Task.yield() }
            events.append("hook-end")
            XCTAssertEqual(result.transferredAccountIDs, ["iptv"])
        }
        let timer = Task { @MainActor in await coordinator.refresh(.scheduled) }
        await provider.waitUntilStarted()
        coordinator.requestManualRefresh()
        let manual = Task { @MainActor in
            let result = await coordinator.refresh(.manual)
            events.append("manual-resumed")
            return result
        }
        await settle()
        XCTAssertTrue(coordinator.isRefreshing)
        await provider.release()
        let first = await timer.value
        let second = await manual.value
        let triggers = await provider.triggers
        XCTAssertEqual(triggers, [.scheduled], "The transfer already made is never repeated for the manual request")
        XCTAssertEqual(first, second)
        XCTAssertEqual(events, ["hook-start", "hook-end", "manual-resumed"], "Waiters resume only after the awaited hook")
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testManualThenTimerShareOneManualOperation() async {
        let provider = Provider()
        let coordinator = coordinator(provider)
        let hooks = Mutex(0)
        coordinator.didRefresh = { _ in hooks.withLock { $0 += 1 } }
        coordinator.requestManualRefresh()
        await provider.waitUntilStarted()
        let timer = Task { @MainActor in await coordinator.refresh(.scheduled) }
        await settle()
        await provider.release()
        let result = await timer.value
        XCTAssertNotNil(result)
        let triggers = await provider.triggers
        XCTAssertEqual(triggers, [.manual])
        XCTAssertEqual(hooks.withLock { $0 }, 1)
    }

    func testManualDuringADueProbeRechecksOnlyAnAccountThatAskedNoServer() async {
        let provider = Provider(transferred: [0, 1])
        let coordinator = coordinator(provider)
        let timer = Task { @MainActor in await coordinator.refresh(.scheduled) }
        await provider.waitUntilStarted()
        coordinator.requestManualRefresh()
        await provider.release()
        _ = await timer.value
        let triggers = await provider.triggers
        XCTAssertEqual(triggers, [.scheduled, .manual])
    }

    func testDismissingTheRequesterDoesNotCancelAManualRun() async {
        let provider = Provider()
        let coordinator = coordinator(provider)
        let hooks = Mutex(0)
        coordinator.didRefresh = { _ in hooks.withLock { $0 += 1 } }
        coordinator.requestManualRefresh()
        await provider.waitUntilStarted()
        let waiter = Task { @MainActor in await coordinator.refresh(.scheduled) }
        await settle()
        waiter.cancel()
        let detached = await waiter.value
        XCTAssertNil(detached)
        XCTAssertTrue(coordinator.isRefreshing, "The pinned run outlives its waiter")
        await provider.release()
        await settle()
        XCTAssertEqual(hooks.withLock { $0 }, 1)
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testAuthorizationChangeRetiresTheRunWithoutAHookOrAResult() async {
        let provider = Provider()
        let coordinator = coordinator(provider)
        let hooks = Mutex(0)
        coordinator.didRefresh = { _ in hooks.withLock { $0 += 1 } }
        let timer = Task { @MainActor in await coordinator.refresh(.scheduled) }
        await provider.waitUntilStarted()
        coordinator.configure(.init(
            accountIDs: ["iptv"], authorizationID: "b", isAuthorized: true, resolver: { _ in nil }
        ))
        let result = await timer.value
        XCTAssertNil(result)
        await provider.release()
        await settle()
        XCTAssertEqual(hooks.withLock { $0 }, 0)
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testUnavailableCoordinatorAdmitsNothing() async {
        let provider = Provider(gated: false)
        let coordinator = coordinator(provider, isAuthorized: false)
        XCTAssertFalse(coordinator.isAvailable)
        coordinator.requestManualRefresh()
        let result = await coordinator.refresh(.scheduled)
        XCTAssertNil(result)
        await settle()
        let triggers = await provider.triggers
        XCTAssertEqual(triggers, [])
    }

    func testManualRefreshRunsWithAutomaticUpdatesOffAndNeverMovesTheTimer() async {
        // The coordinator never reads the interval: with the timer not running at all (Off), a manual request still
        // runs, and with the timer running its waits are exactly what they were.
        let provider = Provider(gated: false)
        let coordinator = coordinator(provider)
        coordinator.requestManualRefresh()
        await settle()
        var triggers = await provider.triggers
        XCTAssertEqual(triggers, [.manual])

        let now = Date(timeIntervalSince1970: 1_000)
        let timed = Provider(gated: false, transferred: [1], due: now.addingTimeInterval(1_800))
        let shared = self.coordinator(timed)
        let waits = Mutex<[TimeInterval]>([])
        await LiveTVGuideAutoUpdate.run(
            coordinator: shared, interval: 3_600, now: { now },
            sleep: { seconds in
                let count = waits.withLock { $0.append(seconds); return $0.count }
                if count == 1 { _ = await shared.refresh(.manual) }
                if count == 3 { throw CancellationError() }
            }
        )
        XCTAssertEqual(waits.withLock { $0 }, [60, 1_800, 1_800])
        triggers = await timed.triggers
        XCTAssertEqual(triggers, [.manual, .scheduled, .scheduled])
    }
}
