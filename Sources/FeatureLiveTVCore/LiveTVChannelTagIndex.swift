import CoreModels
import Foundation

/// Who is a favourite or was recently watched right now. Those two tags are checked against these sets every time,
/// never stored in the index, so they follow the stars and the watching as they change.
public struct LiveTVLiveTagMembers: Equatable, Sendable {
    public var favouriteIDs: Set<String>
    public var recentIDs: Set<String>

    public init(favouriteIDs: Set<String> = [], recentIDs: Set<String> = []) {
        self.favouriteIDs = favouriteIDs
        self.recentIDs = recentIDs
    }

    func contains(_ channelID: String, tag: String) -> Bool {
        if tag == LiveTVFilterTagCatalog.favouriteChannelsID { return favouriteIDs.contains(channelID) }
        if tag == LiveTVFilterTagCatalog.recentlyWatchedID { return recentIDs.contains(channelID) }
        return false
    }
}

/// Which channel of a lineup carries which tag. Built once per lineup build, off the main actor: one sorted list of
/// channel positions per tag (about five entries per channel), so matching several tags is a list intersection and a
/// count is a list length. Positions refer to the `channels` array the index was built from.
public struct LiveTVChannelTagIndex: Sendable {
    public static let empty = LiveTVChannelTagIndex(channelCount: 0, postings: [:])

    public let channelCount: Int
    /// Stored tags only: tag identifier → ascending channel positions.
    let postings: [String: [Int32]]

    /// The tags at least one channel of the lineup carries, by identifier. The two live tags are not stored.
    public var storedTagIDs: Set<String> { Set(postings.filter { !$0.value.isEmpty }.keys) }

    /// The channels carrying a stored tag.
    public func count(ofStoredTag id: String) -> Int { postings[id]?.count ?? 0 }

    /// Whether the channel at `position` carries the stored tag.
    public func has(_ id: String, at position: Int) -> Bool {
        guard let list = postings[id], position >= 0, position <= Int(Int32.max) else { return false }
        return Self.contains(list, Int32(position))
    }

    /// The positions of the channels that match `tagIDs`, ascending: tags of one section widen (a channel needs any of them), different
    /// sections narrow (it needs one from each) — English + Canada + United States is English channels from either country
    /// (`LiveTVFilterTagCatalog.groups(of:)`). An empty list of tags matches nothing.
    public func positions(
        matching tagIDs: [String], channels: [LiveTVPrototypeChannel], live: LiveTVLiveTagMembers
    ) -> [Int] {
        guard !tagIDs.isEmpty else { return [] }
        // A group of stored tags is the union of their lists; a group with a live tag is checked per candidate.
        var storedLists: [[Int32]] = []
        var liveGroups: [[String]] = []
        for group in LiveTVFilterTagCatalog.groups(of: tagIDs) {
            if group.contains(where: LiveTVFilterTagCatalog.liveTagIDs.contains) {
                liveGroups.append(group)
                continue
            }
            let union = group.reduce([Int32]()) { Self.union($0, postings[$1] ?? []) }
            if union.isEmpty { return [] }
            storedLists.append(union)
        }
        var candidates: [Int]
        if storedLists.isEmpty {
            candidates = Array(0..<min(channelCount, channels.count))
        } else {
            storedLists.sort { $0.count < $1.count }
            candidates = storedLists[0].compactMap { position in
                storedLists.dropFirst().allSatisfy { Self.contains($0, position) } ? Int(position) : nil
            }
        }
        guard !liveGroups.isEmpty else { return candidates }
        candidates.removeAll { position in
            guard position < channels.count else { return true }
            return !liveGroups.allSatisfy { group in
                group.contains { id in
                    LiveTVFilterTagCatalog.liveTagIDs.contains(id)
                        ? live.contains(channels[position].id, tag: id) : has(id, at: position)
                }
            }
        }
        return candidates
    }

    /// A copy whose genre tags also carry what the guide's programme categories say (`genres`: channel position → tag identifiers).
    public func addingGuideGenres(_ genres: [Int: [String]]) -> LiveTVChannelTagIndex {
        guard !genres.isEmpty else { return self }
        var merged = postings
        var additions: [String: [Int32]] = [:]
        for (position, ids) in genres where position >= 0 && position < channelCount {
            for id in ids { additions[id, default: []].append(Int32(position)) }
        }
        for (id, extra) in additions {
            merged[id] = Self.union(merged[id] ?? [], extra.sorted())
        }
        return LiveTVChannelTagIndex(channelCount: channelCount, postings: merged)
    }

    private static func contains(_ list: [Int32], _ value: Int32) -> Bool {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low < list.count && list[low] == value
    }

    private static func union(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let next: Int32
            if j == b.count || (i < a.count && a[i] < b[j]) { next = a[i]; i += 1 } else if i == a.count || b[j] < a[i] { next = b[j]; j += 1 } else { next = a[i]; i += 1; j += 1 }
            if result.last != next { result.append(next) }
        }
        return result
    }

    init(channelCount: Int, postings: [String: [Int32]]) {
        self.channelCount = channelCount
        self.postings = postings
    }
}

extension LiveTVChannelTagIndex {
    /// Derives every channel's stored tags from what the lineup already knows (see `LiveTVChannelTagging`) and indexes them.
    /// Section markers are not channels and carry no tags. `measuredResolution` supplies the measured-quality rule for 4K.
    public static func build(
        channels: [LiveTVPrototypeChannel],
        measuredResolution: (LiveTVPrototypeChannel) -> LiveChannelResolutionLabel? = { $0.measuredResolution() }
    ) -> LiveTVChannelTagIndex {
        var tagger = LiveTVChannelTagging()
        var lists = [[Int32]](repeating: [], count: LiveTVChannelTagging.vocabulary.count)
        var slots: [Int] = []
        for (position, channel) in channels.enumerated() {
            slots.removeAll(keepingCapacity: true)
            tagger.storedSlots(for: channel, measured: measuredResolution, into: &slots)
            for slot in slots { lists[slot].append(Int32(position)) }
        }
        var postings: [String: [Int32]] = [:]
        for (slot, list) in lists.enumerated() where !list.isEmpty { postings[LiveTVChannelTagging.vocabulary[slot]] = list }
        return LiveTVChannelTagIndex(channelCount: channels.count, postings: postings)
    }

    /// Tag identifiers of a single channel, for tests and the detail views (not used when building).
    public static func storedTagIDs(
        of channel: LiveTVPrototypeChannel, measured: LiveChannelResolutionLabel? = nil
    ) -> [String] {
        var tagger = LiveTVChannelTagging()
        var slots: [Int] = []
        tagger.storedSlots(for: channel, measured: { _ in measured }, into: &slots)
        return slots.map { LiveTVChannelTagging.vocabulary[$0] }.sorted()
    }
}
