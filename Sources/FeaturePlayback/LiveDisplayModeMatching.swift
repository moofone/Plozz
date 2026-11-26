#if canImport(AVFoundation)
#if os(tvOS)
import AVKit
#endif
import UIKit

/// Reads the system Match Content setting (Settings › Video and Audio › Match Content).
@MainActor
enum LiveDisplayModeMatching {
    /// False only when the system says it will not switch display modes for content.
    /// Unknown (no window, or no display manager) keeps the veil, as before.
    static func isEnabled() -> Bool {
        #if os(tvOS)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              window.responds(to: Selector(("avDisplayManager"))) else { return true }
        return window.avDisplayManager.isDisplayCriteriaMatchingEnabled
        #else
        return true
        #endif
    }
}
#endif
