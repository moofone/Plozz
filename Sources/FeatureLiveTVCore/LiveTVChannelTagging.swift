import CoreModels
import Foundation

/// Derives a channel's stored filter tags from metadata the app already holds. Nothing is fetched and nothing is guessed
/// beyond the closed rule tables below, which are the mockup's `chTags`, `NET_RULES` and `EVENT_SPORT` plus the provider's
/// own group labels:
/// - Region: the canonical places the region parser reads from a linear channel's name (`LiveTVChannelRegion`).
/// - Country & Region, Language: the channel's `country` / `language` (filled from the name's prefix by `IPTVChannelName.split`).
/// - 4K: the name's `4K`/`UHD`/`8K` tag, unless the measured resolution is below 2000 lines; a measured 4K counts without the tag.
/// - Genre: the provider's group labels (a few hundred distinct labels, each read once) and the guide's programme categories.
/// - Sport: the sports parser's league, the event-slot rules on an event's name, and sport words in a sports channel's name.
/// - Network: the mockup's name rules.
/// - Channels: Live Events (event slots), 4K, 24/7, Pay-per-view (group or name), Radio (provider group only: "ICI RADIO CANADA TELE" is television). Favourite Channels and Recently Watched are live
///   and never stored.
struct LiveTVChannelTagging {
    /// Slot → tag identifier, for every distinct tag of the vocabulary.
    static let vocabulary: [String] = {
        var seen = Set<String>()
        return LiveTVFilterTagCatalog.all.map(\.id).filter { seen.insert($0).inserted }
    }()
    private static let slotByID: [String: Int] = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($0.element, $0.offset) })
    private static let regionSlot: [String: Int] = Dictionary(
        uniqueKeysWithValues: LiveTVPlaceNames.tagPlaces.compactMap { place in
            slotByID[LiveTVFilterTagCatalog.regionTagID(place)].map { (place, $0) }
        })
    private static func slot(_ title: String) -> Int { slotByID[LiveTVFilterTagCatalog.tagID(title)]! }
    private static func slots(_ titles: String...) -> [Int] { titles.map(slot) }

    private var stamps = [Int](repeating: -1, count: LiveTVChannelTagging.vocabulary.count)
    private var stamp = 0
    private var groupSlots: [String: [Int]] = [:]
    private var countryLists: [String: [Int]] = [:]
    private var languageLists: [String: [Int]] = [:]

    mutating func storedSlots(
        for channel: LiveTVPrototypeChannel, measured: (LiveTVPrototypeChannel) -> LiveChannelResolutionLabel?, into result: inout [Int]
    ) {
        // Section markers are not channels; only a name that starts with decoration can be one.
        if let first = channel.name.first(where: { !$0.isWhitespace }), first == "#" || first == "*", channel.isSectionMarker { return }
        stamp += 1
        func add(_ slots: [Int]) { for slot in slots where stamps[slot] != stamp { stamps[slot] = stamp; result.append(slot) } }

        if let country = channel.country { add(countrySlots(list: country)) }
        if let language = channel.language { add(languageSlots(list: language)) }
        for place in LiveTVChannelRegion.places(for: channel) { if let slot = Self.regionSlot[place] { add([slot]) } }
        for tag in channel.tags {
            if let code = tag.country { add(countrySlots(list: code)) }
            if let code = tag.language { add(languageSlots(list: code)) }
        }
        if Self.isUltraHD(tags: channel.tags, measured: measured(channel)) { add([Self.ultraHD]) }
        if channel.eventSlot != nil { add([Self.liveEvents]) }

        for group in channel.categories { add(groupTagSlots(group)) }

        let nameTokens = Self.tokens(channel.name)
        var sportsFound = false
        for token in nameTokens {
            if let sports = Self.nameSportTokens[token] { add(sports); sportsFound = true }
            switch token {
            case "PPV": add([Self.payPerView])
            case "24/7": add([Self.twentyFourSeven])
            default: break
            }
        }
        add(Self.networks(in: nameTokens))
        if channel.eventSlot != nil || sportsFound || stamps[Self.sports] == stamp { add(Self.sports(of: channel)) }
        if sportsFound { add([Self.sports]) }
    }

    // MARK: Country, language

    /// The Country & Region tag for a viewer's ISO country code, when the vocabulary has one.
    static func countryTag(forRegion code: String) -> LiveTVFilterTag? {
        let key = code.uppercased()
        guard let normalized = countryCodes[key], let title = countryTitleByCode[normalized] else { return nil }
        return LiveTVFilterTagCatalog.all.first { $0.title == title && $0.section == .countryRegion }
    }

    /// The slots of a provider `country` value, which may list several ("CA;US"). Read once per distinct value.
    private mutating func countrySlots(list: String) -> [Int] {
        if let known = countryLists[list] { return known }
        var found: [Int] = []
        for value in LiveTVPrototypeChannel.metadataValues(list) {
            let key = value.uppercased()
            guard let code = Self.countryCodes[key] ?? Self.countryNames[key] else { continue }
            if let slot = Self.countrySlot[code] { found.append(slot) }
            if Self.arabicRegion.contains(code) { found.append(Self.arabic) }
            if Self.africaRegion.contains(code) { found.append(Self.africa) }
            if Self.latinAmericaRegion.contains(code) { found.append(Self.latinAmerica) }
            if Self.balkansRegion.contains(code) { found.append(Self.balkans) }
        }
        countryLists[list] = found
        return found
    }

    private mutating func languageSlots(list: String) -> [Int] {
        if let known = languageLists[list] { return known }
        let found = LiveTVPrototypeChannel.metadataValues(list).compactMap { Self.languageSlot[$0.uppercased()] }
        languageLists[list] = found
        return found
    }

    // MARK: Quality

    private static func isUltraHD(tags: [IPTVChannelTag], measured: LiveChannelResolutionLabel?) -> Bool {
        if let measured { return measured.isUltraHD }
        return tags.contains(where: \.isUltraHighDefinition)
    }

    // MARK: Groups and genres

    private mutating func groupTagSlots(_ group: String) -> [Int] {
        if let known = groupSlots[group] { return known }
        var found: [Int] = []
        for token in Self.groupTokens(group) {
            if let slots = Self.genreTokens[token] { found.append(contentsOf: slots) }
            if let slots = Self.nameSportTokens[token] { found.append(contentsOf: slots); found.append(Self.sports) }
            switch token {
            case "PPV": found.append(Self.payPerView)
            case "RADIO": found.append(Self.radio)
            case "24/7": found.append(Self.twentyFourSeven)
            default: break
            }
        }
        if let league = LiveTVSportsLeague.league(inGroups: [group]) { found.append(contentsOf: [Self.sport(of: league), Self.sports]) }
        groupSlots[group] = found
        return found
    }

    /// Tag identifiers a guide programme category names, for the majority vote over a channel's listings.
    static func genreIDs(forGuideCategory category: String) -> [String] {
        var found = Set<Int>()
        for token in tokens(category) {
            for slot in genreTokens[token] ?? [] where genreSlots.contains(slot) { found.insert(slot) }
        }
        return found.sorted().map { vocabulary[$0] }
    }

    /// The genre tags each channel's listings vote for: every genre named by at least half of the channel's categorised
    /// programmes. Channels whose listings carry no recognised category are absent.
    static func guideGenreVotes(_ programs: [String: [LiveTVPrototypeProgram]]) -> [String: [String]] {
        var memo: [String: [String]] = [:]
        var result: [String: [String]] = [:]
        for (channelID, listings) in programs {
            var votes: [String: Int] = [:]
            var counted = 0
            for program in listings {
                guard let categories = program.details?.categories, !categories.isEmpty else { continue }
                var genres = Set<String>()
                for category in categories {
                    if let known = memo[category] { genres.formUnion(known) } else {
                        let ids = genreIDs(forGuideCategory: category)
                        memo[category] = ids
                        genres.formUnion(ids)
                    }
                }
                guard !genres.isEmpty else { continue }
                counted += 1
                for genre in genres { votes[genre, default: 0] += 1 }
            }
            let winners = votes.filter { $0.value * 2 >= counted }.keys.sorted()
            if counted > 0, !winners.isEmpty { result[channelID] = winners }
        }
        return result
    }

    // MARK: Sport

    private static func sports(of channel: LiveTVPrototypeChannel) -> [Int] {
        var found: [Int] = []
        if let league = LiveTVSportsEventParser.parse(channel.name, groups: channel.categories)?.league {
            found.append(contentsOf: [sport(of: league), sports])
        }
        guard channel.eventSlot != nil else { return found }
        let lower = channel.name.lowercased()
        let words = Set(tokens(channel.name))
        for rule in eventSportRules where rule.phrases.contains(where: lower.contains) || rule.words.contains(where: words.contains) {
            found.append(contentsOf: [rule.slot, sports])
        }
        return found
    }

    private static func sport(of league: LiveTVSportsLeague) -> Int {
        switch league {
        case .mls, .uefaChampionsLeague, .uefaEuropaLeague: football
        case .nba, .wnba, .ncaab: basketball
        case .nfl, .cfl, .ncaaf: americanFootball
        case .nhl: iceHockey
        case .mlb: baseball
        case .wta: tennis
        }
    }

    // MARK: Network

    private static func networks(in tokens: [String]) -> [Int] {
        var found: [Int] = []
        for (index, token) in tokens.enumerated() {
            for rule in networkRules[token] ?? [] where rule.matches(tokens, at: index) { found.append(rule.slot) }
            if token.hasPrefix("ITV") { found.append(itv) }
            if token.hasPrefix("EUROSPORT") { found.append(eurosport) }
            if token.hasPrefix("SPORTSNET") { found.append(sportsnet) }
            if token.hasPrefix("ESPN") { found.append(espn) }
            if token.hasPrefix("PARAMOUNT") { found.append(paramountPlus) }
            if token.hasPrefix("DISCOVERY") { found.append(discovery) }
        }
        return found
    }

    private struct NetworkRule {
        let rest: [String]
        let slot: Int
        func matches(_ tokens: [String], at index: Int) -> Bool {
            guard index + rest.count < tokens.count else { return false }
            return rest.indices.allSatisfy { tokens[index + 1 + $0] == rest[$0] }
        }
    }

    private static let networkRules: [String: [NetworkRule]] = {
        var rules: [String: [NetworkRule]] = [:]
        func rule(_ title: String, _ phrase: String...) {
            rules[phrase[0], default: []].append(NetworkRule(rest: Array(phrase.dropFirst()), slot: slot(title)))
        }
        rule("Sky", "SKY"); rule("BBC", "BBC"); rule("Channel 4", "CHANNEL", "4"); rule("Now TV", "NOW", "TV")
        rule("TNT Sports", "TNT", "SPORTS"); rule("National Geographic", "NAT", "GEO"); rule("National Geographic", "NATGEO")
        rule("National Geographic", "NATIONAL", "GEOGRAPHIC"); rule("Comedy Central", "COMEDY", "CENTRAL")
        rule("CBC", "CBC"); rule("CTV", "CTV"); rule("TSN", "TSN"); rule("DAZN", "DAZN"); rule("beIN Sports", "BEIN")
        rule("beIN Sports", "BEIN", "SPORTS"); rule("Canal+", "CANAL+"); rule("SuperSport", "SUPERSPORT")
        rule("SuperSport", "SUPER", "SPORT"); rule("CNN", "CNN"); rule("Fox", "FOX"); rule("NBC", "NBC"); rule("DStv", "DSTV")
        return rules
    }()

    // MARK: Tables

    private static let sports = slot("Sports"), football = slot("Football"), basketball = slot("Basketball")
    private static let americanFootball = slot("American Football"), iceHockey = slot("Ice Hockey"), baseball = slot("Baseball")
    private static let tennis = slot("Tennis")
    private static let ultraHD = slot("4K"), twentyFourSeven = slot("24/7"), radio = slot("Radio")
    private static let payPerView = slot("Pay-per-view"), liveEvents = slot("Live Events")
    private static let arabic = slot("Arabic"), africa = slot("Africa"), latinAmerica = slot("Latin America"), balkans = slot("Balkans")
    private static let itv = slot("ITV"), eurosport = slot("Eurosport"), sportsnet = slot("Sportsnet"), espn = slot("ESPN")
    private static let paramountPlus = slot("Paramount+"), discovery = slot("Discovery")

    private static let genreSlots: Set<Int> = Set(LiveTVFilterTagCatalog.tags(in: .genre).map { slot($0.title) })

    /// Words of a provider group label or a guide category that name a genre (and the sports they imply).
    private static let genreTokens: [String: [Int]] = {
        var table: [String: [Int]] = [:]
        func add(_ words: [String], _ titles: String...) { for word in words { table[word, default: []] += titles.map(slot) } }
        add(["SPORT", "SPORTS"], "Sports")
        add(["MOVIE", "MOVIES", "CINEMA", "FILM", "FILMS"], "Movies")
        add(["NEWS"], "News")
        add(["KIDS", "KID", "CARTOON", "CARTOONS", "CHILDREN", "CHILDRENS", "CHILDREN'S", "ANIMATION"], "Kids")
        add(["FAMILY"], "Family")
        add(["DOCUMENTARY", "DOCUMENTARIES", "DOCU", "DOCS"], "Documentary")
        add(["MUSIC"], "Music")
        add(["COMEDY"], "Comedy")
        add(["DRAMA"], "Drama")
        add(["REALITY"], "Reality")
        add(["LIFESTYLE"], "Lifestyle")
        add(["FOOD", "COOKING"], "Food")
        add(["NATURE", "ANIMALS", "WILDLIFE"], "Nature")
        add(["HISTORY"], "History")
        add(["RELIGION", "RELIGIOUS", "FAITH"], "Religion")
        add(["ENTERTAINMENT", "GENERAL"], "Entertainment")
        return table
    }()

    /// Sport words. They name the sport, and the channel is a sports channel.
    private static let nameSportTokens: [String: [Int]] = {
        var table: [String: [Int]] = [:]
        func add(_ words: [String], _ title: String) { for word in words { table[word, default: []].append(slot(title)) } }
        add(["SOCCER", "FOOTBALL", "MLS", "UEFA", "UCL", "BUNDESLIGA", "LALIGA"], "Football")
        add(["F1", "FORMULA1"], "Formula 1")
        add(["NASCAR", "INDYCAR", "MOTOGP", "MOTORSPORT", "MOTORSPORTS"], "Motorsport")
        add(["GOLF", "PGA"], "Golf")
        add(["TENNIS", "ATP", "WTA"], "Tennis")
        add(["CRICKET"], "Cricket")
        add(["RUGBY"], "Rugby")
        add(["NBA", "WNBA", "NCAAB", "BASKETBALL"], "Basketball")
        add(["NFL", "NCAAF", "CFL"], "American Football")
        add(["NHL", "HOCKEY"], "Ice Hockey")
        add(["MLB", "MILB", "BASEBALL"], "Baseball")
        add(["BOXING", "UFC", "MMA", "WWE"], "Boxing & MMA")
        add(["CYCLING"], "Cycling")
        add(["DARTS", "SNOOKER"], "Darts & Snooker")
        return table
    }()

    /// The mockup's `EVENT_SPORT`: a competition named in an event's title gives its sport.
    private static let eventSportRules: [(slot: Int, phrases: [String], words: [String])] = [
        (football, ["premier league", "la liga", "serie a", "bundesliga", "ligue 1", "champions league", "europa league", "fa cup",
                    "football", "soccer"], ["MLS"]),
        (iceHockey, ["hockey"], ["NHL"]),
        (basketball, ["basketball"], ["NBA"]),
        (tennis, ["tennis"], ["ATP", "WTA"]),
        (slot("Formula 1"), ["formula 1", "grand prix"], ["F1"]),
        (americanFootball, ["american football"], ["NFL"]),
        (slot("Rugby"), ["rugby"], []),
        (slot("Cricket"), ["cricket"], []),
        (slot("Golf"), ["golf"], ["PGA"]),
        (slot("Boxing & MMA"), ["boxing"], ["UFC", "MMA"])
    ]

    static let countryTitleByCode: [String: String] = [
        "GB": "United Kingdom", "IE": "Ireland", "US": "United States", "CA": "Canada", "AU": "Australia", "NZ": "New Zealand",
        "FR": "France", "DE": "Germany", "ES": "Spain", "IT": "Italy", "PT": "Portugal", "NL": "Netherlands", "BE": "Belgium",
        "CH": "Switzerland", "AT": "Austria", "SE": "Sweden", "NO": "Norway", "DK": "Denmark", "FI": "Finland", "PL": "Poland",
        "TR": "Turkey", "GR": "Greece", "IN": "India", "PK": "Pakistan", "BR": "Brazil", "MX": "Mexico", "AR": "Argentina",
        "PH": "Philippines", "IL": "Israel", "SA": "Saudi Arabia"
    ]
    static let countryCodes: [String: String] = {
        var table = Dictionary(uniqueKeysWithValues: countryTitleByCode.keys.map { ($0, $0) })
        for code in arabicRegion.union(africaRegion).union(latinAmericaRegion).union(balkansRegion) { table[code] = code }
        table["UK"] = "GB"
        return table
    }()
    private static let countryNames: [String: String] = {
        var table = Dictionary(uniqueKeysWithValues: countryTitleByCode.map { ($0.value.uppercased(), $0.key) })
        table["USA"] = "US"; table["UNITED STATES OF AMERICA"] = "US"; table["GREAT BRITAIN"] = "GB"; table["ENGLAND"] = "GB"
        table["UK"] = "GB"; table["UAE"] = "AE"
        return table
    }()
    private static let countrySlot: [String: Int] = Dictionary(uniqueKeysWithValues: countryTitleByCode.map { ($0.key, slot($0.value)) })
    static let arabicRegion: Set<String> = ["SA", "AE", "EG", "IQ", "JO", "KW", "LB", "LY", "MA", "OM", "QA", "SY", "TN", "YE", "BH", "DZ", "SD", "PS"]
    static let africaRegion: Set<String> = ["ZA", "NG", "KE", "GH", "ET", "UG", "TZ", "SN", "CI", "CM", "DZ", "MA", "TN", "EG", "SO", "ZW", "ZM", "AO", "MZ", "CV", "RW"]
    static let latinAmericaRegion: Set<String> = ["MX", "AR", "BR", "CO", "CL", "PE", "VE", "EC", "UY", "PY", "BO", "CR", "PA", "DO", "GT", "HN", "SV", "NI", "CU"]
    static let balkansRegion: Set<String> = ["AL", "BA", "BG", "HR", "XK", "MK", "ME", "RS", "SI"]

    private static let languageSlot: [String: Int] = {
        var table: [String: Int] = [:]
        let rows: [(String, [String])] = [
            ("English", ["EN", "ENG"]), ("Arabic", ["AR", "ARA"]), ("Spanish", ["ES", "SPA"]), ("German", ["DE", "DEU", "GER"]),
            ("Turkish", ["TR", "TUR"]), ("French", ["FR", "FRA", "FRE"]), ("Dutch", ["NL", "NLD", "DUT"]), ("Italian", ["IT", "ITA"]),
            ("Portuguese", ["PT", "POR"]), ("Polish", ["PL", "POL"]), ("Greek", ["EL", "ELL", "GRE"]), ("Russian", ["RU", "RUS"]),
            ("Persian", ["FA", "FAS", "PER"]), ("Hindi", ["HI", "HIN"]), ("Urdu", ["UR", "URD"]), ("Punjabi", ["PA", "PAN"]),
            ("Tamil", ["TA", "TAM"]), ("Swedish", ["SV", "SWE"])
        ]
        for (title, codes) in rows {
            let id = slot(title)
            table[title.uppercased()] = id
            for code in codes { table[code] = id }
        }
        return table
    }()

    // MARK: Tokenizing

    /// Upper-case words of a channel name or category: letters and digits, with `+`, `/` and `'` kept inside a word ("CANAL+", "24/7").
    static func tokens(_ text: String) -> [String] {
        var text = text
        let ascii: [String]? = text.withUTF8 { bytes -> [String]? in
            var result: [String] = []
            var word: [UInt8] = []
            word.reserveCapacity(16)
            func flush() {
                if !word.isEmpty { result.append(String(decoding: word, as: UTF8.self)); word.removeAll(keepingCapacity: true) }
            }
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"): word.append(byte - 32)
                case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "'"):
                    word.append(byte)
                case 0x80...: return nil
                default: flush()
                }
            }
            flush()
            return result
        }
        if let ascii { return ascii }
        var result: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                result.append(String(current).uppercased())
                current = String.UnicodeScalarView()
            }
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "+" || scalar == "/" || scalar == "'" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// A provider group label's words, superscripts folded, with `A/B` also read as `A` and `B`.
    private static func groupTokens(_ group: String) -> [String] {
        let folded = group.decomposedStringWithCompatibilityMapping
        var words: [String] = []
        for token in tokens(folded) {
            words.append(token)
            if token.contains("/"), token != "24/7" {
                words.append(contentsOf: token.split(separator: "/").map(String.init))
            }
            if token.hasSuffix("+"), token.count > 1 { words.append(String(token.dropLast())) }
        }
        return words
    }
}
