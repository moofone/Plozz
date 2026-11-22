import Foundation
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import MetadataKit
#if canImport(UIKit)
import UIKit
#endif

/// Connects Live TV channel logos to the app's TMDB access.
public enum LiveTVChannelLogoRuntime {
    /// Live TV reads the same access as the rest of the app on every use: the bundled token
    /// or proxy, or the household key the user entered in Settings. With neither, TMDB is off.
    public static func configure() {
        LiveTVChannelLogoService.configureShared { MetadataAccessRuntime.currentConfig().tmdb }
        // The stored results are read once, here, off the main thread, so the first Live TV screen never waits for the file.
        DispatchQueue.global(qos: .utility).async { _ = LiveTVChannelLogoService.shared }
        #if canImport(UIKit)
        // Changes are saved a few seconds after they settle; leaving the foreground or quitting saves what is pending.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                // Off the main thread, and kept alive long enough to finish.
                ProcessInfo.processInfo.performExpiringActivity(withReason: "Save Live TV logo choices") { expired in
                    if !expired { LiveTVChannelLogoService.shared.store.flush() }
                }
            }
        }
        #endif
    }
}

import FeatureSyncCloud

extension LiveTVChannelLogoRuntime {
    /// The profile's approved Live TV server sources, read fresh for each sync-time artwork run. Nothing is returned when the
    /// sources cannot be read, so no artwork is prepared for them.
    public static func serverSourcesLoader(
        profileID: String, namespace: String?
    ) -> @Sendable () -> [LiveTVServerSource] {
        {
            (try? LiveTVSourceStorage.approvalAwareStore(profileID: profileID, namespace: namespace).load().servers) ?? []
        }
    }
}

extension LiveTVChannelLogoRuntime {
    /// The household-wide iCloud channel for channel logo choices. It runs on the app's one sync
    /// engine, so it follows the device's iCloud Sync setting; with sync off the choices stay local.
    /// `publish` is called after each local change so the engine can upload it.
    public static func syncChannel(
        stateFileURL: URL, store: LiveTVChannelLogoStore = LiveTVChannelLogoService.shared.store,
        publish: @escaping @Sendable () -> Void
    ) -> CloudConfigSyncService.ChannelConfiguration {
        store.onLocalChange = publish
        return .init(
            schema: .liveTVLogosV1, stateFileURL: stateFileURL,
            captureRecords: { fallback in LiveTVChannelLogoSync.capture(store) ?? fallback },
            applyRecords: { changes in LiveTVChannelLogoSync.apply(changes, to: store) },
            isHydrated: { store.isLoaded },
            applySnapshot: { snapshot in LiveTVChannelLogoSync.apply(snapshot.changes, to: store) }
        )
    }
}
