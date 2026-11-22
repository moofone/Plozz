import CoreModels
import CoreSecureStore
import Foundation
import MetadataKit

/// The one place the app composes its TMDB access: the bundled token or proxy, overridden by the
/// household key the user entered in Settings. Every runtime reads it through here.
public enum MetadataAccessRuntime {
    /// Reads the key store on every call, so a key added or removed in Settings applies at once.
    public static func currentConfig() -> MetadataProviderConfig {
        currentConfig(base: .resolved(), keyStore: householdKeyStore)
    }

    static func currentConfig(base: MetadataProviderConfig, keyStore: TMDBUserKeyStore) -> MetadataProviderConfig {
        base.withUserToken(keyStore.load())
    }

    private static var householdKeyStore: TMDBUserKeyStore {
        TMDBUserKeyStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
    }
}
