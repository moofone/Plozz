import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

/// Group and name prefixes as a real Xtream list writes them (read from the simulator's list: `UK: …`, `AFR| …`, `ASIA| …`, `KU| …`).
final class LiveTVLineupPrefixTests: XCTestCase {
    private func row(_ id: String, _ name: String, group: String?, country: String? = nil) -> ServerLiveTVChannel {
        ServerLiveTVChannel(id: id, name: name, groups: group.map { [$0] } ?? [], guideCountry: country)
    }

    private func placement(_ name: String, group: String?) -> LiveTVLineupClassifier.Placement {
        var classifier = LiveTVLineupClassifier()
        return classifier.placement(of: row("1", name, group: group))
    }

    func testUnitedKingdomRowsAreKeptByTheDefaultLineupWhateverTheSpelling() {
        let rows = [
            row("1", "UK: BBC One 4K", group: "UK| ENTERTAINMENT ᴿᴬᵂ"),
            row("2", "UK : ITV QUIZ 4K", group: nil),
            row("3", "Uk:  ITV Channel Islands 4K ◉", group: nil),
            row("4", "UK: 24/7 30 ROCK 4K", group: "UK| 24/7 DRAMA ᴿᴬᵂ ⁶⁰ᶠᵖˢ"),
            row("5", "Sky News", group: "GB| NEWS"),
            row("6", "Channel 4", group: "UK| GENERAL", country: "UK"),
            row("7", "Channel 5", group: "UK| GENERAL", country: "GB")
        ]
        let result = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(result.kept.map(\.id), ["1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(result.summary.keptByCountry["GB"], 7)
        XCTAssertEqual(result.inventory.codeCounts["GB"], 7)
    }

    func testTheDebugLaunchArgumentTakesUKAsTheUnitedKingdom() {
        XCTAssertEqual(LiveTVLineupState.debugLineup(from: "CA,US,UK")?.placeIDs, ["CA", "US", "GB"])
        XCTAssertEqual(LiveTVLineupState.debugLineup(from: "ca, gb")?.placeIDs, ["CA", "GB"])
        XCTAssertNil(LiveTVLineupState.debugLineup(from: " "))
    }

    func testRegionPrefixesAreRegionsNotGroupsWithoutACountry() {
        XCTAssertEqual(placement("X", group: "AFR| AFRICA VIP HD/4K"), .region("region.africa"))
        XCTAssertEqual(placement("X", group: "AFR| SOMALI TV LIVE ᴴᴰ"), .region("region.africa"))
        XCTAssertEqual(placement("X", group: "ASIA| HINDI"), .region("region.asia"))
        XCTAssertEqual(placement("X", group: "ASIA| 24/7 PUNJABI"), .region("region.asia"))
        XCTAssertEqual(placement("X", group: "KU| KURDISH DVB-T ᶠ ᴴᴰ"), .region("region.kurdistan"))
        XCTAssertEqual(placement("X", group: "EXYU| 24/7 ᴿᴬᵂ"), .region("region.balkans"))
        XCTAssertEqual(placement("X", group: "EU| NEWS"), .region("region.europe"))
        XCTAssertEqual(placement("X", group: "LATAM| DEPORTES"), .region("region.latin-america"))
        XCTAssertEqual(placement("X", group: "ARAB| MBC"), .region("region.arabic"))
        XCTAssertEqual(placement("X", group: "AR| BEIN"), .region("region.arabic"))
        XCTAssertEqual(placement("X", group: "CARIB| ISLAND TV"), .region("region.caribbean"))
        XCTAssertEqual(placement("X", group: "AF| NOLLYWOOD"), .region("region.africa"))
    }

    func testACountryWordInARegionGroupAssignsThatCountry() {
        XCTAssertEqual(placement("X", group: "ASIA| BANGLADESH"), .country("BD"))
        XCTAssertEqual(placement("X", group: "ASIA| 24/7 INDIA"), .country("IN"))
        XCTAssertEqual(placement("X", group: "ASIA| 24/7 PAKISTAN"), .country("PK"))
        XCTAssertEqual(placement("X", group: "ASIA| UK HEVC"), .country("GB"))
        XCTAssertEqual(placement("X", group: "ASIA| UK"), .country("GB"))
        XCTAssertEqual(placement("X", group: "ASIA| NEPAL"), .country("NP"))
        XCTAssertEqual(placement("X", group: "AFR| CABO VERDE ⱽᴵᴾ"), .country("CV"))
        XCTAssertEqual(placement("X", group: "AFR| ETHIOPIA & ERITREA"), .country("ET"))
        XCTAssertEqual(placement("X", group: "AFR| SOMALIA"), .country("SO"))
    }

    func testGroupsWithNoCountryOrRegionStayWithoutACountry() {
        for group in ["4K| ᵁᴴᴰ ³⁸⁴⁰ᴾ", "4K| 24/7 ᵁᴴᴰ", "8K| SPORT ON AIR ⁸ᴷ", "RX| RELAX 4K ☼", "TS| TENNIS TV PPV", "WT| WORLD CRICKET",
                      "Sport On Air", "24/7 Movies"] {
            guard case .group = placement("Some Channel", group: group) else { return XCTFail("\(group) is not a country or region") }
        }
    }

    func testAMockupAliasReadsARasArabicAFasAfricaAndSRasSerbia() {
        XCTAssertEqual(placement("AR: MBC 1", group: nil), .region("region.arabic"))
        XCTAssertEqual(placement("AF: Nigeria Info", group: nil), .region("region.africa"))
        XCTAssertEqual(placement("SR: RTS 1", group: nil), .country("RS"))
        XCTAssertEqual(placement("US: ESPN", group: nil), .country("US"))
    }

    func testRegionsAreOffByDefaultAndKeepTheirRowsWhenSelected() {
        let rows = [
            row("1", "Gulf TV", group: "AFR| AFRICA VIP HD/4K"),
            row("2", "Zee", group: "ASIA| HINDI"),
            row("3", "BTV", group: "ASIA| BANGLADESH"),
            row("4", "Univision", group: "US| NEWS")
        ]
        let standard = LiveTVLineupFilter.apply(.standard, to: rows)
        XCTAssertEqual(standard.kept.map(\.id), ["4"])
        XCTAssertEqual(standard.inventory.regionCounts, ["region.africa": 1, "region.asia": 1])
        XCTAssertEqual(standard.inventory.keptCount(by: .standard), 1)
        XCTAssertTrue(standard.summary.keptByGroupWithoutCountry.isEmpty)

        var asia = LiveTVLineup.standard
        asia.placeIDs.insert("region.asia")
        let withAsia = LiveTVLineupFilter.apply(asia, to: rows)
        XCTAssertEqual(Set(withAsia.kept.map(\.id)), ["2", "4"], "Asia keeps the rows that only name Asia; Bangladesh is its own country")
        XCTAssertEqual(withAsia.inventory.keptCount(by: asia), 2)
        XCTAssertEqual(withAsia.inventory.codeCounts["BD"], 1)
    }

    func testTheSheetListsTheNewRegionsWithTheirCounts() {
        let rows = [row("1", "A", group: "KU| KURDISH NEWS HD/4K"), row("2", "B", group: "ASIA| TAMIL"), row("3", "C", group: "ASIA| HINDI")]
        let inventory = LiveTVLineupFilter.apply(.standard, to: rows).inventory
        let counts = Dictionary(uniqueKeysWithValues: LiveTVLineupPlace.regions.map { ($0.id, inventory.count(ofRegion: $0)) })
        XCTAssertEqual(counts["region.asia"], 2)
        XCTAssertEqual(counts["region.kurdistan"], 1)
    }

    func testAnInventorySavedBeforeRegionsWereCountedStillLoads() throws {
        let old = #"{"total":3,"codeCounts":{"US":3},"groups":[],"adultCount":0}"#
        let inventory = try JSONDecoder().decode(LiveTVLineupInventory.self, from: Data(old.utf8))
        XCTAssertEqual(inventory.regionCounts, [:])
        let round = try JSONDecoder().decode(LiveTVLineupInventory.self, from: JSONEncoder().encode(
            LiveTVLineupInventory(total: 1, codeCounts: [:], groups: [], adultCount: 0, regionCounts: ["region.asia": 1])))
        XCTAssertEqual(round.regionCounts, ["region.asia": 1])
    }

    func testTheLogPrintsEveryGroupPrefixWithItsClassAndTheTopNoCountryGroups() {
        let rows = [
            row("1", "A", group: "ASIA| HINDI"), row("2", "B", group: "ASIA| BANGLADESH"), row("3", "C", group: "UK| NEWS"),
            row("4", "D", group: "4K| UHD"), row("5", "E", group: "Sport On Air")
        ]
        let fields = LiveTVLineupFilter.apply(.standard, to: rows).summary.logFields(source: "iptv")
        XCTAssertTrue(fields.contains("prefixes="), fields)
        XCTAssertTrue(fields.contains("ASIA:region=1"), fields)
        XCTAssertTrue(fields.contains("ASIA:country=1"), fields)
        XCTAssertTrue(fields.contains("UK:country=1"), fields)
        XCTAssertTrue(fields.contains("4K:none=1"), fields)
        XCTAssertTrue(fields.contains("noCountryGroups=4K| UHD=1|Sport On Air=1"), fields)
        XCTAssertEqual(LiveTVLineupSummary().logFields(source: "x", topGroups: 30).contains("noCountryGroups="), true)
    }

    /// Name prefixes of this provider that are not an ISO code, each checked against its channel names in the sim's list.
    func testProviderAliasesAndEveryIsoPrefixReadAsTheirCountry() {
        let expected: [String: String] = [
            "UK: ITV": "GB", "Uk:  ITV Channel Islands": "GB", "UK : ITV QUIZ 4K": "GB", "ARG: CANAL 9": "AR", "BAN: ZEE BANGLA": "BD",
            "UGA: ADOM TV": "UG", "SOM: HORYAAL TV": "SO", "ARM: SHANT TV": "AM", "ETH: EBS": "ET", "SRI: HIRU TV": "LK", "NIG: NOLLYWOOD": "NG",
            "GHA: ADOM TV": "GH", "SEN: RTS1": "SN", "IRL: RTE ONE": "IE", "AFG: RTA SPORTS": "AF", "CHL: CHV NOTICIAS": "CL",
            "CAM: CRTV": "CM", "CON: RTNC": "CD", "GUI: TVGE": "GN", "MOZ: TVM1": "MZ", "TOG: TVT": "TG", "NIC: CANAL 10": "NI",
            "BU: DIEMA SPORT 3": "BG", "CG: RTV PLJEVLJA": "ME", "SR: AGRO TV": "RS", "IN-PREM: CINEMA 1 HD": "IN",
            "PAK-PREM: SHAAN CINEMA HD": "PK", "AL-VIP: KANAL 7": "AL", "PL VP: ROZRYWKA": "PL", "DE GO: DAZN 1 HD": "DE",
            "CA EN: DISNEY CHANNEL HD": "CA", "|FR| TF1": "FR", "CH: 3+ HD": "CH", "IL: 11": "IL", "NZ: CNN": "NZ", "KR: ARIRANG": "KR",
            "BH: HERCEG TV": "BA", "KN: CITIZEN TV": "KE", "PR: GOL PERU": "PE"
        ]
        for (name, code) in expected {
            XCTAssertEqual(placement(name, group: nil), .country(code), name)
        }
        XCTAssertEqual(placement("KU: 4 KURD HD", group: nil), .region("region.kurdistan"))
        XCTAssertEqual(placement("EXYU: A NIGHTMARE", group: nil), .region("region.balkans"))
        XCTAssertEqual(placement("LA: TELEMUNDO BOSTON", group: nil), .region("region.latin-america"))
        XCTAssertEqual(placement("CRB: SPORTSMAX", group: nil), .region("region.caribbean"))
        for name in ["TV: 1+1 INTERNACIONAL", "MC: 90S R&B", "SS: BEIN MOVIES", "VIP: 11 TV", "PRIME: 13EME RUE", "NEXT | #24 FLORIDA STATE",
                     "RK: 48 HOURS", "NF: NETFLIX 01", "SC: CFL Plays", "TK: AD SPORTS 1", "TF: COMEDIA", "AT&T: 123 GO!", "flohockey: 2026 Abbotsford", "## 24/7 ACTION ##", "Plain name"] {
            guard case .group = placement(name, group: nil) else { return XCTFail("\(name) is a package or a plain name, not a country") }
        }
    }

    func testGroupPrefixAliasesAndPackagesFollowTheSameTable() {
        XCTAssertEqual(placement("X", group: "ARG| DEPORTES"), .country("AR"))
        XCTAssertEqual(placement("X", group: "BAN| BANGLA"), .country("BD"))
        XCTAssertEqual(placement("X", group: "CG| BALKAN"), .country("ME"))
        XCTAssertEqual(placement("X", group: "LA| NOTICIAS"), .region("region.latin-america"))
        guard case .group = placement("X", group: "TV| ENTERTAINMENT") else { return XCTFail("TV| is a package, not Tuvalu") }
    }

    /// Every chip of the sheet (countries and regions) loads exactly its counted rows when it alone is selected: no country is
    /// listed that the filter then cannot keep.
    @MainActor
    func testEveryChipKeepsItsCountedRowsWhenSelected() {
        let prefixes = ["UK", "US", "CA EN", "ARG", "BAN", "UGA", "CG", "SR", "RS", "PL VP", "DE GO", "IN-PREM", "PAK-PREM", "AL-VIP",
                        "FR", "IRL", "NIG", "AFG", "CHL", "ES", "KR"]
        var rows = prefixes.enumerated().flatMap { index, prefix in
            (0..<3).map { row("p\(index)-\($0)", "\(prefix): Channel \($0)", group: nil) }
        }
        rows += [row("r1", "News", group: "AFR| SOMALI"), row("r2", "News 2", group: "ASIA| HINDI"), row("r3", "BTV", group: "ASIA| BANGLADESH"),
                 row("r4", "X", group: "KU| KURDISH"), row("r5", "AR", group: nil), row("r6", "AR: MBC 1", group: nil)]
        let inventory = LiveTVLineupFilter.apply(.standard, to: rows).inventory
        let state = LiveTVLineupState(store: nil)
        state.record(inventory: inventory, leftOut: [])
        let chips = state.sections().filter { $0.kind == .countries || $0.kind == .regions }.flatMap(\.chips)
        XCTAssertGreaterThan(chips.count, 20)
        for chip in chips {
            let only = LiveTVLineup(placeIDs: [chip.id], removedGroupIDs: Set(inventory.groups.map(\.id)), keepsFavouritesAndRecents: false,
                                    keepsLiveEvents: false, searchesLeftOut: false)
            let kept = LiveTVLineupFilter.apply(only, to: rows).kept.count
            XCTAssertGreaterThan(kept, 0, "\(chip.title) keeps nothing")
            XCTAssertEqual(kept, chip.count, "\(chip.title): the chip counts \(chip.count) and selecting it keeps \(kept)")
        }
    }
}
