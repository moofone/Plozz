import XCTest
@testable import CoreModels

final class OfflineModeTests: XCTestCase {
    func testRolloutIsEnabledInBothBuildConfigurations() {
        XCTAssertTrue(RuntimeFeatureFlags.productionDefault.isEnabled(.offlineMode))
        var build = RuntimeFeatureFlags.buildDefault
        build.set(.schedulesDirect, enabled: false)  // DEBUG-only research flag
        XCTAssertEqual(build, .productionDefault)
    }

    func testDisabledFlagCannotBlockNetworking() throws {
        let mode = OfflineMode(featureFlags: .init())
        mode.setEnabled(true)
        XCTAssertFalse(mode.isAvailable)
        XCTAssertFalse(mode.isEnabled)
        XCTAssertNoThrow(try mode.requireNetworkAccess())
    }

    func testAvailableModeRequiresExplicitActivation() throws {
        let mode = OfflineMode(featureFlags: .init(enabled: [.offlineMode]))
        XCTAssertFalse(mode.isEnabled)
        mode.setEnabled(true)
        XCTAssertThrowsError(try mode.requireNetworkAccess())
        mode.setEnabled(false)
        XCTAssertNoThrow(try mode.requireNetworkAccess())
    }

    func testDisabledFlagRemovesOnlyOfflineModeFromSettingsSearch() {
        var disabled = RuntimeFeatureFlags.productionDefault
        disabled.set(.offlineMode, enabled: false)
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet] {
            let enabledIDs = Set(SettingsSearchCatalog.entries(on: platform).map(\.id))
            let disabledIDs = Set(SettingsSearchCatalog.entries(on: platform, featureFlags: disabled).map(\.id))
            XCTAssertEqual(enabledIDs.subtracting(disabledIDs), ["offline-mode"])
            XCTAssertTrue(disabledIDs.contains("downloads-cellular"))
        }
    }
}
