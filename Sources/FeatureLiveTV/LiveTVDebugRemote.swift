#if DEBUG
import CoreNetworking
import Foundation
import Observation
import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// A command from the DEBUG-only `plozz-debug://livetv/…` URL channel.
///
/// `xcrun simctl openurl <sim> <url>` delivers the URL without activating any Mac window, so Live TV can be driven on a
/// simulator in the background. Each command acts as the matching remote press would, through the screen's own
/// coordinators; the screen's profile, parental and authorization checks still apply.
public enum LiveTVDebugRemoteCommand: Equatable, Sendable {
    case open
    /// Tune the channel whose raw name (and group, when given) matches exactly.
    case tune(name: String, group: String?)
    /// From full-screen playback, show the guide with the picture behind (the same as Back).
    case guide
    case quickMenu
    case context
    case panel
    /// Move guide focus to the channel whose raw name (and group, when given) matches exactly.
    case focus(name: String, group: String?)
    case back
    case stop

    /// The command name as written in the URL path (and in the log line).
    public var name: String {
        switch self {
        case .open: "open"
        case .tune: "tune"
        case .guide: "guide"
        case .quickMenu: "quickmenu"
        case .context: "context"
        case .panel: "panel"
        case .focus: "focus"
        case .back: "back"
        case .stop: "stop"
        }
    }
}

public enum LiveTVDebugRemoteParseResult: Equatable, Sendable {
    case command(LiveTVDebugRemoteCommand)
    /// `command` is the path name when there was one; `reason` is the log reason.
    case rejected(command: String, reason: String)
}

/// What a command did. `reason` is a short token with no secrets or stream URLs.
public enum LiveTVDebugRemoteOutcome: Equatable, Sendable {
    case ok
    case ignored(String)

    var logValue: String {
        switch self {
        case .ok: "ok"
        case let .ignored(reason): "ignored:\(reason)"
        }
    }
}

/// How a name (and optional group) selects a channel.
public struct LiveTVDebugRemoteChannelKey: Equatable, Sendable {
    public let id: String
    public let name: String
    public let groups: [String]

    public init(id: String, name: String, groups: [String]) {
        self.id = id
        self.name = name
        self.groups = groups
    }
}

public enum LiveTVDebugRemoteMatch: Equatable, Sendable {
    case match(id: String)
    case missing
    case ambiguous
}

struct LiveTVDebugRemoteRefusal: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

public enum LiveTVDebugRemoteParser {
    public static let scheme = "plozz-debug"
    static let host = "livetv"

    /// Nil when the URL is not for this channel at all (another scheme or host).
    public static func parse(_ url: URL) -> LiveTVDebugRemoteParseResult? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .rejected(command: "", reason: "malformed-url")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count == 1, let name = segments.first else {
            return .rejected(command: segments.first ?? "", reason: segments.isEmpty ? "missing-command" : "unknown-command")
        }
        switch name {
        case "open": return .command(.open)
        case "guide": return .command(.guide)
        case "quickmenu": return .command(.quickMenu)
        case "context": return .command(.context)
        case "panel": return .command(.panel)
        case "back": return .command(.back)
        case "stop": return .command(.stop)
        case "tune", "focus":
            let items = components.queryItems ?? []
            let names = items.filter { $0.name == "name" }
            let groups = items.filter { $0.name == "group" }
            guard names.count == 1, let channelName = names[0].value, !channelName.isEmpty else {
                return .rejected(command: name, reason: names.count > 1 ? "duplicate-name" : "missing-name")
            }
            guard groups.count <= 1 else { return .rejected(command: name, reason: "duplicate-group") }
            let group = groups.first?.value
            if let group, group.isEmpty { return .rejected(command: name, reason: "empty-group") }
            return .command(name == "tune" ? .tune(name: channelName, group: group) : .focus(name: channelName, group: group))
        default:
            return .rejected(command: name, reason: "unknown-command")
        }
    }

    /// Exact name (and, when given, exact group) match. Never fuzzy, and never by the provider's number.
    public static func resolve(
        name: String, group: String?, in channels: [LiveTVDebugRemoteChannelKey]
    ) -> LiveTVDebugRemoteMatch {
        var found: String?
        for channel in channels where channel.name == name && (group.map { channel.groups.contains($0) } ?? true) {
            if found != nil { return .ambiguous }
            found = channel.id
        }
        return found.map { .match(id: $0) } ?? .missing
    }
}

/// The URL channel's mailbox between `AppState.handle(url:)` and the Live TV screen.
@MainActor
@Observable
public final class LiveTVDebugRemote {
    public static let shared = LiveTVDebugRemote()

    public struct Delivery: Equatable, Sendable {
        public let id: Int
        public let command: LiveTVDebugRemoteCommand
    }

    public private(set) var delivery: Delivery?
    private var nextID = 0
    private var claimedID = -1
    private var mountedScreens = 0

    private init() {}

    /// Returns true when the URL belonged to this channel (handled or logged as ignored).
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let parsed = LiveTVDebugRemoteParser.parse(url) else { return false }
        switch parsed {
        case let .rejected(command, reason):
            Self.log(command: command, outcome: .ignored(reason))
        case let .command(command):
            guard mountedScreens > 0 || command == .open else {
                Self.log(command: command.name, outcome: .ignored("live-tv-not-mounted"))
                return true
            }
            nextID += 1
            delivery = Delivery(id: nextID, command: command)
        }
        return true
    }

    /// The screen that performs `delivery` takes it once; a second screen would get false.
    func claim(_ delivery: Delivery) -> Bool {
        guard delivery.id > claimedID else { return false }
        claimedID = delivery.id
        return true
    }

    func screenAppeared() { mountedScreens += 1 }
    func screenDisappeared() { mountedScreens = max(0, mountedScreens - 1) }

    /// Writes the one log line for a command: `LIVE_TV event=debugRemote cmd=<cmd> result=<ok|ignored:<reason>>`.
    static func log(command: String, outcome: LiveTVDebugRemoteOutcome) {
        PlozzLog.app.info("LIVE_TV event=debugRemote cmd=\(command) result=\(outcome.logValue)")
    }

    func finish(_ command: LiveTVDebugRemoteCommand, _ outcome: LiveTVDebugRemoteOutcome) {
        Self.log(command: command.name, outcome: outcome)
    }

    #if os(tvOS)
    /// The focused item's frame in window coordinates (the guide cell the remote is on), or nil.
    static func focusedFrame() -> CGRect? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let view = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView else { return nil }
        let frame = view.convert(view.bounds, to: window)
        return frame.isEmpty ? nil : frame
    }
    #endif
}

#if os(tvOS)
/// Hands each delivered command to the Live TV screen. `perform` runs on the main actor and returns what happened;
/// `open` belongs to the shell, which selects the tab, so the screen leaves it alone.
struct LiveTVDebugRemoteReceiver: ViewModifier {
    let perform: (LiveTVDebugRemoteCommand) -> LiveTVDebugRemoteOutcome
    private let remote = LiveTVDebugRemote.shared

    func body(content: Content) -> some View {
        content
            .onAppear { remote.screenAppeared() }
            .onDisappear { remote.screenDisappeared() }
            .onChange(of: remote.delivery, initial: true) { _, delivery in
                guard let delivery, delivery.command != .open, remote.claim(delivery) else { return }
                remote.finish(delivery.command, perform(delivery.command))
            }
    }
}
#endif

/// The shell side of `open`: selects the Live TV tab the way the remote's Guide button does.
public struct LiveTVDebugRemoteOpenRouter: View {
    /// Returns whether Live TV could be opened (the destination exists for this profile and the profile is authorized).
    let open: () -> Bool
    private let remote = LiveTVDebugRemote.shared

    public init(open: @escaping () -> Bool) { self.open = open }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: remote.delivery, initial: true) { _, delivery in
                guard let delivery, delivery.command == .open, remote.claim(delivery) else { return }
                remote.finish(.open, open() ? .ok : .ignored("live-tv-unavailable"))
            }
    }
}
#endif
