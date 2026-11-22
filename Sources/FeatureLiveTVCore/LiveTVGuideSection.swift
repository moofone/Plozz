import Foundation

public enum LiveTVGuideSection: String, Hashable, Sendable {
    case recent, favorites, channels
}

public struct LiveTVGuideRowID: Hashable, Sendable {
    public let channelID: String
    public let section: LiveTVGuideSection

    public init(channelID: String, section: LiveTVGuideSection = .channels) {
        self.channelID = channelID
        self.section = section
    }
}

public struct LiveTVGuideChannel: Identifiable, Equatable, Sendable {
    public let channel: LiveTVPrototypeChannel
    public let section: LiveTVGuideSection
    public let startsSection: Bool
    public var id: LiveTVGuideRowID { LiveTVGuideRowID(channelID: channel.id, section: section) }
}

/// Keep transport order stable while successful watching reorders Recents.
public struct LiveTVChannelSequence {
    private let ids: [String]
    /// Event slots with no event: channel up/down never lands on them.
    private let idleSlotIDs: Set<String>

    public init(channels: [LiveTVPrototypeChannel]) {
        var seen = Set<String>()
        ids = channels.map(\.id).filter { seen.insert($0).inserted }
        idleSlotIDs = Set(channels.lazy.filter { $0.eventSlot?.isIdle == true }.map(\.id))
    }

    /// The order the viewer tuned from, for surfaces that list its neighbours.
    public var channelIDs: [String] { ids }

    /// The channel `offset` steps away among the visible ones, wrapping at the ends. Idle event slots are
    /// skipped, so in Events the step wraps within the active events and returns nil (stays put) when none is active.
    public func neighbor(
        of channelID: String?, offset: Int, visibleChannels: [LiveTVPrototypeChannel]
    ) -> String? {
        let visible = Set(visibleChannels.map(\.id))
        let available = ids.filter { visible.contains($0) && !idleSlotIDs.contains($0) }
        guard let channelID, let index = available.firstIndex(of: channelID) else { return nil }
        let step = offset % available.count
        return available[(index + step + available.count) % available.count]
    }
}
