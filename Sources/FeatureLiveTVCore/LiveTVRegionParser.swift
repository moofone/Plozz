import Foundation

/// The name-reading part of `LiveTVChannelRegion`. Pure and free of the channel model so it can be tested on bare names.
enum LiveTVRegionParser {
    /// A place at the end of the name, ignoring what providers append (quality, state code, call sign, "NEWS"), or a leading "CITY, ST".
    static func places(inRawName raw: String) -> [String] {
        let name = body(of: raw)
        guard !name.isEmpty, !raw.drop(while: \.isWhitespace).hasPrefix("24/7") else { return [] }
        var tokens = tokenize(name)
        if let leading = leadingCityWithState(in: tokens) { return leading }
        let hadBrandSuffix = stripTrailingNoise(&tokens)
        let words = tokens.filter { !separators.contains($0) }.joined(separator: " ")
        if brandsContainingAPlace.contains(where: { words.hasSuffix($0) }) { return [] }
        return trailingPlaces(in: tokens, mayBeOnlyAPlace: hadBrandSuffix)
    }

    // MARK: Normalising

    /// Names that end in a place but are a brand ("TELE QUEBEC"): the place is part of the brand, not the feed's place.
    static let brandsContainingAPlace = ["TELE QUEBEC", "TV5 QUEBEC", "TV 5 QUEBEC", "MADISON SQUARE GARDEN"]

    /// Words that, right before a place, make a title of it ("CAUGHT IN PROVIDENCE", "LADY OF LEBANON", "ALL-OUT ALASKA").
    private static let titleWords: Set<String> = ["IN", "OF", "THE", "ON", "AT", "AND", "&", "OUT", "TO", "FROM"]

    private static let separators: Set<String> = ["/", "-", ",", "(", ")", "[", "]", "|", "–", "—"]
    private static let closers: Set<String> = [")", "]"]

    /// Upper case, accent-free, compatibility-folded (superscript quality tags become plain letters) and without the provider's
    /// "CA EN:" style prefix.
    static func body(of raw: String) -> String {
        var text = raw.decomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive], locale: nil).uppercased()
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[..<colon]
            if prefix.count <= 8, prefix.allSatisfy({ $0.isLetter || $0.isNumber || " &/".contains($0) }) {
                text = String(text[text.index(after: colon)...])
            }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Words with the brackets and separators kept as their own tokens. Apostrophes and full stops vanish ("ST. JOHN'S").
    static func tokenize(_ name: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { tokens.append(word); word = "" } }
        for character in name {
            switch character {
            case "'", "’", ".": continue
            case " ", "_": flush()
            case "/", "-", ",", "(", ")", "[", "]", "|", "–", "—":
                flush(); tokens.append(String(character))
            default: word.append(character)
            }
        }
        flush()
        return tokens
    }

    // MARK: Trailing words that are not part of the place

    private static let noiseWords: Set<String> = [
        "HD", "SD", "FHD", "UHD", "4K", "8K", "RAW", "60FPS", "50FPS", "CITY", "AREA", "LIVE", "DT", "HDTV", "NET", "IP", "HS"
    ]

    /// Words a news brand adds after its city ("BOSTON 25 NEWS", "ATLANTA NEWS FIRST"). A name holding only a place and one of these is a feed.
    private static let brandSuffixWords: Set<String> = ["NEWS", "FIRST", "PLUS", "LOCAL", "CABLE"]

    static let stateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI",
        "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT",
        "VT", "VA", "WA", "WV", "WI", "WY", "DC", "ON", "QC", "BC", "AB", "SK", "MB", "NS", "NB", "NL", "PE"
    ]

    private static let networkWords: Set<String> = ["ABC", "NBC", "CBS", "FOX", "CW", "PBS", "MNT", "PC", "ION"]

    /// A station call sign: four letters starting K, W or C ("KUSA"), or longer with a digital suffix ("KRQEDT2", "WQMCDT3").
    private static func isCallSign(_ word: String) -> Bool {
        guard let first = word.first, "KWC".contains(first), !isPlace(word), word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let stem = word.trimmingCharacters(in: .decimalDigits)
        if (3...4).contains(stem.count), stem.allSatisfy(\.isLetter), word.count - stem.count <= 1 { return true }
        return (5...7).contains(word.count) && (stem.hasSuffix("DT") || stem.hasSuffix("LD") || stem.hasSuffix("CD") || stem.hasSuffix("TV"))
    }

    private static func isNoiseToken(_ token: String) -> Bool {
        if noiseWords.contains(token) || brandSuffixWords.contains(token) { return true }
        if networkWords.contains(token) { return true }
        if token.allSatisfy(\.isNumber) { return true }
        // "A3", "DT2", "1080P": a short mixed run of letters and digits is a feed descriptor.
        return descriptorShape.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    private static let descriptorShape = try! NSRegularExpression(pattern: #"^(?:[A-Z]{1,2}\d{1,2}|\d{3,4}[PI])$"#)

    private static func isDroppableInBrackets(_ word: String) -> Bool {
        if isPlace(word) { return false }
        return isCallSign(word) || word.count <= 5 && word.allSatisfy(\.isLetter) || isNoiseToken(word)
    }

    /// Removes what a provider appends after the place; true when that included a news-brand word.
    private static func stripTrailingNoise(_ tokens: inout [String]) -> Bool {
        var brandSuffix = false
        defer { dropUnknownLastOfList(&tokens) }
        while let last = tokens.last, tokens.count > 0 {
            if separators.contains(last) && !closers.contains(last) { tokens.removeLast(); continue }
            if closers.contains(last) {
                guard let open = tokens.lastIndex(where: { $0 == "(" || $0 == "[" }) else { return brandSuffix }
                let inner = Array(tokens[(open + 1)..<(tokens.count - 1)])
                let words = inner.filter { !separators.contains($0) }
                if !endsInPlace(inner), !endsInPlace(inner.last.map { stateCodes.contains($0) } == true ? Array(inner.dropLast()) : inner),
                   words.allSatisfy(isDroppableInBrackets) || words.contains(where: isCallSign) { tokens.removeSubrange(open...) } else { tokens.removeLast(); tokens.remove(at: open) }
                continue
            }
            if endsInPlace(tokens) { return brandSuffix }
            if brandSuffixWords.contains(last) { brandSuffix = true }
            if let glued = removingGluedQuality(last) { tokens[tokens.count - 1] = glued; continue }
            if isNoiseToken(last) || (isCallSign(last) && tokens.count > 1) { tokens.removeLast(); continue }
            if stateCodes.contains(last), tokens.count > 1, endsInPlace(Array(tokens.dropLast())) { tokens.removeLast(); continue }
            return brandSuffix
        }
        return brandSuffix
    }

    /// "GREENVILLE / SPARTANBURG / ASHVILLE": a last item of a slash list that is no known place is dropped when the items before are places.
    private static func dropUnknownLastOfList(_ tokens: inout [String]) {
        guard tokens.count >= 3, tokens[tokens.count - 2] == "/", !separators.contains(tokens[tokens.count - 1]),
              !endsInPlace(tokens), endsInPlace(Array(tokens.dropLast(2))) else { return }
        tokens.removeLast(2)
    }

    /// "MONTREALHD": a quality tag written straight after the last word.
    private static func removingGluedQuality(_ word: String) -> String? {
        for suffix in ["FHD", "UHD", "HD", "SD"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            let stem = String(word.dropLast(suffix.count))
            if isPlace(stem) { return stem }
        }
        return nil
    }

    // MARK: Places

    private struct Entry { let canonical: String; let words: Int; let type: Character }

    /// Normalised term → canonical name; built once.
    private static let index: [String: Entry] = {
        var result: [String: Entry] = [:]
        for line in LiveTVPlaceNames.table.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 3, let type = parts[2].first else { continue }
            let key = normalizedKey(parts[0])
            if result[key] == nil { result[key] = Entry(canonical: parts[1], words: key.split(whereSeparator: { $0 == " " || $0 == "-" }).count, type: type) }
        }
        return result
    }()

    private static let maximumWords: Int = index.values.map(\.words).max() ?? 1

    static func normalizedKey(_ term: String) -> String {
        let text = term.decomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive], locale: nil).uppercased()
        return key(of: tokenize(text)[...])
    }

    /// Words joined by a space, a hyphen joining its neighbours without one: "WINSTON-SALEM" and "WILKES BARRE" are different keys.
    private static func key<S: Sequence>(of tokens: S) -> String where S.Element == String {
        var result = ""
        var glue = false
        for token in tokens {
            if token == "-" { glue = true; continue }
            if separators.contains(token) { continue }
            if !result.isEmpty { result += glue ? "-" : " " }
            glue = false
            result += token
        }
        return result
    }

    private static func isPlace(_ word: String) -> Bool { index[word] != nil }

    private static func endsInPlace(_ tokens: [String]) -> Bool {
        var end = tokens.count
        while end > 0, separators.contains(tokens[end - 1]), !closers.contains(tokens[end - 1]) { end -= 1 }
        return placeEnding(at: end, in: tokens) != nil
    }

    /// The longest place whose last word is at `end - 1`: its first token's index, canonical name and type. A hyphen may sit inside
    /// a place ("WINSTON-SALEM").
    private static func placeEnding(at end: Int, in tokens: [String]) -> (start: Int, entry: Entry)? {
        guard end > 0, !separators.contains(tokens[end - 1]) else { return nil }
        for size in stride(from: min(maximumWords * 2, end), through: 1, by: -1) {
            let slice = tokens[(end - size)..<end]
            guard let first = slice.first, !separators.contains(first) else { continue }
            if slice.contains(where: { separators.contains($0) && $0 != "-" }) { continue }
            if let entry = index[key(of: slice)] { return (end - size, entry) }
        }
        return nil
    }

    /// The run of places at the end of the tokens ("FORT WORTH", then "DALLAS" before it), joined by a slash, hyphen, comma, a bracket
    /// group or nothing. A name that is only a place has no brand and so no feed.
    private static func trailingPlaces(in tokens: [String], mayBeOnlyAPlace: Bool) -> [String] {
        var end = tokens.count
        var found: [(entry: Entry, separated: Bool)] = []
        var separated = false
        while end > 0 {
            var place = placeEnding(at: end, in: tokens)
            var wrapped = false
            if place == nil, end >= 3, closers.contains(tokens[end - 1]), let inside = placeEnding(at: end - 1, in: tokens),
               inside.start > 0, tokens[inside.start - 1] == "(" || tokens[inside.start - 1] == "[" {
                place = (inside.start - 1, inside.entry); wrapped = true
            }
            guard let place else { break }
            found.insert((place.entry, separated || wrapped), at: 0)
            end = place.start
            separated = false
            if end > 0, ["/", "-", ",", "|"].contains(tokens[end - 1]) { separated = tokens[end - 1] != ","; end -= 1 }
            if end > 0, found.count == 1, !separated, wrapped == false, tokens[end - 1] == "-" { separated = true }
        }
        guard !found.isEmpty, end > 0 || mayBeOnlyAPlace else { return [] }
        let before = tokens[..<end].filter { !separators.contains($0) }
        if before.last == "THE", before.count >= 2, titleWords.contains(before[before.count - 2]) { return [] }
        if before.last != "THE", let word = before.last, titleWords.contains(word) { return [] }
        // A metropolitan area stands for the city beside it; a state after a city only qualifies it.
        var entries = found.map(\.entry)
        // A carrier written before the place ("ROGERS OTTAWA") is not a place.
        if entries.count >= 2, entries[0].canonical.split(separator: " ").count == 1,
           LiveTVTMDbLogoMatcher.carrierWords.contains(entries[0].canonical.lowercased()) { entries.removeFirst(); found.removeFirst() }
        if entries.count == 2, entries.contains(where: { $0.type == "m" }) { entries = entries.filter { $0.type == "m" } }
        if entries.count >= 2, let last = found.last, "sf".contains(last.entry.type), !last.separated, found[found.count - 2].entry.type == "p" {
            entries.removeLast()
        }
        var names: [String] = []
        for entry in entries where names.last != entry.canonical { names.append(entry.canonical) }
        return names
    }

    /// "LANSING, MI WILX NBC 10": a city, a comma and a state code open the name.
    private static func leadingCityWithState(in tokens: [String]) -> [String]? {
        guard let comma = tokens.firstIndex(of: ","), comma > 0, comma + 1 < tokens.count, stateCodes.contains(tokens[comma + 1]),
              let place = placeEnding(at: comma, in: tokens), place.start == 0 else { return nil }
        return [place.entry.canonical]
    }
}
