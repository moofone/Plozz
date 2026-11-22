import Foundation

/// The US stations of a guide, by call sign and subchannel, read once when the station index is built.
///
/// A guide that spells its stations the way `WTXFTV291.us@HD` / `FOX (WTXF) Philadelphia, PA HD` does names the call sign in the
/// display name's brackets (`(WTVD)`, `(WTVD-DT2)`, `(WTVD3)`, `(KJCX-LD)`) and, failing that, in the id (`<CALLSIGN><TV|DT|LD|CD>
/// <channel digits><subchannel digit>`). A row matches a station only when
/// 1. the call sign and the subchannel agree (`WTVD` is the main service, `WTVD-DT2` another one: Localish; a main row never takes
///    a station that exists only as a subchannel, nor the other way round; `-LD`/`-CD` low-power stations are not the full-power one);
/// 2. when the row names a network (ABC, CBS, NBC, FOX, CW, PBS, MNT, ION, Telemundo, Univision…), the station's own network word is
///    one of them. A row naming two networks (`NBC 10 (WWSI) TELEMUNDO`) is judged by the station: it matches only a station of one
///    of those two, so the Telemundo station but not an NBC station of the same call sign;
/// 3. exactly one station claims that call sign and subchannel. `@HD` and `@SD` of one id are one station (HD read first); `@East` is
///    the base feed of its id; `@West`, `@Pacific`, `@Plus1` and any other feed are other schedules and are never entered, so a row
///    that asks for them (which the matcher already keeps off station reads) is never given the base.
/// A call sign the table knows but cannot serve for the row is a refusal, not a reason to look further: a wrong guide is worse than none.
struct LiveTVGuideCallSignTable: Sendable {
    struct Station: Sendable {
        /// Station ids to read, the preferred feed first (`WTVD111.us@HD`, then `WTVD111.us@SD`).
        let ids: [String]
        /// The network word before the brackets in the display name, canonical (`fox`); nil when the name has none.
        let network: String?
        /// The words of the station's display names (`kiro`, `seattle`, `wa`); a call sign a row names alone is confirmed by them.
        let nameWords: Set<String>
        /// The station's own id names the call sign (`WTIC.us`, `WZTVDT2.us`, `WTICTV611.us`), not only its display name.
        let idNamesSign: Bool
    }

    enum Answer: Equatable, Sendable {
        /// The guide has no station of that call sign (any subchannel): the caller's other rules decide.
        case unknown
        /// The guide knows the call sign but has no single station that serves this row.
        case refused
        case station(ids: [String])
    }

    private var stations: [String: [Station]] = [:]
    /// Call signs (without subchannel) of every station read, including the ones left out as ambiguous.
    private var knownBases: Set<String> = []
    private(set) var ambiguousStemCount = 0

    var isEmpty: Bool { knownBases.isEmpty }

    init(guideChannels: [String: [String]]) {
        // One entry per id without its feed marker (`WTVD111.us`); its feeds are read in a fixed order.
        var feeds: [String: (sign: LiveTVGuideStationIndex.CallSign, network: String?, words: Set<String>, idNamesSign: Bool, ids: [(rank: Int, id: String)])] = [:]
        var conflicted = Set<String>()
        for (id, names) in guideChannels {
            guard let parts = LiveTVCallSignData.idParts(of: id), parts.isUS else { continue }
            guard let rank = LiveTVCallSignData.feedRank[parts.feed ?? ""] else {
                // Another schedule of the station (`@West`, `@Plus1`): never served, but the call sign is known, so a row it
                // cannot serve is refused rather than given the base station by another rule.
                if let sign = names.lazy.compactMap(LiveTVCallSignData.callSign(inDisplayName:)).first
                    ?? LiveTVCallSignData.callSign(ofStationID: parts.stem) { knownBases.insert(sign.base) }
                continue
            }
            let fromName = names.lazy.compactMap(LiveTVCallSignData.callSign(inDisplayName:)).first
            let fromID = LiveTVCallSignData.callSign(ofStationID: parts.stem)
            let sign: LiveTVGuideStationIndex.CallSign
            switch (fromName, fromID) {
            case (nil, let id?): sign = id
            case (let name?, nil): sign = name
            case (nil, nil): continue
            case let (name?, id?):
                // The name's bracket is the station's own call sign (the id may carry the licence it was renamed from, or a
                // translator's `D`). A name that gives no subchannel while the id gives one (`WJLP338`) leaves the service unknown.
                if name.full == name.base, id.full != id.base {
                    for base in [name.base, id.base] { knownBases.insert(base) }
                    conflicted.insert(parts.stem)
                    continue
                }
                sign = name
            }
            knownBases.insert(sign.base)
            // The network is read only from a name that carries the call sign: another name of the id (`WTVA.us` named `ABC GOOD
            // MORNING AMERICA` by a lineup) says nothing about the station.
            let network = names.first(where: { LiveTVCallSignData.callSign(inDisplayName: $0) != nil })
                .flatMap(LiveTVCallSignData.network(inDisplayName:))
            var entry = feeds[parts.stem] ?? (sign, network, Set(names.flatMap(LiveTVGuideStationIndex.words(of:))), fromID?.base == sign.base && fromID?.full == sign.full, [])
            entry.ids.append((rank, id))
            feeds[parts.stem] = entry
        }
        for (stem, entry) in feeds where !conflicted.contains(stem) {
            let ordered = entry.ids.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }.map(\.id)
            stations[entry.sign.full, default: []].append(Station(ids: ordered, network: entry.network, nameWords: entry.words, idNamesSign: entry.idNamesSign))
        }
        for (key, claimants) in stations where claimants.count > 1 {
            // Two ids claim one call sign and subchannel. The one whose own id names it is the station (a guide that lists a
            // mislabelled id, `KHON.us` named `FOX (WTIC)`, beside `WTIC.us`); with none or several such, the table serves neither.
            let own = claimants.filter(\.idNamesSign)
            if own.count == 1 { stations[key] = own } else {
                ambiguousStemCount += claimants.count
                stations[key] = nil
            }
        }
    }

    /// The main-service station of a call sign a row may name without brackets or a network word (`KIRO 7 NEWS`, `WNBC`), when the
    /// row's other words are numbers, filler or words of the station's own name (`KTLA LOS ANGELES HD`), so `WGN AMERICA` is not
    /// the Chicago station. Only a call sign the guide has; two candidates in one row give nothing.
    func freeCallSignAnswer(words: [String], rowNetworks: Set<String>) -> Answer {
        var candidate: (word: String, station: Station)?
        for word in words where word.utf8.count == 3 || word.utf8.count == 4 {
            guard let first = word.utf8.first, first == 0x6B || first == 0x77,
                  let station = stations[word]?.first, !LiveTVGuideStationData.notCallSigns.contains(word.uppercased()) else { continue }
            if candidate != nil { return .unknown }
            candidate = (word, station)
        }
        guard let (word, station) = candidate else { return .unknown }
        for other in words where other != word {
            // `A3`, `D12`: a provider's own marker (a letter and digits); numbers are channel numbers.
            guard other.first?.isNumber != true, !(other.count > 1 && other.dropFirst().allSatisfy(\.isNumber)),
                  !LiveTVCallSignData.fillerWords.contains(other),
                  LiveTVCallSignData.networks[other] == nil, !station.nameWords.contains(other) else { continue }
            return .refused
        }
        if !rowNetworks.isEmpty, let network = station.network, !rowNetworks.contains(network) { return .refused }
        return .station(ids: station.ids)
    }

    /// The station for a row's call sign and the networks it names (canonical words; empty when it names none).
    func answer(for sign: LiveTVGuideStationIndex.CallSign, rowNetworks: Set<String>) -> Answer {
        guard knownBases.contains(sign.base) else { return .unknown }
        guard let station = stations[sign.full]?.first else { return .refused }
        if !rowNetworks.isEmpty, let network = station.network, !rowNetworks.contains(network) { return .refused }
        return .station(ids: station.ids)
    }

    var stationCount: Int { stations.values.reduce(0) { $0 + $1.count } }
}

/// The call-sign tables of the matcher as data, and the readers that use them. Nothing here names a guide or a provider.
enum LiveTVCallSignData {
    /// Feeds of one station id that carry its own schedule, in reading order: HD before the id without a feed, SD, then East.
    /// `@West`, `@Pacific`, `@Plus1` and every other feed are absent: they are other schedules.
    static let feedRank: [String: Int] = ["HD": 0, "": 1, "SD": 2, "East": 3]

    /// Network words as a guide or a lineup spells them → one canonical word.
    static let networks: [String: String] = [
        "abc": "abc", "nbc": "nbc", "cbs": "cbs", "fox": "fox", "cw": "cw", "pbs": "pbs", "ion": "ion",
        "mnt": "mnt", "mynetworktv": "mnt", "mynetwork": "mnt",
        "telemundo": "telemundo", "univision": "univision", "uni": "univision", "unimas": "unimas",
        "metv": "metv", "estrella": "estrella", "antenna": "antenna", "cozi": "cozi", "charge": "charge", "localish": "localish"
    ]

    /// Words a local's row carries besides its call sign, city and network.
    static let fillerWords: Set<String> = ["hd", "uhd", "fhd", "sd", "4k", "tv", "news", "my", "raw", "us"]

    /// Words of a row that name a network, canonical.
    static func networks(inWords words: [String]) -> Set<String> {
        var found = Set<String>()
        for word in words { if let network = networks[word] { found.insert(network) } }
        return found
    }

    /// The network a display name carries, canonical. A name that starts `FOX (WTXF) …` is labelled by the word before its brackets; a
    /// single unknown word there (`ROAR (KOKI)`) is a label of its own that equals no row's network. Longer text before the brackets
    /// (a lineup row's own name, `US: NBC 5 ALEXANDRIA LA (KALB)`; a licensee, `Connecticut Public Television (WEDW)`) is read for
    /// the first network word it holds; with none the station has no network to compare.
    static func network(inDisplayName name: String) -> String? {
        guard let open = name.firstIndex(where: { $0 == "(" || $0 == "[" }) else { return nil }
        let label = name[..<open].trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, !label.contains(where: \.isWhitespace), let key = LiveTVGuideStationIndex.key(of: label) {
            return networks[key] ?? key
        }
        return LiveTVGuideStationIndex.words(of: label).lazy.compactMap { networks[$0] }.first
    }

    struct IDParts {
        /// The id without its `@feed`, as written (`WTVD111.us`).
        let stem: String
        let feed: String?
        /// The id's region suffix is `.us`.
        let isUS: Bool
    }

    static func idParts(of id: String) -> IDParts? {
        var text = Substring(id.trimmingCharacters(in: .whitespacesAndNewlines))
        var feed: String?
        if let at = text.firstIndex(of: "@") {
            feed = String(text[text.index(after: at)...])
            text = text[..<at]
        }
        guard !text.isEmpty else { return nil }
        let isUS = text.lowercased().hasSuffix(".us")
        return IDParts(stem: String(text), feed: feed, isUS: isUS)
    }

    // MARK: Readers

    /// The call sign in the first bracketed part of a display name that reads as one (`(WTVD-DT2)`, `[KJCX-LD]`).
    static func callSign(inDisplayName name: String) -> LiveTVGuideStationIndex.CallSign? {
        var current = ""
        var inside = false
        for character in name {
            switch character {
            case "(", "[": inside = true; current = ""
            case ")", "]":
                if inside, let sign = callSign(ofToken: current, bracketed: true) { return sign }
                inside = false
            default: if inside { current.append(character) }
            }
        }
        return nil
    }

    /// `WTXFTV291.us` and `K44JPD1.us`: the call sign, an optional `TV`/`DT`/`LD`/`CD`, and digits. Two or more digits are the channel
    /// number and the subchannel (`291` is 29, subchannel 1); one digit after `DT`/`LD`/`CD` is the subchannel itself.
    static func callSign(ofStationID stem: String) -> LiveTVGuideStationIndex.CallSign? {
        let name = stem.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? stem
        // An id that is the call sign alone (`WTIC`, `WZTVDT2`, `KRQE-DT2`).
        // (Two or more trailing digits are a channel number and a subchannel, read below: `KCWCDT41` is channel 4, subchannel 1.)
        if name.reversed().prefix(while: \.isNumber).count <= 1, let sign = callSign(ofToken: name, bracketed: false) { return sign }
        let bytes = Array(name.utf8)
        var end = bytes.count
        while end > 0, isDigit(bytes[end - 1]) { end -= 1 }
        let digits = bytes[end...]
        guard !digits.isEmpty, end >= 3 else { return nil }
        var letters = String(decoding: bytes[..<end], as: UTF8.self).uppercased()
        var suffix = ""
        // `WTXFTV` ends in `TV`; a four-letter call sign such as `WTVD` or `KDTV` has no suffix.
        if letters.count >= 5, let found = ["TV", "DT", "LD", "CD", "LP"].first(where: letters.hasSuffix) {
            suffix = found
            letters.removeLast(2)
        }
        // A digital translator's id adds a `D` to its call sign (`K44JPD1` is K44JP-D).
        if letters.count == 6, isDigit(Array(letters.utf8)[1]), letters.hasSuffix("D") { letters.removeLast() }
        guard let base = callSignBase(letters) else { return nil }
        let lowPower = suffix == "LD" || suffix == "CD" || suffix == "LP"
        let subchannel: Int
        if digits.count == 1 {
            // After a digital suffix, or a translator's call sign (`K44JPD1`, whose channel is in the letters), the single digit is
            // the subchannel; after a plain call sign it is only a channel number.
            let translator = base.utf8.dropFirst().first.map(isDigit) == true
            guard suffix == "DT" || lowPower || translator, let value = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
            subchannel = value
        } else {
            subchannel = Int(String(decoding: digits.suffix(1), as: UTF8.self)) ?? 1
        }
        return makeSign(identity: lowPower ? base + suffix.lowercased() : base, subchannel: subchannel)
    }

    /// A call sign token: `WTVD`, `WTVD-DT2`, `KRQEDT2`, `WTOV-D2`, `WTVD.2`, `KJCX-LD`, and `WTVD3` (digits joined to the letters
    /// only inside brackets, so a free word such as `WORLD2` is no call sign).
    static func callSign(ofToken token: String, bracketed: Bool) -> LiveTVGuideStationIndex.CallSign? {
        let upper = token.trimmingCharacters(in: .whitespaces).uppercased()
        let bytes = Array(upper.utf8)
        guard bytes.count >= 3, bytes.count <= 12, bytes[0] == 0x4B || bytes[0] == 0x57,
              !LiveTVGuideStationData.notCallSigns.contains(upper) else { return nil }
        // `K`/`W` and two or three letters, or a translator's `K44JPD`; the longer letter run is tried first (`WTVD`, then `WTV`+`D`).
        let lead = bytes.count > 3 && isDigit(bytes[1]) && isDigit(bytes[2]) ? 3 : 1
        for count in [3, 2] where lead + count <= bytes.count {
            guard bytes[lead..<(lead + count)].allSatisfy(isLetter) else { continue }
            let base = String(decoding: bytes[..<(lead + count)], as: UTF8.self).lowercased()
            if let sign = readRest(bytes[(lead + count)...], base: base, bracketed: bracketed) { return sign }
        }
        return nil
    }

    private static func readRest(_ rest: ArraySlice<UInt8>, base: String, bracketed: Bool) -> LiveTVGuideStationIndex.CallSign? {
        guard !rest.isEmpty else { return makeSign(identity: base, subchannel: 1) }
        var text = String(decoding: rest, as: UTF8.self)
        let separated = text.hasPrefix("-") || text.hasPrefix(".")
        if separated { text.removeFirst() }
        func subchannel(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.count <= 2, value.allSatisfy(\.isNumber) else { return nil }
            return Int(value)
        }
        if separated {
            if ["TV", "DT", "D"].contains(text) { return makeSign(identity: base, subchannel: 1) }
            if let value = subchannel(Substring(text)) { return makeSign(identity: base, subchannel: value) }
            if text.hasPrefix("D"), let value = subchannel(text.dropFirst(text.hasPrefix("DT") ? 2 : 1)) {
                return makeSign(identity: base, subchannel: value)
            }
            for kind in ["LD", "LP", "CD", "CA"] where text.hasPrefix(kind) {
                let tail = text.dropFirst(2)
                if tail.isEmpty { return makeSign(identity: base + kind.lowercased(), subchannel: 1) }
                if let value = subchannel(tail) { return makeSign(identity: base + kind.lowercased(), subchannel: value) }
            }
            return nil
        }
        if text.hasPrefix("DT") {
            let tail = text.dropFirst(2)
            if tail.isEmpty { return bracketed ? makeSign(identity: base, subchannel: 1) : nil }
            return subchannel(tail).map { makeSign(identity: base, subchannel: $0) }
        }
        if bracketed, let value = subchannel(Substring(text)) { return makeSign(identity: base, subchannel: value) }
        return nil
    }

    /// Main service (subchannel 1 or none) is the bare identity; `WTVD` subchannel 2 is `wtvddt2`.
    private static func makeSign(identity: String, subchannel: Int) -> LiveTVGuideStationIndex.CallSign {
        .init(full: subchannel <= 1 ? identity : identity + "dt\(subchannel)", base: identity)
    }

    private static func callSignBase(_ letters: String) -> String? {
        let bytes = Array(letters.utf8)
        guard bytes.count >= 3, bytes.count <= 6, bytes[0] == 0x4B || bytes[0] == 0x57 else { return nil }
        if bytes.count >= 5, isDigit(bytes[1]), isDigit(bytes[2]) {
            guard bytes[3...].allSatisfy(isLetter), bytes.count - 3 <= 3 else { return nil }
        } else {
            guard bytes[1...].allSatisfy(isLetter), bytes.count <= 4 else { return nil }
        }
        let base = letters.lowercased()
        return LiveTVGuideStationData.notCallSigns.contains(letters) ? nil : base
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isLetter(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
}
