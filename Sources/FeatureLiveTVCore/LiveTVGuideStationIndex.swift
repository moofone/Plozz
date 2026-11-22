import CoreModels
import Foundation

/// Finds the XMLTV station for a lineup row that has no usable guide id: the row's cleaned name and its country against the
/// stations' id stems and display names. One rule for every country; nothing here is specific to a place or a provider.
///
/// A station id such as `AMC.us`, `BBC2.uk` or `BBCAmerica.us@SD` is a station name followed by a region suffix. Its key is the
/// name folded to lower-case letters and digits (`amc`, `bbc2`, `bbcamerica`); the same fold is applied to the display names.
/// A row's key is its name with the country/language prefix, the feed descriptors and bracketed tags (`(R)`, `(CA)`) removed.
/// Everything the lookups need is built once per guide (`init`); a row costs a few dictionary reads.
///
/// Lookup order for a row whose country is known (the first rule that finds a station wins):
/// 1. the row's key, or an alias of it (`LiveTVGuideStationData.aliases`), among stations of the row's country (a station with no
///    region suffix serves any country; the shortest id wins, so `AMC.us` beats `AMC.us2`);
/// 2. the *loose* key (generic words such as `channel`, `network`, `tv`, the country's own name and `ici` dropped, camel-case
///    ids split into words: `TheWeatherNetwork` = `WEATHER NETWORK`), only when it names one station base in that country;
/// 3. a feed of another country the row's country shares (`LiveTVGuideStationData.sharedFeedCountries`), in that country's
///    order, when the station's country speaks the row's language (the tag `FR` in `CA FR:`, else the country's first language).
/// A key that is claimed by several different stations of one country is ambiguous and gives nothing: a wrong guide is
/// worse than none. A row whose country is unknown takes a key only when its stations are of one region.
public struct LiveTVGuideStationIndex: Sendable {
    struct Station: Sendable {
        let id: String
        /// The upper-case ISO country the id's suffix names (`uk` is `GB`); nil when the id has none.
        let country: String?
        /// The id's name folded (`AMC` for `AMC.us2`).
        let stemKey: String
    }

    struct Resolution: Equatable, Sendable {
        let id: String
        /// `.displayName` for the row's own country, `.foreignFeed` for a feed of a country that shares its feeds.
        let method: LiveTVGuideMatchMethod
    }

    private let exact: [String: [Station]]
    private let loose: [String: [Station]]
    /// Keys of display names with a trailing qualifier in brackets (`TVO (TV Ontario)`, `CFCM TVA (Quebec)`): read without it and
    /// with it unbracketed, after the exact, alias and loose keys, so they never make one of those ambiguous.
    private let qualified: [String: [Station]]
    /// Stations whose id is a US call sign (`KPIX`, `WZTVDT2`, `abc11wtvd`), by call sign with and without the `DT` subchannel.
    private let callSigns: [String: Station]
    /// Stations that name their call sign and subchannel (`FOX (WTXF) …`, `WTXFTV291.us@HD`); see `LiveTVGuideCallSignTable`.
    private let stationSigns: LiveTVGuideCallSignTable

    init(guideChannels: [String: [String]]) {
        var exactTable: [String: [Station]] = [:]
        var looseTable: [String: [Station]] = [:]
        var callSignTable: [String: Station] = [:]
        var qualifiedTable: [String: [Station]] = [:]
        for (id, names) in guideChannels {
            let stem = Self.stem(of: id)
            let feed = Self.feedWord(of: id)
            // `CBS.us@West` is the CBS Pacific schedule: its key is `cbswest`, and the bare `cbs` is the base feed's alone.
            let shiftedFeed = feed.map(LiveTVGuideStationData.shiftedFeedWords.contains) == true
            let baseKey = Self.key(of: stem.name) ?? ""
            let stemKey = shiftedFeed && !baseKey.isEmpty ? baseKey + (feed ?? "") : baseKey
            let station = Station(id: id, country: stem.country, stemKey: stemKey)
            var keys = Set<String>()
            var looseKeys = Set<String>()
            if shiftedFeed, !stemKey.isEmpty {
                keys.insert(stemKey)
            } else if !stemKey.isEmpty {
                keys.insert(stemKey)
                if let key = Self.looseKey(words: Self.camelWords(stem.name)) { looseKeys.insert(key) }
                // An all-lower-case id cannot be split into words (`reelzchannel`): a trailing `channel` is dropped from its key.
                if stemKey.count > LiveTVGuideStationData.trailingGenericWord.count + 3, stemKey.hasSuffix(LiveTVGuideStationData.trailingGenericWord),
                   let key = Self.looseKey(words: [String(stemKey.dropLast(LiveTVGuideStationData.trailingGenericWord.count))]) {
                    looseKeys.insert(key)
                }
            }
            for name in names {
                if let key = Self.key(of: name) { keys.insert(key) }
                if let key = Self.looseKey(words: Self.words(of: name)) { looseKeys.insert(key) }
                if !shiftedFeed {
                    for key in Self.qualifiedKeys(of: name, stemKey: stemKey) { qualifiedTable[key, default: []].append(station) }
                    // A provider's own guide names its stations like its rows (`CA EN: CBC HALIFAX HD`): the name is also read the
                    // way a row is, so a row without the provider's id still finds a station whose id is only a call sign (`CBHT.ca`).
                    // Only a station with that one name: the provider lists every row it pointed at an id, so an id with several
                    // names carries its mistakes (`HBO.us` named `HBO WEST`) or is a catch-all (`TS`, hundreds of channels). That one
                    // name is the row that carried the id, so it must pass the checks the matcher puts on a row's id: a name the id
                    // contradicts (`QUEST RED +1` on `W.uk`, `SPECTRUM NEWS 1` on `SpectrumNews13`) is the provider's mistake.
                    if names.count == 1, name.utf8.contains(0x3A) {
                        let facts = RowFacts(name: name)
                        if let key = Self.key(of: facts.cleaned), key.count >= 3, key != Self.key(of: name),
                           Self.providerNameAgreesWithID(id: id, facts: facts) {
                            qualifiedTable[key, default: []].append(station)
                        }
                    }
                }
            }
            if let sign = Self.callSign(ofStem: stemKey) {
                // The whole call sign (`wztvdt2`) is exact; the base (`wztv`) serves a row that names no subchannel, unless a
                // station of exactly that call sign exists.
                // A station named by the call sign alone outranks one that adds a network and number; then the shorter id.
                func prefers(_ new: Station, over old: Station?) -> Bool {
                    guard let old else { return true }
                    return (new.stemKey == sign.full ? 0 : 1, new.id.count, new.id) < (old.stemKey == sign.full ? 0 : 1, old.id.count, old.id)
                }
                if prefers(station, over: callSignTable[sign.full]) { callSignTable[sign.full] = station }
                if sign.full == sign.base, prefers(station, over: callSignTable[sign.base]) { callSignTable[sign.base] = station }
                else if callSignTable[sign.base] == nil { callSignTable[sign.base] = station }
            }
            for key in keys { exactTable[key, default: []].append(station) }
            for key in looseKeys { looseTable[key, default: []].append(station) }
        }
        func order(_ stations: [Station]) -> [Station] { stations.sorted { ($0.id.count, $0.id) < ($1.id.count, $1.id) } }
        exact = exactTable.mapValues(order)
        loose = looseTable.mapValues(order)
        qualified = qualifiedTable.mapValues(order)
        callSigns = callSignTable
        stationSigns = LiveTVGuideCallSignTable(guideChannels: guideChannels)
    }

    var isEmpty: Bool { exact.isEmpty }

    /// The station id for a row, or nil when none matches or the match would cross countries.
    func resolve(name: String, country: String?, language: String? = nil) -> String? {
        resolution(name: name, country: country, language: language)?.id
    }

    /// `exactOnly` reads the name as written (own country, no loose key, no shared feed): what a name must reach to overrule a provider id.
    func resolution(name: String, country: String?, language: String? = nil, exactOnly: Bool = false) -> Resolution? {
        resolution(facts: RowFacts(name: name), country: country, language: language, exactOnly: exactOnly)
    }

    func resolution(facts: RowFacts, country: String?, language: String? = nil, exactOnly: Bool = false) -> Resolution? {
        guard !exact.isEmpty else { return nil }
        let row = Self.rowNames(facts)
        let rowLanguage = row.language ?? language
        for text in row.texts {
            if exactOnly {
                guard let country, case .station(let station) = Self.pick(exact[text.exact] ?? [], country: country) else { continue }
                return Resolution(id: station.id, method: .displayName)
            }
            if let found = lookup(text, country: country, language: rowLanguage) { return found }
        }
        return nil
    }

    /// The station whose call sign the row names (`CBS (WSBK) BOSTON`, `KMGH ABC 7`), for a country that has call signs.
    func callSignStation(facts: RowFacts, country: String?) -> String? {
        if case .station(let ids) = callSignAnswer(facts: facts, country: country) { return ids.first }
        return nil
    }

    /// What the call sign a row names says about the guide: the stations to read (the preferred feed first), a refusal when the guide
    /// knows the call sign but not that subchannel or network, or nothing (`.unknown`) so the other rules decide.
    func callSignAnswer(facts: RowFacts, country: String?) -> LiveTVGuideCallSignTable.Answer {
        guard let country, LiveTVGuideStationData.callSignCountries.contains(country), let sign = facts.callSign else { return .unknown }
        switch stationSigns.answer(for: sign, rowNetworks: LiveTVCallSignData.networks(inWords: facts.words)) {
        case .unknown: return (callSigns[sign.full] ?? callSigns[sign.base]).map { .station(ids: [$0.id]) } ?? .unknown
        case let answer: return answer
        }
    }

    /// The station a row names by a bare call sign the guide has (`KIRO 7 NEWS`, `WNBC`), for a row with no call sign of the usual shape.
    func freeCallSignAnswer(facts: RowFacts, country: @autoclosure () -> String?) -> LiveTVGuideCallSignTable.Answer {
        guard facts.callSign == nil, !facts.shifted, !stationSigns.isEmpty else { return .unknown }
        let answer = stationSigns.freeCallSignAnswer(words: facts.words, rowNetworks: LiveTVCallSignData.networks(inWords: facts.words))
        guard answer != .unknown, let country = country(), LiveTVGuideStationData.callSignCountries.contains(country) else { return .unknown }
        return answer
    }

    /// The stations a row may read, for deciding which of a guide's stations to retain: the one its name resolves to and every feed
    /// of the one its call sign names.
    func retainedStationIDs(name: String, country: String?, groups: [String] = []) -> [String] {
        let facts = RowFacts(name: name, groups: groups)
        var ids: [String] = []
        if let found = resolution(facts: facts, country: country)?.id { ids.append(found) }
        if !facts.shifted, case .station(let signed) = callSignAnswer(facts: facts, country: country) { ids += signed }
        else if case .station(let signed) = freeCallSignAnswer(facts: facts, country: country) { ids += signed }
        return ids
    }

    /// Whether any station of any country carries the row's name, exactly or loosely: false means the guide has nothing
    /// for the row (a provider gap), true means a matcher rule declined it.
    func hasAnyStation(named name: String, groups: [String] = []) -> Bool {
        Self.rowNames(RowFacts(name: name, groups: groups)).texts.contains { text in
            exact[text.exact] != nil || Self.aliasedKey(text.exact).flatMap { exact[$0] } != nil
                || text.loose.flatMap { loose[$0] } != nil || qualified[text.exact] != nil
        }
    }

    private func lookup(_ text: RowText, country: String?, language: String?) -> Resolution? {
        let named = exact[text.exact] ?? []
        let aliased = Self.aliasedKey(text.exact).flatMap { exact[$0] } ?? []
        let direct = named.isEmpty ? aliased : named
        guard let country else {
            guard !direct.isEmpty, Set(direct.map(\.country)).count == 1 else { return nil }
            return Resolution(id: direct[0].id, method: .displayName)
        }
        let near = text.loose.flatMap { loose[$0] } ?? []
        let bracketed = qualified[text.exact] ?? []
        // A country's own stations decide first; two of them claiming the name is an ambiguity, not a reason to look abroad.
        // The name as written first, then its alias (`NATIONAL GEOGRAPHIC` names stations of other countries but `NatGeo.us` is the US one).
        for candidates in [named, aliased, near, bracketed] {
            switch Self.pick(candidates, country: country) {
            case .station(let station): return Resolution(id: station.id, method: .displayName)
            case .ambiguous: return nil
            case .none: continue
            }
        }
        guard let sharing = LiveTVGuideStationData.sharedFeedCountries[country] else { return nil }
        let wanted = language ?? LiveTVGuideStationData.countryLanguages[country]?.first
        for other in sharing {
            guard let wanted, LiveTVGuideStationData.countryLanguages[other]?.contains(wanted) == true else { continue }
            for candidates in [named, aliased, near] {
                if case .station(let station) = Self.pick(candidates, country: other) {
                    return Resolution(id: station.id, method: .foreignFeed)
                }
            }
        }
        return nil
    }

    private enum Pick {
        case station(Station), ambiguous, none
    }

    /// The station of `country` (or one with no region) among `stations`; ambiguous when two different stations claim the key.
    private static func pick(_ stations: [Station], country: String) -> Pick {
        for region in [country, nil] as [String?] {
            guard let first = stations.first(where: { $0.country == region }) else { continue }
            // Stations are ordered by id length; a second stem in the region makes the key ambiguous.
            if stations.contains(where: { $0.country == region && $0.stemKey != first.stemKey }) { return .ambiguous }
            return .station(first)
        }
        return .none
    }

    private static func aliasedKey(_ key: String) -> String? { LiveTVGuideStationData.aliases[key] }

    /// The lower-case feed word after an id's `@` (`west` for `CBS.us@West`); nil when there is none.
    static func feedWord(of id: String) -> String? {
        guard let at = id.lastIndex(of: "@") else { return nil }
        let feed = id[id.index(after: at)...].lowercased()
        return feed.isEmpty ? nil : feed
    }

    /// The keys of a display name that ends in a bracketed qualifier: the name without it (`TVO (TV Ontario)` is `tvo`) and with it
    /// unbracketed (`CFCM TVA (Quebec)` is `tva quebec`), a leading word the station's own id starts with (its call sign `CFCM`) left
    /// out of the second. Empty when the name has no trailing qualifier or a key would be the id's bare call sign.
    static func qualifiedKeys(of name: String, stemKey: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex else { return [] }
        let head = words(of: String(trimmed[..<open]))
        let tail = words(of: String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]))
        guard !head.isEmpty, !tail.isEmpty else { return [] }
        var unbracketed = head + tail
        if head.count > 1, let first = head.first, first.count >= 3, stemKey.hasPrefix(first) { unbracketed.removeFirst() }
        let leadingSign = head.count == 1 && head[0].count >= 3 && stemKey.hasPrefix(head[0]) && stemKey != head[0]
        // `HBO (Pacific)` without its qualifier would read as the base feed.
        let namesAFeed = tail.contains(where: LiveTVGuideStationData.shiftedFeedWords.contains)
        return [leadingSign || namesAFeed ? nil : head.joined(), unbracketed.joined()].compactMap { $0 }.filter { $0.count >= 3 }
    }

    // MARK: Names

    struct RowText {
        let exact: String
        let loose: String?
    }

    /// The texts to try for a row, whole name first; `NOW: ALIBI` has a provider package label before the colon.
    private static func rowNames(_ facts: RowFacts) -> (texts: [RowText], language: String?) {
        let cleaned = facts.cleaned
        var sources: [([String])] = [facts.words]
        if let separator = cleaned.firstIndex(where: { $0 == ":" || $0 == "|" }) {
            sources.append(words(of: String(cleaned[cleaned.index(after: separator)...])))
        }
        var texts: [RowText] = []
        for parts in sources {
            guard !parts.isEmpty else { continue }
            texts.append(RowText(exact: parts.joined(), loose: looseKey(words: parts)))
            // `HBO EAST` is the base feed. (`WEST`, `PACIFIC` and `+N` are other schedules: only a station of their own serves them.)
            if parts.count > 1, parts.last.map(LiveTVGuideStationData.baseFeedWords.contains) == true {
                let base = Array(parts.dropLast())
                texts.append(RowText(exact: base.joined(), loose: looseKey(words: base)))
            }
        }
        return (texts, facts.language)
    }

    private static let dashPrefix = try? NSRegularExpression(pattern: #"^([A-Z]{2})(?:[ /-]([A-Z]{2}))?\s*[-\u2013\u2014]\s*(?=\S)"#)

    /// `CA - NAME` and `CA-EN- NAME` read as `CA: NAME` and `CA EN: NAME` (the split reads a colon or ` |` after the codes).
    // MARK: Provider ids

    /// A provider id that names no station: empty, or shorter than three characters (`TS`), or a filler word.
    static func isPlaceholderID(_ id: String) -> Bool {
        let folded = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.count < 3 || LiveTVGuideStationData.placeholderIDs.contains(folded)
    }

    /// What the matcher reads from a row name, computed once per row.
    struct RowFacts {
        let raw: String
        /// The name without prefix tags, brackets, quality words.
        let cleaned: String
        let language: String?
        let words: [String]
        let shifted: Bool
        let callSign: CallSign?

        /// `groups`: the row's own group labels. A package prefix they corroborate (`PRIME:` in `CA| PRIME`, `IPTVChannelName.packagePrefix`)
        /// is not part of the station's name, so the facts read the name without it.
        init(name rawName: String, groups: [String] = []) {
            raw = rawName
            let name = IPTVChannelName.packagePrefix(in: rawName, groups: groups)?.rest ?? rawName
            let split = IPTVChannelName.split(LiveTVGuideStationIndex.colonPrefix(LiveTVGuideStationIndex.removingTagBrackets(name)))
            // `+1` is the word `plus 1`, the way a guide spells its time-shifted ids (`E4plus1`).
            var text = split.name.utf8.contains(0x2B) ? LiveTVGuideStationIndex.plusRead(split.name) : split.name
            var language: String?
            for tag in split.tags {
                if case let .language(code) = tag { language = code }
                // `UK: UK ALIBI` repeats its country.
                if case let .country(code) = tag, text.count > 3, text.uppercased().hasPrefix(code + " ") { text = String(text.dropFirst(3)) }
            }
            self.language = language
            cleaned = text
            words = LiveTVGuideStationIndex.words(of: text)
            callSign = LiveTVGuideStationIndex.callSign(in: name)
            shifted = LiveTVGuideStationIndex.endsWithFeedMarker(words) || LiveTVGuideStationIndex.hasPlusShift(name)
        }
    }

    /// A row carrying a time shift (`ITV2 +1`, `ITV 3+1`, `NAT GEO +6H`): its schedule is the base station's moved by hours.
    static func isTimeShifted(_ name: String) -> Bool { RowFacts(name: name).shifted }

    static func hasPlusShift(_ name: String) -> Bool {
        guard name.utf8.contains(0x2B) else { return false }
        let bytes = Array(name.utf8)
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x2B, bytes[index + 1] >= 0x30, bytes[index + 1] <= 0x39 {
                var end = index + 1
                while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 { end += 1 }
                if end < bytes.count, bytes[end] == 0x48 || bytes[end] == 0x68 { end += 1 }
                if end == bytes.count || !(bytes[end] >= 0x41 && bytes[end] <= 0x5A || bytes[end] >= 0x61 && bytes[end] <= 0x7A) { return true }
            }
            index += 1
        }
        return false
    }

    /// Whether the name's last word marks another coast's feed (`HBO WEST`, `ESPN PACIFIC`); `WEST PALM BEACH` is a place.
    fileprivate static func endsWithFeedMarker(_ parts: [String]) -> Bool {
        guard parts.count > 1, let last = parts.last else { return false }
        return LiveTVGuideStationData.shiftedFeedWords.contains(last)
    }

    /// `+1` and `+6H` read as `plus 1`, `plus 6H`.
    static func plusRead(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            if character == "+", offset + 1 < characters.count, characters[offset + 1].isNumber { result += " plus " } else { result.append(character) }
        }
        return result
    }

    /// Whether a station id is itself a time-shifted one (`E4plus1.uk`, `ITV2+1`, `HBOWest.us`).
    static func isTimeShiftedStation(_ id: String) -> Bool {
        let lower = id.lowercased()
        if let feed = feedWord(of: id), LiveTVGuideStationData.shiftedFeedWords.contains(feed) { return true }
        if LiveTVGuideStationData.shiftedFeedWords.contains(where: { lower.contains("." ) ? stem(of: id).name.lowercased().hasSuffix($0) : lower.hasSuffix($0) }) { return true }
        var search = lower[...]
        while let range = search.range(of: "plus") {
            if let next = search[range.upperBound...].first, next.isNumber { return true }
            search = search[range.upperBound...]
        }
        return lower.contains("+1") || lower.contains("+2")
    }

    /// Whether the provider's id names a different region or channel number than the row's name does: `BBC ONE WALES` carrying
    /// `BBCOneNorthWest`, `BBC ONE LONDON` carrying `BBCOneOxford`, `SKY SPORTS 1` carrying `SkySports2`. Both sides must name one,
    /// and they must differ. A region the name or the id names alone is a difference too (`BBC TWO` carrying `BBCTwoWales`, `BBC ONE NI`
    /// carrying `bbc1`); channel numbers only differ when both sides carry one.
    static func idContradictsName(id: String, name: String) -> Bool { idContradictsName(id: id, facts: RowFacts(name: name)) }

    static func idContradictsName(id: String, facts: RowFacts) -> Bool {
        let idWords = camelWords(stem(of: id).name)
        let nameWords = facts.words
        let nameRegions = regions(in: nameWords), idRegions = regions(in: idWords)
        if !idRegions.isEmpty, nameRegions != idRegions { return true }
        // A region only the name carries contradicts an id that is the same brand without one (`BBC ONE NI` / `bbc1`); an id of
        // an unrelated call sign (`CTV2 LONDON` / `CFPL`) is the station's own name for the region.
        if idRegions.isEmpty, !nameRegions.isEmpty, let brand = nameWords.first, idWords.joined().hasPrefix(brand) { return true }
        let nameNumbers = numbers(in: nameWords), idNumbers = numbers(in: idWords)
        return !facts.shifted && !nameNumbers.isEmpty && !idNumbers.isEmpty && Set(nameNumbers) != Set(idNumbers)
    }

    private static func regions(in words: [String]) -> Set<String> {
        var rewritten = words
        rewritten = rewrite(rewritten)
        let squashed = rewritten.joined()
        var found = Set(LiveTVGuideStationData.regionWords.filter { squashed.contains($0) })
        // `eastmidland` contains `midland`: the longest name stands.
        for long in found { for short in found where short != long && long.contains(short) { found.remove(short) } }
        return found
    }

    /// The trailing digit run of each word (`bbc2` → 2, `5` → 5), with a number word before another word read as its digit.
    private static func numbers(in words: [String]) -> [String] {
        let folded = words.count > 1 ? words.map { LiveTVGuideStationData.numberWords[$0] ?? $0 } : words
        return folded.compactMap { word in
            let digits = word.reversed().prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits.reversed())
        }
    }

    private static func rewrite(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        outer: while index < words.count {
            for (phrase, replacement) in LiveTVGuideStationData.phraseRewrites
            where words[index] == phrase[0] && index + phrase.count <= words.count
                && phrase.indices.allSatisfy({ words[index + $0] == phrase[$0] }) {
                result.append(contentsOf: replacement)
                index += phrase.count
                continue outer
            }
            result.append(words[index])
            index += 1
        }
        return result
    }

    // MARK: Call signs

    /// Names the rules that decide which stations of a guide a lineup retains (this index and `LiveTVGuideCallSignTable`). Change it
    /// with any change to them: a saved guide indexed under another value is read again once.
    static let rulesFingerprint = "stations-r3-callsign-v1"

    struct CallSign: Equatable {
        /// Lower-case with the subchannel (`wztvdt2`), and without it (`wztv`).
        let full: String, base: String
    }

    /// A US call sign a row names: in brackets (`(WTIC)`) always, free (`KMGH ABC 7`) only beside a network name, so `WEST` or `KIDS`
    /// alone is no call sign. `-DT`, `-DT2` and `-TV` suffixes are read.
    static func callSign(in name: String) -> CallSign? {
        guard hasCallSignCandidate(name) else { return nil }
        var tokens: [(text: String, bracketed: Bool, beforeComma: Bool)] = []
        var current = ""
        var depth = 0
        func flush() { if !current.isEmpty { tokens.append((current.uppercased(), depth > 0, false)); current = "" } }
        for character in name {
            switch character {
            case "(", "[": flush(); depth += 1
            case ")", "]": flush(); depth = max(0, depth - 1)
            // A free word before a comma is a place (`WACO, TX KCEN NBC 6`), never a call sign.
            case ",": flush(); if !tokens.isEmpty { tokens[tokens.count - 1].beforeComma = true }
            case " ", "/", ":", "|": flush()
            default: current.append(character)
            }
        }
        flush()
        let hasNetwork = tokens.contains { LiveTVGuideStationData.networkWords.contains($0.text) }
        for token in tokens where token.bracketed || (hasNetwork && !token.beforeComma) {
            guard !LiveTVGuideStationData.notCallSigns.contains(token.text), let sign = callSign(ofToken: token.text, bracketed: token.bracketed) else { continue }
            return sign
        }
        return nil
    }

    /// Whether any token (a run between the separators the reader splits on) starts with `K` or `W`: most names have none.
    private static func hasCallSignCandidate(_ name: String) -> Bool {
        var atStart = true
        for byte in name.utf8 {
            switch byte {
            case 0x28, 0x5B, 0x29, 0x5D, 0x20, 0x2C, 0x2F, 0x3A, 0x7C: atStart = true
            default:
                if atStart, byte == 0x4B || byte == 0x57 || byte == 0x6B || byte == 0x77 { return true }
                atStart = false
            }
        }
        return false
    }

    /// `WZTV-DT2`, `KPIX`, `WCBS-TV`, `KRQEDT2`, `WTOV-D2` as a call sign; nil for anything else (`LiveTVCallSignData`).
    private static func callSign(ofToken token: String, bracketed: Bool) -> CallSign? {
        LiveTVCallSignData.callSign(ofToken: token, bracketed: bracketed)
    }

    /// The call sign a guide station id is: the whole stem (`KPIX`, `WZTVDT2`) or a network, a number and then the call sign (`abc11wtvd`).
    static func callSign(ofStem key: String) -> CallSign? {
        var text = Substring(key)
        if let network = LiveTVGuideStationData.networkWords.map({ $0.lowercased() }).first(where: { text.hasPrefix($0) }) {
            let rest = text.dropFirst(network.count).drop(while: \.isNumber)
            if rest.count != text.count - network.count, rest.count >= 3 { text = rest }
        }
        guard text.count >= 3, text.count <= 8, let first = text.first, first == "k" || first == "w",
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var base = text
        var full = String(text)
        if text.count > 4 {
            let tail = text.dropFirst(4)
            guard tail == "tv" || tail.hasPrefix("dt") && tail.dropFirst(2).count <= 1 else { return nil }
            base = text.prefix(4)
            full = tail == "tv" ? String(base) : String(text)
        }
        guard base.allSatisfy(\.isLetter), !LiveTVGuideStationData.notCallSigns.contains(base.uppercased()) else { return nil }
        return CallSign(full: full, base: String(base))
    }

    /// Whether the provider's id is the call sign of another station than the one the row names (a wrong market's affiliate).
    /// Whether a provider's id may be read by the name of the row that carried it: the trust checks of `LiveTVGuideMatcher` on a row's id.
    static func providerNameAgreesWithID(id: String, facts: RowFacts) -> Bool {
        !isPlaceholderID(id) && !idContradictsName(id: id, facts: facts) && !idCallSignDiffers(id: id, facts: facts)
            && !idIsSiblingOfName(id: id, facts: facts) && (!facts.shifted || isTimeShiftedStation(id))
    }

    static func idCallSignDiffers(id: String, facts: RowFacts) -> Bool {
        guard let row = facts.callSign, let key = key(of: stem(of: id).name), let other = callSign(ofStem: key) else { return false }
        return row.base != other.base
    }

    /// An affiliate named by network and number or city but no call sign (`ABC 7 [BUFFALO]`): the guide cannot say which market.
    static func isLocalWithoutCallSign(_ name: String) -> Bool { isLocalWithoutCallSign(RowFacts(name: name)) }

    static func isLocalWithoutCallSign(_ facts: RowFacts) -> Bool {
        guard facts.callSign == nil else { return false }
        let parts = facts.words
        for (offset, word) in parts.enumerated() where LiveTVGuideStationData.networkWords.contains(word.uppercased()) {
            guard offset + 1 < parts.count else { continue }
            let next = parts[offset + 1]
            if next.first?.isNumber == true && next.allSatisfy(\.isNumber) || next == "net" { return true }
        }
        return false
    }

    /// Whether the provider's id is a sibling of the row's name: the same leading letters (at least the row's first word and four
    /// characters), then different tails, neither key holding the other and neither tail an abbreviation or a near spelling of the
    /// other (`SKY SPORTS DARTS` / `SkySportsF1`), or the name is the id's name plus a number above one that the id lacks (`HBO 2` /
    /// `HBO`; a trailing `1` is the base channel). The id is another station of the same family, so it is not trusted for this row.
    /// Generic words (`channel`, `network`, `canada`) and `&` are left out of both keys; `DISNEY JR` / `DisneyJunior`, `NEWS 12 CT` /
    /// `News12Connecticut` and `GLOBAL CALAGRY` / `GlobalCalgary` are one station each. A call-sign id (`abc11wtvd`) is the market's
    /// own name and never a sibling.
    static func idIsSiblingOfName(id: String, facts: RowFacts) -> Bool {
        guard let first = facts.words.first, var idKey = key(of: stem(of: id).name) else { return false }
        if callSign(ofStem: idKey) != nil { return false }
        var stripped = true
        while stripped {
            stripped = false
            for word in LiveTVGuideStationData.genericWords where word.count >= 5 && idKey.count >= word.count + 3 && idKey.hasSuffix(word) {
                idKey.removeLast(word.count)
                stripped = true
            }
        }
        let nameKey = facts.words.filter { $0 != "and" && !LiveTVGuideStationData.genericWords.contains($0) }.joined()
        guard nameKey != idKey, !nameKey.isEmpty else { return false }
        // `HBO 2` is not `HBO`: a number above one that the id does not carry (`HBO 1` is the base channel).
        if nameKey.hasPrefix(idKey), idKey.last?.isNumber == false {
            let number = nameKey.dropFirst(idKey.count)
            if !number.isEmpty, number.allSatisfy(\.isNumber), number != "1" { return true }
        }
        guard !nameKey.contains(idKey), !idKey.contains(nameKey) else { return false }
        let name = Array(nameKey), other = Array(idKey)
        var shared = 0
        while shared < min(name.count, other.count), name[shared] == other[shared] { shared += 1 }
        guard shared >= max(first.count, LiveTVGuideStationData.minimumSiblingPrefix) else { return false }
        let nameTail = Array(name[shared...]), idTail = Array(other[shared...])
        if isSubsequence(nameTail[...], of: idTail[...]) || isSubsequence(idTail[...], of: nameTail[...]) { return false }
        let shorter = min(nameTail.count, idTail.count)
        return !(shorter >= 3 && editDistance(nameTail, idTail) <= (shorter >= 4 ? 2 : 1))
    }

    /// Whether `short`'s letters appear in order in `long` (`jr` in `junior`).
    private static func isSubsequence(_ short: ArraySlice<Character>, of long: ArraySlice<Character>) -> Bool {
        var remaining = short[...]
        for character in long where remaining.first == character { remaining = remaining.dropFirst() }
        return remaining.isEmpty
    }

    /// Levenshtein distance of two short tails.
    private static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = [row + 1]
            for (column, rightCharacter) in right.enumerated() {
                current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (leftCharacter == rightCharacter ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }

    /// Whether the provider's id looks like it names something else than the row: neither key holds the other.
    static func idUnrelatedToName(id: String, facts: RowFacts) -> Bool {
        let nameKey = facts.words.joined()
        guard let idKey = key(of: stem(of: id).name), !nameKey.isEmpty else { return false }
        return !(nameKey.contains(idKey) || idKey.contains(nameKey))
    }

    static func colonPrefix(_ name: String) -> String {
        guard name.utf8.prefix(12).contains(where: { $0 == 0x2D || $0 == 0xE2 }) else { return name }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = dashPrefix?.firstMatch(in: name, range: range), let whole = Range(match.range, in: name),
              let first = Range(match.range(at: 1), in: name) else { return name }
        var codes = [String(name[first])]
        if let second = Range(match.range(at: 2), in: name) { codes.append(String(name[second])) }
        guard codes.allSatisfy({ LiveTVGuideStationData.bracketTags.contains($0) }) else { return name }
        return codes.joined(separator: " ") + ": " + name[whole.upperBound...]
    }

    /// `name` without decorative symbols (`◉`, `★`) that some providers append; letters, digits and punctuation stay. A symbol drawn
    /// in place of a letter (`SP⚽RTS`) is that letter (`LiveTVGuideStationData.symbolLetters`).
    static func withoutSymbols(_ name: String) -> String {
        guard !isASCII(name), name.unicodeScalars.contains(where: { $0.value >= 0x80 && $0.properties.generalCategory == .otherSymbol }) else { return name }
        var kept = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if let letter = LiveTVGuideStationData.symbolLetters[scalar] { kept.append(letter) }
            else if scalar.properties.generalCategory != .otherSymbol { kept.append(scalar) }
        }
        return String(kept).trimmingCharacters(in: .whitespaces)
    }

    static func isASCII(_ text: String) -> Bool { text.utf8.allSatisfy { $0 < 0x80 } }

    /// `name` without bracketed tags that carry no part of the name: `(R)`, `(CA)`, `[FR]`, `(HD)`, `(BACKUP)`.
    static func removingTagBrackets(_ name: String) -> String {
        var text = withoutSymbols(name)
        guard text.utf8.contains(where: { $0 == 0x28 || $0 == 0x5B }) else { return text }
        // The cuts fall on ASCII brackets, so the kept bytes stay valid UTF-8.
        return text.withUTF8 { bytes -> String in
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x28 || byte == 0x5B, let close = bytes[(index + 1)...].firstIndex(where: { $0 == 0x29 || $0 == 0x5D }) {
                    let inner = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces).uppercased()
                    if LiveTVGuideStationData.bracketTags.contains(inner) {
                        index = close + 1
                        continue
                    }
                }
                result.append(byte)
                index += 1
            }
            return String(decoding: result, as: UTF8.self)
        }
    }

    /// Lower-case words of a name, diacritics folded and `&` read as `and`. ASCII names (nearly every row) take a byte loop.
    static func words(of name: String) -> [String] {
        var text = name
        let ascii: [String]? = text.withUTF8 { bytes -> [String]? in
            var result: [String] = []
            var current: [UInt8] = []
            for byte in bytes {
                if byte >= 0x80 { return nil }
                switch byte {
                case 0x30...0x39, 0x61...0x7A: current.append(byte)
                case 0x41...0x5A: current.append(byte + 32)
                default:
                    if !current.isEmpty { result.append(String(decoding: current, as: UTF8.self)); current.removeAll(keepingCapacity: true) }
                    if byte == 0x26 { result.append("and") }
                }
            }
            if !current.isEmpty { result.append(String(decoding: current, as: UTF8.self)) }
            return result
        }
        if let ascii { return ascii }
        return name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The words of a camel-case id: `CTVDrama` is `ctv drama`, `TheWeatherNetwork` is `the weather network`.
    static func camelWords(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if let previous = current.last {
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let acronymEnd = previous.isUppercase && character.isUppercase
                    && offset + 1 < characters.count && characters[offset + 1].isLowercase
                if lowerToUpper || acronymEnd { parts.append(current); current = "" }
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.flatMap { words(of: $0) }
    }

    /// The words without the generic ones (`channel`, `network`, `tv`…) and with the phrase rewrites applied, joined;
    /// nil when nothing is left.
    static func looseKey(words: [String]) -> String? {
        let rewritten = rewrite(words)
        var kept = rewritten.filter { !LiveTVGuideStationData.genericWords.contains($0) }
        if kept.count > 1 {
            // `BBC ONE` is `bbc1`; a lone `ONE` stays a word. Region words nobody says are dropped (`BBC ONE LONDON` is the national feed).
            kept = kept.map { LiveTVGuideStationData.numberWords[$0] ?? $0 }
            kept.removeAll { LiveTVGuideStationData.defaultRegionWords.contains($0) }
        }
        let key = kept.joined().replacingOccurrences(of: "sports", with: "sport")
        // A loose key of one to three letters (`one` from `TVOne`) names too many things to stand for a station.
        return key.count < LiveTVGuideStationData.minimumLooseKeyLength ? nil : key
    }

    /// The name without a trailing `.xx`, `.xx2` region suffix or `@SD` feed marker, and that region.
    private static func stem(of id: String) -> (name: String, country: String?) {
        var text = Substring(id.trimmingCharacters(in: .whitespacesAndNewlines))
        if let at = text.firstIndex(of: "@") { text = text[..<at] }
        guard let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) >= 3 else { return (String(text), nil) }
        let suffix = text[text.index(after: dot)...]
        let letters = suffix.prefix { $0.isLetter }
        guard letters.count == 2, suffix.dropFirst(2).allSatisfy(\.isNumber) else { return (String(text), nil) }
        return (String(text[..<dot]), String(letters).uppercased() == "UK" ? "GB" : String(letters).uppercased())
    }

    /// Lower-case letters and digits of a name, diacritics and `&` folded; nil when nothing is left.
    static func key(of name: String) -> String? {
        var ascii = name
        let quick: String?? = ascii.withUTF8 { bytes -> String?? in
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            for byte in bytes {
                switch byte {
                case 0x30...0x39, 0x61...0x7A: result.append(byte)
                case 0x41...0x5A: result.append(byte + 32)
                case 0x26: result.append(contentsOf: [0x61, 0x6E, 0x64])
                case 0..<0x80: continue
                default: return nil
                }
            }
            return .some(result.isEmpty ? nil : String(decoding: result, as: UTF8.self))
        }
        if let quick { return quick }
        var folded = String.UnicodeScalarView()
        for scalar in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and").unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            folded.append(scalar)
        }
        let key = String(folded)
        return key.isEmpty ? nil : key
    }
}

/// The matcher's tables, as data. Adding a provider's quirk is a row here and a test, never a branch in the matcher.
enum LiveTVGuideStationData {
    /// Bracketed text that is a tag, not part of a name (upper case).
    static let bracketTags: Set<String> = [
        "R", "D", "HD", "FHD", "UHD", "SD", "4K", "8K", "HDR", "RAW", "BK", "VIP", "ALT", "BACKUP", "HEVC",
        "EN", "FR", "ES", "DE", "IT", "PT", "NL", "AR", "CA", "US", "UK", "GB", "AU", "NZ", "IE"
    ]

    /// Words that name a kind of thing or a place rather than the station (a loose key drops them).
    static let genericWords: Set<String> = ["the", "channel", "network", "tv", "television", "canal", "ici", "canada", "canadian"]

    /// A word an all-lower-case guide id may end with (`reelzchannel`); the loose key of that id leaves it out.
    static let trailingGenericWord = "channel"

    /// Symbols a provider draws in place of a letter.
    static let symbolLetters: [Unicode.Scalar: Unicode.Scalar] = ["\u{26BD}": "O"]

    /// The fewest shared leading characters that make a provider id a sibling of a row's name rather than an unrelated station.
    static let minimumSiblingPrefix = 4

    /// The fewest letters a loose key needs: shorter ones are matched only exactly.
    static let minimumLooseKeyLength = 4

    /// Word runs read as another run before the generic words are dropped (`ICI RADIO-CANADA TELE X` is `ICI TELE X`).
    static let phraseRewrites: [(phrase: [String], replacement: [String])] = [
        (["radio", "canada"], []), (["radio", "tele"], ["tele"]),
        (["ni"], ["northern", "ireland"]), (["midlands"], ["midland"])
    ]

    /// Provider package labels that are also ISO country codes (`TV: ESPN`), so never a foreign-country prefix.
    static let packageLabelCodes: Set<String> = ["TV"]

    /// Ids a provider writes where it has none.
    static let placeholderIDs: Set<String> = ["tbd", "n/a", "none", "null", "unknown", "undefined", "empty", "default"]

    /// Number words read as digits in a name of more than one word (`BBC ONE` is `BBC1`).
    static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5"]

    /// Region words nobody says for the national feed; a loose key drops them.
    static let defaultRegionWords: Set<String> = ["london", "england"]

    /// Regions whose feeds a guide keeps apart (folded, joined words): a provider id of one region does not serve a row of another.
    static let regionWords: [String] = [
        "scotland", "wales", "northernireland", "northwest", "northeast", "southeast", "southwest", "london", "oxford", "yorkshire",
        "eastmidland", "westmidland", "midland", "channelislands", "westcountry", "meridian", "anglia", "granada", "tynetees",
        "utv"
    ]

    /// A row key that reads as another station key: abbreviations the guide's own ids use (`GlobalBC` for Global Vancouver). Never a
    /// 24-hour news channel onto its parent station (`Global News Toronto` is not `Global Toronto`): their schedules differ most of the day.
    static let aliases: [String: String] = [
        "skysportspl": "skysportspremiereleague", "nationalgeo": "natgeo", "nationalgeographic": "natgeo", "dmax": "discoverydmax",
        "globalvancouver": "globalbc", "espnews": "espnnews", "e": "eentertainment", "ifc": "independentfilmchannel",
        "btn": "bigtennetwork", "lmn": "lifetimemovienetwork", "ctvnewschannel": "ctvnc", "ctvnewsnetwork": "ctvnc", "ctvottawa": "ctvoh", "rds1": "rds", "icirdi": "rdinews"
    ]

    /// Network names that mark a local affiliate; a free `K…`/`W…` token counts as a call sign only beside one.
    static let networkWords: Set<String> = ["ABC", "NBC", "CBS", "FOX", "CW", "PBS", "TELEMUNDO", "UNIVISION", "ION", "MYNETWORK", "MNT"]

    /// `K`/`W` words that are not call signs.
    static let notCallSigns: Set<String> = ["WEST", "KIDS", "KIDZ", "WILD", "WINE", "WORK", "WEEK", "KINO", "WWE", "KTV", "WTV"]

    /// Countries whose names carry US call signs.
    static let callSignCountries: Set<String> = ["US"]

    /// A last word that names the base feed: stripped for matching.
    static let baseFeedWords: Set<String> = ["east"]

    /// A last word that names another coast's schedule: never the base station's, only a station of its own.
    static let shiftedFeedWords: Set<String> = ["west", "pacific"]

    /// Countries whose rows may use another country's feed of the same station when it has none of its own, in order.
    static let sharedFeedCountries: [String: [String]] = ["CA": ["US"]]

    /// ISO 639-1 languages by ISO 3166 country, the country's first language first; for the countries above.
    static let countryLanguages: [String: [String]] = [
        "CA": ["EN", "FR"], "US": ["EN", "ES"], "GB": ["EN"], "IE": ["EN", "GA"], "AU": ["EN"], "NZ": ["EN"]
    ]
}

extension LiveTVGuideStationIndex {
    /// The country a row belongs to, read the way the lineup reads it: the provider's value, then the group, then the name prefix.
    static func country(of channel: LiveTVPrototypeChannel, classifier: inout LiveTVLineupClassifier) -> String? {
        if case .country(let code) = classifier.placement(of: channel) { return code }
        return nil
    }
}
