import FeatureLiveTVCore
import Foundation

struct PrototypeServerGuideRequest: Equatable {
    struct Channel: Equatable {
        let id: String
        let reference: LiveTVServerChannelReference
    }

    /// Guide rows a full screen shows (at most 11.3 at the tvOS row height). The anchor is the top visible row and the window
    /// starts 3 rows above it, so the request reaches one row past the bottom of the screen.
    static let rowsOnScreen = 12
    static let rowLimit = 3 + rowsOnScreen + 1
    let channels: [Channel]
    let from: Date
    let to: Date

    init?(
        rows: [LiveTVGuideRowID],
        anchorIndex: Int?,
        references: [String: LiveTVServerChannelReference],
        enabledSourceIDs: Set<String>,
        from: Date,
        to: Date
    ) {
        let channels = Self.nearbyChannelIDs(rows: rows, anchorIndex: anchorIndex, limit: Self.rowLimit)
            .compactMap { id -> Channel? in
                guard let reference = references[id], enabledSourceIDs.contains(reference.sourceID) else { return nil }
                return Channel(id: id, reference: reference)
            }
        guard !channels.isEmpty else { return nil }
        self.channels = channels
        self.from = from
        self.to = to
    }

    static func nearbyChannelIDs(
        rows: [LiveTVGuideRowID], anchorIndex: Int?, limit: Int
    ) -> [String] {
        guard !rows.isEmpty, limit > 0 else { return [] }
        let center = anchorIndex.flatMap { rows.indices.contains($0) ? $0 : nil } ?? 0
        let lower = max(0, min(center - 3, rows.count - limit))
        let upper = min(rows.count, lower + limit)
        var seen = Set<String>()
        return rows[lower..<upper].compactMap { row in
            seen.insert(row.channelID).inserted ? row.channelID : nil
        }
    }
}
