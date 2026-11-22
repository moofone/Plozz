import Foundation

/// One brand in the curated table: the comparison key and the identifiers of its logo sources.
/// IDs only, never images.
public struct LiveTVCuratedBrand: Equatable, Sendable {
    /// The brand's `LiveTVTMDbLogoMatcher.collapsedKey`.
    public let key: String
    public let tmdbNetworkID: Int?
    public let wikidataQID: String?
    /// The entry also covers names that continue with other words ("STARZ ENCORE BLACK" for `STARZ`). Such an entry applies only
    /// when the generic rules found nothing; an entry without it applies to the exact brand and beats every heuristic.
    public let acceptsDescriptors: Bool
    /// The entry applies only to a channel of this country ("TV5" is Québec's for a Canadian channel and the Philippines' for another).
    public let country: String?
}

/// The bundled curated brand table: our own data, licence-clean, built from the provider export's unmatched channels.
///
/// It only adds aliases the generic matcher cannot derive; the matcher stays generic. Its lookup comes right after the user's
/// override. Every entry was verified on 2026-11-16 against TMDB (name, origin country, a logo exists) or Wikidata (a `P154` logo
/// image exists, country `P17`); the evidence is the comment on its line. A network that TMDB lists only under another name or not at all
/// is given by its Wikidata item. Items verified as having no logo image (Tennis Channel, Télémagino) are deliberately absent.
public enum LiveTVCuratedBrands {
    static let entries: [String: LiveTVCuratedBrand] = Dictionary(
        uniqueKeysWithValues: table.map {
            let key = LiveTVTMDbLogoMatcher.collapsedKey($0.name)
            return (key, LiveTVCuratedBrand(key: key, tmdbNetworkID: $0.tmdb, wikidataQID: $0.qid, acceptsDescriptors: $0.descriptors, country: $0.country))
        }
    )

    /// Entries whose brand continues with descriptor words, longest brand first when searching.
    static let descriptorKeys: [String] = entries.values.filter(\.acceptsDescriptors).map(\.key)

    struct Row {
        let name: String
        let tmdb: Int?
        let qid: String?
        let descriptors: Bool
        let country: String?
    }

    private static func row(_ name: String, tmdb: Int? = nil, qid: String? = nil, descriptors: Bool = false, country: String? = nil) -> Row {
        Row(name: name, tmdb: tmdb, qid: qid, descriptors: descriptors, country: country)
    }

    static let table: [Row] = [
        // Canada
        // Canada: brands the same on both sides of the border, or that TMDB lists only under a foreign origin (verified 2026-11-16)
        row("A&E CANADA", tmdb: 129),                                  // TMDB 129 "A&E", US, logo; A&E Canada carries the A&E logo
        row("NBA TV", tmdb: 301),                                      // TMDB 301 "NBA TV", US, logo; "NBA TV Canada" carries it
        row("MAV TV", tmdb: 796),                                      // TMDB 796 "MAVTV", US, logo
        row("SPORTSMAN", tmdb: 957),                                   // TMDB 957 "Sportsman Channel", US, logo
        row("TCM", tmdb: 408),                                         // TMDB 408 "Turner Classic Movies", US, logo
        row("UNIVISION", tmdb: 28),                                    // TMDB 28 "Univision", US, logo (2447 is Puerto Rico's: two origins make the plain name a tie)
        row("VISION", tmdb: 237, country: "CA"),                       // TMDB 237 "VisionTV", CA, logo; the channel's current short name
        row("AHC", tmdb: 1430),                                        // TMDB 1430 "AHC", US, logo
        row("BABY TV", tmdb: 5770),                                    // TMDB 5770 "BabyTV", GB, logo (Wikidata Q2014847 agrees)
        row("CGTN", tmdb: 6360),                                       // TMDB 6360 "CGTN", CN, logo
        row("EWTN", tmdb: 6726),                                       // TMDB 6726 "EWTN", US, logo
        row("FRANCE 24", tmdb: 8148),                                  // TMDB 8148 "France 24", FR, logo
        row("DISCOVERY VELOCITY", tmdb: 435),                          // TMDB 435 "Velocity", US, logo; Discovery Velocity is Canada's licensee of the same brand
        row("CRIME + INVESTIGATION", tmdb: 2392, country: "CA"),         // TMDB 2392 "Crime + Investigation", GB, logo; 2393 (AU) and 1402 (IT) make the plain name a tie; Canada carries the original brand
        row("CANAL SAVOIR", tmdb: 2798),                               // TMDB 2798 "Savoir média", CA, logo; Canal Savoir is its channel
        row("ICI", tmdb: 141, descriptors: true, country: "CA"),       // TMDB 141 "ICI Radio-Canada Télé", CA, logo; "ICI MONTREAL", "ICI VANCOUVER", "ICI TELEVISION", "ICI RADIO TELE TORONTO"
        row("NOOVO", tmdb: 4161, descriptors: true),                   // TMDB 4161 "Noovo", CA, logo; "NOOVO V-TELE"
        row("TV5", tmdb: 1533, country: "CA"),                         // TMDB 1533 "TV5 Québec Canada", CA, logo; "TV5 HD", "TV 5 QUÉBEC" (the Philippines' 42 and Finland's 6736 are other TV5s)
        row("TV5 MONDE", tmdb: 2922, descriptors: true),               // TMDB 2922 "TV5Monde", FR, logo; "TV5 MONDE INFO", "TV5 MONDE STYLE"
        row("CITY NEWS", qid: "Q5122969", country: "CA"),              // Wikidata Q5122969 "CityNews" (Toronto newscast), P154; "CITY NEWS TORONTO ON"
        row("CITY NEWS TORONTO ON", qid: "Q5122969", country: "CA"),  // same item; "ON" is not in the place list because it is also a word
        row("TRACE URBAN", qid: "Q1755296"),                           // Wikidata Q1755296 "Trace Urban", P154 (Africa, Naija and Toca have no Wikidata item)
        row("MEZZO", qid: "Q854003", descriptors: true),               // Wikidata Q854003 "Mezzo TV", FR, P154; "MEZZO LIVE HD"
        row("MUSIC PLUS", qid: "Q3328571", country: "CA"),             // Wikidata Q3328571 "MusiquePlus", CA (Q16), P154; the French channel written "MUSIC PLUS"
        row("ENGLISH CLUB TV", qid: "Q2152911"),                       // Wikidata Q2152911 "English Club TV", P154
        row("CTV NEWS LIVE EVENTS", tmdb: 673, descriptors: true),      // TMDB 673 "CTV News Channel", CA, logo; 6 channels "CTV NEWS LIVE EVENTS 1-6"
        row("SPORTSNET PPV", tmdb: 1019),                              // TMDB 1019 "Sportsnet", CA, logo; "CA EN: SPORTSNET PPV HD" (a channel, not a PPV group)
        row("SUPER CHANNEL", tmdb: 783, descriptors: true),             // TMDB 783 "Super Channel", CA, logo; 3 channels (FUSE, HEART & HOME, VAULT)
        row("ICI TELE", tmdb: 141, descriptors: true),                  // TMDB 141 "ICI Radio-Canada Télé", CA, logo; 9 regional "ICI TELE <city>" channels
        row("RDI", tmdb: 2290),                                        // TMDB 2290 "ICI RDI", CA, logo
        row("TSN", tmdb: 641, descriptors: true),                       // TMDB 641 "The Sports Network", CA, logo (verified 2026-11-16); TSN 1-5, "TSN RDS EXTRA n"
        row("CRAVE", tmdb: 1344, descriptors: true),                    // TMDB 1344 "Crave", CA, logo; "CRAVE 1 / TMN 1" ×4
        row("TELETOON FRENCH", tmdb: 83),                              // TMDB 83 "Teletoon", CA, logo
        // US: NBCUniversal feeds written "NBC <network>"
        row("NBC TELEMUNDO", tmdb: 193),                               // TMDB 193 "Telemundo", US, logo; 14 Telemundo stations written "NBC (KDEN) TELEMUNDO"
        row("NBC NEWS NOW", qid: "Q123488148"),                        // Wikidata Q123488148 "NBC News Now", P154; 7 channels
        row("NBC SPORTS", qid: "Q3046048", descriptors: true),         // Wikidata Q3046048 "NBC Sports", US, P154; NBC SPORTS NOW ×5, regional "NBC SPORTS <region> PLUS" ×6
        row("FOX NEWS", tmdb: 45, descriptors: true),                   // TMDB 45 "Fox News Channel", US, logo; FOX NEWS is its own brand and must never take FOX's logo
        row("NBC OXYGEN", tmdb: 132),                                  // TMDB 132 "Oxygen", US, logo; "NBC OXYGEN (WEST)"
        row("NBC CNBC", tmdb: 175),                                    // TMDB 175 "CNBC", US, logo
        row("NBC E", tmdb: 76),                                        // TMDB 76 "E!", US, logo
        row("NBC SYFY", tmdb: 77),                                     // TMDB 77 "Syfy", US, logo
        row("NBC USA NETWORK", tmdb: 30),                              // TMDB 30 "USA Network", US, logo
        row("NBC BRAVO", tmdb: 74),                                    // TMDB 74 "Bravo", US, logo
        row("NBC GOLF", tmdb: 420),                                    // TMDB 420 "Golf Channel", US, logo ("NBC GOLF" and "NBC GOLF CHANNEL")
        row("NBC MS NOW", tmdb: 8703),                                 // TMDB 8703 "MS NOW", US, logo
        // US: carriers and regional sports
        row("SPECTRUM NEWS", qid: "Q8045983", descriptors: true),       // Wikidata Q8045983 "Spectrum News 1 Rochester", US, P154 (the brand's logo); TMDB has no Spectrum News; 25+6 channels
        row("FOX SPORTS", qid: "Q75776", descriptors: true),            // Wikidata Q75776 "Fox Sports", US, P154; TMDB 338 "Fox Sports" is Australian; 25 regional channels
        row("FOX SOUL", qid: "Q105081974"),                            // Wikidata Q105081974 "Fox Soul", US, P154
        row("FOX WEATHER", qid: "Q107431409"),                         // Wikidata Q107431409 "Fox Weather", P154; 7 channels
        row("MSG", tmdb: 227, descriptors: true),                       // TMDB 227 "MSG", US, logo; "MSG ALT-1…3", "MSG SPORTSNET"
        row("BIG TEN NETWORK", tmdb: 917, descriptors: true),           // TMDB 917 "Big Ten Network", US, logo; "BIG TEN NETWORK OVERFLOW 2-4"
        row("BTN", tmdb: 917),                                         // same network, the provider's abbreviation
        row("NESN", qid: "Q3338942", descriptors: true),                // Wikidata Q3338942 "New England Sports Network", US, P154
        row("COURT TV", tmdb: 4138, descriptors: true),                 // TMDB 4138 "Court TV", US, logo
        // US: premium cable families ("STARZ ENCORE BLACK", "SHOWTIME NEXT", "CINEMAX ACTION", "HBO HITS EAST")
        row("STARZ", tmdb: 318, descriptors: true),                     // TMDB 318 "STARZ", US, logo; 26 channels
        row("SHOWTIME", tmdb: 67, descriptors: true),                   // TMDB 67 "Showtime", US, logo
        row("CINEMAX", tmdb: 359, descriptors: true),                   // TMDB 359 "Cinemax", US, logo
        row("HBO", tmdb: 49, descriptors: true),                        // TMDB 49 "HBO", US, logo
        row("EPIX", tmdb: 922, descriptors: true),                      // TMDB 922 "Epix", US, logo
        row("TUDN", qid: "Q6156913", descriptors: true),                // Wikidata Q6156913 "Univision Deportes Network", US, P154; "TUDN EXTRA 1-11"
        row("ZONA TUDN", qid: "Q6156913"),                             // same
        row("DAZN", tmdb: 2558, descriptors: true),                     // TMDB 2558 "DAZN", no origin set, logo; DAZN COMBAT, RISE…
        row("MLB NETWORK", tmdb: 748, descriptors: true),               // TMDB 748 "MLB Network", US, logo; "MLB NETWORK ALT."
        row("BET", tmdb: 24, descriptors: true),                        // TMDB 24 "BET", US, logo; BET GOSPEL, BET JAMS
        row("OXYGEN TRUE CRIME", tmdb: 132),                           // TMDB 132 "Oxygen", US, logo
        row("CNNI", tmdb: 373),                                        // TMDB 373 "CNN International", US, logo
        row("BBC NEWS", tmdb: 375),                                    // TMDB 375 "BBC News", GB, logo (carried on US lineups)
        row("SKY NEWS", tmdb: 480),                                    // TMDB 480 "Sky News", GB, logo
        row("THE MOVIE CHANNEL", tmdb: 651, descriptors: true)          // TMDB 651 "The Movie Channel", US, logo; "THE MOVIE CHANNEL XTRA"
    ]
}
