import Foundation

/// A sport drawn as an SF Symbol when nothing better is known. Matched against whole tokens of the channel title and its group
/// (superscripts folded); a token also matches when it is a FloSports prefix plus a keyword ("flohockey", "florugby").
public enum LiveTVSportGlyph: String, CaseIterable, Sendable {
    case basketball, hockey, soccer, americanFootball, baseball, tennis, golf, wrestling, volleyball, rugby, cricket
    case combat, motorsport, cycling, darts, skiing

    /// SF Symbol names; each is checked to exist on tvOS by `LiveTVSportsArtPlanTests`.
    public var symbolName: String {
        switch self {
        case .basketball: "basketball"
        case .hockey: "hockey.puck"
        case .soccer: "soccerball"
        case .americanFootball: "football"
        case .baseball: "baseball"
        case .tennis: "tennis.racket"
        case .golf: "figure.golf"
        case .wrestling: "figure.wrestling"
        case .volleyball: "volleyball"
        case .rugby: "rugbyball"
        case .cricket: "cricket.ball"
        case .combat: "figure.boxing"
        case .motorsport: "flag.checkered"
        case .cycling: "figure.outdoor.cycle"
        case .darts: "target"
        case .skiing: "figure.skiing.downhill"
        }
    }

    /// The closed keyword table, in priority order. Evidence: the 1,630 event-like names of the provider export name their sport as
    /// "Basketball (W): …", "flohockey: …", "2026 ATP Finals: …", or by group (`US| NCAAB PPV`, `US| TENNIS PPV`).
    static let keywords: [(glyph: LiveTVSportGlyph, words: [String])] = [
        (.basketball, ["BASKETBALL", "NBA", "WNBA", "NCAAB", "NCAAM", "NCAAW", "HOOPS"]),
        (.hockey, ["HOCKEY", "NHL", "WHL", "OHL", "QMJHL", "AHL"]),
        (.soccer, ["SOCCER", "MLS", "UEFA", "FIFA", "FUTBOL", "UCL", "MATCHWEEK"]),
        (.americanFootball, ["FOOTBALL", "NFL", "NCAAF", "CFL", "NFHS"]),
        (.baseball, ["BASEBALL", "MLB", "MILB", "SOFTBALL"]),
        (.tennis, ["TENNIS", "ATP", "WTA"]),
        (.golf, ["GOLF", "PGA", "LPGA"]),
        (.wrestling, ["WRESTLING", "WWE", "AEW"]),
        (.volleyball, ["VOLLEYBALL"]),
        (.rugby, ["RUGBY"]),
        (.cricket, ["CRICKET"]),
        (.combat, ["BOXING", "MMA", "UFC", "MATCHROOM", "KICKBOXING"]),
        (.motorsport, ["F1", "RACING", "NASCAR", "INDYCAR", "MOTOGP", "MOTORSPORT", "MOTORSPORTS"]),
        (.cycling, ["CYCLING"]),
        (.darts, ["DARTS"]),
        (.skiing, ["SKIING", "SKI", "SNOWBOARD"])
    ]

    /// The sport named by the title or the groups. The title is read first.
    public static func glyph(name: String, groups: [String]) -> LiveTVSportGlyph? {
        for text in [name] + groups {
            let tokens = LiveTVChannelKind.tokens(of: text)
            for entry in keywords {
                for word in entry.words where tokens.contains(where: { $0 == word || $0 == "FLO" + word }) { return entry.glyph }
            }
        }
        return nil
    }
}

/// The streaming service or network an event channel is carried on, from its group or its `(Service 123)` tag. The display name is
/// the query for the normal logo resolver (TMDB networks, then Wikidata), so it is subject to the same placeholder and no-flag rules.
public struct LiveTVSportsBroadcaster: Equatable, Sendable {
    public let displayName: String

    /// Closed table: tokens of a group or tag label → the network's name. Evidence: the PPV groups of the provider export
    /// (`FLO VIP PPV` 1,001, `ESPN+ PPV` 1,602, `TSN+ PPV` 152, `DAZN PPV` 252, `PEACOCK PPV` 101, `SPORTSNET+ PPV` 92 …).
    static let table: [(tokens: [String], name: String)] = [
        (["FLO", "FLOSPORTS", "FLSP"], "FloSports"),
        (["ESPN+", "ESPN"], "ESPN+"),
        (["TSN+", "TSN"], "TSN"),
        (["SPORTSNET+", "SPORTSNET"], "Sportsnet"),
        (["DAZN"], "DAZN"),
        (["PEACOCK"], "Peacock"),
        (["PARAMOUNT+"], "Paramount+"),
        (["APPLE"], "Apple TV"),
        (["VICTORY+"], "Victory+"),
        (["BTN+", "BTN"], "Big Ten Network"),
        (["CBC"], "CBC"),
        (["FIFA+"], "FIFA+"),
        (["STAN"], "Stan"),
        (["ROGERS"], "Sportsnet"), // "ROGERS SUPER SPORTS PACK n": Rogers' Sportsnet-branded pack
        (["MAX"], "Max"),
        (["BALLY"], "Bally Sports")
    ]

    public static func broadcaster(name: String, groups: [String]) -> LiveTVSportsBroadcaster? {
        for text in groups + [name] {
            let tokens = LiveTVChannelKind.tokens(of: text)
            for entry in table where entry.tokens.contains(where: tokens.contains) { return LiveTVSportsBroadcaster(displayName: entry.name) }
        }
        return nil
    }
}

/// What an event channel's plate shows, most specific first. A pure function of the title, the groups and what art is available, so
/// the guide plate, the hero and the matchup card agree.
public enum LiveTVSportsComposition: Equatable, Sendable {
    /// Two crests and the league badge.
    case twoCrests(league: LiveTVSportsLeague)
    /// One crest and the league badge.
    case oneCrest(league: LiveTVSportsLeague)
    case leagueBadge(LiveTVSportsLeague)
    /// The broadcaster's logo and the sport glyph.
    case broadcaster(name: String, glyph: LiveTVSportGlyph?)
    case glyph(LiveTVSportGlyph)
    /// Nothing is known: the channel name as text.
    case text

    /// - Parameters:
    ///   - crestCount: crests found for the event's teams (Wikidata logos with an allowed Commons licence).
    ///   - broadcasterLogoAvailable: the logo resolver found the broadcaster's logo.
    public static func compose(
        name: String, groups: [String], crestCount: Int = 0, broadcasterLogoAvailable: Bool = false
    ) -> LiveTVSportsComposition {
        let glyph = LiveTVSportGlyph.glyph(name: name, groups: groups)
        if let event = LiveTVSportsEventParser.parse(name, groups: groups) {
            if crestCount >= 2 { return .twoCrests(league: event.league) }
            if crestCount == 1 { return .oneCrest(league: event.league) }
            return .leagueBadge(event.league)
        }
        if broadcasterLogoAvailable, let broadcaster = LiveTVSportsBroadcaster.broadcaster(name: name, groups: groups) {
            return .broadcaster(name: broadcaster.displayName, glyph: glyph)
        }
        if let glyph { return .glyph(glyph) }
        return .text
    }
}

/// Two teams to show on the matchup card.
public struct LiveTVSportsMatchup: Equatable, Sendable {
    public let league: LiveTVSportsLeague
    public let leftTeam: String
    public let rightTeam: String
    /// Whether the left team is the visitor (`A @ B`). Only then may AWAY and HOME labels be drawn.
    public let hasAwayHome: Bool

    /// `nil` unless the title names a league and exactly two teams.
    public static func matchup(name: String, groups: [String]) -> LiveTVSportsMatchup? {
        guard let event = LiveTVSportsEventParser.parse(name, groups: groups), event.teams.count == 2 else { return nil }
        return LiveTVSportsMatchup(
            league: event.league, leftTeam: event.teams[0], rightTeam: event.teams[1], hasAwayHome: event.teamsAreAwayThenHome
        )
    }
}
