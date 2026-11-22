import Foundation
import CoreModels
import CoreSecureStore

public extension SchedulesDirectService {
    /// The production wiring: Keychain (`…ThisDeviceOnly`, separate from the
    /// household-shared items), `URLSession`, Application Support storage and the
    /// build's feature flags.
    static func standard(namespace: String?) -> SchedulesDirectService {
        SchedulesDirectService(
            namespace: namespace,
            secureStore: KeychainStore(service: "com.plozz.app.schedulesdirect", userIndependent: false)
        )
    }
}
