import Foundation
import MetadataKit

/// Pre-compiled regular expressions for name cleaning. `String.replacingOccurrences(options: .regularExpression)` compiles its
/// pattern on every call, which dominates matching a 14,000-channel lineup.
struct LiveTVNameRegex: Sendable {
    private let expression: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = false) {
        expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
    func replacing(_ text: String, with template: String = "") -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    func firstRange(in text: String) -> Range<String.Index>? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }
    }
    func matches(_ text: String) -> Bool { firstRange(in: text) != nil }
}

/// What the matcher needs to know about a channel. Only the name, the provider's group
/// labels and the declared country take part; nothing is inferred about logo quality.
public struct LiveTVTMDbChannelQuery: Equatable, Sendable {
    public let name: String
    public let groups: [String]
    public let country: String?

    public init(name: String, groups: [String] = [], country: String? = nil) {
        self.name = name
        self.groups = groups
        self.country = country
    }

    public init(channel: LiveTVPrototypeChannel) {
        self.init(name: channel.name, groups: channel.groups ?? [], country: channel.country)
    }
}

/// A TMDB network whose name matches a channel name, before the country is checked.
public struct LiveTVTMDbCandidate: Equatable, Sendable {
    public let networkID: Int
    public let networkName: String
    public let confidence: Double
    public let rule: LiveTVTMDbMatchRule
}

public enum LiveTVTMDbMatchRule: String, Equatable, Sendable {
    /// The network name equals the channel name after normalisation.
    case exactName
    /// The network name equals the channel name with its city or feed suffix stripped.
    case alternateName
    /// A documented alias maps the channel's name or stripped name to this network.
    case alias
    /// The names are equal once generic words ("Television", "TV", "Network", "Channel", a leading "The") are dropped.
    case collapsedName
    /// No exact entry: the longest known brand at the start of the name, followed only by variant words
    /// (a number, a place or a feed word), such as "TSN 4" for TSN.
    case family
    /// The channel's provider group names the brand, and the name adds only variant words ("US: MACON, GA WMGT NBC 41").
    case groupBrand
    /// A local station: one broadcast-network word plus the station's call sign ("NBC (KOAA) PUEBLO, CO").
    case affiliate
    /// The bundled curated brand table names this network for the brand key.
    case curated
}

/// Matches channel names to TMDB TV networks.
///
/// Ported from the logo exploration (`tmdb_candidates.py`). The rules are deterministic:
/// exact normalised name 0.9, an explicit alias 0.7, the stripped alternate name 0.5.
/// A network of unknown country loses ``unknownCountryPenalty``. A match is accepted only
/// when the best score reaches ``acceptanceThreshold`` and beats the runner-up by at least
/// ``minimumLead``; otherwise the channel stays unmatched.
public struct LiveTVTMDbLogoMatcher: Sendable {
    public static let exactConfidence = 0.9
    public static let aliasConfidence = 0.7
    public static let alternateConfidence = 0.5
    public static let unknownCountryPenalty = 0.15
    public static let acceptanceThreshold = 0.5
    public static let minimumLead = 0.05

    /// Explicit alias table: normalised channel key to TMDB network names.
    static let aliases: [String: [String]] = [
        normalized("CTV NEWS CHANNEL"): ["CTV News Channel"],
        normalized("CTV"): ["CTV", "CTV Television Network"],
        normalized("CBC"): ["CBC Television", "CBC"],
        normalized("GLOBAL"): ["Global TV", "Global Television Network"],
        normalized("GLOBAL NEWS"): ["Global News"],
        normalized("CW"): ["The CW"]
    ]

    public static let collapsedConfidence = 0.85
    public static let familyConfidence = 0.6
    public static let groupBrandConfidence = 0.55

    private let networksByKey: [String: [TMDbNetworkEntry]]
    private let networksByCollapsedKey: [String: [TMDbNetworkEntry]]
    private let networksByID: [Int: TMDbNetworkEntry]
    /// The curated table names TMDB network IDs. A list that is not TMDB's (Wikidata's pseudo-networks, numbered by position) must not
    /// resolve them: ID 1089 would be an unrelated item.
    private let usesCuratedTMDbIDs: Bool

    public init(networks: [TMDbNetworkEntry], usesCuratedTMDbIDs: Bool = true) {
        self.usesCuratedTMDbIDs = usesCuratedTMDbIDs
        networksByKey = Dictionary(grouping: networks) { Self.normalized($0.name) }
        networksByCollapsedKey = Dictionary(grouping: networks) { Self.collapsedKey($0.name) }
        networksByID = Dictionary(networks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Candidates

    /// Networks matching the name alone, best score per network, strongest first.
    ///
    /// Order: the curated brand table; then the exact name, the stripped brand name and the alias table; then the
    /// name with generic words dropped; then the longest known brand followed only by variant words (``familyCandidates``);
    /// then the same after a leading carrier word (Rogers, Bell…); last the provider group's brand.
    public func candidates(for query: LiveTVTMDbChannelQuery) -> [LiveTVTMDbCandidate] {
        guard !LiveTVChannelKind.isEventForLogos(name: query.name, groups: query.groups) else { return [] }
        let primary = Self.primaryKey(query.name)
        guard !primary.isEmpty else { return [] }
        let alternate = Self.alternateKey(query.name)
        var found = curatedCandidates(Self.curatedEntry(for: query))
        if found.isEmpty { found = nameCandidates(primary: primary, alternate: alternate) }
        if found.isEmpty { found = familyCandidates(alternate) }
        if found.isEmpty, let rest = Self.removingCarrier(alternate) {
            found = nameCandidates(primary: rest, alternate: rest)
            if found.isEmpty { found = familyCandidates(rest) }
        }
        if found.isEmpty { found = affiliateCandidates(primary: primary) }
        if found.isEmpty { found = groupBrandCandidates(alternate: alternate, groups: query.groups) }
        if found.isEmpty { found = curatedCandidates(Self.curatedEntry(for: query, descriptors: true)) }
        return found.sorted { ($0.confidence, $1.networkID) > ($1.confidence, $0.networkID) }
    }

    /// The curated entry for the channel's brand, if the table has one. An exact entry matches the brand key (or the brand followed
    /// only by variant words); a descriptor entry matches a brand followed by any other words and is meant as a last resort.
    public static func curatedEntry(for query: LiveTVTMDbChannelQuery, descriptors: Bool = false) -> LiveTVCuratedBrand? {
        guard !LiveTVChannelKind.isEventForLogos(name: query.name, groups: query.groups) else { return nil }
        let alternate = alternateKey(query.name)
        let country = country(for: query)
        func entry(_ key: String) -> LiveTVCuratedBrand? {
            guard let entry = LiveTVCuratedBrands.entries[key], entry.country == nil || entry.country == country else { return nil }
            return entry
        }
        if !descriptors {
            if let exact = entry(collapsedKey(alternate)) { return exact }
            return familyCuratedEntry(alternate, entry: entry)
        }
        let words = splitGlued(alternate.split(separator: " ").map(String.init))
        for size in stride(from: words.count, through: 1, by: -1) {
            if let entry = entry(collapsedKey(words[0..<size].joined(separator: " "))), entry.acceptsDescriptors { return entry }
        }
        return nil
    }

    private static func familyCuratedEntry(_ text: String, entry lookup: (String) -> LiveTVCuratedBrand?) -> LiveTVCuratedBrand? {
        let words = splitGlued(text.split(separator: " ").map(String.init))
        guard words.count >= 2 else { return nil }
        for size in stride(from: words.count - 1, through: 1, by: -1) {
            guard let entry = lookup(collapsedKey(words[0..<size].joined(separator: " "))) else { continue }
            return isVariantTail(Array(words[size...]), allowBareCallSigns: false) ? entry : nil
        }
        return nil
    }

    private func curatedCandidates(_ entry: LiveTVCuratedBrand?) -> [LiveTVTMDbCandidate] {
        guard usesCuratedTMDbIDs, let entry, let id = entry.tmdbNetworkID, let network = networksByID[id] else { return [] }
        return [LiveTVTMDbCandidate(networkID: id, networkName: network.name, confidence: 1.0, rule: .curated)]
    }

    private func nameCandidates(primary: String, alternate: String) -> [LiveTVTMDbCandidate] {
        let primaryNorm = Self.normalized(primary)
        let alternateNorm = Self.normalized(alternate)
        var best: [Int: LiveTVTMDbCandidate] = [:]
        func add(_ network: TMDbNetworkEntry, _ confidence: Double, _ rule: LiveTVTMDbMatchRule) {
            if let existing = best[network.id], existing.confidence >= confidence { return }
            best[network.id] = LiveTVTMDbCandidate(
                networkID: network.id, networkName: network.name, confidence: confidence, rule: rule
            )
        }
        let exact = networksByKey[primaryNorm] ?? []
        for network in exact { add(network, Self.exactConfidence, .exactName) }
        if exact.isEmpty, alternateNorm != primaryNorm {
            for network in networksByKey[alternateNorm] ?? [] { add(network, Self.alternateConfidence, .alternateName) }
        }
        for key in Set([primaryNorm, alternateNorm]) {
            for name in Self.aliases[key] ?? [] {
                for network in networksByKey[Self.normalized(name)] ?? [] {
                    add(network, Self.aliasConfidence, .alias)
                }
            }
        }
        if best.isEmpty {
            for key in Set([Self.collapsedKey(primary), Self.collapsedKey(alternate)]) {
                for network in networksByCollapsedKey[key] ?? [] { add(network, Self.collapsedConfidence, .collapsedName) }
            }
        }
        return Array(best.values)
    }

    // MARK: Family fallback

    /// Networks of the brand a name starts with, when the rest of the name is only variant words.
    ///
    /// Takes the longest leading run of words that is a known brand (a TMDB network, an alias or a curated entry). The
    /// words after it must all be variants: a number, a place or timezone word from ``LiveTVGazetteer``, or a feed word.
    /// Any other word means no fallback ("CBS SPORTS NETWORK" is not CBS, "FOX NEWS" is not FOX, "NBC SPORTS" is not NBC).
    /// The longest known brand decides; a shorter prefix would keep the same extra word.
    private func familyCandidates(_ text: String) -> [LiveTVTMDbCandidate] {
        let words = Self.splitGlued(text.split(separator: " ").map(String.init))
        guard words.count >= 2 else { return [] }
        for size in stride(from: words.count - 1, through: 1, by: -1) {
            let prefix = words[0..<size].joined(separator: " ")
            let networks = brandNetworks(prefix)
            guard !networks.isEmpty else { continue }
            guard Self.isUsableBrandPrefix(prefix),
                  Self.isVariantTail(Array(words[size...]), allowBareCallSigns: false) else { return [] }
            return networks.map {
                LiveTVTMDbCandidate(networkID: $0.id, networkName: $0.name, confidence: Self.familyConfidence, rule: .family)
            }
        }
        return []
    }

    /// Networks known under this brand name: by collapsed name, by alias or by the curated table.
    private func brandNetworks(_ name: String) -> [TMDbNetworkEntry] {
        var result: [Int: TMDbNetworkEntry] = [:]
        for network in networksByCollapsedKey[Self.collapsedKey(name)] ?? [] { result[network.id] = network }
        for aliasName in Self.aliases[Self.normalized(name)] ?? [] {
            for network in networksByKey[Self.normalized(aliasName)] ?? [] { result[network.id] = network }
        }
        if usesCuratedTMDbIDs, let id = LiveTVCuratedBrands.entries[Self.collapsedKey(name)]?.tmdbNetworkID, let network = networksByID[id] {
            result[id] = network
        }
        return result.values.sorted { $0.id < $1.id }
    }

    /// Brands whose own name is a bare generic word are never a family parent ("News 3" is not a brand called "News").
    private static let genericBrandWords: Set<String> = [
        "tv", "live", "movie", "movies", "sports", "sport", "news", "kids", "music", "comedy", "drama", "action", "family",
        "world", "free", "now", "plus", "go", "max", "one", "super", "classic", "channel", "network", "television", "city",
        "local", "national", "america", "american", "the", "new", "home", "life", "cinema", "film", "radio", "video"
    ]

    static func isUsableBrandPrefix(_ prefix: String) -> Bool {
        let letters = prefix.filter(\.isLetter).count
        guard letters >= 2 else { return false }
        return !genericBrandWords.contains(normalized(prefix)) || prefix.contains(" ")
    }

    /// "CTV2" is "CTV" and "2": a trailing number glued to a word of two or more letters.
    private static let gluedNumber = LiveTVNameRegex(#"^[A-Za-z]{2,}(?=\d{1,3}$)"#)

    private static let glueableSuffixes = ["television", "network", "channel"]

    /// "OMNITELEVISION" is "OMNI" and "TELEVISION": a generic suffix glued to a brand of at least three letters.
    static func splitGlued(_ words: [String]) -> [String] {
        words.flatMap { word -> [String] in
            if let match = gluedNumber.firstRange(in: word) { return [String(word[match]), String(word[match.upperBound...])] }
            let lower = word.lowercased()
            if let suffix = glueableSuffixes.first(where: { lower.hasSuffix($0) && lower.count - $0.count >= 3 }) {
                let cut = word.index(word.endIndex, offsetBy: -suffix.count)
                return [String(word[..<cut]), String(word[cut...])]
            }
            return [word]
        }
    }

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"
    ]

    /// Words that only say which variant of a brand a channel is. Evidence: the export's "SPORTSNET WORLD" (5),
    /// "FOX 10 LOCAL PHOENIX" (15) and "FOX NET [ABILENE TX]" (21). "Plus" is deliberately absent: "TSN+" is its own brand.
    /// Also the words of a streaming service's numbered shelves ("HULU ORIGINALS 3", "NFL REPLAY 12", "DISNEY+ PREMIERE 1"): 33 NFL/NHL replay,
    /// 20 Hulu, 18 HBO Max, 12 Peacock, 13 Disney+ and 11 Paramount+ rows in the export.
    private static let variantWords: Set<String> = ["local", "net", "world", "original", "originals", "premiere", "replay", "series"]

    private static let bareCallSign = try! NSRegularExpression(pattern: #"^[kw][a-z]{3}$"#)

    /// True when every word is a number, a number word, a place or feed word (up to three words long) or a variant word.
    /// A bare call sign counts only when `allowBareCallSigns` (a four-letter K/W word reads as a place's station).
    static func isVariantTail(_ tokens: [String], allowBareCallSigns: Bool) -> Bool {
        let folded = tokens.map { token -> String in
            token.lowercased().replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
        }.filter { !$0.isEmpty }
        var index = 0
        while index < folded.count {
            var consumed = 0
            for size in stride(from: min(LiveTVGazetteer.maximumPhraseWords, folded.count - index), through: 1, by: -1) {
                let phrase = folded[index..<index + size].joined(separator: " ")
                if LiveTVGazetteer.places.contains(phrase) { consumed = size; break }
                if size == 1, isVariantWord(phrase, allowBareCallSigns: allowBareCallSigns) { consumed = 1; break }
            }
            guard consumed > 0 else { return false }
            index += consumed
        }
        return true
    }

    private static func isVariantWord(_ word: String, allowBareCallSigns: Bool) -> Bool {
        if let number = Int(word) { return (1...999).contains(number) }
        if numberWords.contains(word) || variantWords.contains(word) || genericNameWords.contains(word) { return true }
        return allowBareCallSigns && bareCallSign.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil
    }

    // MARK: Carrier prefixes

    /// Owners and carriers that a provider writes before a brand ("ROGERS SPORTSNET ONE"). Evidence: the export's
    /// `ROGERS SPORTSNET …` and `SPECTRUM NEWS …` rows. The word is removed only when something else follows.
    static let carrierWords: Set<String> = ["rogers", "bell", "shaw", "at&t", "att", "spectrum", "telus", "cogeco", "cox", "xfinity"]

    static func removingCarrier(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2, carrierWords.contains(words[0].lowercased()) else { return nil }
        return words.dropFirst().joined(separator: " ")
    }

    // MARK: Local stations

    /// Broadcast networks whose local stations are named by call sign. Evidence: the export's `US| NBC`, `FOX`, `CBS`, `ABC`, `CW`
    /// and `TELEMUNDO NETWORK` groups hold about 1,300 stations named "NBC 13 (KCWY) CASPER/RIVERTON (D)".
    static let affiliateBrands: Set<String> = ["abc", "nbc", "cbs", "fox", "cw", "pbs", "telemundo", "univision", "ion", "mynetworktv"]

    private static let parenCallSign = try! NSRegularExpression(pattern: #"\(\s*(?!WEST\b)[KWC][A-Z]{2,3}(?:-[A-Z]{1,2})?\d?\s*\)"#)
    private static let bareCallSignBefore = try! NSRegularExpression(pattern: #"\b[KW][A-Z]{2,3}(?:-[A-Z0-9]{1,3})?\s+(?:ABC|NBC|CBS|FOX|CW|PBS|MNT)\b"#)

    /// A local station is its network's logo. Exactly one network word and a call sign (in brackets, or four letters starting K or W right
    /// before the network) are required; anything without a call sign ("NBC BRAVO", "NBC SPORTS NOW") is left to the other rules.
    private func affiliateCandidates(primary: String) -> [LiveTVTMDbCandidate] {
        let words = primary.lowercased().split(whereSeparator: { " ,/".contains($0) }).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let brands = Set(words.filter { Self.affiliateBrands.contains($0) })
        guard brands.count == 1, let brand = brands.first else { return [] }
        let range = NSRange(primary.startIndex..., in: primary)
        guard Self.parenCallSign.firstMatch(in: primary, range: range) != nil
            || Self.bareCallSignBefore.firstMatch(in: primary.uppercased(), range: NSRange(primary.startIndex..., in: primary)) != nil
        else { return [] }
        return brandNetworks(brand.uppercased()).map {
            LiveTVTMDbCandidate(networkID: $0.id, networkName: $0.name, confidence: Self.groupBrandConfidence, rule: .affiliate)
        }
    }

    // MARK: Provider group brand

    /// Local affiliates carry their brand in the group ("US| NBC ᴴᴰ/ᴿᴬᵂ") and bury it in the name
    /// ("US: MACON, GA WMGT NBC 41 (A)"). The brand matches when the name contains it as whole words and every other word is a
    /// number, place, feed word or station call sign.
    private func groupBrandCandidates(alternate: String, groups: [String]) -> [LiveTVTMDbCandidate] {
        let words = alternate.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return [] }
        for group in groups {
            let brand = Self.groupBrand(group)
            guard !brand.isEmpty else { continue }
            let brandWords = brand.split(separator: " ").map(String.init)
            guard brandWords.count < words.count else { continue }
            let lower = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let target = brandWords.map { $0.lowercased() }
            guard let start = (0...(lower.count - target.count)).first(where: { Array(lower[$0..<$0 + target.count]) == target })
            else { continue }
            let networks = brandNetworks(brand)
            guard !networks.isEmpty, Self.isUsableBrandPrefix(brand) else { continue }
            var rest = words
            rest.removeSubrange(start..<start + target.count)
            let affiliate = Self.affiliateBrands.contains(Self.normalized(brand))
            guard Self.isVariantTail(rest, allowBareCallSigns: affiliate) else { continue }
            return networks.map {
                LiveTVTMDbCandidate(networkID: $0.id, networkName: $0.name, confidence: Self.groupBrandConfidence, rule: .groupBrand)
            }
        }
        return []
    }

    /// The brand a provider group names: the label after `US|`, without quality tags, feed notes and generic words.
    /// "US| NBC ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ" is "NBC"; "US| TELEMUNDO NETWORK …" is "TELEMUNDO".
    private static let fpsWord = LiveTVNameRegex(#"\b60\s?FPS\b"#, caseInsensitive: true)

    static func groupBrand(_ group: String) -> String {
        let label = group.split(separator: "|", maxSplits: 1).last.map(String.init) ?? group
        var text = alternateKey(label)
        text = fpsWord.replacing(text, with: " ")
        text = text.replacingOccurrences(of: "/", with: " ")
        let words = text.split(separator: " ").map(String.init).filter {
            !["raw", "hd", "network", "networks", "channel", "channels"].contains($0.lowercased())
        }
        return words.joined(separator: " ")
    }

    // MARK: Selection

    /// The candidate to use, or `nil` when none passes the country filter and threshold or
    /// the top two brands are too close to separate. `originCountries` holds each candidate's
    /// TMDB origin country; a candidate missing from it, or mapped to `nil`, has an unknown country.
    ///
    /// A curated candidate wins outright. Networks whose names collapse to one brand ("CBC" and "CBC Television") are one
    /// brand: the one whose origin is the channel's country is preferred, then the higher score, then the lowest network ID.
    /// Different brands that score within ``minimumLead`` of each other stay unmatched.
    /// The curated table is written for Canadian and American lineups, where a brand may be listed under another origin. For a
    /// channel of any other known country a curated brand applies only to its own origin: "BTN TV" of Rwanda is not the Big Ten Network.
    private static func curatedAppliesToCountry(
        _ candidate: LiveTVTMDbCandidate, _ origins: [Int: String?], _ channelCountry: String?
    ) -> Bool {
        guard let channelCountry, !["CA", "US"].contains(channelCountry),
              let origin = (origins[candidate.networkID] ?? nil)?.uppercased(), !origin.isEmpty else { return true }
        return origin == channelCountry
    }

    public static func select(
        from candidates: [LiveTVTMDbCandidate],
        originCountries: [Int: String?],
        channelCountry: String?
    ) -> LiveTVTMDbCandidate? {
        if let curated = candidates.filter({ $0.rule == .curated && curatedAppliesToCountry($0, originCountries, channelCountry) })
            .min(by: { $0.networkID < $1.networkID }) { return curated }
        var scored: [(candidate: LiveTVTMDbCandidate, score: Double, nativeOrigin: Bool)] = []
        for candidate in candidates {
            let known = (originCountries[candidate.networkID] ?? nil)?.uppercased()
            var score = candidate.confidence
            var native = false
            if let known, !known.isEmpty {
                native = known == channelCountry
                if let channelCountry, known != channelCountry,
                   !allowsCrossBorder(candidate, known: known, channelCountry: channelCountry,
                                      candidates: candidates, originCountries: originCountries) { continue }
            } else {
                score -= unknownCountryPenalty
            }
            guard score >= acceptanceThreshold - 1e-9 else { continue }
            scored.append((candidate, score, native))
        }
        var brands: [String: [(candidate: LiveTVTMDbCandidate, score: Double, nativeOrigin: Bool)]] = [:]
        for item in scored { brands[collapsedKey(item.candidate.networkName), default: []].append(item) }
        if channelCountry == nil {
            // Without a country nothing says which origin is meant: same-named networks of different countries are different brands.
            for (key, group) in brands where Set(group.map { (originCountries[$0.candidate.networkID] ?? nil) ?? "" }).count > 1 {
                brands[key] = nil
                for item in group { brands["\(key)#\(item.candidate.networkID)"] = [item] }
            }
        }
        var representatives = brands.values.compactMap { group in
            group.min { lhs, rhs in
                if lhs.nativeOrigin != rhs.nativeOrigin { return lhs.nativeOrigin }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.candidate.networkID < rhs.candidate.networkID
            }
        }
        representatives.sort { ($0.score, $1.candidate.networkID) > ($1.score, $0.candidate.networkID) }
        guard let top = representatives.first else { return nil }
        if representatives.count > 1, top.score - representatives[1].score < minimumLead - 1e-9 { return nil }
        return top.candidate
    }

    /// US networks that Canadian lineups carry under their own name. A Canadian channel may use one only
    /// when no Canadian network has the same name. Evidence: the export's `CA EN:` rows carry A&E, AMC,
    /// CNN, CNBC, MSNBC, Fox News, FX, HBO, MTV, CMT, Discovery, Disney and others unchanged, and `CA:` rows carry CBS East and West.
    static let crossBorderNetworks: Set<String> = Set([
        "A&E", "AMC", "Disney Channel", "Disney Junior", "Disney XD", "CNN", "CNBC", "MSNBC", "Fox News", "FX", "FXX",
        "HBO", "MTV", "CMT", "BET", "Lifetime", "Discovery", "Discovery Channel", "Animal Planet", "Cartoon Network",
        "Adult Swim", "Comedy Central", "Nickelodeon", "Golf Channel", "Food Network", "Syfy", "TLC", "TBS", "TNT",
        "ESPN", "ESPN2", "Paramount Network", "National Geographic", "Nat Geo Wild", "BBC America", "E!", "Oxygen",
        "Showtime", "Starz", "Cinemax", "Bravo", "USA Network", "Travel Channel", "HGTV", "History", "Investigation Discovery",
        "CBS", "NBC", "ABC", "FOX", "PBS"
    ].map { normalized($0) })

    private static func allowsCrossBorder(
        _ candidate: LiveTVTMDbCandidate, known: String, channelCountry: String,
        candidates: [LiveTVTMDbCandidate], originCountries: [Int: String?]
    ) -> Bool {
        guard channelCountry == "CA", known == "US" else { return false }
        let name = normalized(candidate.networkName)
        guard crossBorderNetworks.contains(name) else { return false }
        return !candidates.contains { other in
            normalized(other.networkName) == name && ((originCountries[other.networkID] ?? nil)?.uppercased() == "CA")
        }
    }

    // MARK: Country

    /// The channel's country: a `CA|`/`US|` group first, then a `CA EN:` name prefix,
    /// then the declared country. `nil` when none of them is a country code.
    public static func country(for query: LiveTVTMDbChannelQuery) -> String? {
        for group in query.groups {
            if let code = prefixCountry(group) { return code }
        }
        if let code = prefixCountry(query.name) { return code }
        return declaredCountry(query.country)
    }

    private static let countryPrefix = LiveTVNameRegex(#"^(?:[A-Za-z]{2})\s*(?:EN|FR)?\s*[:|]"#)

    private static func prefixCountry(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = countryPrefix.firstRange(in: trimmed) else {
            return nil
        }
        let code = String(trimmed[match].prefix(2)).uppercased()
        return ["CA", "US", "GB", "UK", "AU", "NZ", "IE"].contains(code) ? (code == "UK" ? "GB" : code) : nil
    }

    private static func declaredCountry(_ value: String?) -> String? {
        guard let first = value?.split(whereSeparator: { ";,/".contains($0) }).first else { return nil }
        let text = first.trimmingCharacters(in: .whitespaces)
        if text.count == 2, text.allSatisfy(\.isLetter) { return text.uppercased() == "UK" ? "GB" : text.uppercased() }
        switch text.lowercased() {
        case "canada": return "CA"
        case "united states", "united states of america", "usa": return "US"
        case "united kingdom", "great britain": return "GB"
        default: return nil
        }
    }

    // MARK: Normalisation

    private static let qualityWords = try! NSRegularExpression(
        pattern: #"\b(UHD|FHD|HD|SD|RAW|60\s?FPS|4K|8K|VIP|BK)\b"#, options: [.caseInsensitive]
    )

    /// Quality tag stuck to the name ("MONTREALHD"): needs a space before the tag to be recognised.
    private static let gluedQuality = try! NSRegularExpression(
        pattern: #"(?<=[A-Za-z]{3})(HD|SD)(?=$|[\s(\[)])"#
    )

    /// Call-sign and feed notes: "(KMSP)", "(A)", "(R)", "(CA)", "(US)", "[MILWAUKEE]".
    private static let feedNotes = try! NSRegularExpression(
        pattern: #"\(\s*(?:[KWC][A-Z]{2,3}(?:-[A-Z]{1,2})?|[A-Z]|CA|US)\s*\)|\[[^\]]*\]"#
    )

    /// A local affiliate's channel number: "FOX 9", "NBC 10", "CW 18".
    private static let affiliateNumber = try! NSRegularExpression(
        pattern: #"^(ABC|NBC|CBS|FOX|CW|PBS|UNIVISION|TELEMUNDO|ION|MYNETWORKTV|CTV2?|CITYTV)\s+\d{1,2}\b"#,
        options: [.caseInsensitive]
    )

    /// A pay-per-view or event listing ("flowrestling: … (2026-11-20 10:00:00)", "PPV EVENT 36"): a game
    /// or bout, not a network, so it never matches one.
    public static func isEventListing(_ name: String) -> Bool {
        LiveTVChannelKind.isEventForLogos(name: name, groups: [])
    }

    private static let sourcePrefix = LiveTVNameRegex(#"^\s*(?:CA|US|RK|AT&T|PRIME|TV|24/7)\s*(?:EN|FR)?\s*[:|]\s*"#, caseInsensitive: true)
    private static let hashAndSpace = CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)
    private static let emptyParens = LiveTVNameRegex(#"\(\s*\)"#)
    private static let slashBetweenLetters = LiveTVNameRegex(#"([A-Za-z])/([A-Za-z])"#)

    /// A word of six or more letters that is one edit from exactly one word of the brand vocabulary is that word ("INVERSTIGATION").
    /// A word that is itself in the vocabulary, or near two of its words, is left alone.
    static func correctingSpelling(_ text: String) -> String {
        guard text.utf8.count >= 6 else { return text }
        var changed = false
        let words = text.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            guard lower.count >= 6, lower.allSatisfy(\.isLetter), !LiveTVGazetteer.brandVocabulary.contains(lower) else { return String(word) }
            let near = LiveTVGazetteer.brandVocabulary.filter { abs($0.count - lower.count) <= 1 && isOneEditApart(Array($0), Array(lower)) }
            guard near.count == 1, let fix = near.first else { return String(word) }
            changed = true
            return fix.uppercased()
        }
        return changed ? words.joined(separator: " ") : text
    }

    private static let strayLeadingSlash = LiveTVNameRegex(#"(^|\s)/+|/+(\s|$)"#)
    private static let whitespaceRun = LiveTVNameRegex(#"\s+"#)
    private static let parenthesised = LiveTVNameRegex(#"\([^)]*\)"#)

    /// Removes the country/language prefix, decorations and compatibility forms such as
    /// superscript letters, so `ᴴᴰ/ᴿᴬᵂ ⁶⁰ᶠᵖˢ` becomes `HD/RAW 60fps`.
    static func cleaned(_ raw: String) -> String {
        // Cheap string tests guard each pass: most names need only a few of them.
        var text = raw.utf8.allSatisfy { $0 < 0x80 } ? raw : raw.decomposedStringWithCompatibilityMapping
        if Self.hasByte(text, ":") || Self.hasByte(text, "|") { text = sourcePrefix.replacing(text) }
        if !text.utf8.allSatisfy({ $0 < 0x80 }) {
            text = text.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
        }
        return text.trimmingCharacters(in: Self.hashAndSpace)
    }

    /// The channel name without prefix, decorations or quality words.
    /// Shared by every logo and guide matcher; switch to `IPTVChannelName.split` when it lands.
    public static func primaryKey(_ raw: String) -> String { LiveTVNameKeyMemo.shared.keys(for: raw).primary }

    fileprivate static func computePrimaryKey(_ raw: String) -> String {
        var text = cleaned(raw)
        if Self.hasByte(text, "D") {
            text = gluedQuality.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " $1"
            )
        }
        text = qualityWords.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
        )
        if Self.hasByte(text, "(") { text = emptyParens.replacing(text, with: " ") }
        if Self.hasByte(text, "/") { text = strayLeadingSlash.replacing(text, with: " ") }
        // "MUCH_MUSIC" and "TSN/RDS EXTRA": a separator between two words is a space. "24/7" keeps its slash.
        if Self.hasByte(text, "_") { text = text.replacingOccurrences(of: "_", with: " ") }
        if Self.hasByte(text, "/") { text = slashBetweenLetters.replacing(text, with: "$1 $2") }
        text = collapsingSpaces(text)
        text = correctingSpelling(text.trimmingCharacters(in: CharacterSet(charactersIn: " -_/")))
        return text
    }

    /// The brand: the primary key without feed notes, an affiliate's channel number and trailing places.
    /// "CBC CALGARY HD" is "CBC"; "NBC 10 (WJAR) RHODE ISLAND (A)" is "NBC".
    public static func alternateKey(_ raw: String) -> String { LiveTVNameKeyMemo.shared.keys(for: raw).alternate }

    /// One space between words, as `split` and `joined` give; the common case of a single space needs no regular expression.
    /// `String.contains(_: String)` goes through Foundation's search; a byte scan of an ASCII character is far cheaper.
    private static func hasByte(_ text: String, _ character: Unicode.Scalar) -> Bool {
        text.utf8.contains(UInt8(ascii: character))
    }

    static func collapsingSpaces(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.value <= 0x20 || (scalar.value > 0x7F && scalar.properties.isWhitespace) {
                pendingSpace = !scalars.isEmpty
            } else {
                if pendingSpace { scalars.append(" "); pendingSpace = false }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    fileprivate static func computeAlternateKey(primary: String) -> String {
        var text = primary
        if Self.hasByte(text, "(") || Self.hasByte(text, "[") {
            text = feedNotes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            text = parenthesised.replacing(text, with: " ")
        }
        text = collapsingSpaces(text).trimmingCharacters(in: CharacterSet(charactersIn: " -_/"))
        if text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) {
            text = affiliateNumber.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
            )
        }
        var words = text.split(separator: " ").map(String.init)
        while words.count > 1, let size = trailingPlaceWords(words) { words.removeLast(size) }
        // "CTV CALGARY NEWS": a local newscast is the station's brand. NEWS is dropped only behind a place, so "GLOBAL NEWS" stays.
        if words.count >= 3, words.last?.lowercased() == "news", let size = trailingPlaceWords(Array(words.dropLast())) {
            words.removeLast(size + 1)
            while words.count > 1, let more = trailingPlaceWords(words) { words.removeLast(more) }
        }
        return words.joined(separator: " ")
    }

    /// How many trailing words form a place (longest phrase first), leaving at least one word.
    /// A provider typo of a place ("CALARY", "HALFAX"): one edit away from exactly one single-word place, at least six letters.
    /// Two candidate places make it ambiguous, so nothing is stripped.
    static func uniqueMisspelledPlace(_ word: String) -> Bool {
        let text = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard text.count >= 6, text.allSatisfy(\.isLetter), !LiveTVGazetteer.places.contains(text),
              let initial = text.first else { return false }
        var found = 0
        for place in LiveTVGazetteer.singleWordPlaces[initial] ?? [] where abs(place.count - text.count) <= 1 && place.count >= 6 {
            if isOneEditApart(Array(place), Array(text)) { found += 1; if found > 1 { return false } }
        }
        return found == 1
    }

    static func isOneEditApart(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return false }
        if a.count == b.count { return zip(a, b).filter { $0 != $1 }.count == 1 }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    private static func trailingPlaceWords(_ words: [String]) -> Int? {
        for size in stride(from: min(LiveTVGazetteer.maximumPhraseWords, words.count - 1), through: 1, by: -1) {
            let phrase = words.suffix(size).map { $0.lowercased().replacingOccurrences(of: "'", with: "") }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " ")
            if LiveTVGazetteer.places.contains(phrase) { return size }
        }
        if let word = words.last, uniqueMisspelledPlace(word) { return 1 }
        return nil
    }

    private static let genericNameWords: Set<String> = ["television", "tv", "network", "networks", "channel"]

    /// The comparison key of a brand without generic words: a leading "The" and trailing "Television", "TV", "Network" or
    /// "Channel" are dropped, always leaving at least one word. "CBC Television" and "CBC" are both `cbc`.
    public static func collapsedKey(_ text: String) -> String {
        var words = text.decomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0 == " " }).map(String.init)
        if words.count > 1, words[0] == "the" { words.removeFirst() }
        while words.count > 1, let last = words.last, genericNameWords.contains(last) { words.removeLast() }
        return normalized(words.joined(separator: " "))
    }

    /// Case-, accent- and punctuation-insensitive comparison key.
    public static func normalized(_ text: String) -> String {
        let folded = text.decomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: "+", with: "plus")
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }
}

/// The primary and alternate key of every channel name seen, computed once. A catalog build asks for the same name's keys from the
/// matcher, the placeholder pass and the guide matcher; cleaning a name costs about ten regular-expression passes. Bounded: the table is
/// emptied when it reaches ``capacity`` names.
final class LiveTVNameKeyMemo: @unchecked Sendable {
    struct Keys: Sendable {
        let primary: String
        let alternate: String
    }

    static let shared = LiveTVNameKeyMemo()
    static let capacity = 60_000
    private let lock = NSLock()
    private var table: [String: Keys] = [:]

    func keys(for raw: String) -> Keys {
        lock.lock()
        if let hit = table[raw] { lock.unlock(); return hit }
        lock.unlock()
        let primary = LiveTVTMDbLogoMatcher.computePrimaryKey(raw)
        let keys = Keys(primary: primary, alternate: LiveTVTMDbLogoMatcher.computeAlternateKey(primary: primary))
        lock.lock()
        if table.count >= Self.capacity { table.removeAll(keepingCapacity: true) }
        table[raw] = keys
        lock.unlock()
        return keys
    }
}
