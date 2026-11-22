import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

private struct LiveTVGuideAutoUpdateModifier: ViewModifier {
    let accountIDs: [String]
    let authorizationID: String
    let isAuthorized: Bool
    let namespace: String?
    let resolver: LiveTVServerProviderResolver
    let didRefresh: (@MainActor (LiveTVGuideRefreshResult) async -> Void)?
    let sources: (@Sendable () -> [LiveTVServerSource])?
    @State private var coordinator = LiveTVGuideRefreshCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var interval: LiveTVGuideUpdateInterval
    #if canImport(UIKit)
    @State private var artworkWriter = LiveTVSyncArtworkWriter()
    @State private var artworkRevision = 0
    #endif

    init(
        accountIDs: [String], authorizationID: String, isAuthorized: Bool,
        namespace: String?, resolver: @escaping LiveTVServerProviderResolver,
        sources: (@Sendable () -> [LiveTVServerSource])?,
        didRefresh: (@MainActor (LiveTVGuideRefreshResult) async -> Void)?
    ) {
        self.sources = sources
        self.didRefresh = didRefresh
        self.accountIDs = accountIDs
        self.authorizationID = authorizationID
        self.isAuthorized = isAuthorized
        self.namespace = namespace
        self.resolver = resolver
        _interval = State(initialValue: Self.interval(namespace))
    }

    private static func interval(_ namespace: String?) -> LiveTVGuideUpdateInterval {
        LiveTVViewSettingsStore(namespace: namespace).load().guideUpdateInterval
    }

    /// What the published station marks were derived under; a change revokes them.
    private struct MarkScope: Equatable {
        let accountIDs: [String]
        let authorizationID: String
        let isAuthorized: Bool
    }

    private struct Run: Equatable {
        let accountIDs: [String]
        let authorizationID: String
        let seconds: TimeInterval?
        let isActive: Bool
    }

    /// The hook the shared coordinator awaits once per scheduled or manual run: prepares themed artwork for what the run
    /// committed, then lets the parent's own hook run.
    private var refreshHook: (@MainActor (LiveTVGuideRefreshResult) async -> Void)? {
        #if canImport(UIKit)
        guard let sources else { return didRefresh }
        let writer = artworkWriter, coordinator = coordinator, resolver = resolver
        let accountIDs = accountIDs, authorizationID = authorizationID, didRefresh = didRefresh
        return { result in
            await writer.publish(result, scope: .init(
                accountIDs: accountIDs, resolver: resolver, sources: sources,
                isCurrent: {
                    coordinator.isAvailable && coordinator.currentAuthorizationID == authorizationID
                        && coordinator.currentAccountIDs == accountIDs
                }
            ), retriesFailedLogos: true)
            await didRefresh?(result)
        }
        #else
        return didRefresh
        #endif
    }

    #if canImport(UIKit)
    private struct ArtworkRun: Equatable {
        let scope: MarkScope
        let isForeground: Bool
        let choicesRevision: Int
    }

    /// Restores prepared artwork and fills missing logos for saved lineups without waiting for a guide update.
    private func restoreStationMarks() async {
        guard !Task.isCancelled, isAuthorized, scenePhase == .active, let sources else { return }
        let coordinator = coordinator, authorizationID = authorizationID, accountIDs = accountIDs
        coordinator.configure(refreshScope)
        await artworkWriter.publish(LiveTVGuideRefreshResult(), scope: .init(
            accountIDs: accountIDs, resolver: resolver, sources: sources,
            isCurrent: {
                coordinator.isAvailable && coordinator.currentAuthorizationID == authorizationID
                    && coordinator.currentAccountIDs == accountIDs
            }
        ))
    }
    #endif

    private var refreshScope: LiveTVGuideRefreshScope {
        LiveTVGuideRefreshScope(
            accountIDs: accountIDs, authorizationID: authorizationID, isAuthorized: isAuthorized,
            isForeground: scenePhase == .active, resolver: resolver
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.savedGuideRefresh, coordinator)
            .onChange(of: Run(
                accountIDs: accountIDs, authorizationID: authorizationID, seconds: nil,
                isActive: isAuthorized && scenePhase == .active
            ), initial: true) { _, _ in
                coordinator.didRefresh = refreshHook
                coordinator.configure(refreshScope)
            }
            #if canImport(UIKit)
            .onChange(of: MarkScope(accountIDs: accountIDs, authorizationID: authorizationID, isAuthorized: isAuthorized)) {
                LiveTVGuideStationMarkIndex.shared.revoke()
                let writer = artworkWriter
                Task { await writer.reset() }
            }
            .task(
                id: ArtworkRun(
                    scope: MarkScope(accountIDs: accountIDs, authorizationID: authorizationID, isAuthorized: isAuthorized),
                    isForeground: scenePhase == .active, choicesRevision: artworkRevision
                ),
                priority: .utility
            ) { await restoreStationMarks() }
            .onReceive(NotificationCenter.default.publisher(for: LiveTVChannelLogoStore.didResolveArtworkChoices,
                                                             object: LiveTVChannelLogoService.shared.store)) { _ in
                artworkRevision = LiveTVChannelLogoService.shared.store.artworkChoicesRevision
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: LiveTVViewSettingsStore.didChange)) { _ in
                interval = Self.interval(namespace)
            }
            .onChange(of: namespace) { _, namespace in interval = Self.interval(namespace) }
            .task(
                id: Run(
                    accountIDs: accountIDs, authorizationID: authorizationID, seconds: interval.seconds,
                    isActive: isAuthorized && scenePhase == .active
                ),
                priority: .utility
            ) {
                guard isAuthorized, scenePhase == .active, let seconds = interval.seconds else { return }
                coordinator.didRefresh = refreshHook
                coordinator.configure(refreshScope)
                await LiveTVGuideAutoUpdate.run(coordinator: coordinator, interval: seconds)
            }
    }
}

public extension View {
    /// Keeps the active profile's saved programme guides current while the app is in the
    /// foreground, following that profile's "Update guide automatically" setting. It also owns the profile's shared
    /// refresh coordinator and publishes it to descendants as `\.savedGuideRefresh` for Settings "Sync Now".
    /// `didRefresh` is awaited once per shared run (timer or manual) after the sync-time themed artwork writer has
    /// prepared the run's committed inputs (the writer runs only when the root supplies `sources`, the profile's
    /// current approved Live TV sources).
    func liveTVGuideAutoUpdate(
        accountIDs: [String], authorizationID: String, isAuthorized: Bool,
        namespace: String?, resolver: @escaping LiveTVServerProviderResolver,
        sources: (@Sendable () -> [LiveTVServerSource])? = nil,
        didRefresh: (@MainActor (LiveTVGuideRefreshResult) async -> Void)? = nil
    ) -> some View {
        modifier(LiveTVGuideAutoUpdateModifier(
            accountIDs: accountIDs, authorizationID: authorizationID, isAuthorized: isAuthorized,
            namespace: namespace, resolver: resolver, sources: sources, didRefresh: didRefresh
        ))
    }
}
