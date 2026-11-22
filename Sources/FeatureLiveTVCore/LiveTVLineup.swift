import CoreModels
import Foundation

/// "Your Lineup": which of a provider's channels Live TV loads at all. It is applied to the playlist the moment it is read
/// (`LiveTVLineupFilter`), before identity reconciliation, storage, guide matching, logo matching, tagging or sorting see a row.
///
/// A channel belongs to exactly one of: a **country** (ISO code from the name's `CA EN:` prefix, else the provider's country,
/// else the group title's `CA|` prefix: all read by `IPTVChannelName.split`), a **group without a country** (the 4K groups
/// among them; each its own chip), or **Adult**. Adult rows are never loaded unless the lineup includes them.
public struct LiveTVLineup: Codable, Equatable, Sendable {
    /// Country codes ("CA") and region ids ("region.africa") that are loaded.
    public var placeIDs: Set<String>
    /// Groups without a country the viewer removed; every other one, including groups that appear later, is kept.
    public var removedGroupIDs: Set<String>
    public var includesAdult: Bool
    /// "Always keep": favourites and recently watched channels stay whatever their country.
    public var keepsFavouritesAndRecents: Bool
    /// "Always keep": every live event slot stays.
    public var keepsLiveEvents: Bool
    /// "Always keep": a left-out channel can still be found by name.
    public var searchesLeftOut: Bool

    public init(
        placeIDs: Set<String>, removedGroupIDs: Set<String> = [], includesAdult: Bool = false,
        keepsFavouritesAndRecents: Bool = true, keepsLiveEvents: Bool = true, searchesLeftOut: Bool = true
    ) {
        self.placeIDs = placeIDs
        self.removedGroupIDs = removedGroupIDs
        self.includesAdult = includesAdult
        self.keepsFavouritesAndRecents = keepsFavouritesAndRecents
        self.keepsLiveEvents = keepsLiveEvents
        self.searchesLeftOut = searchesLeftOut
    }

    /// The lineup of every profile and source on first run: Canada, the United States and the United Kingdom.
    public static let standard = LiveTVLineup(placeIDs: ["CA", "US", "GB"])

    public func keeps(code: String) -> Bool {
        placeIDs.contains(code) || LiveTVLineupPlace.regionIDs(containing: code).contains(where: placeIDs.contains)
    }

    public func keepsGroup(_ id: String) -> Bool { !removedGroupIDs.contains(id) }
}

/// Country and region chips of the lineup sheet.
public enum LiveTVLineupPlace {
    public struct Region: Sendable {
        public let id: String
        public let title: String
        /// Countries the region contains. Asia, Europe, Kurdistan and the Caribbean hold only rows whose group prefix names them
        /// ("ASIA| HINDI"); the countries inside them stay their own chips.
        let codes: Set<String>
        /// The provider's group prefixes that name the region itself ("AFR|", "ASIA|"), upper case.
        let prefixes: Set<String>
    }

    public static let regions: [Region] = [
        Region(id: "region.africa", title: "Africa", codes: LiveTVChannelTagging.africaRegion, prefixes: ["AFR", "AF", "AFRICA"]),
        Region(id: "region.arabic", title: "Arabic", codes: LiveTVChannelTagging.arabicRegion, prefixes: ["ARAB", "AR", "ARABIC"]),
        Region(
            id: "region.latin-america", title: "Latin America", codes: LiveTVChannelTagging.latinAmericaRegion,
            prefixes: ["LATAM", "LAT", "LA"]),
        Region(id: "region.balkans", title: "Balkans", codes: LiveTVChannelTagging.balkansRegion, prefixes: ["EXYU", "BALK", "BALKAN"]),
        Region(id: "region.asia", title: "Asia", codes: [], prefixes: ["ASIA"]),
        Region(id: "region.europe", title: "Europe", codes: [], prefixes: ["EU", "EUR", "EUROPE"]),
        Region(id: "region.kurdistan", title: "Kurdistan", codes: [], prefixes: ["KU", "KURD"]),
        Region(id: "region.caribbean", title: "Caribbean", codes: [], prefixes: ["CARIB", "CARIBBEAN", "CRB"])
    ]

    /// Prefixes this provider writes for a country that are not its ISO 3166 alpha-2 code. Each was checked against the provider's
    /// own channel names (`UK: ITV…`, `ARG: CANAL 9`, `BH: HERCEG TV` = Bosnia, `KN: CITIZEN TV` = Kenya, `PR: GOL PERU` = Peru, `BAN: ZEE BANGLA`, `CG: RTV PLJEVLJA` = Montenegro, `SR: AGRO TV` = Serbia, `SU| SURINAME 4K` = Suriname).
    static let countryPrefixAliases: [String: String] = [
        "UK": "GB", "ARG": "AR", "ARM": "AM", "ETH": "ET", "SRI": "LK", "NIG": "NG", "GHA": "GH", "SEN": "SN", "IRL": "IE",
        "AFG": "AF", "CHL": "CL", "CAM": "CM", "CON": "CD", "GUI": "GN", "MOZ": "MZ", "TOG": "TG", "NIC": "NI", "UGA": "UG",
        "BAN": "BD", "SOM": "SO", "BU": "BG", "CG": "ME", "SR": "RS", "IN-PREM": "IN", "PAK-PREM": "PK", "AL-VIP": "AL",
        "BH": "BA", "KN": "KE", "PR": "PE", "SU": "SR"
    ]

    /// ISO country codes this provider uses for a package or service, not a country ("TV: 1+1 INTERNACIONAL", "MC: 90S R&B", "NF: NETFLIX 01", "SC: CFL Plays", "TK: AD SPORTS", "TF: COMEDIA").
    static let packagePrefixes: Set<String> = ["TV", "MC", "SS", "TF", "NF", "SC", "TK"]

    private static let isoCountryCodes: Set<String> = Set(
        Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })

    static func isISOCountry(_ code: String) -> Bool { isoCountryCodes.contains(code) }

    static func region(forPrefix prefix: String) -> Region? { regions.first { $0.prefixes.contains(prefix) } }

    /// A country the text names ("24/7 INDIA", "BANGLADESH"), read as whole words; the first one in the text.
    static func countryNamed(in text: String) -> String? {
        let words = IPTVChannelName.foldingSuperscripts(text).folding(options: [.diacriticInsensitive], locale: nil).uppercased()
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return nil }
        for start in words.indices {
            for length in stride(from: min(3, words.count - start), through: 1, by: -1) {
                if let code = countryByName[words[start..<(start + length)].joined(separator: " ")] { return code }
            }
        }
        return nil
    }

    private static let countryByName: [String: String] = {
        var table: [String: String] = [:]
        let locale = Locale(identifier: "en_GB")
        for region in Locale.Region.isoRegions where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            guard let name = locale.localizedString(forRegionCode: region.identifier) else { continue }
            let key = name.folding(options: [.diacriticInsensitive], locale: nil).uppercased()
                .split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
            if key.split(separator: " ").count <= 3 { table[key] = region.identifier }
        }
        let aliases: [String: String] = [
            "UK": "GB", "BRITAIN": "GB", "ENGLAND": "GB", "USA": "US", "AMERICA": "US", "TURKEY": "TR", "CZECH REPUBLIC": "CZ",
            "CZECHIA": "CZ", "UAE": "AE", "IVORY COAST": "CI", "BOSNIA": "BA", "MACEDONIA": "MK", "CABO VERDE": "CV",
            "CAPE VERDE": "CV", "ETHOPIA": "ET", "SOUTH KOREA": "KR", "KOREA": "KR", "RUSSIA": "RU", "IRAN": "IR", "VIETNAM": "VN"
        ]
        table.merge(aliases) { _, alias in alias }
        return table
    }()

    public static func regionIDs(containing code: String) -> [String] {
        regions.filter { $0.codes.contains(code) }.map(\.id)
    }

    public static func title(ofCode code: String) -> String {
        LiveTVChannelTagging.countryTitleByCode[code]
            ?? Locale(identifier: "en_GB").localizedString(forRegionCode: code) ?? code
    }

    /// The short name the heading and tray use for a place ("UK", "US").
    public static func shortTitle(ofCode code: String) -> String {
        switch code {
        case "GB": "UK"
        case "US": "US"
        default: title(ofCode: code)
        }
    }
}

/// How many channels of the provider's list fall in each place, counted once per import over the whole list
/// (so the sheet can show them for countries that are not loaded).
public struct LiveTVLineupInventory: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Identifiable, Sendable {
        /// The provider's group title, or "" for channels with no group ("Everything Else").
        public let id: String
        public let title: String
        public var count: Int

        public init(id: String, title: String, count: Int) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    public var total: Int
    public var codeCounts: [String: Int]
    public var groups: [Group]
    public var adultCount: Int
    /// Channels whose group names a region and no country inside it ("AFR| SOMALI TV": Africa, "ASIA| HINDI": Asia).
    public var regionCounts: [String: Int]

    public init(total: Int, codeCounts: [String: Int], groups: [Group], adultCount: Int, regionCounts: [String: Int] = [:]) {
        self.total = total
        self.codeCounts = codeCounts
        self.groups = groups
        self.adultCount = adultCount
        self.regionCounts = regionCounts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        codeCounts = try container.decode([String: Int].self, forKey: .codeCounts)
        groups = try container.decode([Group].self, forKey: .groups)
        adultCount = try container.decode(Int.self, forKey: .adultCount)
        // An inventory saved before regions were counted has none.
        regionCounts = try container.decodeIfPresent([String: Int].self, forKey: .regionCounts) ?? [:]
    }

    public static let empty = LiveTVLineupInventory(total: 0, codeCounts: [:], groups: [], adultCount: 0)

    public func count(ofRegion region: LiveTVLineupPlace.Region) -> Int {
        codeCounts.reduce(0) { $0 + (region.codes.contains($1.key) ? $1.value : 0) } + (regionCounts[region.id] ?? 0)
    }

    func merging(_ other: LiveTVLineupInventory) -> LiveTVLineupInventory {
        var merged = self
        merged.total += other.total
        merged.adultCount += other.adultCount
        merged.codeCounts.merge(other.codeCounts, uniquingKeysWith: +)
        merged.regionCounts.merge(other.regionCounts, uniquingKeysWith: +)
        for group in other.groups {
            if let index = merged.groups.firstIndex(where: { $0.id == group.id }) { merged.groups[index].count += group.count }
            else { merged.groups.append(group) }
        }
        merged.groups.sort { ($0.count, $1.title) > ($1.count, $0.title) }
        return merged
    }

    /// The channels the lineup loads from this list (always-keep rows excluded: they are not countable from the list alone).
    public func keptCount(by lineup: LiveTVLineup) -> Int {
        codeCounts.reduce(0) { $0 + (lineup.keeps(code: $1.key) ? $1.value : 0) }
            + regionCounts.reduce(0) { $0 + (lineup.placeIDs.contains($1.key) ? $1.value : 0) }
            + groups.reduce(0) { $0 + (lineup.keepsGroup($1.id) ? $1.count : 0) }
            + (lineup.includesAdult ? adultCount : 0)
    }
}

/// A channel the lineup left out, kept by name only so Search can still offer it.
public struct LiveTVLeftOutChannel: Equatable, Sendable {
    public let id: String
    public let name: String
}

/// How one playlist row is placed. Names, groups and country lists repeat across a provider's list, so each is read once.
struct LiveTVLineupClassifier {
    enum Placement: Equatable {
        case country(String)
        /// The group names a region ("AFR| …") and no country inside it.
        case region(String)
        case group(String)
        case adult
    }

    private struct GroupInfo {
        var code: String?
        var regionID: String?
        var isAdult: Bool
        /// The text before the group's `|` ("AFR"), upper case; "" when there is none.
        var prefix: String
    }

    /// Which rule read the last row: "provider-country", "group-country:AFR", "group-region:ASIA", "name-prefix:UK", "adult", "none".
    private(set) var lastRule = "none"
    private var groupInfo: [String: GroupInfo] = [:]
    private var countryByList: [String: String?] = [:]

    mutating func placement(of channel: some LiveTVLineupRow) -> Placement {
        let groups = channel.lineupGroups
        var groupCode: String?
        var groupRegion: String?
        var adult = false
        for group in groups {
            let info = information(group)
            adult = adult || info.isAdult
            if groupCode == nil { groupCode = info.code }
            if groupRegion == nil { groupRegion = info.regionID }
        }
        lastRule = "adult"
        if adult || Self.nameIsAdult(channel.lineupName) { return .adult }
        // The provider's own country and group win over a name prefix: "TV: Weather" is a US channel in "US| TV", not Tuvalu.
        if let code = providerCode(of: channel) { lastRule = "provider-country"; return .country(code) }
        if let groupCode { lastRule = "group-country:" + (groups.first.map { information($0).prefix } ?? ""); return .country(groupCode) }
        if let groupRegion { lastRule = "group-region:" + (groups.first.map { information($0).prefix } ?? ""); return .region(groupRegion) }
        if let named = namePrefixPlacement(of: channel) { lastRule = "name-prefix:" + (Self.namePrefixToken(channel.lineupName) ?? ""); return named }
        lastRule = "none"
        return .group(groups.first ?? "")
    }

    /// The class of the row's first group, for the `prefixes` log: the prefix text and "country", "region" or "none".
    mutating func prefixClass(of channel: some LiveTVLineupRow, placement: Placement) -> (prefix: String, kind: String) {
        var prefix = channel.lineupGroups.first.map { information($0).prefix } ?? ""
        if prefix.isEmpty { prefix = Self.namePrefixToken(channel.lineupName) ?? "" }
        switch placement {
        case .country: return (prefix, "country")
        case .region: return (prefix, "region")
        case .group: return (prefix, "none")
        case .adult: return (prefix, "adult")
        }
    }

    /// The name's prefix ("CA EN:", "UK :", "ARG:", "PL VP:"): a region, a provider alias, or an ISO country code. Aliases: "AR:" is
    /// Arabic (not Argentina; the mockup), "AF:" is Africa, "TV:" is a package, not Tuvalu.
    private func namePrefixPlacement(of channel: some LiveTVLineupRow) -> Placement? {
        guard let token = Self.namePrefixToken(channel.lineupName) else { return nil }
        if let region = LiveTVLineupPlace.region(forPrefix: token) { return .region(region.id) }
        if let code = LiveTVLineupPlace.countryPrefixAliases[token] { return .country(code) }
        if LiveTVLineupPlace.packagePrefixes.contains(token) { return nil }
        return LiveTVLineupPlace.isISOCountry(token) ? .country(token) : nil
    }

    /// The first word before a `:` or `|` within the name's first characters, upper case, with at most one short word (a language)
    /// after it; case and a space before the colon do not matter. `nil` when the name has no such prefix.
    static func namePrefixToken(_ name: String) -> String? {
        let text = name.drop { $0 == "|" || $0 == " " }
        guard let end = text.prefix(14).firstIndex(where: { $0 == ":" || $0 == "|" }) else { return nil }
        let words = text[..<end].split(separator: " ")
        guard (1...2).contains(words.count), words.dropFirst().allSatisfy({ $0.count <= 3 }),
              let first = words.first, first.first?.isLetter == true else { return nil }
        return first.uppercased()
    }

    /// The provider's own country value, which may list several ("CA;US").
    private mutating func providerCode(of channel: some LiveTVLineupRow) -> String? {
        if let list = channel.lineupCountry, !list.isEmpty {
            if let known = countryByList[list] {
                if let known { return known }
            } else {
                let code = LiveTVPrototypeChannel.metadataValues(list).lazy.compactMap(Self.isoCode).first
                countryByList[list] = code
                if let code { return code }
            }
        }
        return nil
    }

    private mutating func information(_ group: String) -> GroupInfo {
        if let known = groupInfo[group] { return known }
        let tokens = IPTVChannelName.foldingSuperscripts(group).uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" })
        let isAdult = tokens.contains { $0 == "XXX" || $0 == "ADULT" || $0 == "ADULTS" || $0 == "18+" || $0 == "PORN" }
        let prefix = Self.prefix(of: group)
        var info = GroupInfo(code: nil, regionID: nil, isAdult: isAdult, prefix: prefix)
        if let region = LiveTVLineupPlace.region(forPrefix: prefix) {
            // "ASIA| BANGLADESH" is Bangladesh; "ASIA| HINDI" is only Asia.
            let rest = group.drop { $0 != "|" }.dropFirst()
            if let code = LiveTVLineupPlace.countryNamed(in: String(rest)) { info.code = code } else { info.regionID = region.id }
        } else if let code = LiveTVLineupPlace.countryPrefixAliases[prefix] {
            info.code = code
        } else if !LiveTVLineupPlace.packagePrefixes.contains(prefix) {
            info.code = IPTVChannelName.split(group).tags.lazy.compactMap(\.country).first.flatMap(Self.isoCode)
        }
        groupInfo[group] = info
        return info
    }

    /// The upper-case letters or digits before the group's `|`: "AFR" of "AFR| AFRICA VIP"; "" when the group has no such prefix.
    private static func prefix(of group: String) -> String {
        let text = IPTVChannelName.foldingSuperscripts(group)
        guard let bar = text.firstIndex(of: "|") else { return "" }
        let token = text[..<bar].trimmingCharacters(in: .whitespaces).uppercased()
        return token.count <= 8 && token.allSatisfy({ $0.isLetter || $0.isNumber }) ? token : ""
    }

    private static func isoCode(_ value: String) -> String? {
        let key = value.uppercased()
        return LiveTVChannelTagging.countryCodes[key] ?? (key.count == 2 ? key : nil)
    }

    private static func nameIsAdult(_ name: String) -> Bool {
        var run = 0
        for byte in name.utf8 {
            if byte == 0x58 || byte == 0x78 { run += 1; if run == 3 { return true } } else { run = 0 }
        }
        return false
    }
}

/// What the lineup needs to read of a row, so one filter serves a playlist's rows and a server's rows.
protocol LiveTVLineupRow {
    /// The id storage gives the row (what favourites and recents remember).
    var lineupID: String { get }
    var lineupName: String { get }
    /// The channel number as the provider wrote it, for the DEBUG audit only.
    var lineupNumber: String? { get }
    /// `tvg-id` / `epg_channel_id`, `tvg-name` and the provider's radio flag, for the DEBUG snapshot only.
    var lineupGuideID: String? { get }
    var lineupGuideName: String? { get }
    var lineupIsRadio: Bool { get }
    var lineupCountry: String? { get }
    /// The provider's group titles; empty for a row without one.
    var lineupGroups: [String] { get }
    /// The groups the live-event classifier reads (a row without a group is read under its single fallback category).
    var lineupEventGroups: [String] { get }
}

extension LiveTVPrototypeChannel: LiveTVLineupRow {
    var lineupID: String { id }
    var lineupName: String { name }
    var lineupNumber: String? { String(number) }
    var lineupGuideID: String? { guideID }
    var lineupGuideName: String? { guideName }
    var lineupIsRadio: Bool { false }
    var lineupCountry: String? { country }
    var lineupGroups: [String] { groups ?? [] }
    var lineupEventGroups: [String] { categories }
}

extension LiveTVLastSeenSnapshot.Entry: LiveTVLineupRow {
    var lineupID: String { channel.id }
    var lineupName: String { channel.name }
    var lineupNumber: String? { String(channel.number) }
    var lineupGuideID: String? { channel.guideID }
    var lineupGuideName: String? { channel.guideName }
    var lineupIsRadio: Bool { false }
    var lineupCountry: String? { channel.country }
    var lineupGroups: [String] { channel.groups ?? [] }
    var lineupEventGroups: [String] { channel.categories }
}

extension ServerLiveTVChannel: LiveTVLineupRow {
    var lineupID: String { id }
    var lineupName: String { name }
    var lineupNumber: String? { number }
    var lineupGuideID: String? { guideID }
    var lineupGuideName: String? { guideName }
    var lineupIsRadio: Bool { isRadio }
    var lineupCountry: String? { guideCountry }
    var lineupGroups: [String] { groups }
    var lineupEventGroups: [String] { groups.isEmpty ? [isRadio ? "Radio" : "Live TV"] : groups }
}

/// Why rows were loaded or left out, for the `lineupApplied` log line.
struct LiveTVLineupSummary: Equatable, Sendable {
    var read = 0
    var kept = 0
    var keptByCountry: [String: Int] = [:]
    var keptByGroupWithoutCountry: [String: Int] = [:]
    var keptAdult = 0
    var keptAlways = 0
    /// Rows dropped as placeholders before any other rule (`LiveTVPlaceholder`); not part of `read - kept` accounting of places.
    var placeholders = 0
    var keptByRegion: [String: Int] = [:]
    /// Every row's first-group prefix with how it was read ("country", "region", "none", "adult"), whether or not it was kept.
    var prefixCounts: [PrefixKey: Int] = [:]

    struct PrefixKey: Hashable, Sendable {
        let prefix: String
        let kind: String
    }

    var dropped: Int { read - kept - placeholders }
    var keptWithoutCountry: Int { keptByGroupWithoutCountry.values.reduce(0, +) }

    /// `event=lineupApplied` fields. Country codes and group titles only; never a URL or a channel name.
    func logFields(source: String, topGroups: Int = 30, topPrefixes: Int = 60) -> String {
        let countries = keptByCountry.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(12)
            .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let groups = keptByGroupWithoutCountry.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(topGroups)
            .map { "\($0.key.isEmpty ? "(none)" : $0.key)=\($0.value)" }.joined(separator: "|")
        let regions = keptByRegion.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let prefixes = prefixCounts.sorted { ($1.value, $0.key.prefix, $0.key.kind) < ($0.value, $1.key.prefix, $1.key.kind) }
            .prefix(topPrefixes).map { "\($0.key.prefix.isEmpty ? "(none)" : $0.key.prefix):\($0.key.kind)=\($0.value)" }.joined(separator: "|")
        return "source=\(source) read=\(read) kept=\(kept) dropped=\(dropped)"
            + " byReason=country:\(keptByCountry.values.reduce(0, +)),region:\(keptByRegion.values.reduce(0, +)),nocountry:\(keptWithoutCountry),always:\(keptAlways),adult:\(keptAdult)"
            + " countries=\(countries) regions=\(regions) noCountryGroups=\(groups) prefixes=\(prefixes)"
    }
}

/// Applies a lineup to a freshly read list of rows.
enum LiveTVLineupFilter {
    struct Result<Row: LiveTVLineupRow> {
        var kept: [Row]
        var leftOut: [LiveTVLeftOutChannel]
        var inventory: LiveTVLineupInventory
        var summary: LiveTVLineupSummary
        /// A debug audit that was told to defer its work: `finishInBackground()` it once the list is published.
        var audit: LiveTVLineupAudit?
    }

    /// - Parameters:
    ///   - keepIDs: ids (as `scopedID` makes them) of the channels always kept: favourites and recently watched.
    ///   - scopedID: the id a raw channel gets in storage; called only for a row that is otherwise left out.
    static func apply<Row: LiveTVLineupRow>(
        _ lineup: LiveTVLineup, to channels: [Row], keepIDs: Set<String> = [],
        scopedID: (Row) -> String = { $0.lineupID }, audit: LiveTVLineupAudit? = nil
    ) -> Result<Row> {
        audit?.begin(rows: channels.count)
        defer { if audit?.defersWork != true { audit?.finish() } }
        var classifier = LiveTVLineupClassifier()
        var kept: [Row] = []
        var leftOut: [LiveTVLeftOutChannel] = []
        var codeCounts: [String: Int] = [:]
        var groupCounts: [String: Int] = [:]
        var groupOrder: [String] = []
        var regionCounts: [String: Int] = [:]
        var adultCount = 0
        var summary = LiveTVLineupSummary(read: channels.count)
        var groupIsEvent: [String: Bool] = [:]
        let isEventGroup: (String) -> Bool = { group in
            if let known = groupIsEvent[group] { return known }
            let value = LiveTVEventSlotClassifier.isEventGroup(group)
            groupIsEvent[group] = value
            return value
        }
        let keepsAny = lineup.keepsFavouritesAndRecents && !keepIDs.isEmpty
        kept.reserveCapacity(channels.count)
        let cutTime = Date()
        for channel in channels {
            // Placeholders (headers, idle or ended event slots) are dropped first: no count, chip, audit row or later stage sees them.
            if LiveTVPlaceholder.isPlaceholder(
                name: channel.lineupName, groups: channel.lineupGroups, eventGroups: channel.lineupEventGroups,
                now: cutTime, isEventGroup: isEventGroup) {
                summary.placeholders += 1
                continue
            }
            let placement = classifier.placement(of: channel)
            let prefixClass = classifier.prefixClass(of: channel, placement: placement)
            summary.prefixCounts[LiveTVLineupSummary.PrefixKey(prefix: prefixClass.prefix, kind: prefixClass.kind), default: 0] += 1
            let inLineup: Bool
            switch placement {
            case .country(let code):
                codeCounts[code, default: 0] += 1
                inLineup = lineup.keeps(code: code)
                if inLineup { summary.keptByCountry[code, default: 0] += 1 }
            case .region(let id):
                regionCounts[id, default: 0] += 1
                inLineup = lineup.placeIDs.contains(id)
                if inLineup { summary.keptByRegion[id, default: 0] += 1 }
            case .group(let id):
                if groupCounts[id] == nil { groupOrder.append(id) }
                groupCounts[id, default: 0] += 1
                inLineup = lineup.keepsGroup(id)
                if inLineup { summary.keptByGroupWithoutCountry[id, default: 0] += 1 }
            case .adult:
                adultCount += 1
                inLineup = lineup.includesAdult
                if inLineup { summary.keptAdult += 1 }
            }
            if inLineup {
                kept.append(channel)
                audit?.record(channel, scopedID: scopedID(channel), placement: placement, rule: classifier.lastRule, kept: true, reason: Self.reason(of: placement))
                continue
            }
            // Left out. Adult is never loaded unless the lineup includes it, whatever else would keep it.
            if placement != .adult {
                // Only a slot with an event on (the cheap candidate test first); "NO EVENT STREAMING" placeholders are not kept.
                if lineup.keepsLiveEvents,
                   LiveTVEventSlotClassifier.isCandidate(
                    name: channel.lineupName, groups: channel.lineupEventGroups, groupIsEvent: isEventGroup),
                   LiveTVEventSlotClassifier.classify(name: channel.lineupName, groups: channel.lineupEventGroups) != nil {
                    kept.append(channel); summary.keptAlways += 1
                    audit?.record(channel, scopedID: scopedID(channel), placement: placement, rule: classifier.lastRule, kept: true, reason: "always-keep:live-event")
                    continue
                }
                if keepsAny, keepIDs.contains(scopedID(channel)) {
                    kept.append(channel); summary.keptAlways += 1
                    audit?.record(channel, scopedID: scopedID(channel), placement: placement, rule: classifier.lastRule, kept: true, reason: "always-keep:favourite-or-recent")
                    continue
                }
            }
            audit?.record(channel, scopedID: scopedID(channel), placement: placement, rule: classifier.lastRule, kept: false, reason: Self.reason(of: placement) + "-off")
            if lineup.searchesLeftOut { leftOut.append(LiveTVLeftOutChannel(id: channel.lineupID, name: channel.lineupName)) }
        }
        summary.kept = kept.count
        let groups = groupOrder.map {
            LiveTVLineupInventory.Group(id: $0, title: $0.isEmpty ? "Everything Else" : $0, count: groupCounts[$0] ?? 0)
        }.sorted { ($0.count, $1.title) > ($1.count, $0.title) }
        return Result(
            kept: kept, leftOut: leftOut,
            inventory: LiveTVLineupInventory(total: channels.count - summary.placeholders, codeCounts: codeCounts, groups: groups, adultCount: adultCount, regionCounts: regionCounts),
            summary: summary, audit: audit
        )
    }

    private static func reason(of placement: LiveTVLineupClassifier.Placement) -> String {
        switch placement {
        case .country: "country"
        case .region: "region"
        case .group: "group"
        case .adult: "adult"
        }
    }

    /// Re-applies a lineup to rows that were already filtered once (a cached list); changes nothing about counts.
    static func narrow<Row: LiveTVLineupRow>(_ lineup: LiveTVLineup, _ channels: [Row], keepIDs: Set<String>) -> [Row] {
        apply(lineup, to: channels, keepIDs: keepIDs).kept
    }
}

extension LiveTVLineupFilter.Result: Sendable where Row: Sendable {}
