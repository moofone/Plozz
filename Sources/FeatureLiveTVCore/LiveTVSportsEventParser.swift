import Foundation

/// A sports league named by an explicit bracket tag in a channel name.
public enum LiveTVSportsLeague: String, CaseIterable, Sendable, Codable {
    case mls, nba, wnba, nfl, nhl, mlb, uefaChampionsLeague, uefaEuropaLeague
    /// Added in round 2; each item was checked on 2026-11-16 to carry a `logo image` (P154). The Western Hockey League
    /// (Q849096), ATP (Q744089) and rugby have none and are deliberately absent: those events get a sport glyph.
    case cfl, ncaab, ncaaf, wta

    /// SF Symbol drawn for an event channel that has no better logo.
    public var glyphSymbolName: String {
        switch self {
        case .mls, .uefaChampionsLeague, .uefaEuropaLeague: "soccerball"
        case .nba, .wnba, .ncaab: "basketball"
        case .nfl, .cfl, .ncaaf: "football"
        case .nhl: "hockey.puck"
        case .mlb: "baseball"
        case .wta: "tennis.racket"
        }
    }

    /// The league's Wikidata item; its `logo image` (P154) is the league badge.
    public var wikidataItem: String {
        switch self {
        case .mls: "Q18543"
        case .nba: "Q155223"
        case .wnba: "Q2593221"
        case .nfl: "Q1215884"
        case .nhl: "Q1215892"
        case .mlb: "Q1163715"
        case .uefaChampionsLeague: "Q18756"
        case .uefaEuropaLeague: "Q18760"
        case .cfl: "Q1032175"
        case .ncaab: "Q996954"
        case .ncaaf: "Q271805" // the NCAA's own logo: Wikidata has no logo for college football itself
        case .wta: "Q948442"
        }
    }

    /// The closed table of tags a provider writes in brackets, such as `(MLS)`.
    static func league(forTag tag: String) -> LiveTVSportsLeague? {
        switch tag.trimmingCharacters(in: .whitespaces).uppercased() {
        case "MLS": .mls
        case "NBA": .nba
        case "WNBA": .wnba
        case "NFL": .nfl
        case "NHL": .nhl
        case "MLB": .mlb
        case "UEFA", "UCL", "UEFA CHAMPIONS LEAGUE", "CHAMPIONS LEAGUE": .uefaChampionsLeague
        case "UEL", "UEFA EUROPA LEAGUE", "EUROPA LEAGUE": .uefaEuropaLeague
        case "CFL": .cfl
        case "NCAAB", "NCAAM", "NCAAW": .ncaab
        case "NCAAF": .ncaaf
        case "WTA": .wta
        default: nil
        }
    }

    /// The league a provider group names: `US| NBA PPV`, `CA| CFL PPV`, `US| NCAAB PPV`. Matched on whole tokens of the group label
    /// (superscripts such as `ⱽᴵᴾ` folded), so "NHLX" or "PBAS" never match. The first token that names a league wins.
    static func league(inGroups groups: [String]) -> LiveTVSportsLeague? {
        for group in groups {
            for token in LiveTVChannelKind.tokens(of: group) {
                if let league = league(forTag: token) { return league }
            }
        }
        return nil
    }
}

/// What a sports event channel name states outright: its league and, when it reads
/// `A vs. B` or `A @ B`, the two team names as written. Nothing else is inferred.
public struct LiveTVSportsEvent: Equatable, Sendable {
    public let league: LiveTVSportsLeague
    /// The first name written (the visitor in `A @ B` is still first; no home/away is inferred).
    public let teams: [String]
    /// `true` only for `A @ B`, which says A visits B. `A vs. B` states no home side, so no AWAY/HOME label may be drawn for it.
    public let teamsAreAwayThenHome: Bool

    public init(league: LiveTVSportsLeague, teams: [String], teamsAreAwayThenHome: Bool = false) {
        self.league = league
        self.teams = teams
        self.teamsAreAwayThenHome = teamsAreAwayThenHome
    }
}

/// Reads provider event channels such as
/// `(Apple) (MLS) 004 |  Seattle vs. Salt Lake  (2026-11-19 21:25:00)`.
public enum LiveTVSportsEventParser {
    /// `nil` unless a bracket tag names a league in the closed table.
    public static func parse(_ name: String, groups: [String] = []) -> LiveTVSportsEvent? {
        let brackets = bracketGroups(in: name)
        guard let league = brackets.lazy.compactMap({ LiveTVSportsLeague.league(forTag: $0.text) }).first
            ?? LiveTVSportsLeague.league(inGroups: groups) else {
            return nil
        }
        let teams = teams(in: name)
        return LiveTVSportsEvent(league: league, teams: teams.names, teamsAreAwayThenHome: teams.separator == " @ ")
    }

    private static func teams(in name: String) -> (names: [String], separator: String?) {
        // The title follows the last `|`; without one nothing is read as teams.
        guard let bar = name.lastIndex(of: "|") else { return ([], nil) }
        var title = String(name[name.index(after: bar)...])
        for group in bracketGroups(in: title).reversed() {
            title.removeSubrange(group.range)
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for separator in [" vs. ", " vs ", " v ", " @ "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let teams = parts.map { $0.trimmingCharacters(in: .whitespaces) }
            return teams.contains(where: \.isEmpty) ? ([], nil) : (teams, separator)
        }
        return ([], nil)
    }

    private static func bracketGroups(in text: String) -> [(text: String, range: Range<String.Index>)] {
        var groups: [(String, Range<String.Index>)] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            let end = text.index(after: close)
            groups.append((String(text[text.index(after: open)..<close]), open..<end))
            index = end
        }
        return groups
    }
}
