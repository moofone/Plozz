import CoreModels
import Foundation

/// One tag in the picker with the number of channels that carry it.
public struct LiveTVFilterTagChoice: Hashable, Sendable {
    public let tag: LiveTVFilterTag
    public let count: Int
}

/// A picker section: Suggested, or one of the tag sections.
public struct LiveTVFilterTagSection: Identifiable, Equatable, Sendable {
    public static let suggestedID = "suggested"
    public let id: String
    public let title: String
    public let tags: [LiveTVFilterTagChoice]
}

extension LiveTVPrototypeModel {
    public var favoriteFilterList: [LiveTVFavoriteFilter] { favoriteFilters.filters }
    public var selectedFavoriteFilterID: String? { favoriteFilters.selectedFilterID }
    /// What the guide's heading pill shows instead of "My Channels", or `nil` when no filter is selected.
    public var favoriteFilterHeadingTitle: String? { favoriteFilters.selectedName }

    public func favoriteFilterName(_ filter: LiveTVFavoriteFilter) -> String { favoriteFilters.name(of: filter) }

    public func checkFavoriteFilter(tagIDs: [String], name: String? = nil, editing: String? = nil) -> LiveTVFavoriteFilterState.SaveCheck {
        favoriteFilters.check(tagIDs, name: name, editing: editing)
    }

    /// The tags a new favourite filter starts with (none until the person uses "Save as Default").
    public var favoriteFilterDefaultTagIDs: [String] { favoriteFilters.defaultTagIDs }
    public func canSaveFavoriteFilterDefault(_ tagIDs: [String]) -> Bool { favoriteFilters.canSaveDefault(tagIDs) }
    public func canRestoreFavoriteFilterDefault(_ tagIDs: [String]) -> Bool { favoriteFilters.canRestoreDefault(tagIDs) }
    @discardableResult
    public func saveFavoriteFilterDefault(tagIDs: [String]) -> Bool { favoriteFilters.saveDefault(tagIDs: tagIDs) }

    /// The live favourites and recents the two live tags are checked against.
    var liveTagMembers: LiveTVLiveTagMembers {
        LiveTVLiveTagMembers(favouriteIDs: favoriteIDs, recentIDs: Set(recentChannelIDs))
    }

    // MARK: Selecting

    /// Narrows the guide to a saved filter's channels, or back to My Channels with `nil`. A provider group (category)
    /// does not combine with a filter, so selecting one clears it, as the mockup does.
    @discardableResult
    public func selectFavoriteFilter(_ id: String?) -> Bool {
        guard favoriteFilters.select(id) else { return false }
        isBatchingFilterChanges = true
        category = nil
        isBatchingFilterChanges = false
        refreshVisibleChannels()
        return true
    }

    // MARK: Editing

    @discardableResult
    public func createFavoriteFilter(tagIDs: [String], name: String? = nil) -> LiveTVFavoriteFilter? {
        favoriteFilters.create(tagIDs: tagIDs, name: name)
    }

    /// Saves new tags for a filter; when it is the one selected, the guide follows the edit.
    @discardableResult
    public func updateFavoriteFilter(id: String, tagIDs: [String], name: String? = nil) -> Bool {
        guard favoriteFilters.update(id: id, tagIDs: tagIDs, name: name) else { return false }
        if id == favoriteFilters.selectedFilterID { refreshVisibleChannels() }
        return true
    }

    @discardableResult
    public func moveFavoriteFilter(id: String, _ direction: LiveTVFavoriteFilterState.Direction) -> Bool {
        favoriteFilters.move(id: id, direction)
    }

    /// Deletes a filter; when it was selected the guide returns to My Channels.
    @discardableResult
    public func deleteFavoriteFilter(id: String) -> Bool {
        let wasSelected = favoriteFilters.selectedFilterID == id
        guard favoriteFilters.delete(id: id) else { return false }
        if wasSelected { refreshVisibleChannels() }
        return true
    }

    // MARK: Counts and the picker's tags

    /// Whether a channel counts toward tags: not hidden, and an event only where Live Events is required.
    private func countsToward(_ channel: LiveTVPrototypeChannel, requiresEvents: Bool, hidden: Set<String>) -> Bool {
        (channel.eventSlot != nil) == requiresEvents && !hidden.contains(channel.id)
    }

    /// The channels a filter with these tags would show now (live tags included).
    public func matchingChannelCount(tagIDs: [String]) -> Int {
        guard !tagIDs.isEmpty else { return 0 }
        let index = favoriteFilters.resolvedTagIndex(for: channels)
        let hidden = effectiveHiddenChannelIDs
        let requiresEvents = tagIDs.contains(LiveTVFilterTagCatalog.liveEventsID)
        return index.positions(matching: tagIDs, channels: channels, live: liveTagMembers)
            .reduce(0) { $0 + (countsToward(channels[$1], requiresEvents: requiresEvents, hidden: hidden) ? 1 : 0) }
    }

    /// Counts the filter sheet's tags in the background once the lineup or guide has been quiet for a second, so opening the sheet
    /// reads them (an O(1) cache hit) instead of counting 43,000 channels on the main actor.
    func scheduleFilterCountPrewarm() {
        filterCountTask?.cancel()
        filterCountTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, !channels.isEmpty, let snapshot = favoriteFilters.chipCountSnapshot() else { return }
            let (channels, live, hidden, revision) = (channels, liveTagMembers, effectiveHiddenChannelIDs, catalogRevision)
            let counts = await Task.detached(priority: .utility) {
                LiveTVFavoriteFilterState.countTags(index: snapshot.index, channels: channels, live: live) { channel, tag in
                    (channel.eventSlot != nil) == (tag == LiveTVFilterTagCatalog.liveEventsID) && !hidden.contains(channel.id)
                }
            }.value
            guard !Task.isCancelled, revision == catalogRevision else { return }
            favoriteFilters.storeChipCounts(
                counts, indexRevision: snapshot.indexRevision, live: live, hidden: hidden, catalogRevision: revision)
        }
    }

    public func favoriteFilterCount(_ filter: LiveTVFavoriteFilter) -> Int { matchingChannelCount(tagIDs: filter.tagIDs) }

    /// The tag picker's sections for a search text: Suggested (when not searching), then each section. Only tags at least one
    /// channel of the lineup carries are offered, except the two live tags, which are always available (a filter can be set up
    /// before the first star). `region` is the viewer's ISO country code; its tag leads Suggested. `selectedTagIDs` is the draft's
    /// tags: the Region section follows its countries (none picked: no Region section; see `LiveTVRegionTagScope`).
    public func filterTagSections(
        query: String = "", region: String? = Locale.current.region?.identifier, selectedTagIDs: [String] = []
    ) -> [LiveTVFilterTagSection] {
        let hiddenForCounts = effectiveHiddenChannelIDs
        let counts = favoriteFilters.chipCounts(
            channels: channels, live: liveTagMembers, hidden: hiddenForCounts, catalogRevision: catalogRevision
        ) { [self] channel, tag in
            countsToward(channel, requiresEvents: tag == LiveTVFilterTagCatalog.liveEventsID, hidden: hiddenForCounts)
        }
        func offered(_ tag: LiveTVFilterTag) -> LiveTVFilterTagChoice? {
            let count = counts[tag.id] ?? 0
            guard count > 0 || LiveTVFilterTagCatalog.liveTagIDs.contains(tag.id) else { return nil }
            return LiveTVFilterTagChoice(tag: tag, count: count)
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ choice: LiveTVFilterTagChoice) -> Bool { search.isEmpty || choice.tag.title.lowercased().contains(search) }

        var sections: [LiveTVFilterTagSection] = []
        if search.isEmpty {
            var suggested = LiveTVFilterTagCatalog.suggestedTitles.compactMap { title in
                LiveTVFilterTagCatalog.all.first { $0.title == title }.flatMap(offered)
            }
            if let region, let home = LiveTVChannelTagging.countryTag(forRegion: region).flatMap(offered) {
                suggested.removeAll { $0.tag == home.tag }
                suggested.insert(home, at: 0)
            }
            if !suggested.isEmpty { sections.append(.init(id: LiveTVFilterTagSection.suggestedID, title: "Suggested", tags: suggested)) }
        }
        for section in LiveTVFilterTag.Section.allCases {
            let candidates = section == .region ? regionTags(selectedTagIDs: selectedTagIDs, counts: counts) : LiveTVFilterTagCatalog.tags(in: section)
            let tags = candidates.compactMap { section == .region ? regionChoice($0, counts: counts) : offered($0) }.filter(matches)
            if !tags.isEmpty { sections.append(.init(id: section.rawValue, title: section.title, tags: tags)) }
        }
        return sections
    }

    /// The Region tags the picker offers for the draft's countries.
    private func regionTags(selectedTagIDs: [String], counts: [String: Int]) -> [LiveTVFilterTag] {
        let carried = LiveTVFilterTagCatalog.tags(in: .region).filter { (counts[$0.id] ?? 0) > 0 }
        let index = favoriteFilters.resolvedTagIndex(for: channels)
        let live = liveTagMembers
        return LiveTVRegionTagScope.offeredRegionTags(carriedRegionTags: carried, selectedTagIDs: selectedTagIDs) { country in
            Set(carried.filter { !index.positions(matching: [country, $0.id], channels: channels, live: live).isEmpty }.map(\.id))
        }
    }

    private func regionChoice(_ tag: LiveTVFilterTag, counts: [String: Int]) -> LiveTVFilterTagChoice {
        LiveTVFilterTagChoice(tag: tag, count: counts[tag.id] ?? 0)
    }
}

