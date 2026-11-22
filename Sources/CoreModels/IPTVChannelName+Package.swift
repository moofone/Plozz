import Foundation

extension IPTVChannelName {
    /// A provider package label at the start of a name: `PRIME` in `PRIME: GLOBAL MARITIMES ᴿᴬᵂ` filed under `CA| PRIME ᴿᴬᵂ ⁶⁰ᶠᵖˢ`.
    ///
    /// The rule is a property of the row itself: the text before the first `:` is one word that starts with a letter and is not a
    /// country or language code (those keep the prefix rule of `split`), and it equals (letter case ignored) the first word of one of
    /// the row's own group labels after the group's country and trailing descriptors. The label then names the package the provider
    /// filed the row in, not the station, so it leaves the name. Nothing here knows a provider or a brand.
    /// `rest` is the name after the colon; a label with nothing after it is not a package prefix.
    public static func packagePrefix(in name: String, groups: [String]) -> (label: String, rest: String)? {
        guard !groups.isEmpty, let colon = name.firstIndex(of: ":") else { return nil }
        // Nearly every row fails on the shape of its first word, before any group is read.
        guard name.utf8.distance(from: name.startIndex, to: colon) <= 16 else { return nil }
        let word = name[name.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard (2...12).contains(word.count), let first = word.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic,
              !word.contains(where: \.isWhitespace), !word.contains("|") else { return nil }
        if word.utf8.count == 2, let key = pairKey(word), regionCodes.contains(key) || languageCodes.contains(key) || word.uppercased() == "UK" {
            return nil
        }
        let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let folded = word.uppercased()
        for group in groups where groupFirstWord(group) == folded {
            return (folded, rest)
        }
        return nil
    }

    /// The first word of a group label, upper case, after its country prefix and trailing descriptors (`US| AT&T ᴿᴬᵂ` is `AT&T`).
    private static func groupFirstWord(_ group: String) -> String? {
        let label = split(group).name
        return label.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() }
    }

    /// `split(_:)` with the package prefix the row's groups corroborate taken off the name and kept as a `.package` tag
    /// (after any country and language tag, before the feed descriptors).
    public static func split(_ name: String, groups: [String]) -> (name: String, tags: [IPTVChannelTag]) {
        guard let package = packagePrefix(in: name, groups: groups) else { return split(name) }
        var result = split(package.rest)
        let leading = result.tags.prefix { $0.country != nil || $0.language != nil }.count
        result.tags.insert(.package(package.label), at: leading)
        return result
    }
}
