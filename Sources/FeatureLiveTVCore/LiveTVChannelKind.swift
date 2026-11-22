import Foundation

/// What kind of lineup row a channel is, for logo matching. Computed from the name and the provider's
/// group labels alone, once per catalog build.
public enum LiveTVChannelKind: String, Equatable, Sendable {
    /// A decorated line that only labels a run of channels ("## 24/7 ACTION/ADVENTURE ##"); it is not a channel.
    case sectionMarker
    /// A dated game, PPV slot or bundle. It is not a channel, so no logo is matched (it belongs to the Events filter).
    case event
    /// A radio station inside a TV group ("CA: CJWV Oldies 96.7 FM", "Best Hits Radio 80's"). It has no TV guide.
    case radio
    /// A 24/7 single-show channel ("24/7: NCIS"); its logo is the show's title logo.
    case showLoop
    /// A free ad-supported streaming channel or provider-curated stream (AT&T, PRIME, RK, TUBI prefixes).
    case fast
    /// Everything else: a linear channel.
    case linear

    /// Provider name prefixes that mark FAST/streaming lineups, for a row whose name the guide does not know as a station.
    /// Evidence: the export's `AT&T:` (846 rows), `PRIME:` (1,032), `RK:` (652) and `TUBI:` (152) prefixes sit in groups of the same
    /// names (`RK:` in `US| ROKU`, which the package rule of `IPTVChannelName.packagePrefix` cannot corroborate).
    static let fastPrefixes: Set<String> = ["AT&T", "PRIME", "RK", "TUBI"]

    private static let shelfName = LiveTVNameRegex(#"\b(ORIGINALS?|PREMIERE|SERIES|REPLAY)\s+\d{1,2}\b|\bCINEMANIA\b"#, caseInsensitive: true)
    private static let oneplayPrefix = LiveTVNameRegex(#"^ONEPLAY\s*[-:]?\s*"#, caseInsensitive: true)

    /// `stations` and `country` are for a guide-aware caller: a row filed under a package label (`PRIME:` in `CA| PRIME`,
    /// `IPTVChannelName.packagePrefix`) is judged by the name after the label, and a name the guide has a station for is a linear
    /// channel, not FAST (`PRIME: GLOBAL MARITIMES` is the station `CA EN: GLOBAL MARITIMES HD` is). `country` is read only for such rows.
    public static func classify(
        name: String, groups: [String], stations: LiveTVGuideStationIndex? = nil, country: @autoclosure () -> String? = nil
    ) -> LiveTVChannelKind {
        if isSectionMarker(name: name, groups: groups) { return .sectionMarker }
        if isEvent(name: name, groups: groups) { return .event }
        if isRadio(name: name) { return .radio }
        if showLoopTitle(name: name, groups: groups) != nil { return .showLoop }
        if let package = IPTVChannelName.packagePrefix(in: name, groups: groups) {
            if shelfName.matches(package.rest) { return .fast }
            if let stations, stations.resolution(
                facts: LiveTVGuideStationIndex.RowFacts(name: name, groups: groups), country: country()) != nil { return .linear }
        }
        if let prefix = namePrefix(name), fastPrefixes.contains(prefix) { return .fast }
        if shelfName.matches(name) {
            return .fast
        }
        return .linear
    }

    /// A section header (`IPTVChannelName.isSectionMarker`, rule C) against the row's own groups, or alone when it has none.
    public static func isSectionMarker(name: String, groups: [String]) -> Bool {
        guard let first = name.first(where: { !$0.isWhitespace }), first == "#" || first == "*" else { return false }
        if groups.isEmpty { return IPTVChannelName.isSectionMarker(name: name, groupTitle: nil) }
        return groups.contains { IPTVChannelName.isSectionMarker(name: name, groupTitle: $0) }
    }

    // MARK: Radio

    /// A radio frequency (`96.7 FM`, `FM 96.7`, `1010 AM`) or a lone `FM` word.
    private static let frequency = LiveTVNameRegex(#"\b\d{2,4}(?:[.,]\d)?\s*(?:FM|AM)\b|\b(?:FM|AM)\s*\d{2,4}[.,]\d\b|\bFM\b"#, caseInsensitive: true)

    /// The word `RADIO` in a TV brand's own name does not make a radio station: the word after it, folded.
    static let radioBrandFollowers: Set<String> = ["CANADA", "TELE", "TELEVISION", "TV"]

    /// Radio by signal: a frequency, or the word `RADIO` that is not the start of a TV brand (`ICI RADIO-CANADA TÉLÉ`).
    public static func isRadio(name: String) -> Bool {
        let cleaned = IPTVChannelName.split(name).name
        if frequency.matches(cleaned) { return true }
        let words = LiveTVGuideStationIndex.words(of: cleaned)
        for (index, word) in words.enumerated() where word == "radio" {
            let next = index + 1 < words.count ? words[index + 1].uppercased() : nil
            if let next, radioBrandFollowers.contains(next) { continue }
            return true
        }
        return false
    }

    // MARK: Replay and VOD slots

    private static let replayName = LiveTVNameRegex(#"\b(SERIES INFO|RED BUTTON|REPLAYS?|HIGHLIGHTS|OFF AIR|OVERFLOW\s*\d*)\b"#, caseInsensitive: true)
    private static let replayGroup = LiveTVNameRegex(#"\b(REPLAYS?|IPLAYER|ON DEMAND|VOD)\b"#, caseInsensitive: true)

    /// A slot that replays, informs or overflows rather than being a channel, by name; or, for a row with no guide id of its own,
    /// a VOD/replay pack by its group.
    public static func isReplaySlot(name: String, groups: [String], hasGuideID: Bool) -> Bool {
        replayName.matches(name) || (!hasGuideID && groups.contains { replayGroup.matches(IPTVChannelName.foldingSuperscripts($0)) })
    }

    // MARK: Events

    /// An event slot, by the single rule `LiveTVEventSlotClassifier.isEventSlot` (shared with the Events filter).
    public static func isEvent(name: String, groups: [String]) -> Bool {
        LiveTVEventSlotClassifier.isEventSlot(name: name, groups: groups)
    }

    /// Whether logo matching treats the row as an event (no network, no logo): an event slot that no network brand names.
    public static func isEventForLogos(name: String, groups: [String]) -> Bool {
        isEvent(name: name, groups: groups) && !LiveTVEventSlotClassifier.isNumberedLiveEventSlot(name: name)
    }

    static func tokens(of text: String) -> [String] {
        text.decomposedStringWithCompatibilityMapping.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "/" })
            .map(String.init)
    }

    // MARK: 24/7 loops

    /// Group labels whose rows are named for a single show, though they do not say 24/7. Evidence: "US: COBRA KAI 4K",
    /// "US: BLACK MIRROR 4K" and "US: NCIS: 4K" in `US| CINEMA TV SHOWS` (312 rows) and `US| NETFLIX ON AIR` (134 rows).
    static let showGroupLabels = ["CINEMA TV SHOWS", "NETFLIX ON AIR"]

    /// The show title of a 24/7 single-show channel, or `nil` when the row is not one. A loop has a `24/7:` name
    /// prefix or sits in a group whose label starts with `24/7` (after the country prefix).
    /// `includingActors`: the "24/7 MOVIES/ACTORS" rows too. Their titles are no use for a logo search, but they are loops: the guide
    /// shows each as one cell named for its actor or film run.
    public static func showLoopTitle(name: String, groups: [String], includingActors: Bool = false) -> String? {
        // "## 24/7 COMEDY ##" sits in the group "24/7 COMEDY" but labels the run; it is a header, not a show.
        guard !isSectionMarker(name: name, groups: groups) else { return nil }
        let hasPrefix = namePrefix(name) == "24/7"
        let inGroup = groups.contains { group in
            let label = group.split(separator: "|", maxSplits: 1).last.map(String.init) ?? group
            let folded = label.decomposedStringWithCompatibilityMapping.uppercased().trimmingCharacters(in: .whitespaces)
            return folded.hasPrefix("24/7") || showGroupLabels.contains { folded.hasPrefix($0) }
        }
        guard hasPrefix || inGroup else { return nil }
        // "24/7 MOVIES/ACTORS" (171 rows) names actors and film genres, not shows: a TV search finds 1% of them.
        if !includingActors, groups.contains(where: { $0.uppercased().contains("MOVIES/ACTORS") }) { return nil }
        // Group labels such as "24/7 PPV" or "24/7 DISNEY+" name a theme, not a show; the row's own title is used.
        // "ONEPLAY Paw Patrol" (120 rows in `24/7 ONEPLAY`): the leading word is the playlist's own brand, not part of the title.
        var title = oneplayPrefix.replacing(LiveTVTMDbLogoMatcher.primaryKey(IPTVChannelName.split(name).name))
        // "UK: 24/7 24/7 LAW AND ORDER": the provider repeats the loop marker inside the name; the show is what follows it.
        while title.uppercased().hasPrefix("24/7"), let rest = Optional(String(title.dropFirst(4)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":-")))),
              !rest.isEmpty {
            title = rest
        }
        return title.isEmpty ? nil : title
    }

    /// The text before the first `:` or `|` when it is short ("AT&T", "24/7", "CA EN"), upper-cased.
    static func namePrefix(_ name: String) -> String? {
        guard let end = name.firstIndex(where: { $0 == ":" || $0 == "|" }) else { return nil }
        let prefix = name[name.startIndex..<end].trimmingCharacters(in: .whitespaces).uppercased()
        return prefix.isEmpty || prefix.count > 12 ? nil : prefix
    }
}
