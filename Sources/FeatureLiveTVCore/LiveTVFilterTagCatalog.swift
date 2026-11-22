import Foundation

/// A tag a favourite filter can require: the mockup's curated vocabulary, never free text.
/// `Arabic` is both a region and a language and is one tag (the mockup keys tags by identifier), listed in both sections.
public struct LiveTVFilterTag: Hashable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case genre, sport, channels, countryRegion, region, language, network

        /// The section title the tag picker shows.
        public var title: String {
            switch self {
            case .genre: "Genre"
            case .sport: "Sport"
            case .channels: "Channels"
            case .countryRegion: "Country & Region"
            case .region: "Region"
            case .language: "Language"
            case .network: "Network"
            }
        }
    }

    public let id: String
    public let title: String
    public let section: Section
    /// The name used inside a filter's auto-generated name ("UK", "Favourites"), as the mockup abbreviates it.
    public let shortTitle: String
}

/// The tag vocabulary (the mockup's `TAG_SECTIONS`), its identifiers and the suggested list.
public enum LiveTVFilterTagCatalog {
    /// The mockup's `tagId`: lower case, `&` → "and", `+` → "plus", everything else non-alphanumeric → "-".
    public static func tagID(_ title: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in title.lowercased() {
            let piece: String
            switch character {
            case "&": piece = "and"
            case "+": piece = "plus"
            default:
                if character.isASCII, character.isLetter || character.isNumber { piece = String(character) } else { pendingSeparator = true; continue }
            }
            if pendingSeparator, !result.isEmpty { result += "-" }
            pendingSeparator = false
            result += piece
        }
        return result
    }

    /// A region tag's identifier: "region-" and the place's slug, so a place never collides with a country or a network.
    public static func regionTagID(_ place: String) -> String { "region-" + tagID(place) }

    public static let favouriteChannelsID = tagID("Favourite Channels")
    public static let recentlyWatchedID = tagID("Recently Watched")
    public static let liveEventsID = tagID("Live Events")
    public static let ultraHDID = tagID("4K")
    public static let twentyFourSevenID = tagID("24/7")
    public static let radioID = tagID("Radio")
    public static let payPerViewID = tagID("Pay-per-view")

    /// Tags decided from the live favourites and recents, never from the lineup build.
    public static let liveTagIDs: Set<String> = [favouriteChannelsID, recentlyWatchedID]

    /// Tags whose stored identifier is not `tagID(title)`: "Hockey" was "Ice Hockey", and saved filters and the channel tagger keep the
    /// identifier `ice-hockey`, so nothing is migrated.
    private static let identifierOverrides = ["Hockey": "ice-hockey"]

    private static let abbreviations = ["Favourite Channels": "Favourites", "United Kingdom": "UK", "United States": "US"]

    private static let sectionTitles: [(Tag.Section, [String])] = [
        (.genre, ["Sports", "Movies", "Entertainment", "News", "Kids", "Family", "Documentary", "Music", "Comedy", "Drama", "Reality",
                  "Lifestyle", "Food", "Nature", "History", "Religion"]),
        (.sport, ["Football", "Hockey", "Formula 1", "Motorsport", "Golf", "Tennis", "Cricket", "Rugby", "Basketball", "American Football",
                  "Baseball", "Boxing & MMA", "Cycling", "Darts & Snooker"]),
        (.channels, ["Favourite Channels", "Recently Watched", "Live Events", "4K", "24/7", "Radio", "Pay-per-view"]),
        (.countryRegion, ["United Kingdom", "Ireland", "United States", "Canada", "Australia", "New Zealand", "France", "Germany", "Spain",
                          "Italy", "Portugal", "Netherlands", "Belgium", "Switzerland", "Austria", "Sweden", "Norway", "Denmark",
                          "Finland", "Poland", "Turkey", "Greece", "India", "Pakistan", "Brazil", "Mexico", "Argentina", "Philippines",
                          "Israel", "Saudi Arabia", "Africa", "Arabic", "Latin America", "Balkans"]),
        (.region, LiveTVPlaceNames.tagPlaces),
        (.language, ["English", "Arabic", "Spanish", "German", "Turkish", "French", "Dutch", "Italian", "Portuguese", "Polish", "Greek",
                     "Russian", "Persian", "Hindi", "Urdu", "Punjabi", "Tamil", "Swedish"]),
        (.network, ["Sky", "BBC", "ITV", "Channel 4", "Now TV", "TNT Sports", "Eurosport", "DAZN", "ESPN", "beIN Sports", "Canal+",
                    "SuperSport", "Paramount+", "Discovery", "National Geographic", "Comedy Central", "CNN", "Fox", "NBC", "DStv",
                    "CBC", "CTV", "TSN", "Sportsnet"])
    ]
    private typealias Tag = LiveTVFilterTag

    /// Every tag, in the picker's section order.
    public static let all: [LiveTVFilterTag] = sectionTitles.flatMap { section, titles in
        titles.map {
            LiveTVFilterTag(id: section == .region ? regionTagID($0) : (identifierOverrides[$0] ?? tagID($0)), title: $0, section: section, shortTitle: abbreviations[$0] ?? $0)
        }
    }

    private static let byID: [String: LiveTVFilterTag] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

    public static func tag(id: String) -> LiveTVFilterTag? { byID[id] }

    public static func tags(in section: LiveTVFilterTag.Section) -> [LiveTVFilterTag] { all.filter { $0.section == section } }

    /// The mockup's quick picks, before they are filtered to what the lineup has.
    static let suggestedTitles = ["Favourite Channels", "Recently Watched", "Live Events", "United Kingdom", "Sports", "Football",
                                  "Formula 1", "News", "Movies", "Family", "Kids", "4K"]

    /// The section a tag counts in for matching: the first that lists it (`Arabic` is a Country & Region tag and a Language tag; the
    /// mockup's `TAG_SEC` keeps the first).
    private static let matchingSection: [String: LiveTVFilterTag.Section] = {
        var result: [String: LiveTVFilterTag.Section] = [:]
        for tag in all where result[tag.id] == nil { result[tag.id] = tag.section }
        return result
    }()

    /// The picked tags by section, each section's in the order picked, the sections in the order first picked (the mockup's
    /// `tagGroups`). Tags in one group widen (any of them), groups narrow (every group). A tag outside the catalog is a group of its own.
    public static func groups(of tagIDs: [String]) -> [[String]] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for id in tagIDs {
            let key = matchingSection[id]?.rawValue ?? id
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(id)
        }
        return order.compactMap { grouped[$0] }
    }

    /// The name of a filter: each section's tags' short names joined with " or ", the sections with " · "
    /// ("English · Canada or US").
    public static func name(for tagIDs: [String]) -> String {
        groups(of: tagIDs)
            .map { $0.compactMap { byID[$0]?.shortTitle }.joined(separator: " or ") }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
