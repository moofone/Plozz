import Foundation

/// Places that providers append to a brand to say which local feed a channel is ("CBC CALGARY",
/// "NBC 10 (WJAR) RHODE ISLAND"). A trailing place is dropped to find the brand key.
///
/// Sources: Canadian provinces and the cities that have regional CBC, CTV, Global and Citytv feeds; the
/// 50 US states; the largest US designated market areas (Nielsen's top 100, by principal city). Provider
/// misspellings that occur in the export are listed explicitly with their evidence. Entries are lower case
/// and compared word by word; a phrase is up to three words.
enum LiveTVGazetteer {
    static let maximumPhraseWords = 3

    /// Single words and phrases. Two-letter state and province codes are included only where the code
    /// cannot be an ordinary word ("or", "in", "me", "hi", "ok", "oh", "de", "pa", "la", "ma", "md", "id",
    /// "al", "on", "ne" and "nt" are left out).
    static let places: Set<String> = {
        var set = Set<String>()
        set.formUnion(canadaRegions)
        set.formUnion(canadaCities)
        set.formUnion(usStates)
        set.formUnion(usStateCodes)
        set.formUnion(usMarkets)
        set.formUnion(feedWords)
        set.formUnion(misspellings)
        return set
    }()

    /// Single-word cities and regions (not feed words) by first letter, for matching a provider's typo to a unique place.
    static let singleWordPlaces: [Character: [String]] = {
        var byInitial: [Character: [String]] = [:]
        let named = canadaRegions.union(canadaCities).union(usStates).union(usMarkets)
        for place in named where !place.contains(" ") && place.count >= 6 { byInitial[place.first!, default: []].append(place) }
        return byInitial
    }()

    static let canadaRegions: Set<String> = [
        "ontario", "quebec", "alberta", "british columbia", "manitoba", "saskatchewan", "nova scotia",
        "new brunswick", "newfoundland", "newfoundland and labrador", "prince edward island", "yukon",
        "northwest territories", "nunavut", "maritimes", "atlantic", "prairies", "bc", "ab", "sk", "mb", "qc",
        "ns", "nb", "nl", "pei", "gta"
    ]

    static let canadaCities: Set<String> = [
        "toronto", "montreal", "vancouver", "calgary", "edmonton", "ottawa", "winnipeg", "quebec city",
        "hamilton", "kitchener", "london", "halifax", "victoria", "windsor", "saskatoon", "regina", "st johns",
        "st john's", "sherbrooke", "barrie", "kelowna", "abbotsford", "kingston", "sudbury", "thunder bay",
        "moncton", "saint john", "charlottetown", "fredericton", "lethbridge", "medicine hat", "red deer",
        "peterborough", "yellowknife", "whitehorse", "iqaluit", "brandon", "prince george", "kamloops",
        "nanaimo", "trois rivieres", "saguenay", "gatineau", "sault ste marie", "north bay", "timmins",
        "oshawa", "guelph", "cambridge", "brantford", "niagara", "st catharines", "grande prairie",
        "fort mcmurray", "lloydminster", "swift current", "prince albert", "moose jaw", "kenora"
    ]

    static let usStates: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware",
        "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky",
        "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi", "missouri",
        "montana", "nebraska", "nevada", "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island",
        "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont", "virginia", "washington",
        "west virginia", "wisconsin", "wyoming", "washington dc", "dc"
    ]

    static let usStateCodes: Set<String> = [
        "ak", "az", "ar", "ca", "co", "ct", "fl", "ga", "il", "ia", "ks", "ky", "mi", "mn", "ms", "mo", "mt",
        "nv", "nh", "nj", "nm", "ny", "nc", "nd", "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv",
        "wi", "wy"
    ]

    static let usMarkets: Set<String> = [
        "new york city", "los angeles", "chicago", "philadelphia", "dallas", "fort worth", "san francisco",
        "oakland", "san jose", "atlanta", "houston", "boston", "washington", "seattle", "tacoma", "phoenix",
        "tampa", "st petersburg", "detroit", "minneapolis", "st paul", "miami", "fort lauderdale", "denver",
        "orlando", "daytona beach", "melbourne", "cleveland", "sacramento", "stockton", "charlotte",
        "portland", "pittsburgh", "raleigh", "durham", "st louis", "baltimore", "indianapolis", "san diego",
        "nashville", "hartford", "new haven", "kansas city", "columbus", "salt lake city", "cincinnati",
        "milwaukee", "greenville", "spartanburg", "san antonio", "west palm beach", "harrisburg", "las vegas",
        "grand rapids", "norfolk", "birmingham", "oklahoma city", "greensboro", "albuquerque", "santa fe",
        "jacksonville", "louisville", "new orleans", "memphis", "providence", "new bedford", "fort myers",
        "buffalo", "fresno", "visalia", "richmond", "mobile", "pensacola", "little rock", "wilkes barre",
        "scranton", "albany", "schenectady", "troy", "tulsa", "lexington", "dayton", "tucson", "honolulu",
        "des moines", "ames", "spokane", "green bay", "appleton", "wichita", "roanoke", "lynchburg", "omaha",
        "flint", "saginaw", "bay city", "springfield", "toledo", "huntsville", "shreveport", "madison",
        "syracuse", "chattanooga", "harlingen", "mcallen", "brownsville", "savannah", "charleston",
        "austin", "knoxville", "baton rouge", "el paso", "cedar rapids", "waterloo", "colorado springs",
        "burlington", "plattsburgh", "lincoln", "boise", "jackson", "reno", "eugene", "sioux falls",
        "fargo", "lansing", "evansville", "peoria", "bloomington", "champaign", "rochester", "binghamton",
        "traverse city", "monterey", "salinas", "santa barbara", "palm springs", "bakersfield", "yuma",
        "lubbock", "amarillo", "odessa", "midland", "tyler", "longview", "waco", "temple", "bryan",
        "corpus christi", "laredo", "beaumont", "lafayette", "monroe", "columbia", "augusta", "macon",
        "tallahassee", "gainesville", "panama city", "dothan", "montgomery", "wichita falls", "topeka",
        "joplin", "st joseph", "springfield", "paducah", "bowling green", "johnstown", "altoona",
        "erie", "elmira", "utica", "watertown", "ithaca", "tri cities", "charlottesville", "greenville",
        "bangor", "portland maine", "manchester", "south bend", "fort wayne", "terre haute", "quad cities",
        "davenport", "rockford", "duluth", "marquette", "wausau", "la crosse", "bismarck", "minot",
        "rapid city", "billings", "missoula", "great falls", "butte", "bozeman", "helena", "casper",
        "cheyenne", "twin falls", "idaho falls", "pocatello", "anchorage", "fairbanks", "juneau"
    ]

    /// Words that name a feed rather than a place.
    static let feedWords: Set<String> = [
        "east", "west", "pacific", "mountain", "central", "eastern", "western", "backup", "alt", "national",
        "north", "south", "northeast", "northwest", "southeast", "southwest", "midwest", "plains", "gulf"
    ]

    /// Provider typos seen in the export: "CTV CALARY NEWS" and "GLOBAL CALAGRY" (Calgary, 2 channels),
    /// "CTV ATLENTIC" (Atlantic, 1), "CBC MONTREALHD" (handled by the glued-quality rule).
    /// Words a provider misspells inside a brand name, whose spelling is not in doubt. A longer word one edit from exactly one of these
    /// is corrected (`LiveTVTMDbLogoMatcher.correctingSpelling`). Evidence: "CRIME + INVERSTIGATION" in the export.
    static let brandVocabulary: Set<String> = [
        "investigation", "television", "discovery", "network", "channel", "classics", "entertainment", "documentary", "programming"
    ]

    static let misspellings: Set<String> = ["calary", "calagry", "atlentic", "winnepeg", "vancover", "edmonten"]
}
