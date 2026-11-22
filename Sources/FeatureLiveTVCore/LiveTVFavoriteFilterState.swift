import CoreModels
import Foundation
import Observation

/// The profile's favourite filters, the one selected, and the tag index they are matched against.
///
/// Owned by `LiveTVPrototypeModel`, which applies the selection to the guide's channel set. Every mutation validates first and
/// persists before it changes what views see; a failed save leaves the list as it was and reports `.saveFailed`.
@MainActor
@Observable
public final class LiveTVFavoriteFilterState {
    /// Why a draft cannot be saved (the mockup's `filterState`).
    public enum SaveCheck: Equatable, Sendable {
        case ok
        /// No tag picked.
        case noTags
        /// Another saved filter already requires exactly these tags.
        case duplicate
        /// The tags are those the edited filter already has.
        case unchanged
    }

    public enum Direction: Sendable { case up, down }

    public private(set) var filters: [LiveTVFavoriteFilter] = []
    public private(set) var selectedFilterID: String?
    public private(set) var issue: LiveTVPreferencesIssue?
    /// The tags a new favourite filter starts with, saved by "Save as Default"; empty until the person saves some.
    public private(set) var defaultTagIDs: [String] = []
    /// Changes whenever the tag index is replaced, for observers that cannot watch it.
    public private(set) var tagIndexRevision = 0

    @ObservationIgnored private let store: (any LiveTVFavoriteFilterStoring)?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private(set) var tagIndex: LiveTVChannelTagIndex?
    /// The index as built from the lineup, before the guide's genre votes are added.
    @ObservationIgnored private var baseTagIndex: LiveTVChannelTagIndex?
    @ObservationIgnored private var guideGenres: [String: [String]] = [:]
    /// How many times the counts were made on the calling (main) actor rather than read from the background's result.
    @ObservationIgnored private(set) var mainActorCountPasses = 0
    @ObservationIgnored private var chipCounts: (key: ChipCountKey, counts: [String: Int])?

    private struct ChipCountKey: Equatable {
        let catalogRevision: Int
        let live: LiveTVLiveTagMembers
        let hidden: Set<String>
    }

    public init(store: (any LiveTVFavoriteFilterStoring)? = nil) {
        self.store = store
        guard let store else { isLoaded = true; return }
        do {
#if DEBUG
            filters = try store.load(seeding: LiveTVFavoriteFilterTestSeed.filter)   // TEST-ONLY seed; see LiveTVFavoriteFilterTestSeed
#else
            filters = try store.load()
#endif
            isLoaded = true
            defaultTagIDs = Self.unique(try store.loadDefaultTagIDs())
        } catch {
            issue = .loadFailed
        }
    }

    /// Whether "Save as Default" would change anything: there are tags and they are not already the default.
    public func canSaveDefault(_ tagIDs: [String]) -> Bool {
        let unique = Self.unique(tagIDs)
        return !unique.isEmpty && Set(unique) != Set(defaultTagIDs)
    }

    /// Whether "Restore Default" would change anything: a default exists and the draft is not already exactly it.
    public func canRestoreDefault(_ tagIDs: [String]) -> Bool {
        !defaultTagIDs.isEmpty && Set(Self.unique(tagIDs)) != Set(defaultTagIDs)
    }

    /// Keeps these tags as the start of every new filter; a failed save leaves the default as it was.
    @discardableResult
    public func saveDefault(tagIDs: [String]) -> Bool {
        guard canSaveDefault(tagIDs) else { return false }
        let unique = Self.unique(tagIDs)
        if let store {
            do { try store.saveDefaultTagIDs(unique) } catch { issue = .saveFailed; return false }
        }
        defaultTagIDs = unique
        return true
    }

    // MARK: Reading

    public var selectedFilter: LiveTVFavoriteFilter? { filters.first { $0.id == selectedFilterID } }
    public var selectedTagIDs: [String] { selectedFilter?.tagIDs ?? [] }
    public var selectedName: String? { selectedFilter.map(name(of:)) }

    /// The filter's name: its tags' short names joined with " · " (the mockup's "Sports · 4K").
    /// The filter's name: the one typed for it, else its tags' short names joined with " · " (the mockup's "Sports · 4K").
    public func name(of filter: LiveTVFavoriteFilter) -> String { filter.name ?? LiveTVFilterTagCatalog.name(for: filter.tagIDs) }

    /// A typed name as it is stored: trimmed, and nil when empty or the same as the tags' own name (it then keeps following the tags).
    public static func storedName(_ typed: String?, tagIDs: [String]) -> String? {
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == LiveTVFilterTagCatalog.name(for: tagIDs) ? nil : trimmed
    }

    /// Whether the selected filter reads the live favourites or recents, so a star or a watch changes its channel set.
    func selectionUsesFavourites() -> Bool { selectedTagIDs.contains(LiveTVFilterTagCatalog.favouriteChannelsID) }
    func selectionUsesRecents() -> Bool { selectedTagIDs.contains(LiveTVFilterTagCatalog.recentlyWatchedID) }
    var selectionIncludesEvents: Bool { selectedTagIDs.contains(LiveTVFilterTagCatalog.liveEventsID) }

    /// Whether `tagIDs` could be saved as a new filter, or as `editing` (an existing filter's identifier).
    /// `name` is the typed name (nil: named after the tags); changing only the name of the edited filter is a change.
    public func check(_ tagIDs: [String], name: String? = nil, editing: String? = nil) -> SaveCheck {
        let unique = Self.unique(tagIDs)
        guard !unique.isEmpty else { return .noTags }
        if filters.contains(where: { $0.id != editing && $0.hasSameTags(as: unique) }) { return .duplicate }
        if let editing, let existing = filters.first(where: { $0.id == editing }), existing.hasSameTags(as: unique),
           existing.name == Self.storedName(name, tagIDs: unique) { return .unchanged }
        return .ok
    }

    // MARK: Changing

    /// Saves a new filter at the end of the list.
    @discardableResult
    public func create(tagIDs: [String], name: String? = nil) -> LiveTVFavoriteFilter? {
        let unique = Self.unique(tagIDs)
        guard check(unique) == .ok else { return nil }
        let filter = LiveTVFavoriteFilter(tagIDs: unique, name: Self.storedName(name, tagIDs: unique))
        return persist(filters + [filter]) ? filter : nil
    }

    /// Replaces an existing filter's tags, keeping its place and selection.
    @discardableResult
    public func update(id: String, tagIDs: [String], name: String? = nil) -> Bool {
        let unique = Self.unique(tagIDs)
        guard let index = filters.firstIndex(where: { $0.id == id }), check(unique, name: name, editing: id) == .ok else { return false }
        var updated = filters
        updated[index].tagIDs = unique
        updated[index].name = Self.storedName(name, tagIDs: unique)
        return persist(updated)
    }

    @discardableResult
    public func move(id: String, _ direction: Direction) -> Bool {
        guard let index = filters.firstIndex(where: { $0.id == id }) else { return false }
        let target = direction == .up ? index - 1 : index + 1
        guard filters.indices.contains(target) else { return false }
        var updated = filters
        updated.swapAt(index, target)
        return persist(updated)
    }

    /// Deletes a filter; when it was selected the guide returns to My Channels.
    @discardableResult
    public func delete(id: String) -> Bool {
        guard filters.contains(where: { $0.id == id }) else { return false }
        guard persist(filters.filter { $0.id != id }) else { return false }
        return true
    }

    /// Selects a saved filter, or `nil` for My Channels. An unknown identifier selects nothing.
    @discardableResult
    func select(_ id: String?) -> Bool {
        let target = id.flatMap { id in filters.contains { $0.id == id } ? id : nil }
        guard target == id, selectedFilterID != target else { return false }
        selectedFilterID = target
        return true
    }

    private func persist(_ updated: [LiveTVFavoriteFilter]) -> Bool {
        guard isLoaded else { issue = .loadFailed; return false }
        if let store {
            do { try store.save(updated) } catch { issue = .saveFailed; return false }
        }
        filters = updated
        issue = nil
        if let selectedFilterID, !updated.contains(where: { $0.id == selectedFilterID }) { self.selectedFilterID = nil }
        return true
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { LiveTVFilterTagCatalog.tag(id: $0) != nil && seen.insert($0).inserted }
    }

    // MARK: Tag index

    func invalidateTagIndex() {
        tagIndex = nil
        baseTagIndex = nil
        chipCounts = nil
    }

    /// Installs the index a lineup build produced.
    func install(tagIndex base: LiveTVChannelTagIndex, channels: [LiveTVPrototypeChannel]) {
        baseTagIndex = base
        tagIndex = base.addingGuideGenres(genresByPosition(in: channels))
        chipCounts = nil
        tagIndexRevision &+= 1
    }

    /// The index of `channels`, built here when no background build supplied one.
    func resolvedTagIndex(for channels: [LiveTVPrototypeChannel]) -> LiveTVChannelTagIndex {
        if let tagIndex { return tagIndex }
        install(tagIndex: LiveTVChannelTagIndex.build(channels: channels), channels: channels)
        return tagIndex ?? .empty
    }

    /// The identifiers of the channels that carry every tag of the selected filter, or `nil` when none is selected.
    func selectedMembers(channels: [LiveTVPrototypeChannel], live: LiveTVLiveTagMembers) -> Set<String>? {
        guard let selected = selectedFilter else { return nil }
        return Self.memberIDs(of: selected.tagIDs, index: resolvedTagIndex(for: channels), channels: channels, live: live)
    }

    nonisolated static func memberIDs(
        of tagIDs: [String], index: LiveTVChannelTagIndex, channels: [LiveTVPrototypeChannel], live: LiveTVLiveTagMembers
    ) -> Set<String> {
        Set(index.positions(matching: tagIDs, channels: channels, live: live).map { channels[$0].id })
    }

    /// Guide programme categories vote for genres: a channel's genre tags also include those named by at least half
    /// of its categorised listings. Replaces the previous vote.
    @discardableResult
    func setGuideGenres(_ genres: [String: [String]], channels: [LiveTVPrototypeChannel]) -> Bool {
        guard genres != guideGenres else { return false }
        guideGenres = genres
        guard let baseTagIndex else { return true }
        tagIndex = baseTagIndex.addingGuideGenres(genresByPosition(in: channels))
        chipCounts = nil
        tagIndexRevision &+= 1
        return true
    }

    private func genresByPosition(in channels: [LiveTVPrototypeChannel]) -> [Int: [String]] {
        guard !guideGenres.isEmpty else { return [:] }
        var result: [Int: [String]] = [:]
        for (position, channel) in channels.enumerated() {
            if let genres = guideGenres[channel.id] { result[position] = genres }
        }
        return result
    }

    // MARK: Counts

    /// What a background count needs from the state, or `nil` when the lineup's tag index has not been installed yet.
    func chipCountSnapshot() -> (index: LiveTVChannelTagIndex, indexRevision: Int)? {
        tagIndex.map { ($0, tagIndexRevision) }
    }

    /// Per tag, counted off the main actor; the same arithmetic as ``chipCounts(channels:live:hidden:catalogRevision:isEligible:)``.
    nonisolated static func countTags(
        index: LiveTVChannelTagIndex, channels: [LiveTVPrototypeChannel], live: LiveTVLiveTagMembers,
        isEligible: (LiveTVPrototypeChannel, _ tag: String) -> Bool
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tag in LiveTVFilterTagCatalog.all where counts[tag.id] == nil {
            counts[tag.id] = index.positions(matching: [tag.id], channels: channels, live: live)
                .reduce(0) { $0 + (isEligible(channels[$1], tag.id) ? 1 : 0) }
        }
        return counts
    }

    /// Keeps counts computed in the background, unless the tag index changed meanwhile.
    func storeChipCounts(
        _ counts: [String: Int], indexRevision: Int, live: LiveTVLiveTagMembers, hidden: Set<String>, catalogRevision: Int
    ) {
        guard indexRevision == tagIndexRevision else { return }
        chipCounts = (ChipCountKey(catalogRevision: catalogRevision, live: live, hidden: hidden), counts)
    }

    /// Per tag, how many channels in `eligible` carry it. Cached until the catalogue, the live members or the hidden set change.
    func chipCounts(
        channels: [LiveTVPrototypeChannel], live: LiveTVLiveTagMembers, hidden: Set<String>, catalogRevision: Int,
        isEligible: (LiveTVPrototypeChannel, _ tag: String) -> Bool
    ) -> [String: Int] {
        let key = ChipCountKey(catalogRevision: catalogRevision, live: live, hidden: hidden)
        if let cached = chipCounts, cached.key == key { return cached.counts }
        mainActorCountPasses += 1
        let index = resolvedTagIndex(for: channels)
        var counts: [String: Int] = [:]
        for tag in LiveTVFilterTagCatalog.all where counts[tag.id] == nil {
            counts[tag.id] = index.positions(matching: [tag.id], channels: channels, live: live)
                .reduce(0) { $0 + (isEligible(channels[$1], tag.id) ? 1 : 0) }
        }
        chipCounts = (key, counts)
        return counts
    }
}
