import Foundation

/// City or short club names that providers write, per league, and the normaliser the crest matcher compares names with.
enum LiveTVSportsTeamAliases {
    /// City or short names providers write, mapped to the full club name. Cities with two clubs
    /// in a league (New York, Los Angeles, Chicago in MLB) are left out so they stay unmatched.
    static func table(for league: LiveTVSportsLeague) -> [String: String] {
        let source: [String: String]
        switch league {
        case .mls: source = mls
        case .nba: source = nba
        case .wnba: source = wnba
        case .nfl: source = nfl
        case .nhl: source = nhl
        case .mlb: source = mlb
        case .uefaChampionsLeague, .uefaEuropaLeague, .cfl, .ncaab, .ncaaf, .wta: source = [:]
        }
        return Dictionary(source.map { (normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static let mls = [
        "Atlanta": "Atlanta United FC", "Austin": "Austin FC", "Charlotte": "Charlotte FC",
        "Chicago": "Chicago Fire", "Cincinnati": "FC Cincinnati", "Colorado": "Colorado Rapids",
        "Columbus": "Columbus Crew", "Dallas": "FC Dallas", "DC United": "D.C. United",
        "Houston": "Houston Dynamo", "Inter Miami": "Inter Miami CF", "Miami": "Inter Miami CF",
        "Kansas City": "Sporting Kansas City", "LA Galaxy": "LA Galaxy", "LAFC": "Los Angeles FC",
        "Minnesota": "Minnesota United FC", "Montreal": "CF Montreal", "Nashville": "Nashville SC",
        "New England": "New England Revolution", "NYCFC": "New York City FC",
        "Red Bulls": "New York Red Bulls", "Orlando": "Orlando City SC", "Philadelphia": "Philadelphia Union",
        "Portland": "Portland Timbers", "Salt Lake": "Real Salt Lake", "San Diego": "San Diego FC",
        "San Jose": "San Jose Earthquakes", "Seattle": "Seattle Sounders FC", "St. Louis": "St. Louis City SC",
        "Toronto": "Toronto FC", "Vancouver": "Vancouver Whitecaps FC"
    ]

    private static let nba = [
        "Atlanta": "Atlanta Hawks", "Boston": "Boston Celtics", "Brooklyn": "Brooklyn Nets",
        "Charlotte": "Charlotte Hornets", "Chicago": "Chicago Bulls", "Cleveland": "Cleveland Cavaliers",
        "Dallas": "Dallas Mavericks", "Denver": "Denver Nuggets", "Detroit": "Detroit Pistons",
        "Golden State": "Golden State Warriors", "Houston": "Houston Rockets", "Indiana": "Indiana Pacers",
        "Lakers": "Los Angeles Lakers", "Clippers": "Los Angeles Clippers", "Memphis": "Memphis Grizzlies",
        "Miami": "Miami Heat", "Milwaukee": "Milwaukee Bucks", "Minnesota": "Minnesota Timberwolves",
        "New Orleans": "New Orleans Pelicans", "Knicks": "New York Knicks", "Oklahoma City": "Oklahoma City Thunder",
        "Orlando": "Orlando Magic", "Philadelphia": "Philadelphia 76ers", "Phoenix": "Phoenix Suns",
        "Portland": "Portland Trail Blazers", "Sacramento": "Sacramento Kings", "San Antonio": "San Antonio Spurs",
        "Toronto": "Toronto Raptors", "Utah": "Utah Jazz", "Washington": "Washington Wizards"
    ]

    private static let wnba = [
        "Atlanta": "Atlanta Dream", "Chicago": "Chicago Sky", "Connecticut": "Connecticut Sun",
        "Dallas": "Dallas Wings", "Golden State": "Golden State Valkyries", "Indiana": "Indiana Fever",
        "Las Vegas": "Las Vegas Aces", "Minnesota": "Minnesota Lynx", "New York": "New York Liberty",
        "Phoenix": "Phoenix Mercury", "Seattle": "Seattle Storm", "Washington": "Washington Mystics",
        "Los Angeles": "Los Angeles Sparks"
    ]

    private static let nfl = [
        "Arizona": "Arizona Cardinals", "Atlanta": "Atlanta Falcons", "Baltimore": "Baltimore Ravens",
        "Buffalo": "Buffalo Bills", "Carolina": "Carolina Panthers", "Cincinnati": "Cincinnati Bengals",
        "Cleveland": "Cleveland Browns", "Dallas": "Dallas Cowboys", "Denver": "Denver Broncos",
        "Detroit": "Detroit Lions", "Green Bay": "Green Bay Packers", "Houston": "Houston Texans",
        "Indianapolis": "Indianapolis Colts", "Jacksonville": "Jacksonville Jaguars",
        "Kansas City": "Kansas City Chiefs", "Las Vegas": "Las Vegas Raiders", "Chargers": "Los Angeles Chargers",
        "Rams": "Los Angeles Rams", "Miami": "Miami Dolphins", "Minnesota": "Minnesota Vikings",
        "New England": "New England Patriots", "New Orleans": "New Orleans Saints", "Giants": "New York Giants",
        "Jets": "New York Jets", "Philadelphia": "Philadelphia Eagles", "Pittsburgh": "Pittsburgh Steelers",
        "San Francisco": "San Francisco 49ers", "Seattle": "Seattle Seahawks", "Tampa Bay": "Tampa Bay Buccaneers",
        "Tennessee": "Tennessee Titans", "Washington": "Washington Commanders"
    ]

    private static let nhl = [
        "Anaheim": "Anaheim Ducks", "Boston": "Boston Bruins", "Buffalo": "Buffalo Sabres", "Calgary": "Calgary Flames",
        "Carolina": "Carolina Hurricanes", "Chicago": "Chicago Blackhawks", "Colorado": "Colorado Avalanche",
        "Columbus": "Columbus Blue Jackets", "Dallas": "Dallas Stars", "Detroit": "Detroit Red Wings",
        "Edmonton": "Edmonton Oilers", "Florida": "Florida Panthers", "Los Angeles": "Los Angeles Kings",
        "Minnesota": "Minnesota Wild", "Montreal": "Montreal Canadiens", "Nashville": "Nashville Predators",
        "New Jersey": "New Jersey Devils", "Islanders": "New York Islanders", "Rangers": "New York Rangers",
        "Ottawa": "Ottawa Senators", "Philadelphia": "Philadelphia Flyers", "Pittsburgh": "Pittsburgh Penguins",
        "San Jose": "San Jose Sharks", "Seattle": "Seattle Kraken", "St. Louis": "St. Louis Blues",
        "Tampa Bay": "Tampa Bay Lightning", "Toronto": "Toronto Maple Leafs", "Utah": "Utah Mammoth",
        "Vancouver": "Vancouver Canucks", "Vegas": "Vegas Golden Knights", "Washington": "Washington Capitals",
        "Winnipeg": "Winnipeg Jets"
    ]

    private static let mlb = [
        "Arizona": "Arizona Diamondbacks", "Atlanta": "Atlanta Braves", "Baltimore": "Baltimore Orioles",
        "Boston": "Boston Red Sox", "Cubs": "Chicago Cubs", "White Sox": "Chicago White Sox",
        "Cincinnati": "Cincinnati Reds", "Cleveland": "Cleveland Guardians", "Colorado": "Colorado Rockies",
        "Detroit": "Detroit Tigers", "Houston": "Houston Astros", "Kansas City": "Kansas City Royals",
        "Angels": "Los Angeles Angels", "Dodgers": "Los Angeles Dodgers", "Miami": "Miami Marlins",
        "Milwaukee": "Milwaukee Brewers", "Minnesota": "Minnesota Twins", "Mets": "New York Mets",
        "Yankees": "New York Yankees", "Athletics": "Oakland Athletics", "Philadelphia": "Philadelphia Phillies",
        "Pittsburgh": "Pittsburgh Pirates", "San Diego": "San Diego Padres", "San Francisco": "San Francisco Giants",
        "Seattle": "Seattle Mariners", "St. Louis": "St. Louis Cardinals", "Tampa Bay": "Tampa Bay Rays",
        "Texas": "Texas Rangers", "Toronto": "Toronto Blue Jays", "Washington": "Washington Nationals"
    ]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
