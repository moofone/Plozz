import CoreModels
import SwiftUI

private struct SavedGuideRefreshKey: EnvironmentKey {
    static let defaultValue: (any SavedGuideRefreshControlling)? = nil
}

public extension EnvironmentValues {
    /// The root-owned guide refresh shared by the interval timer and Settings "Sync Now". Nil where no root installed one.
    var savedGuideRefresh: (any SavedGuideRefreshControlling)? {
        get { self[SavedGuideRefreshKey.self] }
        set { self[SavedGuideRefreshKey.self] = newValue }
    }
}
