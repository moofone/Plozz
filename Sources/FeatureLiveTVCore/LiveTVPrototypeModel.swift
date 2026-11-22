import CoreModels
import CoreNetworking
import Foundation
import MetadataKit
import Observation

public enum LiveTVPrototypeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case iptv
    case jellyfin
    case plex
    case emby
    case plozz

    public var id: String { rawValue }
}

public enum LiveTVPrototypeScenario: String, CaseIterable, Identifiable, Sendable {
    case noGuide
    case mixedGuide
    case fullGuide
    case staleGuide
    case failedGuide

    public var id: String { rawValue }
}

public enum LiveTVPrototypeSort: String, CaseIterable, Identifiable, Sendable {
    case channelNumber
    case name

    public var id: String { rawValue }
}

public enum LiveTVPrototypeDataError: Error {
    case duplicateChannelID
    case invalidProgram
}

public enum LiveTVPreferencesIssue: Equatable, Sendable {
    case loadFailed
    case saveFailed
}

public struct LiveTVPrototypeChannel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let name: String
    public let category: String
    public let symbol: String
    public let accent: Int
    public let source: LiveTVPrototypeSource
    public let tagline: String
    public let logoURL: URL?
    public let streamURL: URL?
    public let logoNeedsDarkBackground: Bool
    public let guideID: String?
    public let guideName: String?
    public let httpHeaders: [String: String]
    public let playlistSourceID: String?
    public let language: String?
    public let country: String?
    public let groups: [String]?
    public let plozzChannelMood: LibraryChannelArtworkMood?
    /// Channel icon the matched XMLTV guide declares; absent until a guide import matches it.
    /// Absent from caches written before guide icons existed, which decode as `nil`.
    public let guideLogoURL: URL?
    /// What the provider wrote into the channel name: country and language prefix, `HD`/`4K`/`60fps` descriptors.
    /// Derived when the catalog is built (`IPTVChannelName.split`), so it is not encoded.
    public let tags: [IPTVChannelTag]
    /// Set when the playlist entry is a PPV/event slot (`LiveTVEventSlotClassifier`); derived with `tags`, not encoded.
    public let eventSlot: LiveTVEventSlot?
    /// The show a 24/7 single-show channel repeats (`LiveTVChannelKind.showLoopTitle`); derived with `tags`, not encoded.
    public let loopTitle: String?
    private enum CodingKeys: String, CodingKey {
        case id, number, name, category, symbol, accent, source, tagline, logoURL, streamURL
        case logoNeedsDarkBackground, guideID, guideName, httpHeaders, playlistSourceID
        case language, country, groups, plozzChannelMood, guideLogoURL
    }
    /// A playlist line that only labels a run of channels, such as `#### CANADA NEWS ####`.
    /// An IPTV entry whose trimmed name is wrapped in "#" or "*" decoration is a marker when
    /// - there are three or more decoration characters on each side, or
    /// - there are exactly two on each side and the inner text, normalised, equals or contains
    ///   its own provider group label (the part after `CC|`) or is contained by it.
    /// So "## UK|BBC One H D ##" and "CA: CHANNEL #1" stay channels. Markers stay in the supplied
    /// lineup but never enter the catalog: not the guide, counts, search, multiview, favourites
    /// or logo matching. Nothing else is parsed from the name.
    public var isSectionMarker: Bool {
        guard source == .iptv, let opening = name.first(where: { !$0.isWhitespace }), opening == "#" || opening == "*" else { return false }
        return categories.contains { IPTVChannelName.isSectionMarker(name: name, groupTitle: $0) }
    }
    public var languages: [String] { Self.metadataValues(language) }
    public var countries: [String] { Self.metadataValues(country) }
    public var categories: [String] { groups?.isEmpty == false ? (groups ?? []) : [category] }
    public var configuredSourceID: String? { playlistSourceID }
    public var organizationMetadata: LiveTVChannelOrganizationMetadata? {
        guard source == .iptv else { return nil }
        return .init(sourceID: configuredSourceID, categories: categories, countries: countries, languages: languages)
    }

    public init(
        id: String,
        number: Int,
        name: String,
        category: String,
        symbol: String,
        accent: Int,
        source: LiveTVPrototypeSource,
        tagline: String,
        logoURL: URL? = nil,
        streamURL: URL? = nil,
        logoNeedsDarkBackground: Bool = false,
        guideID: String? = nil,
        guideName: String? = nil,
        httpHeaders: [String: String] = [:],
        playlistSourceID: String? = nil,
        configuredSourceID: String? = nil,
        language: String? = nil,
        country: String? = nil,
        groups: [String]? = nil,
        plozzChannelMood: LibraryChannelArtworkMood? = nil,
        tags: [IPTVChannelTag] = [],
        eventSlot: LiveTVEventSlot? = nil,
        guideLogoURL: URL? = nil,
        loopTitle: String? = nil
    ) {
        precondition((0...5).contains(accent), "Live TV fixture accent must be between 0 and 5.")
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.symbol = symbol
        self.accent = accent
        self.source = source
        self.tagline = tagline
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.logoNeedsDarkBackground = logoNeedsDarkBackground
        self.guideID = guideID
        self.guideName = guideName
        self.httpHeaders = httpHeaders
        self.playlistSourceID = configuredSourceID ?? playlistSourceID
        self.language = language
        self.country = country
        self.groups = groups
        self.plozzChannelMood = plozzChannelMood
        self.tags = tags
        self.eventSlot = eventSlot
        self.guideLogoURL = guideLogoURL
        self.loopTitle = loopTitle
    }

    /// The same channel carrying `number`.
    public func withNumber(_ number: Int) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: number, name: name, category: category, symbol: symbol, accent: accent, source: source,
            tagline: tagline, logoURL: logoURL, streamURL: streamURL, logoNeedsDarkBackground: logoNeedsDarkBackground,
            guideID: guideID, guideName: guideName, httpHeaders: httpHeaders, playlistSourceID: playlistSourceID,
            language: language, country: country, groups: groups, plozzChannelMood: plozzChannelMood, tags: tags,
            eventSlot: eventSlot, guideLogoURL: guideLogoURL, loopTitle: loopTitle
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id), number: try values.decode(Int.self, forKey: .number),
            name: try values.decode(String.self, forKey: .name), category: try values.decode(String.self, forKey: .category),
            symbol: try values.decode(String.self, forKey: .symbol), accent: try values.decode(Int.self, forKey: .accent),
            source: try values.decode(LiveTVPrototypeSource.self, forKey: .source),
            tagline: try values.decode(String.self, forKey: .tagline),
            logoURL: try values.decodeIfPresent(URL.self, forKey: .logoURL),
            streamURL: try values.decodeIfPresent(URL.self, forKey: .streamURL),
            logoNeedsDarkBackground: try values.decode(Bool.self, forKey: .logoNeedsDarkBackground),
            guideID: try values.decodeIfPresent(String.self, forKey: .guideID),
            guideName: try values.decodeIfPresent(String.self, forKey: .guideName),
            httpHeaders: try values.decode([String: String].self, forKey: .httpHeaders),
            playlistSourceID: try values.decodeIfPresent(String.self, forKey: .playlistSourceID),
            language: try values.decodeIfPresent(String.self, forKey: .language),
            country: try values.decodeIfPresent(String.self, forKey: .country),
            groups: try values.decodeIfPresent([String].self, forKey: .groups),
            plozzChannelMood: try values.decodeIfPresent(LibraryChannelArtworkMood.self, forKey: .plozzChannelMood),
            guideLogoURL: try values.decodeIfPresent(URL.self, forKey: .guideLogoURL)
        )
    }

    static func metadataValues(_ value: String?) -> [String] {
        (value ?? "").split { $0 == ";" || $0 == "," || $0 == "/" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct LiveTVPrototypeProgram: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let channelID: String
    public let title: String
    public let subtitle: String
    public let start: Date
    public let end: Date
    public let details: LiveTVProgramDetails?
    public let libraryItem: LibraryChannelItem?

    /// Names a channel that repeats one show all day; digits and a slash, the same in every language.
    public static let loopTag = "24/7"
    private static let loopIDPrefix = "plozz-loop-"
    /// The id of the single cell a 24/7 loop channel shows (`LiveTVPrototypeChannel.loopTitle`).
    public static func loopID(channelID: String) -> String { loopIDPrefix + channelID }
    /// A cell that stands for a channel looping one show: it has no start or end the viewer should read.
    public var isContinuousLoop: Bool { id.hasPrefix(Self.loopIDPrefix) }

    public init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String,
        start: Date,
        end: Date,
        details: LiveTVProgramDetails? = nil,
        libraryItem: LibraryChannelItem? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.start = start
        self.end = end
        self.details = details
        self.libraryItem = libraryItem
    }

    public func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return date < start ? 0 : 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}

extension LiveTVPrototypeChannel {
    /// The channel as the player lists it, with exactly `resolvedLogoURL` (nil draws the name).
    public func playerItem(program: LiveChannelProgramInfo?, resolvedLogoURL: URL?) -> LiveChannelOnNowItem {
        LiveChannelOnNowItem(
            channelID: id, channelName: name, number: number, logoURL: resolvedLogoURL,
            plozzChannelID: source == .plozz ? id : nil,
            plozzChannelMood: source == .plozz ? plozzChannelMood : nil, program: program
        )
    }

    /// The channel as the player lists it.
    /// `logoURL` replaces the provider's, such as the user's or TMDB's choice.
    public func playerItem(program: LiveChannelProgramInfo?, logoURL: URL? = nil) -> LiveChannelOnNowItem {
        LiveChannelOnNowItem(
            channelID: id, channelName: name, number: number, logoURL: logoURL ?? displayedLogoURL,
            plozzChannelID: source == .plozz ? id : nil,
            plozzChannelMood: source == .plozz ? plozzChannelMood : nil, program: program
        )
    }
}

extension LiveTVPrototypeProgram {
    /// The programme as the player shows it.
    public var playerInfo: LiveChannelProgramInfo {
        LiveChannelProgramInfo(
            title: title,
            subtitle: subtitle.isEmpty ? details?.episode : subtitle,
            description: details?.description,
            start: start, end: end,
            artworkURL: details?.artworkURL
        )
    }
}

public struct LiveTVProgramDetails: Codable, Equatable, Sendable {
    public var description: String?
    public var episode: String?
    public var categories: [String]
    public var languages: [String]
    public var rating: String?
    public var artworkURL: URL?
    public var endWasInferred: Bool

    var retainedTextBytes: Int {
        var count = description?.utf8.count ?? 0
        count += categories.reduce(0) { $0 + $1.utf8.count }
        count += languages.reduce(0) { $0 + $1.utf8.count }
        count += episode?.utf8.count ?? 0
        count += rating?.utf8.count ?? 0
        count += artworkURL?.absoluteString.utf8.count ?? 0
        return count
    }

    public init(
        description: String? = nil, episode: String? = nil, categories: [String] = [],
        languages: [String] = [], rating: String? = nil, artworkURL: URL? = nil,
        endWasInferred: Bool = false
    ) {
        self.description = description
        self.episode = episode
        self.categories = categories
        self.languages = languages
        self.rating = rating
        self.artworkURL = artworkURL
        self.endWasInferred = endWasInferred
    }
}

@MainActor
@Observable
private final class LiveTVPrototypePreferencesState {
    var cleanChannelNames = LiveTVViewSettings().cleanChannelNames
    var recentChannelIDs: [String] = []
    var favoriteIDs: Set<String> = []
    var favoriteMultiviews: [LiveTVMultiviewFavorite] = []
    var favoriteOrder: [String] = []
    var favoriteChannels: [LiveTVHiddenChannel] = []
    var channelOverrides: [String: LiveTVChannelMetadataOverride] = [:]
    var hiddenChannels: [LiveTVHiddenChannel] = []
    var issue: LiveTVPreferencesIssue?
}

@MainActor
@Observable
private final class LiveTVPrototypeGuideState {
    var programs: [String: [LiveTVPrototypeProgram]] = [:]
    var knownChannelIDs: Set<String> = []
    var pendingChannelIDs: Set<String> = []
    /// Whether lists draw channel numbers (the profile's "Show Channel Numbers" setting).
    var showsChannelNumbers = false
}

@MainActor
@Observable
private final class LiveTVPrototypeLogoState {
    /// The logos to draw: the user's choices and TMDB/Wikidata matches.
    var urls: [LiveTVChannelLogoKey: URL] = [:]
    /// Changes whenever ``urls`` does, for observers that cannot watch the dictionary.
    var revision = 0
    /// Changes when the regional logo counts were recomputed.
    var regionRevision = 0
    /// Wikidata/Commons team crests of league events, in title order; `nil` where a team has no crest that may be drawn.
    var crests: [LiveTVChannelLogoKey: [URL?]] = [:]
}

private struct LiveTVCatalogIndex<Entry: Identifiable> {
    let entries: [Entry]
    let ordinals: [Entry.ID: Int]

    init(_ entries: [Entry] = []) {
        self.entries = entries
        ordinals = Dictionary(uniqueKeysWithValues: entries.enumerated().lazy.map { ($0.element.id, $0.offset + 1) })
    }

    subscript(id: Entry.ID) -> Entry? {
        guard let ordinal = ordinals[id] else { return nil }
        return entries[ordinal - 1]
    }
}

extension LiveTVCatalogIndex: Sendable where Entry: Sendable, Entry.ID: Sendable {}

public struct LiveTVBrowseCategory: Identifiable, Equatable, Sendable {
    public let name: String
    public let channelCount: Int
    public var id: String { name }
}

@MainActor
@Observable
public final class LiveTVPrototypeModel {
    public var favoriteMultiviews: [LiveTVMultiviewFavorite] { preferences.favoriteMultiviews }

    @discardableResult
    public func saveMultiviewFavorite(_ favorite: LiveTVMultiviewFavorite) -> Bool {
        guard favorite.isValid else {
            preferencesIssue = .saveFailed
            return false
        }
        var updated = favoriteMultiviews
        updated.removeAll { $0.id == favorite.id }
        updated.append(favorite)
        return persistMultiviewFavorites(updated)
    }

    @discardableResult
    public func removeMultiviewFavorite(_ id: String) -> Bool {
        persistMultiviewFavorites(favoriteMultiviews.filter { $0.id != id })
    }

    private func persistMultiviewFavorites(_ favorites: [LiveTVMultiviewFavorite]) -> Bool {
        persistPreferences(LiveTVPreferences(
            favoriteIDs: preferences.favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browsePreferences, favoriteMultiviews: favorites, organization: organization))
    }

    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refreshVisibleChannels(refreshCategoryCounts: false)
        }
    }

    public var category: String? {
        didSet {
            guard category != oldValue else { return }
            refreshVisibleChannels(refreshCategoryCounts: false)
        }
    }

    public var source: LiveTVPrototypeSource? {
        didSet {
            guard source != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var language: String? {
        didSet { if language != oldValue { refreshVisibleChannels() } }
    }
    public var country: String? {
        didSet { if country != oldValue { refreshVisibleChannels() } }
    }

    public var playlistSourceID: String? {
        didSet {
            guard playlistSourceID != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var configuredSourceID: String? {
        get { playlistSourceID }
        set { playlistSourceID = newValue }
    }

    public var favoritesOnly = false {
        didSet {
            guard favoritesOnly != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    public var guideOnly = false {
        didSet {
            guard guideOnly != oldValue else { return }
            refreshVisibleChannels()
        }
    }

    /// Whether the guide opens with a Recently watched row. Recents are still
    /// recorded while it is off, so turning it back on restores the row.
    /// Whether the guide, search results and other lists show channel numbers. The right channel panel always shows its
    /// number. Set from the profile's Live TV settings; off until then.
    public var showsChannelNumbers: Bool {
        get { guideState.showsChannelNumbers }
        set { guideState.showsChannelNumbers = newValue }
    }

    public var showsRecentChannels = true {
        didSet {
            guard showsRecentChannels != oldValue else { return }
            refreshGuideChannels()
        }
    }

    public var sort: LiveTVPrototypeSort = .channelNumber {
        didSet {
            guard sort != oldValue else { return }
            refreshVisibleChannels(refreshCategoryCounts: false)
        }
    }

    public var cleanChannelNames: Bool {
        get { preferences.cleanChannelNames }
        set {
            guard preferences.cleanChannelNames != newValue else { return }
            preferences.cleanChannelNames = newValue
            rebuildCatalog()
        }
    }

    public var scenario: LiveTVPrototypeScenario {
        didSet {
            if guideOnly && scenario != oldValue { refreshVisibleChannels() }
        }
    }

    public var isLargeCatalog: Bool {
        didSet {
            guard isLargeCatalog != oldValue else { return }
            rebuildCatalog()
        }
    }

    private struct FilteredCatalog: Sendable {
        let channels: [LiveTVPrototypeChannel]
        let categories: [String]
        var categoryCounts: [String: Int] = [:]
        var totalCount = 0
        var activeEventCount = 0
        /// How many channels the last filter pass looked at (for a query: those whose text contains it).
        var candidatesExamined = 0
    }
    private var filteredCatalog = FilteredCatalog(channels: [], categories: [])
    /// The Events filter is selected (see `LiveTVEventSlotClassifier.filterName`).
    public var showsEvents: Bool { category == LiveTVEventSlotClassifier.filterName }
    /// Event slots with an event on now or coming, in the lineup the filters leave (the Events tray entry's count).
    public var activeEventCount: Int { filteredCatalog.activeEventCount }
    /// Channels the latest filter or search pass examined; a deterministic measure of its work.
    var filterCandidatesExamined: Int { filteredCatalog.candidatesExamined }
    var filterCountPassesOnMainActor: Int { favoriteFilters.mainActorCountPasses }
    public var visibleChannels: [LiveTVPrototypeChannel] { filteredCatalog.channels }
    public var matchingCategories: [String] { filteredCatalog.categories }
    public var browsingCategories: [LiveTVBrowseCategory] {
        let summary = provisionalBrowse ?? browseSummary
        return summary.categories.compactMap { name in
            guard let count = summary.categoryCounts[name], count > 0 else { return nil }
            return LiveTVBrowseCategory(name: name, channelCount: count)
        }
    }
    /// Category counts to show while only the rows last on screen have been published.
    /// They describe the whole lineup those rows came from.
    public private(set) var provisionalBrowse: LiveTVBrowseSummary? {
        get { organizationState.provisionalBrowse }
        set { organizationState.provisionalBrowse = newValue }
    }
    public func setProvisionalBrowse(_ summary: LiveTVBrowseSummary?) {
        if provisionalBrowse != summary { provisionalBrowse = summary }
    }
    public var browseSummary: LiveTVBrowseSummary {
        LiveTVBrowseSummary(
            categories: categories, categoryCounts: filteredCatalog.categoryCounts,
            totalCount: filteredCatalog.totalCount
        )
    }
    public var matchingCategoryResults: [LiveTVBrowseCategory] {
        matchingCategories.map { LiveTVBrowseCategory(name: $0, channelCount: categoryChannelCount($0)) }
    }
    public func categoryChannelCount(_ category: String?) -> Int {
        let summary = provisionalBrowse ?? browseSummary
        return category.map { summary.categoryCounts[$0, default: 0] } ?? summary.totalCount
    }
    public private(set) var guideChannels: [LiveTVGuideChannel] = []
    @ObservationIgnored private var orderedGuideRowIDs: [LiveTVGuideRowID] = []
    @ObservationIgnored private var guideEntries = LiveTVCatalogIndex<LiveTVGuideChannel>()
    public var guideRowIDs: [LiveTVGuideRowID] {
        _ = guideChannels
        return orderedGuideRowIDs
    }

    public func guideEntry(for row: LiveTVGuideRowID) -> LiveTVGuideChannel? {
        _ = guideChannels
        return guideEntries[row]
    }

    /// A removed section occurrence falls back to the first remaining occurrence.
    public func guideRowIndex(near row: LiveTVGuideRowID?) -> Int? {
        _ = guideChannels
        guard let row else { return nil }
        if let ordinal = guideEntries.ordinals[row] { return ordinal - 1 }
        for section in [LiveTVGuideSection.recent, .favorites, .channels] {
            if let ordinal = guideEntries.ordinals[.init(channelID: row.channelID, section: section)] {
                return ordinal - 1
            }
        }
        return nil
    }
    private let preferences = LiveTVPrototypePreferencesState()
    public private(set) var recentChannelIDs: [String] {
        get { preferences.recentChannelIDs }
        set { preferences.recentChannelIDs = newValue }
    }
    public private(set) var channels: [LiveTVPrototypeChannel] = []
    public private(set) var catalogRevision = 0 {
        didSet { scheduleFilterCountPrewarm() }
    }
    @ObservationIgnored var filterCountTask: Task<Void, Never>?
    public private(set) var favoriteIDs: Set<String> {
        get { organizationState.effectiveFavoriteIDs }
        set {
            preferences.favoriteIDs = newValue
            organizationState.effectiveFavoriteIDs = newValue.union(categoryFavoriteIDs)
        }
    }
    private let organizationState = LiveTVChannelOrganizationState()
    public private(set) var organization: LiveTVChannelOrganization {
        get { organizationState.organization }
        set { organizationState.organization = newValue }
    }
    public private(set) var categorySummaries: [LiveTVCategorySummary] {
        get { organizationState.categories }
        set { organizationState.categories = newValue }
    }
    public private(set) var hiddenChannelEntries: [LiveTVHiddenChannelEntry] {
        get { organizationState.hiddenChannels }
        set { organizationState.hiddenChannels = newValue }
    }
    public private(set) var organizationCountries: [String] {
        get { organizationState.countries }
        set { organizationState.countries = newValue }
    }
    public private(set) var organizationLanguages: [String] {
        get { organizationState.languages }
        set { organizationState.languages = newValue }
    }
    private var categoryFavoriteIDs: Set<String> {
        get { organizationState.favoriteIDs }
        set {
            organizationState.favoriteIDs = newValue
            organizationState.effectiveFavoriteIDs = preferences.favoriteIDs.union(newValue)
        }
    }
    private var organizationHiddenChannelIDs: Set<String> {
        get { organizationState.hiddenIDs }
        set { organizationState.hiddenIDs = newValue }
    }
    public private(set) var favoriteOrder: [String] {
        get { preferences.favoriteOrder }
        set { preferences.favoriteOrder = newValue }
    }
    public private(set) var favoriteChannels: [LiveTVHiddenChannel] {
        get { preferences.favoriteChannels }
        set { preferences.favoriteChannels = newValue }
    }
    public var homeFavoriteChannelIDs: [String] {
        let hidden = effectiveHiddenChannelIDs
        let explicit = favoriteOrder.filter { !hidden.contains($0) }
        let limit = HomeLiveTVSnapshot.maximumCandidateCount
        let categoryFavoriteIDs = categoryFavoriteIDs
        let explicitFavoriteIDs = preferences.favoriteIDs
        return Array((explicit.prefix(limit) + channels.lazy
            .filter { categoryFavoriteIDs.contains($0.id) && !hidden.contains($0.id) && !explicitFavoriteIDs.contains($0.id) }
            .prefix(max(0, limit - explicit.count)).map(\.id)).prefix(limit))
    }
    public private(set) var channelOverrides: [String: LiveTVChannelMetadataOverride] {
        get { preferences.channelOverrides }
        set { preferences.channelOverrides = newValue }
    }
    public var unavailableFavorites: [LiveTVHiddenChannel] {
        let saved = Dictionary(uniqueKeysWithValues: favoriteChannels.map { ($0.id, $0) })
        return favoriteOrder.filter { channelsByID[$0] == nil }.map { id in
            saved[id] ?? LiveTVHiddenChannel(id: id, name: "Unavailable channel")
        }
    }
    public var programmeSearchChannelIDs: Set<String> {
        let hidden = effectiveHiddenChannelIDs
        return Set(channels.filter {
            !hidden.contains($0.id)
                && ($0.eventSlot != nil) == showsEvents
                && (category == nil || showsEvents || $0.categories.contains { Self.normalized($0) == category.map(Self.normalized) })
                && (source == nil || $0.source == source)
                && (playlistSourceID == nil || $0.playlistSourceID == playlistSourceID)
                && (language == nil || $0.languages.contains { Self.normalized($0) == language.map(Self.normalized) })
                && (country == nil || $0.countries.contains { Self.normalized($0) == country.map(Self.normalized) })
                && (!favoritesOnly || favoriteIDs.contains($0.id))
                && (!guideOnly || hasGuide(for: $0))
        }.map(\.id))
    }
    public private(set) var languages: [String] = []
    public private(set) var countries: [String] = []
    public private(set) var hiddenChannels: [LiveTVHiddenChannel] {
        get { preferences.hiddenChannels }
        set { preferences.hiddenChannels = newValue }
    }
    public var hiddenChannelIDs: Set<String> { Set(hiddenChannels.map(\.id)) }
    public private(set) var scanHiddenChannelIDs: Set<String> = []
    public var effectiveHiddenChannelIDs: Set<String> {
        hiddenChannelIDs.union(scanHiddenChannelIDs).union(organizationHiddenChannelIDs)
    }

    public func setScanHiddenChannelIDs(_ ids: Set<String>) {
        guard scanHiddenChannelIDs != ids else { return }
        scanHiddenChannelIDs = ids
        catalogRevision &+= 1
        refreshOrganization()
        refreshCategories()
        refreshVisibleChannels()
    }
    /// Source authorization is enforced when admitting the catalog. Picker results
    /// exclude hidden channels but never depend on the main guide's browse filters.
    public var unhiddenCatalogChannels: [LiveTVPrototypeChannel] {
        let hidden = effectiveHiddenChannelIDs
        return channels.filter { !hidden.contains($0.id) }
    }

    /// Apply the current profile's IPTV approval and optional scan exclusions.
    /// Server/library catalogs must already have passed their provider authorization.
    public func catalogChannels(
        authorizedBy authorization: LiveTVSourceAuthorization, excluding additionalHiddenIDs: Set<String> = []
    ) -> [LiveTVPrototypeChannel] {
        unhiddenCatalogChannels.filter {
            !additionalHiddenIDs.contains($0.id)
                && ($0.source != .iptv || authorization.allowsPlaylist($0.playlistSourceID))
        }
    }

    public private(set) var preferencesIssue: LiveTVPreferencesIssue? {
        get { preferences.issue }
        set { preferences.issue = newValue }
    }
    public private(set) var now: Date
    /// Where the guide's ruler starts: `now` floored to :00/:30, advanced by clock updates
    /// unless a key press is recent (`LiveTVGuideClock`).
    public var guideWindowStart: Date { guideClockState.windowStart }
    let guideClockState = LiveTVGuideClockState()
    var lastGuideInteraction: Date? {
        get { guideClockState.lastInteraction }
        set { guideClockState.lastInteraction = newValue }
    }
    public private(set) var categories: [String] = []

    public private(set) var playingChannelID: String?
    public private(set) var previousChannelID: String?
    public private(set) var isPaused = false
    public private(set) var behindLiveSeconds: TimeInterval = 0
    #if DEBUG
    public var simulateTunerBusy = false
    #endif
    public private(set) var tuneFailed = false

    @ObservationIgnored private var channelsByID = LiveTVCatalogIndex<LiveTVPrototypeChannel>()
    @ObservationIgnored private var categoryChannelIndices: [String: [Int]] = [:]
    @ObservationIgnored var isBatchingFilterChanges = false
    @ObservationIgnored private var suppliedChannels: [LiveTVPrototypeChannel]? {
        didSet {
            // A lineup prepared off the main actor brings these with it; any other assignment derives them here.
            if let derived = derivedLineupFacts {
                derivedLineupFacts = nil
                placeholderLogos = derived.placeholders
                widestChannelNumberDigits = derived.widestDigits
                return
            }
            placeholderLogos = LiveTVLogoPlaceholders.placeholders(in: suppliedChannels ?? [])
            widestChannelNumberDigits = Self.widestNumberDigits(suppliedChannels ?? [])
        }
    }
    @ObservationIgnored private var derivedLineupFacts: (placeholders: Set<LiveTVPlaceholderLogo>, widestDigits: Int)?
    /// A lineup's O(n) validation and numbering, done by ``prepareCatalog(channels:)`` so that applying it is O(1) in the lineup.
    private struct PreparedLineup: Sendable {
        let source: [LiveTVPrototypeChannel]
        /// What `suppliedChannels` was when this was prepared; it is used only if the lineup still is that.
        let baseline: [LiveTVPrototypeChannel]?
        let numbersBefore: LiveTVStableChannelNumbers?
        let numbersAfter: LiveTVStableChannelNumbers?
        let numbered: [LiveTVPrototypeChannel]
        /// Whether the numbered lineup differs from the one published when this was prepared.
        let changed: Bool
        let ids: Set<String>
        let placeholders: Set<LiveTVPlaceholderLogo>
        let widestDigits: Int
    }
    @ObservationIgnored private var preparedLineup: PreparedLineup?
    /// The digit count of the widest channel number in the lineup, so the guide can size its number column once for every row.
    @ObservationIgnored public private(set) var widestChannelNumberDigits = 0

    nonisolated static func widestNumberDigits(_ channels: [LiveTVPrototypeChannel]) -> Int {
        // The printed width is longest at one end of the range, so only the extremes are formatted (not a String per channel).
        var smallest: Int?
        var largest: Int?
        for channel in channels where !channel.isSectionMarker {
            smallest = min(smallest ?? channel.number, channel.number)
            largest = max(largest ?? channel.number, channel.number)
        }
        guard let smallest, let largest else { return 0 }
        return max(String(smallest).count, String(largest).count)
    }
    /// Provider logo URLs shared by three or more brands in one source; never drawn as a channel logo.
    @ObservationIgnored private var placeholderLogos: Set<LiveTVPlaceholderLogo> = [] {
        didSet { (logoService ?? .shared).rejectGuideIcons(Set(placeholderLogos.map(\.url))) }
    }
    @ObservationIgnored private var preparedBuild: CatalogBuild?
    /// What the lists now published were derived from, when that is fully described by inputs.
    @ObservationIgnored private var installedInputs: CatalogInputs?
    /// How many publications installed a background build rather than deriving on the main actor.
    @ObservationIgnored private(set) var preparedInstallCount = 0
    @ObservationIgnored private let preferencesStore: (any LiveTVPreferencesStoring)?
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var pendingPreferences: LiveTVPreferences?
    @ObservationIgnored private var savedBrowse = LiveTVBrowsePreferences()
    /// This profile's channel numbers (`LiveTVStableChannelNumbers`). Applied to the supplied lineup only when the model
    /// has a preferences store; a model without one (fixtures, previews) shows the numbers it was given.
    @ObservationIgnored private var stableChannelNumbers = LiveTVStableChannelNumbers.empty
    private let guideState = LiveTVPrototypeGuideState()
    /// The profile's favourite filters and the selection that narrows the guide (see `LiveTVPrototypeModel+FavoriteFilters`).
    public let favoriteFilters: LiveTVFavoriteFilterState
    private let logoState = LiveTVPrototypeLogoState()
    @ObservationIgnored private let logoService: LiveTVChannelLogoService?
    @ObservationIgnored private var logoTask: Task<Void, Never>?
    @ObservationIgnored private var didEmitLogoSeamSummary = false
    /// Whether the lineup logos were last resolved for is a complete one (not cached rows, which only read stored results).
    @ObservationIgnored private var logoLineupIsComplete = false
    @ObservationIgnored private(set) var isResolvingLogos = false
    /// Every channel's logo identity for the current lineup, so reading stored results again needs no re-derivation.
    @ObservationIgnored private var logoRequests: [LiveTVLogoRequest] = []
    @ObservationIgnored private var remoteLogoObserver: NSObjectProtocol?
    /// Counts catalogs, so results computed for a replaced catalog are ignored.
    @ObservationIgnored private var logoGeneration = 0
    private var importedPrograms: [String: [LiveTVPrototypeProgram]] {
        get { guideState.programs }
        set { guideState.programs = newValue }
    }
    private var knownGuideChannelIDs: Set<String> {
        get { guideState.knownChannelIDs }
        set { guideState.knownChannelIDs = newValue }
    }

    public var usesPublicStreams: Bool { suppliedChannels != nil }
    public var guideChannelCount: Int { importedPrograms.count }

    public init(
        now: Date = Date(timeIntervalSince1970: 1_788_719_400),
        scenario: LiveTVPrototypeScenario = .mixedGuide,
        isLargeCatalog: Bool = false,
        channels: [LiveTVPrototypeChannel]? = nil,
        preferencesStore: (any LiveTVPreferencesStoring)? = nil,
        logoService: LiveTVChannelLogoService? = nil,
        favoriteFilterStore: (any LiveTVFavoriteFilterStoring)? = nil
    ) {
        self.logoService = logoService
        favoriteFilters = LiveTVFavoriteFilterState(store: favoriteFilterStore)
        self.now = now
        guideClockState.windowStart = LiveTVGuideClock.windowStart(for: now)
        self.scenario = scenario
        self.isLargeCatalog = isLargeCatalog
        self.preferencesStore = preferencesStore
        #if DEBUG
        suppliedChannels = channels
        placeholderLogos = LiveTVLogoPlaceholders.placeholders(in: channels ?? [])
        favoriteIDs = channels == nil && preferencesStore == nil ? Set((1...5).map(Self.channelID)) : []
        #else
        suppliedChannels = channels ?? []
        placeholderLogos = LiveTVLogoPlaceholders.placeholders(in: channels ?? [])
        #endif
        widestChannelNumberDigits = Self.widestNumberDigits(channels ?? [])
        (logoService ?? .shared).rejectGuideIcons(Set(placeholderLogos.map(\.url)))
        if preferencesStore != nil {
            loadPreferences()
            if let supplied = suppliedChannels { suppliedChannels = adoptStableNumbers(supplied) }
        }
        rebuildCatalog()
        resolveLogos(isCompleteLineup: true)
        if let logoService {
            // Choices that arrive from another device apply to the channels on screen.
            remoteLogoObserver = NotificationCenter.default.addObserver(
                forName: LiveTVChannelLogoStore.didApplyRemoteChangesNotification,
                object: logoService.store, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshStoredLogos() }
            }
        }
    }

    deinit {
        logoTask?.cancel()
        if let remoteLogoObserver { NotificationCenter.default.removeObserver(remoteLogoObserver) }
    }

    /// `isCompleteLineup` is `false` for rows shown before the provider's lineup has been read (last session's cached rows): they
    /// show stored logos but never start matching or lineup maintenance (see ``resolveLogos(isCompleteLineup:)``).
    public func replaceChannels(_ channels: [LiveTVPrototypeChannel], isCompleteLineup: Bool = true) throws {
        let lineup = try adoptedLineup(channels)
        let (ids, channels, changed) = (lineup.ids, lineup.channels, lineup.changed)
        derivedLineupFacts = lineup.facts
        suppliedChannels = channels
        if !importedPrograms.isEmpty { importedPrograms = importedPrograms.filter { ids.contains($0.key) } }
        rebuildCatalog()
        if changed || (isCompleteLineup && !logoLineupIsComplete) { resolveLogos(isCompleteLineup: isCompleteLineup) }
    }

    public func replacePrograms(_ programs: [LiveTVPrototypeProgram]) throws {
        guard Set(programs.map(\.id)).count == programs.count,
              programs.allSatisfy({
                  channelsByID[$0.channelID] != nil
                      && $0.start.timeIntervalSince1970.isFinite
                      && $0.end.timeIntervalSince1970.isFinite
                      && $0.start < $0.end
              }) else {
            throw LiveTVPrototypeDataError.invalidProgram
        }

        let updatedPrograms = Dictionary(grouping: programs, by: \.channelID)
            .mapValues { values in
                values.sorted { lhs, rhs in
                    lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
                }
            }
        guard importedPrograms != updatedPrograms else { return }
        importedPrograms = updatedPrograms
        catalogRevision &+= 1
        let genresChanged = refreshGuideGenres()
        if guideOnly || genresChanged { refreshVisibleChannels() }
    }

    /// Re-reads the guide's programme categories into the genre tags. Returns whether the selected favourite filter's
    /// channel set may have changed (a filter is selected and the votes changed).
    private func refreshGuideGenres() -> Bool {
        let changed = favoriteFilters.setGuideGenres(LiveTVChannelTagging.guideGenreVotes(importedPrograms), channels: channels)
        return changed && favoriteFilters.selectedFilter != nil
    }

    public func setKnownGuideChannels(_ ids: Set<String>, pending: Set<String> = []) {
        guard knownGuideChannelIDs != ids || guideState.pendingChannelIDs != pending else { return }
        knownGuideChannelIDs = ids
        guideState.pendingChannelIDs = pending
        catalogRevision &+= 1
        if guideOnly { refreshVisibleChannels() }
    }

    public func replaceCatalog(
        channels: [LiveTVPrototypeChannel], programs: [LiveTVPrototypeProgram], isCompleteLineup: Bool = true
    ) throws {
        let lineup = try adoptedLineup(channels)
        let (ids, channels) = (lineup.ids, lineup.channels)
        if !lineup.changed {
            try replacePrograms(programs)
            if isCompleteLineup, !logoLineupIsComplete { resolveLogos(isCompleteLineup: true) }
            return
        }
        guard Set(programs.map(\.id)).count == programs.count, programs.allSatisfy({
            ids.contains($0.channelID) && $0.start.timeIntervalSince1970.isFinite
                && $0.end.timeIntervalSince1970.isFinite && $0.start < $0.end
        }) else { throw LiveTVPrototypeDataError.invalidProgram }
        derivedLineupFacts = lineup.facts
        suppliedChannels = channels
        importedPrograms = Dictionary(grouping: programs, by: \.channelID).mapValues {
            $0.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        }
        favoriteFilters.setGuideGenres(LiveTVChannelTagging.guideGenreVotes(importedPrograms), channels: [])
        rebuildCatalog()
        resolveLogos(isCompleteLineup: isCompleteLineup)
    }

    /// Re-derives everything time-dependent from `date` in one pass, and moves the guide window
    /// when it is due and the guide is idle. Never touches focus.
    public func synchronizeClock(to date: Date = Date()) {
        now = date
        advanceGuideWindowIfIdle()
    }

    /// How the guide catches its clock up when the picture returns to it at `date`.
    public func returnCatchUp(at date: Date = Date()) -> LiveTVGuideClock.ReturnCatchUp {
        let age = date.timeIntervalSince(now)
        let sameSlot = LiveTVGuideClock.windowStart(for: date) == LiveTVGuideClock.windowStart(for: now)
        return age >= 0 && age < LiveTVGuideClock.labelRefresh && sameSlot ? .deferred : .immediate
    }

    func cachedNativePrograms(
        matching matcher: LiveTVProgramSearchMatcher, range: DateInterval, limit: Int,
        allowedChannelIDs: Set<String>
    ) -> [LiveTVPrototypeProgram] {
        var result = LiveTVProgramSearchResults(limit: limit)
        for id in allowedChannelIDs {
            guard let channel = channelsByID[id], channel.source != .iptv else { continue }
            for program in importedPrograms[id] ?? [] where
                program.start < range.end && program.end > range.start && matcher.matches(program.title) {
                result.insert(program)
            }
        }
        return result.sorted
    }

    public func channel(id: String) -> LiveTVPrototypeChannel? {
        channelsByID[id]
    }

    // MARK: Channel logos

    /// The logo to draw for a channel: what `LiveTVChannelLogoService.displayedLogoURL(for:)` answers, plus matches published
    /// by this model's current run so that a late match redraws. `nil` draws the channel's name; the playlist provider's logo is never drawn.
    public func effectiveLogoURL(for channel: LiveTVPrototypeChannel) -> URL? {
        // Read in the caller's observation scope, so a view that drew a channel's name redraws when its logo arrives
        // or a guide icon is measured (neither changes `urls`).
        _ = logoState.revision
        return logoState.urls[LiveTVChannelLogoKey(channel: channel)] ?? (logoService ?? .shared).displayedLogoURL(for: channel)
    }

    /// Regional channels per drawn logo, counted off the main actor once per lineup and logo settle (never per row).
    @ObservationIgnored private var regionalLogoCounts: (revision: Int, channelCount: Int, counts: [URL: Int])?
    @ObservationIgnored private var regionalCountsTask: Task<Void, Never>?

    /// The place to print under a channel's logo, or `nil`. Only a logo that two or more regional channels of the lineup share needs
    /// it (a network's logo drawn for its Calgary and Halifax feeds); a channel with no region of its own (a national channel) or
    /// whose name is drawn instead of a logo never has one. An O(1) read of the counts; they are recomputed in the background after
    /// the lineup or the logos change, and the label appears when they are ready (the view redraws through `logoState.regionRevision`).
    public func regionLabel(for channel: LiveTVPrototypeChannel) -> String? {
        _ = logoState.regionRevision
        let revision = logoState.revision
        if regionalLogoCounts?.revision != revision || regionalLogoCounts?.channelCount != channels.count {
            scheduleRegionalLogoCounts()
        }
        guard let counts = regionalLogoCounts?.counts, let url = effectiveLogoURL(for: channel),
              let label = LiveTVChannelRegion.region(for: channel) else { return nil }
        return (counts[url] ?? 0) >= 2 ? label : nil
    }

    private func scheduleRegionalLogoCounts() {
        guard regionalCountsTask == nil else { return }
        regionalCountsTask = Task { [weak self] in
            // Logo batches arrive many times a second while matching runs; count once they settle.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let revision = logoState.revision
            let channels = channels
            let urls = logoState.urls
            let service = logoService ?? .shared
            // Only the provider's complete lineup is remembered: a cached or partial one must not replace its counts.
            let persists = logoLineupIsComplete
            let counts = await Task.detached(priority: .utility) {
                // The access is read once for the whole pass: it reads the Keychain.
                let tmdbEnabled = service.isTMDbEnabled
                var inputs = LiveTVStableHash()
                var assigned: [(channel: LiveTVPrototypeChannel, url: URL)] = []
                for other in channels where !other.isSectionMarker && other.source != .plozz {
                    inputs.add(other.id)
                    inputs.add(other.name)
                    for group in other.groups ?? [other.category] { inputs.add(group) }
                    guard let url = urls[LiveTVChannelLogoKey(channel: other)] ?? service.displayedLogoURL(for: other, tmdbEnabled: tmdbEnabled)
                    else { inputs.add("-"); continue }
                    inputs.add(url.absoluteString)
                    assigned.append((other, url))
                }
                // The counts are final for these inputs (channel names and the logo each draws): read them back after a relaunch.
                let inputKey = inputs.value
                if persists, let stored = service.storedRegionalLogoCounts(inputKey: inputKey) { return stored }
                var counts: [URL: Int] = [:]
                for (other, url) in assigned where LiveTVChannelRegion.region(for: other) != nil {
                    counts[url, default: 0] += 1
                }
                counts = counts.filter { $0.value >= 2 }
                if persists { service.saveRegionalLogoCounts(counts, inputKey: inputKey) }
                return counts
            }.value
            regionalLogoCounts = (revision, channels.count, counts)
            regionalCountsTask = nil
            logoState.regionRevision &+= 1
        }
    }

    /// The brand key to screen the drawn image against, or `nil` when the drawn logo is the user's
    /// or an automatic match (those are never screened) or there is no logo.
    public func placeholderScreeningKey(for channel: LiveTVPrototypeChannel) -> String? {
        guard channel.source != .plozz,
              logoState.urls[LiveTVChannelLogoKey(channel: channel)] == nil, channel.guideLogoURL != nil,
              (logoService ?? .shared).displayedLogoURL(for: channel) == channel.guideLogoURL else { return nil }
        return LiveTVLogoPlaceholders.brandKey(channel.name)
    }

    /// The name drawn when there is no logo: the channel name without its prefix and quality words.
    public static func fallbackLogoName(for channel: LiveTVPrototypeChannel) -> String {
        let cleaned = LiveTVTMDbLogoMatcher.primaryKey(channel.name)
        return cleaned.isEmpty ? channel.name : cleaned
    }

    /// How an event channel's plate is composed, or `nil` for a channel that is not an event and for an event whose logo the user
    /// chose. An event with no league and no sport still gets `.text` (its name). The broadcaster's logo counts as available when
    /// the resolver stored one for the channel.
    public func sportsComposition(for channel: LiveTVPrototypeChannel) -> LiveTVSportsComposition? {
        let groups = channel.groups ?? []
        guard channel.source != .plozz, !hasLogoOverride(channel),
              LiveTVChannelKind.isEvent(name: channel.name, groups: groups) else { return nil }
        let crestCount = logoState.crests[LiveTVChannelLogoKey(channel: channel)]?.compactMap { $0 }.count ?? 0
        return LiveTVSportsComposition.compose(
            name: channel.name, groups: groups, crestCount: crestCount,
            broadcasterLogoAvailable: logoState.urls[LiveTVChannelLogoKey(channel: channel)] != nil
        )
    }

    /// The two teams of a league event, for the matchup card. `nil` when the title does not name exactly two teams.
    public func sportsMatchup(for channel: LiveTVPrototypeChannel) -> LiveTVSportsMatchup? {
        guard sportsComposition(for: channel) != nil else { return nil }
        return LiveTVSportsMatchup.matchup(name: channel.name, groups: channel.groups ?? [])
    }

    /// Team crests of an event channel, left then right, from the teams' Wikidata logos; `nil` for a team with none that may be drawn.
    public func sportsCrests(for channel: LiveTVPrototypeChannel) -> [URL?] {
        logoState.crests[LiveTVChannelLogoKey(channel: channel)] ?? []
    }

    /// The sport glyph for an event channel that has no league badge and no broadcaster logo.
    public func sportsGlyphSymbol(for channel: LiveTVPrototypeChannel) -> String? {
        switch sportsComposition(for: channel) {
        case .glyph(let glyph)?: glyph.symbolName
        case .leagueBadge(let league)? where logoState.urls[LiveTVChannelLogoKey(channel: channel)] == nil: league.glyphSymbolName
        default: nil
        }
    }

    public var canChangeLogos: Bool { logoService != nil }
    public var isTMDbLogoAccessEnabled: Bool { logoService?.isTMDbEnabled ?? false }

    public func canChangeLogo(of channel: LiveTVPrototypeChannel) -> Bool {
        logoService != nil && channel.source != .plozz
    }

    public func hasLogoOverride(_ channel: LiveTVPrototypeChannel) -> Bool {
        logoService?.store.hasOverride(LiveTVChannelLogoKey(channel: channel)) ?? false
    }

    /// The work one lineup needs for its logos, derived off the main actor.
    private struct LogoPlan: Sendable {
        /// Every channel's identity, in lookup priority order; kept so a remote change re-reads the store without re-deriving it.
        let requests: [LiveTVLogoRequest]
        let stored: [LiveTVChannelLogoKey: URL]
        /// The requests with no stored result (see ``LiveTVChannelLogoService/pendingRequests(_:)``).
        let pending: [LiveTVLogoRequest]
        let guideIcons: [(key: LiveTVChannelLogoKey, url: URL)]
        let events: [(key: LiveTVChannelLogoKey, event: LiveTVSportsEvent)]
        let channelIDsBySource: [String: Set<String>]

        /// `matching` is `false` for a partial (cached) lineup: stored results are read, nothing is matched, measured or maintained.
        static func make(
            channels: [LiveTVPrototypeChannel], visible: [LiveTVPrototypeChannel], favoriteIDs: Set<String>,
            service: LiveTVChannelLogoService, matching: Bool
        ) -> LogoPlan {
            let ordered = LiveTVPrototypeModel.logoPriorityOrder(channels: channels, visible: visible, favoriteIDs: favoriteIDs)
                .filter { $0.source != .plozz && !$0.isSectionMarker }
            let requests = ordered.map(LiveTVLogoRequest.init(channel:))
            var idsBySource: [String: Set<String>] = [:]
            for request in requests { idsBySource[request.key.sourceID, default: []].insert(request.key.channelID) }
            guard matching else {
                return LogoPlan(
                    requests: requests, stored: service.storedLogoURLs(for: requests.map(\.identity)),
                    pending: [], guideIcons: [], events: [], channelIDsBySource: idsBySource)
            }
            let icons = ordered.compactMap { channel in channel.guideLogoURL.map { (LiveTVChannelLogoKey(channel: channel), $0) } }
            let events: [(key: LiveTVChannelLogoKey, event: LiveTVSportsEvent)] = ordered.compactMap { channel in
                LiveTVSportsEventParser.parse(channel.name, groups: channel.groups ?? []).map { (LiveTVChannelLogoKey(channel: channel), $0) }
            }
            return LogoPlan(
                requests: requests, stored: service.storedLogoURLs(for: requests.map(\.identity)),
                pending: service.pendingRequests(requests), guideIcons: icons, events: events, channelIDsBySource: idsBySource)
        }
    }

    /// Reads the stored logo of every channel and matches only the channels with no stored result, in the background.
    ///
    /// Called when a lineup is applied (a new lineup, or one that differs from the last), never for a launch with an unchanged
    /// lineup, a filter or focus change, or a remote iCloud change: those only read stored results (``refreshStoredLogos()``).
    /// Nothing here runs on the main actor except publishing the batches. A new call replaces the previous run, and results
    /// for an older lineup are dropped.
    ///
    /// `isCompleteLineup` is `true` only for the provider's full lineup as read from the provider (or a saved complete one). A
    /// cached, partial or filtered set reads stored results and stops: it never matches and never lets the store forget anything.
    public func resolveLogos(isCompleteLineup: Bool = true) {
        logoTask?.cancel()
        logoGeneration &+= 1
        logoLineupIsComplete = isCompleteLineup
        guard let logoService, let channels = suppliedChannels, !channels.isEmpty else {
            logoTask = nil
            logoRequests = []
            isResolvingLogos = false
            return
        }
        let generation = logoGeneration
        let visible = visibleChannels
        let favorites = favoriteIDs
        isResolvingLogos = true
        logoTask = Task.detached(priority: .utility) { [weak self] in
            // A lineup republished with the same logo inputs (a guide batch, a filter change, a refetch that changed nothing) has
            // nothing to resolve: its stored results are already applied.
            let fingerprint = Self.logoFingerprint(channels, tmdbEnabled: logoService.isTMDbEnabled, complete: isCompleteLineup)
            if await self?.logoPassIsCurrent(fingerprint) == true {
                await self?.finishResolvingLogos(generation: generation)
                return
            }
            let plan = LogoPlan.make(
                channels: channels, visible: visible, favoriteIDs: favorites, service: logoService, matching: isCompleteLineup)
            guard !Task.isCancelled else { return }
            // Stored choices are applied at once so a logo never flashes the provider's first.
            await self?.installLogoPlan(plan, generation: generation)
            guard isCompleteLineup else {
                await self?.finishResolvingLogos(generation: generation, fingerprint: fingerprint)
                return
            }
            let iconURLs = Set(plan.guideIcons.map(\.url))
            logoService.noteCompleteLineup(channelIDsBySource: plan.channelIDsBySource, iconURLs: iconURLs)
            if !plan.pending.isEmpty {
                await logoService.resolve(plan.pending) { urls in
                    await self?.applyLogos(urls, generation: generation)
                }
                await logoService.preferColourLogos(plan.pending) { urls in
                    await self?.applyLogos(urls, generation: generation)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    NotificationCenter.default.post(name: LiveTVChannelLogoStore.didResolveArtworkChoices, object: logoService.store)
                }
            }
            await self?.measureGuideIcons(of: plan.guideIcons, using: logoService, generation: generation)
            logoService.store.requestWrite()
            #if DEBUG
            if await self?.didEmitLogoSeamSummary == false {
                let counts = logoService.logoSeamCounts(for: channels).line
                await self?.emitLogoSeamSummary(counts, generation: generation)
            }
            #endif
            await self?.finishResolvingLogos(generation: generation, fingerprint: fingerprint)
            await logoService.resolveCrests(plan.events) { crests in
                await self?.applyCrests(crests, generation: generation)
            }
        }
    }

    private func installLogoPlan(_ plan: LogoPlan, generation: Int) {
        guard generation == logoGeneration, !Task.isCancelled else { return }
        logoRequests = plan.requests
        setLogoURLs(plan.stored)
    }

    /// Re-reads the stored logos of the lineup without matching anything. A remote iCloud change lands here: the changed records are
    /// already in the store, so only the differences are applied.
    private func refreshStoredLogos() {
        guard let logoService, !logoRequests.isEmpty else { return }
        let requests = logoRequests
        let generation = logoGeneration
        Task.detached(priority: .utility) { [weak self] in
            let stored = logoService.storedLogoURLs(for: requests.map(\.identity))
            await self?.applyStoredLogos(stored, generation: generation)
        }
    }

    private func applyStoredLogos(_ stored: [LiveTVChannelLogoKey: URL], generation: Int) {
        guard generation == logoGeneration else { return }
        setLogoURLs(stored)
    }

    /// Matches one channel whose result was just reset, if it has none.
    private func matchLogos(of channel: LiveTVPrototypeChannel) {
        guard let logoService, channel.source != .plozz, !channel.isSectionMarker else { return }
        let generation = logoGeneration
        Task.detached(priority: .utility) { [weak self] in
            let pending = logoService.pendingRequests([LiveTVLogoRequest(channel: channel)])
            guard !pending.isEmpty else { return }
            await logoService.resolve(pending) { urls in await self?.applyLogos(urls, generation: generation) }
        }
    }

    /// Measures the guide icons of channels the matchers left without a logo, so a crisp one can be drawn. Unmatched channels only:
    /// a user's or TMDB/Wikidata logo already wins. One download per distinct icon, in priority order.
    private func measureGuideIcons(of icons: [(key: LiveTVChannelLogoKey, url: URL)], using service: LiveTVChannelLogoService, generation: Int) async {
        let known = logoState.urls
        let pending = await Task.detached(priority: .utility) {
            var seen = Set<URL>()
            return icons.filter { known[$0.key] == nil }.map(\.url).filter { seen.insert($0).inserted }
        }.value
        guard !pending.isEmpty else { return }
        let drawableBefore = service.drawableGuideIconCount
        _ = await service.guideIconSizes(for: pending)
        guard generation == logoGeneration, !Task.isCancelled, service.drawableGuideIconCount != drawableBefore else { return }
        logoState.revision &+= 1
    }

    /// DEBUG: once per model, after the first resolution pass, how many channels draw a logo from each source.
    private func emitLogoSeamSummary(_ line: String, generation: Int) {
        #if DEBUG
        guard generation == logoGeneration, !Task.isCancelled, !didEmitLogoSeamSummary else { return }
        didEmitLogoSeamSummary = true
        LiveTVLogoSeamLog.emit(line)
        #endif
    }

    private func finishResolvingLogos(generation: Int, fingerprint: Int? = nil) {
        guard generation == logoGeneration else { return }
        isResolvingLogos = false
        if let fingerprint { lastLogoFingerprint = fingerprint }
    }

    /// What the last finished logo pass was made for. Only a pass that ran to the end records it.
    @ObservationIgnored private var lastLogoFingerprint: Int?

    private func logoPassIsCurrent(_ fingerprint: Int) -> Bool { lastLogoFingerprint == fingerprint }

    /// A hash of everything a logo pass reads from the lineup (identity, name, groups, country, guide icon), in order-independent form.
    nonisolated static func logoFingerprint(_ channels: [LiveTVPrototypeChannel], tmdbEnabled: Bool, complete: Bool) -> Int {
        var total = 0
        for channel in channels where channel.source != .plozz {
            var hasher = Hasher()
            hasher.combine(channel.id)
            hasher.combine(channel.name)
            hasher.combine(channel.groups)
            hasher.combine(channel.country)
            hasher.combine(channel.language)
            hasher.combine(channel.guideLogoURL)
            hasher.combine(channel.playlistSourceID)
            total = total &+ hasher.finalize()
        }
        var hasher = Hasher()
        hasher.combine(total)
        hasher.combine(channels.count)
        hasher.combine(tmdbEnabled)
        hasher.combine(complete)
        return hasher.finalize()
    }

    /// Channels in the order logos are looked up: the current filter in guide order, then favourites, then the rest.
    nonisolated static func logoPriorityOrder(
        channels: [LiveTVPrototypeChannel], visible: [LiveTVPrototypeChannel], favoriteIDs: Set<String>
    ) -> [LiveTVPrototypeChannel] {
        var seen = Set<String>()
        var ordered: [LiveTVPrototypeChannel] = []
        ordered.reserveCapacity(channels.count)
        for channel in visible where seen.insert(channel.id).inserted { ordered.append(channel) }
        for channel in channels where favoriteIDs.contains(channel.id) && seen.insert(channel.id).inserted {
            ordered.append(channel)
        }
        for channel in channels where seen.insert(channel.id).inserted { ordered.append(channel) }
        return ordered
    }

    private func applyCrests(_ crests: [LiveTVChannelLogoKey: [URL?]], generation: Int) {
        guard generation == logoGeneration, !Task.isCancelled else { return }
        logoState.crests.merge(crests) { _, new in new }
        logoState.revision &+= 1
    }

    private func applyLogos(_ urls: [LiveTVChannelLogoKey: URL], generation: Int) {
        guard generation == logoGeneration, !Task.isCancelled else { return }
        var changed = false
        for (key, url) in urls where logoState.urls[key] != url {
            logoState.urls[key] = url
            changed = true
        }
        if changed { logoState.revision &+= 1 }
    }

    func setLogoURLs(_ urls: [LiveTVChannelLogoKey: URL]) {
        guard urls != logoState.urls else { return }
        logoState.urls = urls
        logoState.revision &+= 1
    }

    private func setLogoURL(_ url: URL?, for key: LiveTVChannelLogoKey) {
        var urls = logoState.urls
        urls[key] = url
        setLogoURLs(urls)
    }

    /// Changes when any channel's logo changes.
    public var logoRevision: Int { logoState.revision }

    /// Searches TMDB's network list; needs no key.
    public func searchLogoNetworks(_ query: String) async -> [LiveTVLogoNetworkResult] {
        await logoService?.searchNetworks(query) ?? []
    }

    public func logoNetwork(id: Int) async -> TMDbNetworkLogo? {
        await logoService?.networkLogo(id: id)
    }

    /// Uses a TMDB network's logo for the channel. `false` when TMDB cannot supply one.
    public func chooseLogoNetwork(_ id: Int, for channel: LiveTVPrototypeChannel) async -> Bool {
        guard let logoService, channel.source != .plozz else { return false }
        let key = LiveTVChannelLogoKey(channel: channel)
        guard let url = await logoService.chooseNetwork(id: id, for: key) else { return false }
        setLogoURL(url, for: key)
        return true
    }

    /// Uses an image URL for the channel. `false` when the URL is not an acceptable http(s) URL.
    public func chooseLogoURL(_ text: String, for channel: LiveTVPrototypeChannel) -> Bool {
        guard let logoService, channel.source != .plozz else { return false }
        let key = LiveTVChannelLogoKey(channel: channel)
        guard let url = logoService.chooseURL(text, for: key) else { return false }
        setLogoURL(url, for: key)
        return true
    }

    /// Removes the user's choice; the channel goes back to its TMDB match or the provider's logo.
    public func resetLogo(for channel: LiveTVPrototypeChannel) {
        guard let logoService else { return }
        let identity = LiveTVChannelLogoIdentity(channel: channel)
        setLogoURL(logoService.resetOverride(for: identity), for: identity.key)
        matchLogos(of: channel)
    }

    public func guideRow(for channelID: String, preferring section: LiveTVGuideSection? = nil) -> LiveTVGuideRowID? {
        if let section, let entry = guideEntry(for: .init(channelID: channelID, section: section)) {
            return entry.id
        }
        return guideEntry(for: .init(channelID: channelID, section: .channels))?.id
            ?? guideEntry(for: .init(channelID: channelID, section: .recent))?.id
            ?? guideEntry(for: .init(channelID: channelID, section: .favorites))?.id
    }

    public func toggleFavorite(_ id: String) {
        var favorites = preferences.favoriteIDs
        var organization = organization
        if favoriteIDs.contains(id) {
            favorites.remove(id)
            organization.excludedFavoriteIDs.insert(id)
        } else {
            favorites.insert(id)
            organization.excludedFavoriteIDs.remove(id)
        }
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: favorites,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder + (favorites.contains(id) ? [id] : []),
            favoriteChannels: favoriteChannels + (channelsByID[id].map { [.init(id: id, name: savedName(for: $0))] } ?? []),
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews,
            organization: organization
        )) else { return }
        refreshOrganization()
        catalogRevision &+= 1
        if favoritesOnly || favoriteFilters.selectionUsesFavourites() {
            refreshVisibleChannels()
        } else {
            refreshGuideChannels()
        }
        reclassifySectionMarker(id)
    }

    /// A section marker's visibility follows the favourite and playing state, so it is
    /// classified again when either changes for it.
    private func reclassifySectionMarker(_ id: String?) {
        guard !isRebuildingCatalog, let id,
              suppliedChannels?.contains(where: { $0.id == id && $0.isSectionMarker }) == true else { return }
        rebuildCatalog()
    }
    @ObservationIgnored private var isRebuildingCatalog = false

    /// Called only after deliberate watching has presented live video.
    /// A stale-source confirmation is rejected without changing the lineup.
    @discardableResult
    public func recordWatched(_ id: String) -> Bool {
        guard id == playingChannelID, channelsByID[id] != nil else { return false }
        guard recentChannelIDs.first != id else { return true }
        let recent = [id] + recentChannelIDs.filter { $0 != id }.prefix(2)
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: preferences.favoriteIDs,
            recentChannelIDs: recent,
            hiddenChannels: hiddenChannels, favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels,
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews,
            organization: organization
        )) else { return false }
        if favoriteFilters.selectionUsesRecents() { refreshVisibleChannels() } else { refreshGuideChannels() }
        return true
    }

    /// Hides every rendered occurrence of a channel while retaining its
    /// favorite, recent, guide, and source records for later restoration.
    @discardableResult
    public func hideChannel(_ channel: LiveTVPrototypeChannel) -> Bool {
        let current = currentPreferences
        guard !current.hiddenChannelIDs.contains(channel.id) else { return true }
        guard persistPreferences(current.hidingChannel(id: channel.id, name: savedName(for: channel))) else {
            return false
        }
        refreshOrganization()
        refreshCategories()
        refreshVisibleChannels()
        return true
    }

    public func dismissPreferencesIssue() {
        preferencesIssue = nil
    }

    private func savedName(for channel: LiveTVPrototypeChannel) -> String {
        // Recovery labels must remain reversible even while the source is unavailable.
        channelOverrides[channel.id]?.name
            ?? suppliedChannels?.first(where: { $0.id == channel.id })?.name
            ?? channel.name
    }

    @discardableResult
    public func setCategoryRule(_ rule: LiveTVCategoryRule) -> Bool {
        var updated = organization
        updated.setCategory(rule)
        return setOrganization(updated)
    }

    @discardableResult
    public func setRegionalFilter(_ filter: LiveTVRegionalFilter) -> Bool {
        var updated = organization
        updated.region = filter
        return setOrganization(updated)
    }

    @discardableResult
    public func showChannel(_ id: String) -> Bool {
        guard !scanHiddenChannelIDs.contains(id) else { return false }
        var updated = currentPreferences.restoringChannel(id: id)
        if channelsByID[id]?.source == .iptv {
            updated.organization.shownChannelIDs.insert(id)
        }
        guard persistPreferences(updated) else { return false }
        refreshOrganization()
        refreshCategories()
        refreshVisibleChannels()
        catalogRevision &+= 1
        return true
    }

    @discardableResult
    public func resetOrganizationVisibility() -> Bool {
        setOrganization(organization.resettingVisibility())
    }

    private func setOrganization(_ updated: LiveTVChannelOrganization) -> Bool {
        guard updated != organization else { return true }
        var saved = currentPreferences
        saved.organization = updated
        guard persistPreferences(saved) else { return false }
        refreshOrganization()
        refreshCategories()
        if let category, category != LiveTVEventSlotClassifier.filterName, !categories.contains(category) { self.category = nil }
        refreshVisibleChannels()
        catalogRevision &+= 1
        return true
    }

    @discardableResult
    public func migrateChannelIDs(_ migration: [String: String]) -> Bool {
        let migrated = currentPreferences.migratingChannelIDs(migration)
        guard migrated != currentPreferences else { return true }
        guard persistPreferences(migrated) else { return false }
        refreshOrganization()
        refreshCategories()
        refreshVisibleChannels()
        return true
    }

    @discardableResult
    public func setFavoriteOrder(_ ids: [String]) -> Bool {
        guard Set(ids) == preferences.favoriteIDs, ids.count == preferences.favoriteIDs.count else { return false }
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: preferences.favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: ids, favoriteChannels: favoriteChannels, channelOverrides: channelOverrides,
            browse: browsePreferences, favoriteMultiviews: favoriteMultiviews, organization: organization
        )) else { return false }
        refreshGuideChannels()
        return true
    }

    @discardableResult
    public func setMetadataOverride(_ value: LiveTVChannelMetadataOverride?, channelID: String) -> Bool {
        if let value {
            guard [value.name, value.category, value.language, value.country].compactMap({ $0 }).allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
            }) else { return false }
        }
        var updated = channelOverrides
        updated[channelID] = value
        guard persistPreferences(LiveTVPreferences(
            favoriteIDs: preferences.favoriteIDs, recentChannelIDs: recentChannelIDs, hiddenChannels: hiddenChannels,
            favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels, channelOverrides: updated,
            browse: browsePreferences, favoriteMultiviews: favoriteMultiviews, organization: organization
        )) else { return false }
        rebuildCatalog()
        return true
    }

    public func retryPreferences() {
        reloadPreferences()
    }

    /// Reloads profile-scoped preferences after Settings may have restored
    /// channels. A failed pending mutation is retried first so re-entry never
    /// silently discards it.
    public func reloadPreferences() {
        if let pendingPreferences, let preferencesStore {
            do {
                let latest = try preferencesStore.load()
                _ = persistPreferences(rebasing(pendingPreferences, onto: latest), retrying: true)
            } catch {
                preferencesIssue = .loadFailed
            }
        } else {
            loadPreferences()
        }
        // A peer's numbers may have arrived (or moved a duplicate) while Live TV was away.
        if preferencesStore != nil, let supplied = suppliedChannels {
            suppliedChannels = Self.renumbered(supplied, using: stableChannelNumbers)
        }
        // Returning to Live TV with nothing changed keeps the lists already derived.
        if let installedInputs, let suppliedChannels, preparedBuild == nil,
           installedInputs == catalogInputs(supplied: suppliedChannels) { return }
        rebuildCatalog()
    }

    private func loadPreferences() {
        guard let preferencesStore else { return }
        do {
            let preferences = try preferencesStore.load()
            favoriteIDs = preferences.favoriteIDs
            self.preferences.favoriteMultiviews = preferences.favoriteMultiviews
            recentChannelIDs = preferences.recentChannelIDs
            hiddenChannels = preferences.hiddenChannels
            favoriteOrder = preferences.favoriteOrder
            favoriteChannels = preferences.favoriteChannels
            channelOverrides = preferences.channelOverrides
            organization = preferences.organization
            stableChannelNumbers = preferences.stableChannelNumbers
            isBatchingFilterChanges = true
            category = preferences.browse.category
            language = preferences.browse.language
            country = preferences.browse.country
            source = preferences.browse.sourceType.flatMap(LiveTVPrototypeSource.init(rawValue:))
            playlistSourceID = preferences.browse.configuredSourceID
            sort = LiveTVPrototypeSort(rawValue: preferences.browse.sort) ?? .channelNumber
            favoritesOnly = preferences.browse.favoritesOnly
            guideOnly = preferences.browse.guideOnly
            savedBrowse = preferences.browse
            isBatchingFilterChanges = false
            preferencesLoaded = true
            preferencesIssue = nil
        } catch {
            preferencesIssue = .loadFailed
        }
    }

    private func persistPreferences(_ preferences: LiveTVPreferences, retrying: Bool = false) -> Bool {
        var preferences = preferences
        if let preferencesStore {
            guard preferencesLoaded else {
                preferencesIssue = .loadFailed
                return false
            }
            if !retrying { pendingPreferences = preferences }
            do {
                // Numbers only grow: a save never drops one this model, or a peer's sync, has already assigned.
                if let stored = try? preferencesStore.load() {
                    preferences.stableChannelNumbers = stableChannelNumbers
                        .merging(preferences.stableChannelNumbers).merging(stored.stableChannelNumbers)
                } else {
                    preferences.stableChannelNumbers = stableChannelNumbers.merging(preferences.stableChannelNumbers)
                }
                try preferencesStore.save(preferences)
            } catch {
                preferencesIssue = .saveFailed
                return false
            }
        }
        favoriteIDs = preferences.favoriteIDs
        self.preferences.favoriteMultiviews = preferences.favoriteMultiviews
        recentChannelIDs = preferences.recentChannelIDs
        hiddenChannels = preferences.hiddenChannels
        favoriteOrder = preferences.favoriteOrder
        favoriteChannels = preferences.favoriteChannels
        channelOverrides = preferences.channelOverrides
        organization = preferences.organization
        stableChannelNumbers = preferences.stableChannelNumbers.isEmpty
            ? stableChannelNumbers : stableChannelNumbers.merging(preferences.stableChannelNumbers)
        savedBrowse = preferences.browse
        preferencesIssue = nil
        pendingPreferences = nil
        return true
    }

    private var currentPreferences: LiveTVPreferences {
        LiveTVPreferences(
            favoriteIDs: preferences.favoriteIDs,
            recentChannelIDs: recentChannelIDs,
            hiddenChannels: hiddenChannels, favoriteOrder: favoriteOrder, favoriteChannels: favoriteChannels,
            channelOverrides: channelOverrides, browse: browsePreferences, favoriteMultiviews: favoriteMultiviews,
            organization: organization, stableChannelNumbers: stableChannelNumbers
        )
    }

    private var browsePreferences: LiveTVBrowsePreferences {
        .init(
            category: category == LiveTVEventSlotClassifier.filterName ? nil : category,
            language: language, country: country, sourceType: source?.rawValue,
            configuredSourceID: playlistSourceID, sort: sort.rawValue, favoritesOnly: favoritesOnly, guideOnly: guideOnly
        )
    }

    private func rebasing(_ pending: LiveTVPreferences, onto latest: LiveTVPreferences) -> LiveTVPreferences {
        let base = currentPreferences
        let favorites = latest.favoriteIDs
            .subtracting(base.favoriteIDs.subtracting(pending.favoriteIDs))
            .union(pending.favoriteIDs.subtracting(base.favoriteIDs))
        let removedHidden = base.hiddenChannelIDs.subtracting(pending.hiddenChannelIDs)
        let knownHidden = base.hiddenChannelIDs.union(latest.hiddenChannelIDs)
        let hidden = latest.hiddenChannels.filter { !removedHidden.contains($0.id) }
            + pending.hiddenChannels.filter { !knownHidden.contains($0.id) }
        var recent = latest.recentChannelIDs
        if pending.recentChannelIDs != base.recentChannelIDs, let watched = pending.recentChannelIDs.first {
            recent = [watched] + recent.filter { $0 != watched }
        }
        let removedMultiviews = Set(base.favoriteMultiviews.map(\.id)).subtracting(pending.favoriteMultiviews.map(\.id))
        let changedMultiviews = pending.favoriteMultiviews.filter { item in
            base.favoriteMultiviews.first(where: { $0.id == item.id }) != item
        }
        let changedIDs = Set(changedMultiviews.map(\.id))
        let multiviews = latest.favoriteMultiviews.filter {
            !removedMultiviews.contains($0.id) && !changedIDs.contains($0.id)
        } + changedMultiviews
        // Retry only the failed changes; Settings may have restored channels meanwhile.
        return LiveTVPreferences(
            favoriteIDs: favorites, recentChannelIDs: recent, hiddenChannels: hidden,
            favoriteOrder: pending.favoriteOrder == base.favoriteOrder ? latest.favoriteOrder : pending.favoriteOrder,
            favoriteChannels: latest.favoriteChannels + pending.favoriteChannels,
            channelOverrides: pending.channelOverrides == base.channelOverrides ? latest.channelOverrides : pending.channelOverrides,
            browse: pending.browse == base.browse ? latest.browse : pending.browse,
            favoriteMultiviews: multiviews,
            organization: pending.organization.rebasing(onto: latest.organization, from: base.organization)
        )
    }

    public func resetFilters() {
        isBatchingFilterChanges = true
        query = ""
        category = nil
        source = nil
        language = nil
        country = nil
        playlistSourceID = nil
        favoritesOnly = false
        guideOnly = false
        favoriteFilters.select(nil)
        isBatchingFilterChanges = false
        refreshVisibleChannels()
    }

    public func currentProgram(for channelID: String) -> LiveTVPrototypeProgram? {
        programs(for: channelID, from: now, hours: 1).first {
            $0.start <= now && now < $0.end
        }
    }

    /// What aired on the channel before the current programme, newest last,
    /// reaching back `hours`: the player splits its rewind window at these.
    public func earlierPrograms(for channelID: String, hours: Int = 4) -> [LiveTVPrototypeProgram] {
        let current = currentProgram(for: channelID)
        let boundary = current?.start ?? now
        return programs(for: channelID, from: now.addingTimeInterval(-TimeInterval(hours) * 3_600), hours: hours)
            .filter { $0.end <= boundary && $0.id != current?.id }
            .sorted { $0.start < $1.start }
    }

    public func programs(
        for channelID: String,
        from date: Date,
        hours: Int = 3
    ) -> [LiveTVPrototypeProgram] {
        guard hours > 0, let channel = channelsByID[channelID] else { return [] }
        // An active event slot's programme is its title from its start, 3 hours by default; an idle slot has none.
        if let slot = channel.eventSlot {
            guard case let .active(title, start?) = slot.state else { return [] }
            let end = start.addingTimeInterval(LiveTVEventSlot.defaultDuration)
            guard start < date.addingTimeInterval(TimeInterval(min(hours, 7 * 24)) * 3_600), end > date else { return [] }
            return [LiveTVPrototypeProgram(id: "event-\(channelID)", channelID: channelID, title: title, subtitle: "", start: start, end: end)]
        }
        // A 24/7 single-show channel has no XMLTV: one cell, titled with its show, across the whole window.
        if let title = channel.loopTitle {
            let start = min(date, now)
            let end = max(date.addingTimeInterval(TimeInterval(min(hours, 7 * 24)) * 3_600), now.addingTimeInterval(3_600))
            return [LiveTVPrototypeProgram(
                id: LiveTVPrototypeProgram.loopID(channelID: channelID), channelID: channelID, title: title, subtitle: "",
                start: start, end: end)]
        }
        guard hasGuide(for: channel) else { return [] }

        // A week matches the guide cache's lookahead; the browsable guide grows past a day.
        let boundedHours = min(hours, 7 * 24)
        let requestedEnd = date.addingTimeInterval(TimeInterval(boundedHours) * 3_600)
        if usesPublicStreams {
            return (importedPrograms[channelID] ?? []).filter {
                $0.start < requestedEnd && $0.end > date
            }
        }
        #if DEBUG
        let duration = programDuration(for: channelID)
        var slotStartSeconds = floor(date.timeIntervalSince1970 / duration) * duration
        var result: [LiveTVPrototypeProgram] = []
        result.reserveCapacity(
            Int(ceil((requestedEnd.timeIntervalSince1970 - slotStartSeconds) / duration))
        )

        while slotStartSeconds < requestedEnd.timeIntervalSince1970 {
            let start = Date(timeIntervalSince1970: slotStartSeconds)
            let end = start.addingTimeInterval(duration)
            result.append(program(for: channel, start: start, end: end))
            slotStartSeconds += duration
        }
        return result
        #else
        return []
        #endif
    }

    #if DEBUG
    public func advanceClock(by interval: TimeInterval) {
        precondition(interval.isFinite && interval >= 0, "Live TV prototype clock only advances forward.")
        now = now.addingTimeInterval(interval)
        advanceGuideWindowIfIdle()
        if isPaused, playingChannelID != nil {
            behindLiveSeconds += interval
        }
    }
    #endif

    /// Invalid channel IDs report through `tuneFailed` without changing the stream.
    public func tune(_ id: String) {
        guard let channel = channelsByID[id] else {
            tuneFailed = true
            return
        }
        // An idle event slot has nothing to play.
        guard channel.eventSlot?.isIdle != true else { return }
        if playingChannelID == id {
            tuneFailed = false
            return
        }
        #if DEBUG
        guard !simulateTunerBusy else {
            tuneFailed = true
            return
        }
        #endif

        previousChannelID = playingChannelID
        playingChannelID = id
        isPaused = false
        behindLiveSeconds = 0
        tuneFailed = false
    }

    public func stop() {
        let stopped = playingChannelID
        defer { reclassifySectionMarker(stopped) }
        playingChannelID = nil
        previousChannelID = nil
        isPaused = false
        behindLiveSeconds = 0
        tuneFailed = false
    }

    public func togglePause() {
        guard playingChannelID != nil else { return }
        isPaused.toggle()
    }

    public func goLive() {
        guard playingChannelID != nil else { return }
        isPaused = false
        behindLiveSeconds = 0
    }

    public func tunePrevious() {
        guard let previousChannelID else { return }
        tune(previousChannelID)
    }

    public func clearTuneFailure() {
        tuneFailed = false
    }

    /// Valid for `channels` only; nil until built (a lineup that was not prepared in the background builds it on first search).
    @ObservationIgnored private var searchIndex: SearchIndex?

    private func rebuildCatalog() {
        searchIndex = nil
        isRebuildingCatalog = true
        defer { isRebuildingCatalog = false }
        catalogRevision &+= 1
        let prepared = preparedBuild
        preparedBuild = nil
        favoriteFilters.invalidateTagIndex()
        installedInputs = suppliedChannels.flatMap(catalogInputs(supplied:))
        if let prepared, let suppliedChannels,
           prepared.inputs == catalogInputs(supplied: suppliedChannels) {
            install(prepared)
            preparedInstallCount += 1
            return
        }
        #if DEBUG
        if let suppliedChannels {
            if isLargeCatalog, !suppliedChannels.isEmpty {
                channels = (0..<5_000).map { index in
                    let channel = suppliedChannels[index % suppliedChannels.count]
                    let copy = index / suppliedChannels.count
                    guard copy > 0 else { return channel }
                    return LiveTVPrototypeChannel(
                        id: "\(channel.id)-copy-\(copy)", number: index + 1,
                        name: "\(channel.name) (copy \(copy + 1))", category: channel.category,
                        symbol: channel.symbol, accent: channel.accent, source: channel.source,
                        tagline: channel.tagline, logoURL: channel.logoURL, streamURL: channel.streamURL,
                        logoNeedsDarkBackground: channel.logoNeedsDarkBackground,
                        guideID: channel.guideID, guideName: channel.guideName,
                        httpHeaders: channel.httpHeaders,
                        playlistSourceID: channel.playlistSourceID, language: channel.language, country: channel.country,
                        groups: channel.groups, plozzChannelMood: channel.plozzChannelMood,
                        guideLogoURL: channel.guideLogoURL
                    )
                }
            } else {
                channels = suppliedChannels
            }
        } else {
            let count = isLargeCatalog ? 5_000 : Self.baseStations.count
            channels = (1...count).map(Self.makeChannel)
        }
        #else
        channels = suppliedChannels ?? []
        #endif
        channels = Self.named(
            channels, cleaning: cleanChannelNames, overrides: channelOverrides)
        channelsByID = LiveTVCatalogIndex(channels)
        refreshOrganization()
        refreshCategories()
        dropRemovedPlayback()
        refreshVisibleChannels()
    }

    private func dropRemovedPlayback() {
        if let playingChannelID, channelsByID[playingChannelID] == nil {
            stop()
        } else if let previousChannelID, channelsByID[previousChannelID] == nil {
            self.previousChannelID = nil
        }
    }

    // MARK: Stable channel numbers

    /// The order a lineup's new channels are numbered in: the guide's own order (the provider's number, then identity), as the
    /// supplied lineup is already the profile's My Channels. Section markers are not channels and are not numbered.
    nonisolated static func numberingOrder(_ channels: [LiveTVPrototypeChannel]) -> [String] {
        // A lineup already in number order (the usual one) needs no sort; the order is then the lineup's own.
        var last = Int.min
        var sorted = true
        for channel in channels {
            if channel.number < last { sorted = false; break }
            last = channel.number
        }
        if sorted { return channels.filter { !$0.isSectionMarker }.map(\.id) }
        return channels.enumerated().filter { !$0.element.isSectionMarker }
            .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            .map(\.element.id)
    }

    /// The lineup with each numbered channel carrying its Plozz number. A channel with no assignment (the bounded set is
    /// full) keeps the number it was supplied with.
    nonisolated static func renumbered(
        _ channels: [LiveTVPrototypeChannel], using numbers: LiveTVStableChannelNumbers
    ) -> [LiveTVPrototypeChannel] {
        guard !numbers.isEmpty,
              channels.contains(where: { channel in numbers.number(for: channel.id).map { $0 != channel.number } ?? false })
        else { return channels }
        return channels.map { channel in
            guard let number = numbers.number(for: channel.id), number != channel.number else { return channel }
            return channel.withNumber(number)
        }
    }

    /// Numbers any new channel, saves the profile's assignments when they changed, and returns the numbered lineup.
    /// A failed save is reported as the preferences issue; the numbers still apply for this run.
    private func adoptStableNumbers(_ channels: [LiveTVPrototypeChannel]) -> [LiveTVPrototypeChannel] {
        guard preferencesStore != nil else { return channels }
        let updated = stableChannelNumbers.assigning(orderedChannelIDs: Self.numberingOrder(channels), at: Date())
        adoptNumbers(updated)
        return Self.renumbered(channels, using: stableChannelNumbers)
    }

    private func adoptNumbers(_ updated: LiveTVStableChannelNumbers) {
        if updated != stableChannelNumbers {
            var next = currentPreferences
            next.stableChannelNumbers = updated
            if preferencesLoaded { _ = persistPreferences(next) }
            stableChannelNumbers = stableChannelNumbers.merging(updated)
        }
    }

    /// The lineup to publish: validated, numbered, and compared with the one published. Uses the result of
    /// ``prepareCatalog(channels:)`` when it was made for exactly these channels and this state, so the main actor does no
    /// pass over the lineup; otherwise derives it here.
    private func adoptedLineup(_ channels: [LiveTVPrototypeChannel]) throws -> (
        channels: [LiveTVPrototypeChannel], ids: Set<String>, changed: Bool,
        facts: (placeholders: Set<LiveTVPlaceholderLogo>, widestDigits: Int)?
    ) {
        let prepared = preparedLineup
        preparedLineup = nil
        if let prepared, prepared.source == channels, prepared.baseline == suppliedChannels,
           prepared.numbersBefore == (preferencesStore == nil ? nil : stableChannelNumbers) {
            guard prepared.ids.count == channels.count else { throw LiveTVPrototypeDataError.duplicateChannelID }
            if let after = prepared.numbersAfter { adoptNumbers(after) }
            return (prepared.numbered, prepared.ids, prepared.changed, (prepared.placeholders, prepared.widestDigits))
        }
        let ids = Set(channels.map(\.id))
        guard ids.count == channels.count else { throw LiveTVPrototypeDataError.duplicateChannelID }
        let numbered = adoptStableNumbers(channels)
        return (numbered, ids, suppliedChannels != numbered, nil)
    }

    // MARK: Background catalogue build

    private struct BrowseFilter: Equatable, Sendable {
        var query: String
        var category: String?
        var source: LiveTVPrototypeSource?
        var language: String?
        var country: String?
        var playlistSourceID: String?
        var favoritesOnly: Bool
        var guideOnly: Bool
        var sort: LiveTVPrototypeSort
        /// The selected favourite filter's tags; empty when none is selected.
        var tagIDs: [String] = []
    }

    /// Everything a lineup's derived lists are computed from.
    private struct CatalogInputs: Equatable, Sendable {
        var supplied: [LiveTVPrototypeChannel]
        var cleanNames: Bool
        var overrides: [String: LiveTVChannelMetadataOverride]
        var organization: LiveTVChannelOrganization
        var hiddenChannels: [LiveTVHiddenChannel]
        var scanHidden: Set<String>
        var explicitFavorites: Set<String>
        var filter: BrowseFilter
        var recentIDs: [String]
        var favoriteOrder: [String]
        var playingChannelID: String?
        var watchedIDs: [String]
    }

    /// Each channel's searchable text, folded once when the lineup is built, so typing compares strings and folds nothing.
    /// Parallel to `channels`.
    struct SearchIndex: Sendable {
        struct Entry: Sendable { let name: String; let number: String; let categories: String; let source: String }
        let entries: [Entry]
        /// Every channel's folded text in one buffer (fields separated by 0x01, channels by 0x02), and where each channel starts,
        /// so a query is one `memmem` scan of contiguous bytes and only the channels that contain it are looked at.
        let blob: [UInt8]
        let starts: [Int32]

        nonisolated init(_ channels: [LiveTVPrototypeChannel]) {
            var foldedCategories: [String: String] = [:]
            let entries: [Entry] = channels.map { channel in
                let text = channel.categories.joined(separator: " ")
                let folded: String
                if let known = foldedCategories[text] { folded = known } else {
                    folded = LiveTVPrototypeModel.normalized(text)
                    foldedCategories[text] = folded
                }
                return Entry(
                    name: LiveTVPrototypeModel.normalized(channel.name), number: String(channel.number), categories: folded,
                    source: LiveTVPrototypeModel.normalized(channel.source.rawValue))
            }
            var blob: [UInt8] = []
            blob.reserveCapacity(entries.count * 64)
            var starts: [Int32] = []
            starts.reserveCapacity(entries.count + 1)
            for entry in entries {
                starts.append(Int32(truncatingIfNeeded: blob.count))
                blob.append(contentsOf: entry.name.utf8); blob.append(1)
                blob.append(contentsOf: entry.number.utf8); blob.append(1)
                blob.append(contentsOf: entry.categories.utf8); blob.append(1)
                blob.append(contentsOf: entry.source.utf8); blob.append(2)
            }
            starts.append(Int32(truncatingIfNeeded: blob.count))
            self.entries = entries
            self.blob = blob
            self.starts = starts
        }

        /// The indices, ascending, of the channels whose text contains `query` (bytes of the folded query, none below 0x20).
        nonisolated func channelIndices(containing query: [UInt8]) -> [Int] {
            guard !query.isEmpty else { return Array(entries.indices) }
            var result: [Int] = []
            blob.withUnsafeBufferPointer { buffer in
                query.withUnsafeBufferPointer { needle in
                    guard let base = buffer.baseAddress, let needleBase = needle.baseAddress else { return }
                    var position = 0
                    while position < buffer.count,
                          let hit = memmem(base + position, buffer.count - position, needleBase, needle.count) {
                        let offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        // The channel whose range holds `offset`: the last start at or before it.
                        var low = 0, high = starts.count - 1
                        while low < high {
                            let middle = (low + high + 1) / 2
                            if Int(starts[middle]) <= offset { low = middle } else { high = middle - 1 }
                        }
                        result.append(low)
                        position = Int(starts[low + 1])
                    }
                }
            }
            return result
        }
    }

    private struct CatalogBuild: Sendable {
        let searchIndex: SearchIndex
        let inputs: CatalogInputs
        let tagIndex: LiveTVChannelTagIndex
        let channels: [LiveTVPrototypeChannel]
        let index: LiveTVCatalogIndex<LiveTVPrototypeChannel>
        let organization: OrganizationResult
        let categories: CategoryResult
        let filtered: FilteredCatalog
        let rows: GuideRows
    }

    private var browseFilter: BrowseFilter {
        BrowseFilter(
            query: query, category: category, source: source, language: language, country: country,
            playlistSourceID: playlistSourceID, favoritesOnly: favoritesOnly, guideOnly: guideOnly, sort: sort,
            tagIDs: favoriteFilters.selectedTagIDs
        )
    }

    /// `nil` when the lists depend on state a background build cannot see.
    private func catalogInputs(supplied: [LiveTVPrototypeChannel]) -> CatalogInputs? {
        // Guide-only browsing follows listings that keep arriving; filter batches defer their refresh.
        guard !guideOnly, !isBatchingFilterChanges, !isLargeCatalog else { return nil }
        return CatalogInputs(
            supplied: supplied, cleanNames: cleanChannelNames, overrides: channelOverrides,
            organization: organization, hiddenChannels: hiddenChannels, scanHidden: scanHiddenChannelIDs,
            explicitFavorites: preferences.favoriteIDs, filter: browseFilter,
            recentIDs: showsRecentChannels ? recentChannelIDs : [], favoriteOrder: favoriteOrder,
            playingChannelID: playingChannelID, watchedIDs: recentChannelIDs
        )
    }

    private struct CatalogPreparationTiming {
        private let start: ContinuousClock.Instant?
        private var previous: ContinuousClock.Instant?
        private var phases: [(name: String, elapsed: Duration)] = []

        init() {
            start = HandoffDiagnostics.isEnabled ? .now : nil
            previous = start
        }

        mutating func mark(_ phase: String) {
            guard let previous else { return }
            let now = ContinuousClock.now
            phases.append((phase, previous.duration(to: now)))
            self.previous = now
        }

        func emit(stage: String, count: Int) {
            guard let start else { return }
            let total = Self.milliseconds(start.duration(to: .now))
            let intervals = phases.map { "\($0.name)=\(Self.milliseconds($0.elapsed))ms" }.joined(separator: " ")
            HandoffDiagnostics.emit("LIVE_TV event=prepareCatalog stage=\(stage) channels=\(count) total=\(total)ms \(intervals)")
        }

        private static func milliseconds(_ elapsed: Duration) -> Int64 {
            let parts = elapsed.components
            return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        }
    }

    /// Derives a lineup's lists off the main actor, so that publishing it only installs them.
    /// A large lineup otherwise holds the main actor for the whole derivation. The result is
    /// used only if nothing it was derived from has changed by the time the lineup is published.
    public func prepareCatalog(channels: [LiveTVPrototypeChannel]) async {
        // Validation, numbering, the comparison with the published lineup and the facts derived from it are O(lineup):
        // they run off the main actor, and applying the lineup reuses them.
        var timing = CatalogPreparationTiming()
        let numbers = preferencesStore == nil ? nil : stableChannelNumbers
        let current = suppliedChannels
        let source = channels
        defer { timing.emit(stage: "prepare", count: source.count) }
        let (channels, isNew, lineup) = await Task.detached(priority: .userInitiated) { () -> ([LiveTVPrototypeChannel], Bool, PreparedLineup) in
            var timing = CatalogPreparationTiming()
            var assigned: LiveTVStableChannelNumbers?
            let numbered: [LiveTVPrototypeChannel]
            if let numbers {
                let updated = numbers.assigning(orderedChannelIDs: Self.numberingOrder(source), at: Date())
                assigned = updated
                numbered = Self.renumbered(source, using: updated != numbers ? numbers.merging(updated) : numbers)
            } else {
                numbered = source
            }
            timing.mark("numbering")
            let changed = current != numbered
            timing.mark("compare")
            let ids = Set(source.map(\.id))
            timing.mark("ids")
            let placeholders = LiveTVLogoPlaceholders.placeholders(in: numbered)
            timing.mark("placeholders")
            let widestDigits = Self.widestNumberDigits(numbered)
            timing.mark("widestDigits")
            let lineup = PreparedLineup(
                source: source, baseline: current, numbersBefore: numbers, numbersAfter: assigned, numbered: numbered,
                changed: changed, ids: ids, placeholders: placeholders, widestDigits: widestDigits)
            timing.emit(stage: "lineup", count: source.count)
            return (numbered, changed, lineup)
        }.value
        timing.mark("awaitLineup")
        if !Task.isCancelled { preparedLineup = lineup }
        guard isNew, !Task.isCancelled, let inputs = catalogInputs(supplied: channels) else { return }
        timing.mark("inputs")
        let build = await Task.detached(priority: .userInitiated) { Self.build(inputs) }.value
        timing.mark("awaitBuild")
        guard !Task.isCancelled else { return }
        preparedBuild = build
        timing.mark("storeBuild")
    }

    private nonisolated static func build(_ inputs: CatalogInputs) -> CatalogBuild {
        var timing = CatalogPreparationTiming()
        let channels = named(
            inputs.supplied, cleaning: inputs.cleanNames, overrides: inputs.overrides)
        timing.mark("named")
        let index = LiveTVCatalogIndex(channels)
        timing.mark("catalogIndex")
        let manuallyHidden = Set(inputs.hiddenChannels.map(\.id))
        let organization = organizationResult(
            channels: channels, index: index, organization: inputs.organization,
            manuallyHidden: manuallyHidden, scanHidden: inputs.scanHidden, hiddenChannels: inputs.hiddenChannels
        )
        let hidden = manuallyHidden.union(inputs.scanHidden).union(organization.hidden)
        timing.mark("organization")
        let categories = categoryResult(channels: channels, hidden: hidden)
        timing.mark("categories")
        let favoriteIDs = inputs.explicitFavorites.union(organization.favorites)
        let tagIndex = LiveTVChannelTagIndex.build(channels: channels)
        timing.mark("tagIndex")
        let tagMembers = inputs.filter.tagIDs.isEmpty ? nil : LiveTVFavoriteFilterState.memberIDs(
            of: inputs.filter.tagIDs, index: tagIndex, channels: channels,
            live: LiveTVLiveTagMembers(favouriteIDs: favoriteIDs, recentIDs: Set(inputs.watchedIDs)))
        timing.mark("tagMembers")
        let searchIndex = SearchIndex(channels)
        timing.mark("searchIndex")
        let filtered = filteredCatalog(
            channels: channels, searchIndex: searchIndex, filter: inputs.filter, hidden: hidden, favoriteIDs: favoriteIDs, tagMembers: tagMembers,
            categories: categories.categories, categoryIndices: categories.indices,
            previous: FilteredCatalog(channels: [], categories: []), refreshCategoryCounts: true,
            hasGuide: { _ in true }
        )
        timing.mark("filtered")
        let rows = guideRows(
            visible: filtered.channels, recentIDs: inputs.recentIDs,
            favoriteOrder: inputs.favoriteOrder, favoriteIDs: favoriteIDs
        )
        timing.mark("guideRows")
        timing.emit(stage: "build", count: inputs.supplied.count)
        return CatalogBuild(
            searchIndex: searchIndex, inputs: inputs, tagIndex: tagIndex, channels: channels, index: index, organization: organization,
            categories: categories, filtered: filtered, rows: rows
        )
    }

    /// The same assignments, in the same order, as a rebuild on the main actor.
    private func install(_ build: CatalogBuild) {
        channels = build.channels
        searchIndex = build.searchIndex
        channelsByID = build.index
        favoriteFilters.install(tagIndex: build.tagIndex, channels: build.channels)
        install(build.organization)
        install(build.categories)
        dropRemovedPlayback()
        if preferencesLoaded, savedBrowse != browsePreferences {
            _ = persistPreferences(currentPreferences)
        }
        filteredCatalog = build.filtered
        install(build.rows)
    }

    /// Placeholders (section markers, idle and ended event slots: `LiveTVPlaceholder`) are classified from the supplied names
    /// on every build and never stored, so a renamed slot reappears at once. None is kept, favourited or not.
    private nonisolated static func named(
        _ channels: [LiveTVPrototypeChannel], cleaning cleanChannelNames: Bool,
        overrides channelOverrides: [String: LiveTVChannelMetadataOverride]
    ) -> [LiveTVPrototypeChannel] {
        let kept = channels.filter { !$0.isSectionMarker }
        #if DEBUG
        if kept.count != channels.count { PlozzLog.app.debug("Excluded \(channels.count - kept.count) section markers from the catalog") }
        #endif
        let channels = kept
        let eventZones = eventTimeZones(in: channels)
        // Tags are always derived from the provider's name (once per catalog build, off the main actor);
        // the clean-names setting only decides whether the name loses what became a tag.
        let builtAt = Date()
        return channels.compactMap { channel -> LiveTVPrototypeChannel? in
            let value = channelOverrides[channel.id]
            var name = channel.name
            var tags = channel.tags
            var language = channel.language
            var country = channel.country
            var eventSlot = channel.eventSlot
            var loopTitle = channel.loopTitle
            if channel.source == .iptv {
                eventSlot = eventZones.candidates.contains(channel.id)
                    ? LiveTVEventSlotClassifier.classify(
                        name: channel.name, groups: channel.categories,
                        timeZone: eventZones.zones[channel.playlistSourceID] ?? .current)
                    : nil
                loopTitle = eventSlot == nil
                    ? LiveTVChannelKind.showLoopTitle(name: channel.name, groups: channel.categories, includingActors: true) : nil
                let split = IPTVChannelName.split(channel.name, groups: channel.categories)
                tags = split.tags
                if cleanChannelNames { name = split.name }
                // The provider's own metadata wins over a prefix in the name.
                if language == nil { language = tags.lazy.compactMap(\.language).first }
                if country == nil { country = tags.lazy.compactMap(\.country).first }
            }
            // An idle or ended event slot is a placeholder (`LiveTVPlaceholder`): never part of the catalog.
            if let slot = eventSlot, LiveTVPlaceholder.isPlaceholder(slot, now: builtAt) { return nil }
            name = value?.name ?? name
            if value == nil, name == channel.name, tags == channel.tags,
               language == channel.language, country == channel.country, eventSlot == channel.eventSlot,
               loopTitle == channel.loopTitle { return channel }
            return LiveTVPrototypeChannel(
                id: channel.id, number: channel.number, name: name,
                category: value?.category ?? channel.category, symbol: channel.symbol, accent: channel.accent,
                source: channel.source, tagline: channel.tagline, logoURL: channel.logoURL,
                streamURL: channel.streamURL, logoNeedsDarkBackground: channel.logoNeedsDarkBackground,
                guideID: channel.guideID, guideName: channel.guideName, httpHeaders: channel.httpHeaders,
                playlistSourceID: channel.playlistSourceID, language: value?.language ?? language,
                country: value?.country ?? country, groups: value?.category.map { [$0] } ?? channel.groups,
                plozzChannelMood: channel.plozzChannelMood, tags: tags, eventSlot: eventSlot, guideLogoURL: channel.guideLogoURL,
                loopTitle: loopTitle
            )
        }
    }

    /// The event-slot candidates and, per playlist source, the zone its event stamps are written in
    /// (`LiveTVEventTimeZoneInference`; a source without enough evidence is absent and uses the viewer's zone).
    /// Computed once per catalog build, over the candidates only.
    private nonisolated static func eventTimeZones(
        in channels: [LiveTVPrototypeChannel]
    ) -> (candidates: Set<String>, zones: [String?: TimeZone]) {
        var groupIsEvent: [String: Bool] = [:]
        let isEventGroup: (String) -> Bool = { group in
            if let known = groupIsEvent[group] { return known }
            let value = LiveTVEventSlotClassifier.isEventGroup(group)
            groupIsEvent[group] = value
            return value
        }
        var candidates = Set<String>()
        var namesBySource: [String?: [String]] = [:]
        for channel in channels where channel.source == .iptv
            && LiveTVEventSlotClassifier.isCandidate(name: channel.name, groups: channel.categories, groupIsEvent: isEventGroup) {
            candidates.insert(channel.id)
            namesBySource[channel.playlistSourceID, default: []].append(channel.name)
        }
        var zones: [String?: TimeZone] = [:]
        for (source, names) in namesBySource {
            guard let inferred = LiveTVEventTimeZoneInference.infer(from: names) else {
                #if DEBUG
                PlozzLog.app.debug("Event stamps of source \(source ?? "-") read in the viewer's time zone (no zone agreed)")
                #endif
                continue
            }
            zones[source] = inferred.timeZone
            #if DEBUG
            PlozzLog.app.debug(
                "Event stamps of source \(source ?? "-") read in \(inferred.abbreviation) (\(inferred.matches) of \(inferred.samples) zone-named events agree)")
            #endif
        }
        return (candidates, zones)
    }

    func refreshVisibleChannels(refreshCategoryCounts: Bool = true) {
        guard !isBatchingFilterChanges else { return }
        if preferencesLoaded, savedBrowse != browsePreferences {
            _ = persistPreferences(currentPreferences)
        }
        if searchIndex == nil, !query.isEmpty || sort == .name { searchIndex = SearchIndex(channels) }
        filteredCatalog = Self.filteredCatalog(
            channels: channels, searchIndex: searchIndex, filter: browseFilter, hidden: effectiveHiddenChannelIDs, favoriteIDs: favoriteIDs,
            tagMembers: favoriteFilters.selectedMembers(
                channels: channels, live: LiveTVLiveTagMembers(favouriteIDs: favoriteIDs, recentIDs: Set(recentChannelIDs))),
            categories: categories, categoryIndices: categoryChannelIndices, previous: filteredCatalog,
            refreshCategoryCounts: refreshCategoryCounts, hasGuide: { hasGuide(for: $0) }
        )
        refreshGuideChannels()
    }

    private nonisolated static func filteredCatalog(
        channels: [LiveTVPrototypeChannel], searchIndex: SearchIndex?, filter: BrowseFilter, hidden: Set<String>, favoriteIDs: Set<String>,
        tagMembers: Set<String>?, categories: [String], categoryIndices: [String: [Int]], previous: FilteredCatalog,
        refreshCategoryCounts: Bool, hasGuide: (LiveTVPrototypeChannel) -> Bool
    ) -> FilteredCatalog {
        let normalizedQuery = Self.normalized(filter.query)
        let queryBytes = Array(normalizedQuery.utf8)
        let categoryMatches = normalizedQuery.isEmpty ? [] : categories.filter {
            Self.normalized($0).contains(normalizedQuery)
        }
        let matchingCategoryNames = Set(categoryMatches)
        var visibleCategoryMatches = Set<String>()
        // A filter that requires Live Events is the events lineup, narrowed by its other tags.
        let eventsMode = filter.category == LiveTVEventSlotClassifier.filterName
            || filter.tagIDs.contains(LiveTVFilterTagCatalog.liveEventsID)
        let selectedCategory = eventsMode ? nil : filter.category.map(Self.normalized)
        let hiddenChannelIDs = hidden
        let language = filter.language.map(Self.normalized)
        let country = filter.country.map(Self.normalized)
        let source = filter.source
        let playlistSourceID = filter.playlistSourceID
        let favoritesOnly = filter.favoritesOnly
        let guideOnly = filter.guideOnly
        let sort = filter.sort

        // Event slots are a lineup of their own: never in My Channels, its counts or its search.
        func isEligible(_ channel: LiveTVPrototypeChannel) -> Bool {
            (channel.eventSlot != nil) == eventsMode && isEligibleIgnoringEvents(channel)
        }
        func isEligibleIgnoringEvents(_ channel: LiveTVPrototypeChannel) -> Bool {
            !hiddenChannelIDs.contains(channel.id)
                && (tagMembers == nil || tagMembers?.contains(channel.id) == true)
                && (source == nil || channel.source == source)
                && (language == nil || channel.languages.contains(where: { Self.normalized($0) == language }))
                && (country == nil || channel.countries.contains(where: { Self.normalized($0) == country }))
                && (playlistSourceID == nil || channel.playlistSourceID == playlistSourceID)
                && (!favoritesOnly || favoriteIDs.contains(channel.id))
                && (!guideOnly || hasGuide(channel))
        }

        var counts = previous.categoryCounts
        var total = previous.totalCount
        var activeEvents = previous.activeEventCount
        if refreshCategoryCounts {
            activeEvents = 0
            var normalizedCounts: [String: Int] = [:]
            var eligibleCategories = Set<String>()
            total = 0
            // A large lineup repeats a few hundred category names; fold each one once.
            var normalizedNames: [String: String] = [:]
            func normalizedName(_ category: String) -> String {
                if let known = normalizedNames[category] { return known }
                let value = Self.normalized(category)
                normalizedNames[category] = value
                return value
            }
            for channel in channels where isEligibleIgnoringEvents(channel) {
                if let slot = channel.eventSlot {
                    if !slot.isIdle { activeEvents += 1 }
                    continue
                }
                total += 1
                let categories = channel.categories
                eligibleCategories.formUnion(categories)
                if categories.count == 1 {
                    normalizedCounts[normalizedName(categories[0]), default: 0] += 1
                } else {
                    for name in Set(categories.map(normalizedName)) {
                        normalizedCounts[name, default: 0] += 1
                    }
                }
            }
            counts = Dictionary(uniqueKeysWithValues: eligibleCategories.map {
                ($0, normalizedCounts[normalizedName($0), default: 0])
            })
        }

        var foldedCategoryText: [String: String] = [:]
        // Category/query changes reuse counts and the category index, even for large lineups.
        let queryHasControlCharacters = queryBytes.contains { $0 < 0x20 }
        let candidates: [Int]
        if let selectedCategory {
            candidates = categoryIndices[selectedCategory] ?? []
        } else if let searchIndex, searchIndex.entries.count == channels.count, !normalizedQuery.isEmpty,
                  matchingCategoryNames.isEmpty, !queryHasControlCharacters {
            candidates = searchIndex.channelIndices(containing: queryBytes)
        } else {
            candidates = Array(channels.indices)
        }
        // With the lineup's index, a channel that cannot match the query is rejected from its folded text alone, without
        // touching the (large) channel value.
        let indexEntries = searchIndex.flatMap { $0.entries.count == channels.count ? $0.entries : nil }
        let entries = normalizedQuery.isEmpty || !matchingCategoryNames.isEmpty ? nil : indexEntries
        var visibleChannels = candidates.compactMap {
            index -> (index: Int, rank: Int, number: Int, id: String, name: String)? in
            var indexedRank: Int?
            if let entries {
                guard let rank = Self.searchRank(entries[index], queryBytes: queryBytes, query: normalizedQuery) else { return nil }
                indexedRank = rank
            }
            let channel = channels[index]
            guard isEligible(channel) else { return nil }
            if !matchingCategoryNames.isEmpty {
                for category in channel.categories where matchingCategoryNames.contains(category) {
                    visibleCategoryMatches.insert(category)
                }
            }

            // The folded text comes from the index built with the lineup; without one (a small lineup) it is folded here.
            let entry = indexEntries?[index]
            let name = sort == .name || !normalizedQuery.isEmpty ? (entry?.name ?? Self.normalized(channel.name)) : ""
            guard !normalizedQuery.isEmpty else { return (index, 0, channel.number, channel.id, name) }
            if let indexedRank { return (index, indexedRank, channel.number, channel.id, name) }
            let number = entry?.number ?? String(channel.number)
            if number == normalizedQuery {
                return (index, 0, channel.number, channel.id, name)
            }
            let foldedCategories: String
            if let entry { foldedCategories = entry.categories } else {
                // A lineup repeats a few hundred category lists; each is folded once.
                let categoryText = channel.categories.joined(separator: " ")
                if let known = foldedCategoryText[categoryText] { foldedCategories = known } else {
                    foldedCategories = Self.normalized(categoryText)
                    foldedCategoryText[categoryText] = foldedCategories
                }
            }
            let source = entry?.source ?? Self.normalized(channel.source.rawValue)
            if name.utf8.starts(with: queryBytes) || number.utf8.starts(with: queryBytes)
                || foldedCategories.utf8.starts(with: queryBytes) || source.utf8.starts(with: queryBytes) {
                return (index, 1, channel.number, channel.id, name)
            }
            if Self.contains(name, queryBytes) || Self.contains(number, queryBytes)
                || Self.contains(foldedCategories, queryBytes) || Self.contains(source, queryBytes) {
                return (index, 2, channel.number, channel.id, name)
            }
            return nil
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            switch sort {
            case .channelNumber:
                if lhs.number != rhs.number {
                    return lhs.number < rhs.number
                }
            case .name:
                if lhs.name != rhs.name { return lhs.name < rhs.name }
            }
            return lhs.id < rhs.id
        }
        .map { channels[$0.index] }
        if eventsMode, normalizedQuery.isEmpty { visibleChannels = eventOrdered(visibleChannels) }
        return FilteredCatalog(
            channels: visibleChannels,
            categories: categoryMatches.filter { visibleCategoryMatches.contains($0) },
            categoryCounts: counts, totalCount: total,
            activeEventCount: activeEvents, candidatesExamined: candidates.count
        )
    }

    /// Events with a start first, by start time; events without one; idle slots last. Each group by number.
    private nonisolated static func eventOrdered(_ channels: [LiveTVPrototypeChannel]) -> [LiveTVPrototypeChannel] {
        func group(_ channel: LiveTVPrototypeChannel) -> Int {
            guard let slot = channel.eventSlot, !slot.isIdle else { return 2 }
            return slot.start == nil ? 1 : 0
        }
        return channels.sorted { lhs, rhs in
            let (left, right) = (group(lhs), group(rhs))
            if left != right { return left < right }
            if left == 0, let a = lhs.eventSlot?.start, let b = rhs.eventSlot?.start, a != b { return a < b }
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.id < rhs.id
        }
    }

    private struct CategoryResult: Sendable {
        let indices: [String: [Int]]
        let categories: [String]
        let languages: [String]
        let countries: [String]
    }

    private func refreshCategories() {
        install(Self.categoryResult(channels: channels, hidden: effectiveHiddenChannelIDs))
    }

    private func install(_ result: CategoryResult) {
        categoryChannelIndices = result.indices
        categories = result.categories
        languages = result.languages
        countries = result.countries
    }

    private nonisolated static func categoryResult(
        channels: [LiveTVPrototypeChannel], hidden hiddenChannelIDs: Set<String>
    ) -> CategoryResult {
        var categoryValues = Set<String>()
        var languageValues = Set<String>()
        var countryValues = Set<String>()
        var categoryIndices: [String: [Int]] = [:]
        var normalizedCategories: [String: String] = [:]
        for (index, channel) in channels.enumerated() where !hiddenChannelIDs.contains(channel.id) {
            categoryValues.formUnion(channel.categories)
            var seenCategories = Set<String>()
            for category in channel.categories {
                let normalized = normalizedCategories[category] ?? Self.normalized(category)
                normalizedCategories[category] = normalized
                if seenCategories.insert(normalized).inserted {
                    categoryIndices[normalized, default: []].append(index)
                }
            }
            if let language = channel.language { languageValues.insert(language) }
            if let country = channel.country { countryValues.insert(country) }
        }
        return CategoryResult(
            indices: categoryIndices,
            categories: categoryValues.sorted { Self.normalized($0) < Self.normalized($1) },
            languages: Set(languageValues.flatMap(LiveTVPrototypeChannel.metadataValues)).sorted(),
            countries: Set(countryValues.flatMap(LiveTVPrototypeChannel.metadataValues)).sorted()
        )
    }

    private struct OrganizationResult: Sendable {
        let favorites: Set<String>
        let hidden: Set<String>
        let summaries: [LiveTVCategorySummary]
        let entries: [LiveTVHiddenChannelEntry]
        let countries: [String]
        let languages: [String]
    }

    private func refreshOrganization() {
        install(Self.organizationResult(
            channels: channels, index: channelsByID, organization: organization,
            manuallyHidden: hiddenChannelIDs, scanHidden: scanHiddenChannelIDs, hiddenChannels: hiddenChannels
        ))
    }

    private func install(_ result: OrganizationResult) {
        categoryFavoriteIDs = result.favorites
        organizationHiddenChannelIDs = result.hidden
        categorySummaries = result.summaries
        hiddenChannelEntries = result.entries
        organizationCountries = result.countries
        organizationLanguages = result.languages
    }

    private nonisolated static func organizationResult(
        channels: [LiveTVPrototypeChannel], index channelsByID: LiveTVCatalogIndex<LiveTVPrototypeChannel>,
        organization: LiveTVChannelOrganization, manuallyHidden: Set<String>, scanHidden scanHiddenChannelIDs: Set<String>,
        hiddenChannels: [LiveTVHiddenChannel]
    ) -> OrganizationResult {
        var summaries = organization.categories.mapValues { (rule: $0, total: 0, visible: 0) }
        var favorites = Set<String>()
        var hidden = Set<String>()
        var entries: [LiveTVHiddenChannelEntry] = []
        var countryValues = organization.region.countries
        var languageValues = organization.region.languages
        var categoryKeys: [String: [String: String]] = [:]
        for channel in channels {
            let metadata = channel.organizationMetadata
            let sourceKey = channel.configuredSourceID ?? ""
            let categoryIDs: [String] = metadata?.categories.map { name in
                if let id = categoryKeys[sourceKey]?[name] { return id }
                let id = LiveTVCategoryRule.identifier(sourceID: channel.configuredSourceID, name: name)
                categoryKeys[sourceKey, default: [:]][name] = id
                return id
            } ?? []
            let ruleReason = metadata.flatMap {
                organization.hiddenReason(channelID: channel.id, metadata: $0, categoryIDs: categoryIDs)
            }
            if ruleReason != nil { hidden.insert(channel.id) }
            let reason: LiveTVChannelHiddenReason? = manuallyHidden.contains(channel.id) ? .channel
                : scanHiddenChannelIDs.contains(channel.id) ? .scan : ruleReason
            if let reason { entries.append(.init(id: channel.id, name: channel.name, reason: reason)) }
            guard let metadata else { continue }
            if organization.isCategoryFavorite(channelID: channel.id, metadata: metadata, categoryIDs: categoryIDs) {
                favorites.insert(channel.id)
            }
            countryValues.formUnion(metadata.countries.map(LiveTVRegionMetadata.country))
            languageValues.formUnion(metadata.languages.map(LiveTVRegionMetadata.language))
            var seen = Set<String>()
            for (name, id) in zip(metadata.categories, categoryIDs) {
                guard seen.insert(id).inserted else { continue }
                if summaries[id] == nil {
                    summaries[id] = (.init(sourceID: metadata.sourceID, name: name), 0, 0)
                }
                summaries[id]?.total += 1
                if reason == nil { summaries[id]?.visible += 1 }
            }
        }
        for channel in hiddenChannels where channelsByID[channel.id] == nil {
            entries.append(.init(id: channel.id, name: channel.name, reason: .channel))
        }
        // Sort keys are derived once: a rule's identifier is a digest, not a stored value.
        return OrganizationResult(
            favorites: favorites, hidden: hidden,
            summaries: summaries.values.map { value in
                (key: (value.rule.sourceID ?? "", LiveTVRegionMetadata.normalized(value.rule.name), value.rule.id),
                 summary: LiveTVCategorySummary(
                    rule: value.rule, channelCount: value.total, visibleCount: value.visible))
            }.sorted { $0.key < $1.key }.map(\.summary),
            entries: entries.sorted { ($0.name, $0.id) < ($1.name, $1.id) },
            countries: countryValues.sorted(), languages: languageValues.sorted()
        )
    }

    private struct GuideRows: Sendable {
        let rows: [LiveTVGuideChannel]
        let ids: [LiveTVGuideRowID]
        let index: LiveTVCatalogIndex<LiveTVGuideChannel>
    }

    private func refreshGuideChannels() {
        install(Self.guideRows(
            visible: visibleChannels, recentIDs: showsRecentChannels ? recentChannelIDs : [],
            favoriteOrder: favoriteOrder, favoriteIDs: favoriteIDs
        ))
    }

    private func install(_ result: GuideRows) {
        orderedGuideRowIDs = result.ids
        // Share the row array with presentation; the lookup retains only offsets.
        guideEntries = result.index
        guideChannels = result.rows
    }

    private nonisolated static func guideRows(
        visible visibleChannels: [LiveTVPrototypeChannel], recentIDs: [String],
        favoriteOrder: [String], favoriteIDs: Set<String>
    ) -> GuideRows {
        let retainedIDs = Set(recentIDs).union(favoriteOrder)
        let visibleByID = retainedIDs.isEmpty ? [:] : Dictionary(
            uniqueKeysWithValues: visibleChannels.lazy.filter { retainedIDs.contains($0.id) }.map { ($0.id, $0) }
        )
        let recent = recentIDs.compactMap { visibleByID[$0] }
        let orderedIDs = Set(favoriteOrder)
        let favorites = favoriteOrder.compactMap { visibleByID[$0] }
            + visibleChannels.filter { favoriteIDs.contains($0.id) && !orderedIDs.contains($0.id) }
        let groups: [(LiveTVGuideSection, [LiveTVPrototypeChannel])] = [
            (.recent, recent), (.favorites, favorites), (.channels, visibleChannels)
        ]
        var updated: [LiveTVGuideChannel] = []
        updated.reserveCapacity(recent.count + favorites.count + visibleChannels.count)
        for (section, channels) in groups {
            for (index, channel) in channels.enumerated() {
                updated.append(LiveTVGuideChannel(channel: channel, section: section, startsSection: index == 0))
            }
        }
        return GuideRows(rows: updated, ids: updated.map(\.id), index: LiveTVCatalogIndex(updated))
    }

    private func hasGuide(for channel: LiveTVPrototypeChannel) -> Bool {
        if channel.loopTitle != nil { return true }
        // Imported channels use only provider listings, never synthetic schedules.
        if usesPublicStreams {
            // Filtering must not hide channels before demand loading can discover their guide.
            return knownGuideChannelIDs.contains(channel.id) || guideState.pendingChannelIDs.contains(channel.id)
                || importedPrograms[channel.id]?.isEmpty == false
        }
        #if DEBUG
        switch scenario {
        case .noGuide, .failedGuide:
            return false
        case .fullGuide, .staleGuide:
            return true
        case .mixedGuide:
            let ordinal = channelsByID.ordinals[channel.id] ?? 0
            return channel.source == .plozz || ordinal.isMultiple(of: 3)
        }
        #else
        return false
        #endif
    }

    #if DEBUG
    private func programDuration(for channelID: String) -> TimeInterval {
        let ordinal = channelsByID.ordinals[channelID] ?? 1
        return ordinal.isMultiple(of: 4) ? 3_600 : 1_800
    }

    private func program(
        for channel: LiveTVPrototypeChannel,
        start: Date,
        end: Date
    ) -> LiveTVPrototypeProgram {
        let duration = end.timeIntervalSince(start)
        let slot = Int(start.timeIntervalSince1970 / duration)
        let ordinal = channelsByID.ordinals[channel.id] ?? 1
        let fixture = Self.programFixtures[Self.positiveModulo(slot + ordinal, Self.programFixtures.count)]
        let startSeconds = Int(start.timeIntervalSince1970)
        return LiveTVPrototypeProgram(
            id: "\(channel.id)-\(startSeconds)-\(Int(duration))",
            channelID: channel.id,
            title: fixture.title,
            subtitle: fixture.subtitle,
            start: start,
            end: end
        )
    }

    private static func makeChannel(ordinal: Int) -> LiveTVPrototypeChannel {
        let baseIndex = (ordinal - 1) % baseStations.count
        let variant = (ordinal - 1) / baseStations.count + 1
        let station = baseStations[baseIndex]
        let name = variant == 1 ? station.name : "\(station.name) \(variant)"
        let tagline = variant == 1
            ? station.tagline
            : "\(station.tagline) Catalog variant \(variant)."
        return LiveTVPrototypeChannel(
            id: channelID(ordinal),
            number: ordinal,
            name: name,
            category: station.category,
            symbol: station.symbol,
            accent: (station.accent + variant - 1) % 6,
            source: station.source,
            tagline: tagline
        )
    }

    private static func channelID(_ ordinal: Int) -> String {
        String(format: "live-tv-%04d", ordinal)
    }
    #endif

    /// 0 an exact channel number, 1 a prefix of a field, 2 contained in a field, `nil` no match.
    private nonisolated static func searchRank(_ entry: SearchIndex.Entry, queryBytes: [UInt8], query: String) -> Int? {
        if entry.number == query { return 0 }
        if entry.name.utf8.starts(with: queryBytes) || entry.number.utf8.starts(with: queryBytes)
            || entry.categories.utf8.starts(with: queryBytes) || entry.source.utf8.starts(with: queryBytes) { return 1 }
        if contains(entry.name, queryBytes) || contains(entry.number, queryBytes)
            || contains(entry.categories, queryBytes) || contains(entry.source, queryBytes) { return 2 }
        return nil
    }

    /// Whether `text` contains the bytes of the (already folded) query: a byte search, not Character-by-Character.
    private nonisolated static func contains(_ text: String, _ query: [UInt8]) -> Bool {
        guard let first = query.first else { return true }
        var text = text
        return text.withUTF8 { bytes in
            guard bytes.count >= query.count else { return false }
            let last = bytes.count - query.count
            var position = 0
            while position <= last {
                if bytes[position] == first {
                    var matched = 1
                    while matched < query.count, bytes[position + matched] == query[matched] { matched += 1 }
                    if matched == query.count { return true }
                }
                position += 1
            }
            return false
        }
    }

    nonisolated static func normalized(_ value: String) -> String {
        // Case folding of ASCII text is lower-casing, and it has no diacritics: most of a lineup, at a fraction of the cost.
        if value.utf8.allSatisfy({ $0 < 0x80 }) { return value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if DEBUG
    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private struct StationFixture {
        let name: String
        let category: String
        let symbol: String
        let accent: Int
        let source: LiveTVPrototypeSource
        let tagline: String
    }

    private static let baseStations: [StationFixture] = [
        .init(name: "World Desk", category: "News", symbol: "globe", accent: 0, source: .iptv, tagline: "Headlines from a fictional global newsroom."),
        .init(name: "Cinema Club", category: "Movies", symbol: "film", accent: 1, source: .jellyfin, tagline: "Made-up movies and friendly introductions."),
        .init(name: "Comedy Hour", category: "Comedy", symbol: "theatermasks", accent: 2, source: .plex, tagline: "Sketches, stand-up, and improvised mishaps."),
        .init(name: "Wild Earth", category: "Nature", symbol: "leaf", accent: 3, source: .emby, tagline: "Quiet journeys through imaginary habitats."),
        .init(name: "Arena Central", category: "Sports", symbol: "sportscourt", accent: 4, source: .plozz, tagline: "Fixture matches, recaps, and studio analysis."),
        .init(name: "Café Society", category: "Culture", symbol: "paintpalette", accent: 5, source: .iptv, tagline: "Artists and ideas meet over a fictional cup."),
        .init(name: "Storybook", category: "Kids", symbol: "book.closed", accent: 0, source: .jellyfin, tagline: "Gentle animated tales for young viewers."),
        .init(name: "Neighborhood Live", category: "Community", symbol: "person.3", accent: 1, source: .plex, tagline: "Local events from an entirely invented town."),
        .init(name: "Science Window", category: "Science", symbol: "atom", accent: 2, source: .emby, tagline: "Simple experiments and curious questions."),
        .init(name: "Retro Rewind", category: "Classics", symbol: "clock.arrow.circlepath", accent: 3, source: .plozz, tagline: "Freshly fictional favorites from decades past."),
        .init(name: "Kitchen Table", category: "Food", symbol: "fork.knife", accent: 4, source: .iptv, tagline: "Comfort cooking with pantry-sized challenges."),
        .init(name: "Road Atlas", category: "Travel", symbol: "map", accent: 5, source: .jellyfin, tagline: "Scenic routes through places that never existed."),
        .init(name: "Night Signals", category: "Music", symbol: "music.note", accent: 0, source: .plex, tagline: "Late sets from original imaginary performers."),
        .init(name: "Market Brief", category: "Business", symbol: "chart.line.uptrend.xyaxis", accent: 1, source: .emby, tagline: "Demo markets, explainers, and fictional figures."),
        .init(name: "Weather Watch", category: "Weather", symbol: "cloud.sun", accent: 2, source: .plozz, tagline: "Forecasts for the prototype coast."),
        .init(name: "Open Stage", category: "Culture", symbol: "music.mic", accent: 3, source: .iptv, tagline: "New plays and performances from a demo venue."),
        .init(name: "Game Day Extra", category: "Sports", symbol: "trophy", accent: 4, source: .jellyfin, tagline: "More fictional fixtures and postgame conversation."),
        .init(name: "Documentary Room", category: "Documentary", symbol: "doc.text.image", accent: 5, source: .plex, tagline: "Original short documentaries about imagined subjects."),
        .init(name: "Morning Mix", category: "Lifestyle", symbol: "sun.max", accent: 0, source: .emby, tagline: "A bright fixture blend of guests and ideas."),
        .init(name: "Pixel Play", category: "Gaming", symbol: "gamecontroller", accent: 1, source: .plozz, tagline: "Invented tournaments and relaxed game talk."),
        .init(name: "History Vault", category: "History", symbol: "building.columns", accent: 2, source: .iptv, tagline: "Stories recovered from a fictional archive."),
        .init(name: "Makers Workshop", category: "Education", symbol: "hammer", accent: 3, source: .jellyfin, tagline: "Small builds demonstrated one careful step at a time."),
        .init(name: "Cozy Mysteries", category: "Drama", symbol: "sparkles.tv", accent: 4, source: .plex, tagline: "Low-stakes cases in a made-up village."),
        .init(name: "Late Night Shorts", category: "Comedy", symbol: "rectangle.stack", accent: 5, source: .emby, tagline: "Compact comedies made for this fixture."),
        .init(name: "Ocean View", category: "Nature", symbol: "water.waves", accent: 0, source: .plozz, tagline: "Calm expeditions across imaginary seas."),
        .init(name: "Festival Screen", category: "Movies", symbol: "ticket", accent: 1, source: .iptv, tagline: "Original festival selections and filmmaker chats."),
        .init(name: "Junior Lab", category: "Kids", symbol: "testtube.2", accent: 2, source: .jellyfin, tagline: "Safe science puzzles for curious young minds."),
        .init(name: "City Council", category: "Civic", symbol: "building.2", accent: 3, source: .plex, tagline: "Proceedings from a purely fictional municipality."),
        .init(name: "Quiet Channel", category: "Uncategorized", symbol: "questionmark.square", accent: 4, source: .emby, tagline: "A useful home for uncategorized demo programming."),
        .init(name: "Plozz Preview", category: "Entertainment", symbol: "play.tv", accent: 5, source: .plozz, tagline: "Prototype highlights from across the fixture lineup.")
    ]

    private static let programFixtures: [(title: String, subtitle: String)] = [
        ("First Edition", "A concise start to the next block."),
        ("Open Window", "Stories gathered from around the demo schedule."),
        ("The Long Route", "A thoughtful trip with an unexpected turn."),
        ("Studio Session", "Original guests share work and process."),
        ("Field Notes", "Small observations from a fictional expedition."),
        ("Half-Time Table", "Friendly analysis without real-world results."),
        ("Picture House", "A short feature from the prototype archive."),
        ("Bright Ideas", "Curious questions meet practical demonstrations."),
        ("Local Color", "People and places from an invented community."),
        ("Night Shift", "A calm late block of stories and conversation."),
        ("Second Look", "Another angle on the day's fixture topics."),
        ("Next Stop", "A compact journey to a newly imagined destination.")
    ]
    #endif
}

/// Catalog task identity stays stable when a hidden preload becomes visible.
public struct LiveTVCatalogActivation: Sendable {
    public let isActive: Bool
    public let hasBeenActive: Bool
    public let preloadsCatalog: Bool
    public let isAuthorized: Bool

    public init(isActive: Bool, hasBeenActive: Bool, preloadsCatalog: Bool, isAuthorized: Bool) {
        self.isActive = isActive
        self.hasBeenActive = hasBeenActive
        self.preloadsCatalog = preloadsCatalog
        self.isAuthorized = isAuthorized
    }

    public var loadsCatalog: Bool { isActive || (preloadsCatalog && !hasBeenActive) }

    public func taskID(reloadRequest: Int) -> Int {
        loadsCatalog && isAuthorized ? reloadRequest : -1
    }

    public static func mountsDestination(isActive: Bool, hasAppeared: Bool) -> Bool {
        isActive || hasAppeared
    }

    public static func shouldPreload(preloads: Bool, hasAppeared: Bool) -> Bool {
        preloads && !hasAppeared
    }
}



