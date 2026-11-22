import CoreModels
import Foundation

/// How much of a lineup the saved guide covers, by one rule for every country: the same matcher the guide reads with
/// (`LiveTVGuideMatcher`, trusted ids, then name and country). Used by the DEBUG `event=guideCoverage` log line and its tests.
///
/// Definitions. **Row**: one entry of the lineup. **Linear row**: a row that is a channel a guide can cover, that is, not a section
/// marker, radio station, event slot or FAST/streaming slot (`LiveTVChannelKind`), not a 24/7 single-show loop, not a replay/info/
/// red-button slot or VOD pack, and not a row whose own name prefix names another country than its group (`UA:` in a UK group).
/// The country of a row is the one the lineup assigns it (provider country, then group, then name prefix). **Channel**: the rows a
/// viewer sees as one entry, the same cleaned name in one country (`US: CNN HD`, `US: CNN RAW`, `US: CNN 4K` are one channel); a
/// channel is covered when any of its rows is. `matched` counts rows with a station that has listings in the window.
struct LiveTVGuideCoverage: Equatable, Sendable {
    struct Share: Equatable, Sendable {
        var matched = 0
        var total = 0
    }

    /// Rows that are channels (section headers are not).
    var kept = 0
    /// Linear rows: the ones a guide can cover.
    var linear = 0
    /// Linear rows with a station that has listings in the window.
    var matched = 0
    /// 24/7 single-show loops: one cell each, never an XMLTV station.
    var loops = 0
    /// Event slots and FAST/streaming rows: they follow their own rules, not the guide.
    var placeholders = 0
    /// Radio stations inside TV groups (`LiveTVChannelKind.radio`): no TV guide, not in `linear`.
    var radio = 0
    /// Replay, info and red-button slots and VOD packs (`LiveTVChannelKind.isReplaySlot`): not linear, no guide.
    var replay = 0
    /// Rows whose own name prefix names another country than their group (`UA:` in a UK group): not that country's channels.
    var foreign = 0
    /// Matched rows by how they were matched (`LiveTVGuideMatchMethod.sourceLabel`: id, id-case, name, name-foreign-feed).
    var sources: [String: Int] = [:]
    /// Rows only an extra guide (a user-added XMLTV address) has listings for; nil when no extra guide is configured.
    var extraGuideRows: Int?
    /// Unmatched rows the guide has nothing for: the tvg-id names a station without listings, or no station of any country
    /// carries the row's name. The rest of `unmatched` is declined by a matcher rule (another country, another language, ambiguity).
    var providerGaps: [LiveTVPrototypeChannel] = []
    var byCountry: [String: Share] = [:]
    /// The same by merged channel (quality variants of one name count once; covered when any variant is matched).
    var channelsByCountry: [String: Share] = [:]
    var channelsMatched = 0
    var channelsTotal = 0
    /// Linear rows left without listings: their name and the station name key they would need (for reports; never logged).
    var unmatched: [LiveTVPrototypeChannel] = []
    /// The linear rows themselves (the denominator), for reports.
    var linearRows: [LiveTVPrototypeChannel] = []

    /// The countries the log line reports, in this order, by ISO 3166 code (the United Kingdom is `GB`).
    static let reported: [(label: String, code: String)] = [("CA", "CA"), ("US", "US"), ("GB", "GB")]

    /// A name prefix naming a country other than `home`. `TV:` is a provider package label that is also an ISO code.
    private static func isForeign(_ name: String, home: String) -> Bool {
        for tag in IPTVChannelName.split(name).tags {
            if case let .country(code) = tag { return code != home && !LiveTVGuideStationData.packageLabelCodes.contains(code) }
        }
        return false
    }

    /// `stationsWithListings` limits a match to stations that have programmes; nil counts every station.
    /// `extraStations` are the stations of user-added guides: they are read only for rows the provider's guide has no
    /// listings for, by the same name-and-country resolver as the provider's guide, and those rows count under `extra`.
    static func measure(
        channels: [LiveTVPrototypeChannel], stations: [String: [String]], stationsWithListings: Set<String>? = nil,
        extraStations: [String: [String]]? = nil, extraStationsWithListings: Set<String>? = nil
    ) -> LiveTVGuideCoverage {
        var result = LiveTVGuideCoverage()
        var linear: [LiveTVPrototypeChannel] = []
        var placer = LiveTVLineupClassifier()
        // A station with no listings is no match: a row whose own id names one is read by name instead.
        let readable = stationsWithListings.map { listed in stations.filter { listed.contains($0.key) } } ?? stations
        let index = LiveTVGuideStationIndex(guideChannels: readable)
        func homeCountry(of channel: LiveTVPrototypeChannel) -> String? {
            if case .country(let code) = placer.placement(of: channel) { return code }
            return nil
        }
        for channel in channels {
            let kind = LiveTVChannelKind.classify(
                name: channel.name, groups: channel.categories, stations: index,
                country: homeCountry(of: channel))
            switch kind {
            case .sectionMarker: continue
            case .showLoop: result.loops += 1
            case .radio: result.radio += 1; continue
            case .event, .fast: result.placeholders += 1
            case .linear:
                // "24/7 MOVIES/ACTORS" rows are loops too (one cell named for the actor), though no logo search reads them.
                if LiveTVChannelKind.showLoopTitle(name: channel.name, groups: channel.categories, includingActors: true) != nil {
                    result.loops += 1
                } else if LiveTVChannelKind.isReplaySlot(name: channel.name, groups: channel.categories, hasGuideID: channel.guideID?.isEmpty == false) {
                    result.replay += 1
                    continue
                } else if case .country(let home) = placer.placement(of: channel), isForeign(channel.name, home: home) {
                    result.foreign += 1
                    continue
                } else {
                    linear.append(channel)
                }
            }
            result.kept += 1
        }
        result.linear = linear.count
        result.linearRows = linear
        let assignments = LiveTVGuideMatcher().matching(channels: linear, guideChannels: readable, trustsGuideIDs: true).assignments
        var fromExtra = Set<String>()
        if let extraStations {
            let extraReadable = extraStationsWithListings.map { listed in extraStations.filter { listed.contains($0.key) } }
                ?? extraStations
            let gaps = linear.filter { channel in
                !(assignments[channel.id].map { stationsWithListings?.contains($0.guideChannelID) ?? true } ?? false)
            }
            let extraAssignments = LiveTVGuideMatcher()
                .matching(channels: gaps, guideChannels: extraReadable, trustsGuideIDs: true).assignments
            fromExtra = Set(gaps.map(\.id).filter { extraAssignments[$0] != nil })
            result.extraGuideRows = fromExtra.count
        }
        var classifier = LiveTVLineupClassifier()
        var channelCovered: [String: Bool] = [:]
        var channelCountry: [String: String?] = [:]
        for channel in linear {
            var country: String?
            if case .country(let code) = classifier.placement(of: channel) { country = code }
            let providerListed = assignments[channel.id].map { stationsWithListings?.contains($0.guideChannelID) ?? true } ?? false
            let hasListings = providerListed || fromExtra.contains(channel.id)
            if hasListings {
                result.matched += 1
                if providerListed, let method = assignments[channel.id]?.method { result.sources[method.sourceLabel, default: 0] += 1 }
            } else {
                result.unmatched.append(channel)
                let namesStation = channel.guideID.map { id in stations[id] != nil && readable[id] == nil } ?? false
                if namesStation || !index.hasAnyStation(named: channel.guideName ?? channel.name, groups: channel.categories) { result.providerGaps.append(channel) }
            }
            if let country, reported.contains(where: { $0.code == country }) {
                result.byCountry[country, default: Share()].total += 1
                if hasListings { result.byCountry[country, default: Share()].matched += 1 }
            }
            let channelKey = (country ?? "") + "|" + LiveTVGuideStationIndex.RowFacts(name: channel.guideName ?? channel.name, groups: channel.categories).words.joined()
            channelCovered[channelKey] = (channelCovered[channelKey] ?? false) || hasListings
            channelCountry[channelKey] = .some(country)
        }
        for (key, covered) in channelCovered {
            result.channelsTotal += 1
            if covered { result.channelsMatched += 1 }
            if let country = channelCountry[key] ?? nil, reported.contains(where: { $0.code == country }) {
                result.channelsByCountry[country, default: Share()].total += 1
                if covered { result.channelsByCountry[country, default: Share()].matched += 1 }
            }
        }
        return result
    }

    /// `LIVE_TV event=guideCoverage kept=N linear=N matched=N byCountry=CA:x/y,US:x/y,GB:x/y loops=N placeholders=N radio=N replay=N foreign=N sources=id:N,id-case:N,name:N,name-foreign-feed:N channels=N/N channelsByCountry=CA:x/y,US:x/y,GB:x/y`
    var logLine: String {
        let countries = Self.reported.map { entry in
            let share = byCountry[entry.code] ?? Share()
            return "\(entry.label):\(share.matched)/\(share.total)"
        }.joined(separator: ",")
        let channelCountries = Self.reported.map { entry in
            let share = channelsByCountry[entry.code] ?? Share()
            return "\(entry.label):\(share.matched)/\(share.total)"
        }.joined(separator: ",")
        return "LIVE_TV event=guideCoverage kept=\(kept) linear=\(linear) matched=\(matched) byCountry=\(countries)"
            + " loops=\(loops) placeholders=\(placeholders) radio=\(radio) replay=\(replay) foreign=\(foreign) sources=\(sourcesText)"
            + " channels=\(channelsMatched)/\(channelsTotal) channelsByCountry=\(channelCountries)"
    }

    private var sourcesText: String {
        let names = ["id", "id-case", "name", "name-foreign-feed"].map { "\($0):\(sources[$0] ?? 0)" }
        return (names + (extraGuideRows.map { ["extra:\($0)"] } ?? [])).joined(separator: ",")
    }

    /// The log line for a saved guide's snapshot records (its stations and programmes), or nil when it holds no station.
    static func logLine(
        channels: [LiveTVPrototypeChannel], records: [LiveTVGuideSnapshot.GuideRecord],
        extraRecords: [LiveTVGuideSnapshot.GuideRecord]? = nil
    ) -> String? {
        let primary = stationsAndListings(records)
        guard !primary.stations.isEmpty else { return nil }
        let extra = extraRecords.map(stationsAndListings)
        return measure(
            channels: channels, stations: primary.stations, stationsWithListings: primary.withListings,
            extraStations: extra?.stations, extraStationsWithListings: extra?.withListings
        ).logLine
    }

    private static func stationsAndListings(
        _ records: [LiveTVGuideSnapshot.GuideRecord]
    ) -> (stations: [String: [String]], withListings: Set<String>) {
        var stations: [String: [String]] = [:]
        var withListings = Set<String>()
        for record in records {
            if record.type == "channel", let id = record.id { stations[id] = record.displayNames ?? [] }
            if record.type == "programme", let channel = record.channel { withListings.insert(channel) }
        }
        return (stations, withListings)
    }
}
