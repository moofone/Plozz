import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Remembers that a Back (Menu) press was just spent closing an in-screen panel, so an outer Back handler (the app's sidebar)
/// that is reached by the same press ignores it. The panel's handler removes the focused view while the press is still being
/// delivered; without this the press also opened the sidebar. One press closes the top panel only.
@MainActor
public enum TVBackConsumption {
    /// How long after a panel spent a press an outer handler still treats the press as spent: far longer than one press is
    /// delivered, shorter than a person's second press.
    public static let window: TimeInterval = 0.3

    private static var lastConsumedAt: TimeInterval?

    /// Call from the panel's exit command before it closes.
    public static func consume(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastConsumedAt = now
    }

    /// Whether the press an outer handler received was already spent by a panel.
    public static func wasJustConsumed(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let lastConsumedAt else { return false }
        return now - lastConsumedAt >= 0 && now - lastConsumedAt < window
    }

    /// Takes the press for the caller: true when nobody has spent it yet. The panel's exit command and the shell's Back handler
    /// both call this, so whichever the system delivers first closes the panel and the other ignores the same press.
    public static func claim(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !wasJustConsumed(at: now) else { return false }
        consume(at: now)
        return true
    }

    /// A panel's exit command: closes it once per press. `panel` names it in the DEBUG log.
    public static func closePanel(_ panel: String, close: () -> Void) {
        if claim() {
            TVBackDiagnostics.notice("panel=\(panel) exitCommand fired: closing")
            close()
        } else {
            TVBackDiagnostics.notice("panel=\(panel) exitCommand ignored: the press was already spent")
        }
    }

    /// Tests only.
    public static func reset() { lastConsumedAt = nil }
}

/// DEBUG-only Back-path log, visible without enabling Info messages. Predicate:
/// `subsystem == "com.plozz.app" AND category == "tvBack"`.
public enum TVBackDiagnostics {
    private static let logger = Logger(subsystem: "com.plozz.app", category: "tvBack")

    public static func notice(_ line: String) {
        #if DEBUG
        logger.notice("TVBACK \(line, privacy: .public)")
        #endif
    }

    /// What the focus engine has focused right now (class, accessibility label, frame in the window), for the Back log.
    @MainActor
    public static func focusSummary() -> String {
        #if DEBUG && canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return "none" }
        let label = (item as? NSObject)?.accessibilityLabel ?? ""
        return "\(type(of: item)) label=\"\(label)\" frame=\(item.frame.integral)"
        #else
        return "n/a"
        #endif
    }
}
