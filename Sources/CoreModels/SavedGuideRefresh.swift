import Foundation

/// Who asked for a saved-guide refresh. Both go through the same coordinator and the same
/// provider operation; only the due gate differs.
public enum SavedGuideRefreshTrigger: Sendable, Equatable {
    /// The profile's interval timer. Honours the chosen interval and every due date.
    case scheduled
    /// The Settings "Sync Now" button: validates saved guides even when they are not due, or
    /// when automatic updates are off. Provider refusal, backoff and Retry-After still apply.
    case manual
}

/// One saved guide document whose committed content changed. `sourceKey` is an opaque digest of the guide address
/// (never the address), unique per guide within an account; `contentRevision` is the digest of the committed body.
public struct SavedGuideSourceChange: Sendable, Hashable {
    public let sourceKey: String
    public let contentRevision: String
    /// Guide station ids added, removed, or whose names or icon changed (sorted). Empty when only programmes changed.
    public let changedStationIDs: [String]

    public init(sourceKey: String, contentRevision: String, changedStationIDs: [String]) {
        self.sourceKey = sourceKey
        self.contentRevision = contentRevision
        self.changedStationIDs = changedStationIDs
    }
}

/// Inputs that were durably committed since the previous report for one account. Only changes appear: a 304, or a
/// 200 whose body or lineup is identical to what was committed, yields `isEmpty`. Carries no URLs or credentials.
public struct SavedGuideCommittedInputs: Sendable, Hashable {
    /// Lineup revision the changed channel ids were read from; nil when the lineup did not change.
    public var lineupRevision: String?
    /// Lineup channel ids (sorted) added, removed, or whose name, number, icon, groups or guide identity changed.
    public var changedLineupChannelIDs: [String]
    public var guideChanges: [SavedGuideSourceChange]

    public init(
        lineupRevision: String? = nil, changedLineupChannelIDs: [String] = [], guideChanges: [SavedGuideSourceChange] = []
    ) {
        self.lineupRevision = lineupRevision
        self.changedLineupChannelIDs = changedLineupChannelIDs
        self.guideChanges = guideChanges
    }

    public var isEmpty: Bool { changedLineupChannelIDs.isEmpty && guideChanges.isEmpty }

    /// Combines two receipts; the later lineup revision wins and guide changes of one source collapse to the later one.
    public func merged(with later: SavedGuideCommittedInputs) -> SavedGuideCommittedInputs {
        var guides = Dictionary(uniqueKeysWithValues: guideChanges.map { ($0.sourceKey, $0) })
        for change in later.guideChanges {
            let stations = Set(guides[change.sourceKey]?.changedStationIDs ?? []).union(change.changedStationIDs)
            guides[change.sourceKey] = SavedGuideSourceChange(
                sourceKey: change.sourceKey, contentRevision: change.contentRevision, changedStationIDs: stations.sorted()
            )
        }
        return SavedGuideCommittedInputs(
            lineupRevision: later.lineupRevision ?? lineupRevision,
            changedLineupChannelIDs: Set(changedLineupChannelIDs).union(later.changedLineupChannelIDs).sorted(),
            guideChanges: guides.values.sorted { $0.sourceKey < $1.sourceKey }
        )
    }
}

/// What one refresh of an account's saved guides did. Carries no URLs or credentials.
public struct SavedGuideRefreshReport: Sendable, Equatable {
    /// When the earliest saved guide or lineup next falls due; nil when nothing is due on a schedule.
    public let nextDue: Date?
    /// Saved guides that were asked of the server (validated or replaced) in this refresh.
    public let transferredGuides: Int
    /// Inputs committed by this refresh (or left committed by earlier work not yet reported). Empty when nothing changed.
    public let committedInputs: SavedGuideCommittedInputs

    public init(nextDue: Date?, transferredGuides: Int, committedInputs: SavedGuideCommittedInputs = .init()) {
        self.nextDue = nextDue
        self.transferredGuides = transferredGuides
        self.committedInputs = committedInputs
    }
}

/// The Settings-facing side of the guide refresh coordinator.
@MainActor
public protocol SavedGuideRefreshControlling: AnyObject {
    /// False while the profile is not authorized for Live TV, the app is inactive, or no account can refresh.
    var isAvailable: Bool { get }
    var isRefreshing: Bool { get }
    /// Starts (or joins) the shared refresh. The run is owned by the coordinator, so leaving
    /// Settings does not cancel it.
    func requestManualRefresh()
}
