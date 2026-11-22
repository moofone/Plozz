import Foundation

/// The number Plozz gave one channel, and when (whole seconds since 1970).
public struct LiveTVChannelNumberAssignment: Equatable, Hashable, Sendable {
    public let number: Int
    public let assignedAt: Int

    public init(number: Int, assignedAt: Int) {
        self.number = number
        self.assignedAt = assignedAt
    }

    /// The earlier assignment wins; a tie keeps the lower number, so every device picks the same one.
    fileprivate func precedes(_ other: Self) -> Bool {
        (assignedAt, number) < (other.assignedAt, other.number)
    }
}

/// Plozz's own channel numbers for one profile.
///
/// Providers renumber their lineups from one day to the next, so a provider number or a list position is not an identity.
/// A number is assigned once to a channel's identity (`LiveTVPrototypeChannel.id`) and kept: a new channel takes the next
/// free number, and a channel that leaves the lineup keeps its number reserved, so it has the same number when it returns.
///
/// Two devices may assign independently. `merging(_:)` keeps, per channel, the earliest assignment, and two channels never
/// share a number: the later one moves to the next free number. The result depends only on the merged assignments.
public struct LiveTVStableChannelNumbers: Equatable, Sendable {
    public static let currentVersion = 1
    /// Numbers are small, positive and bounded so that they fit the number column and a portable record.
    public static let maximumNumber = 99_999
    /// Every assignment stays in the profile's preferences and its cloud records, so the count is bounded.
    public static let maximumAssignments = 5_000
    public static let empty = LiveTVStableChannelNumbers()

    public private(set) var assignments: [String: LiveTVChannelNumberAssignment]

    public init() { assignments = [:] }

    /// Normalizes untrusted input: drops out-of-range entries, keeps the earliest `maximumAssignments`, and moves later
    /// holders of a duplicate number to the next free number.
    public init(assignments: [String: LiveTVChannelNumberAssignment]) {
        var valid = assignments.filter {
            !$0.key.isEmpty && (1...Self.maximumNumber).contains($0.value.number)
        }
        if valid.count > Self.maximumAssignments {
            let kept = valid.sorted { Self.precedes($0, $1) }.prefix(Self.maximumAssignments)
            valid = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        self.assignments = Self.resolvingDuplicates(valid)
    }

    public var isEmpty: Bool { assignments.isEmpty }

    public func number(for channelID: String) -> Int? { assignments[channelID]?.number }

    /// Gives every channel in `orderedChannelIDs` that has no number the next free one, in that order. Channels that
    /// already have a number are unchanged, wherever they appear and whether or not they are in the list.
    public func assigning(orderedChannelIDs: [String], at date: Date) -> Self {
        var result = self
        var next = (assignments.values.map(\.number).max() ?? 0) + 1
        let stamp = Int(date.timeIntervalSince1970)
        for id in orderedChannelIDs where result.assignments[id] == nil && !id.isEmpty {
            guard result.assignments.count < Self.maximumAssignments, next <= Self.maximumNumber else { break }
            result.assignments[id] = .init(number: next, assignedAt: stamp)
            next += 1
        }
        return result
    }

    /// Per channel the earliest assignment wins; then no number is shared (see the type's description).
    public func merging(_ other: Self) -> Self {
        merging(assignments: other.assignments)
    }

    public func merging(assignments other: [String: LiveTVChannelNumberAssignment]) -> Self {
        var merged = assignments
        for (id, candidate) in other {
            if let existing = merged[id], !candidate.precedes(existing) { continue }
            merged[id] = candidate
        }
        return Self(assignments: merged)
    }

    /// A channel whose identity changed keeps its number; if both identities were numbered, the earlier assignment wins.
    public func migratingChannelIDs(_ migration: [String: String]) -> Self {
        guard !migration.isEmpty else { return self }
        var migrated: [String: LiveTVChannelNumberAssignment] = [:]
        for (id, assignment) in assignments {
            let newID = migration[id] ?? id
            if let existing = migrated[newID], !assignment.precedes(existing) { continue }
            migrated[newID] = assignment
        }
        return Self(assignments: migrated)
    }

    private static func precedes(
        _ lhs: (key: String, value: LiveTVChannelNumberAssignment),
        _ rhs: (key: String, value: LiveTVChannelNumberAssignment)
    ) -> Bool {
        if lhs.value != rhs.value { return lhs.value.precedes(rhs.value) }
        return lhs.key < rhs.key
    }

    private static func resolvingDuplicates(
        _ assignments: [String: LiveTVChannelNumberAssignment]
    ) -> [String: LiveTVChannelNumberAssignment] {
        var holders: [Int: [(key: String, value: LiveTVChannelNumberAssignment)]] = [:]
        for entry in assignments { holders[entry.value.number, default: []].append((entry.key, entry.value)) }
        guard holders.values.contains(where: { $0.count > 1 }) else { return assignments }
        var result = assignments
        var displaced: [(key: String, value: LiveTVChannelNumberAssignment)] = []
        for group in holders.values where group.count > 1 {
            displaced += group.sorted(by: precedes).dropFirst()
        }
        var next = (assignments.values.map(\.number).max() ?? 0) + 1
        for entry in displaced.sorted(by: precedes) {
            guard next <= maximumNumber else { result[entry.key] = nil; continue }
            result[entry.key] = .init(number: next, assignedAt: entry.value.assignedAt)
            next += 1
        }
        return result
    }
}

/// Compact on disk: parallel arrays keep a few thousand assignments well inside a profile's preferences value.
extension LiveTVStableChannelNumbers: Codable {
    private enum CodingKeys: String, CodingKey { case version, ids, numbers, assignedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A newer version's layout is unknown; it is read as empty rather than failing every Live TV preference.
        guard try container.decodeIfPresent(Int.self, forKey: .version) == Self.currentVersion else {
            self.init()
            return
        }
        let ids = try container.decode([String].self, forKey: .ids)
        let numbers = try container.decode([Int].self, forKey: .numbers)
        let times = try container.decode([Int].self, forKey: .assignedAt)
        guard ids.count == numbers.count, ids.count == times.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .ids, in: container, debugDescription: "Channel number arrays differ in length")
        }
        var decoded: [String: LiveTVChannelNumberAssignment] = [:]
        for index in ids.indices {
            let candidate = LiveTVChannelNumberAssignment(number: numbers[index], assignedAt: times[index])
            if let existing = decoded[ids[index]], !candidate.precedes(existing) { continue }
            decoded[ids[index]] = candidate
        }
        self.init(assignments: decoded)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let ordered = assignments.sorted { $0.value.number < $1.value.number }
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(ordered.map(\.key), forKey: .ids)
        try container.encode(ordered.map(\.value.number), forKey: .numbers)
        try container.encode(ordered.map(\.value.assignedAt), forKey: .assignedAt)
    }
}
