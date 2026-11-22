import CoreModels
import Foundation
import os

/// DEBUG diagnostics log. `HandoffDiagnostics` is gated by a runtime setting; these lines are written at notice level, public, so
/// `log show --predicate 'subsystem == "com.plozz.app" AND category == "liveTVDiag"'` always keeps them.
enum LiveTVDiagnosticLog {
    private static let logger = Logger(subsystem: "com.plozz.app", category: "liveTVDiag")

    static func notice(_ line: String) {
        #if DEBUG
        logger.notice("\(line, privacy: .public)")
        HandoffDiagnostics.emit(line)
        #endif
    }
}

/// DEBUG only. With the launch argument `-PlozzLiveTVEPGProbe N` (default off), once per launch and after the WHOLE kept lineup's
/// guide coverage is known, asks the panel's own per-channel EPG about up to N US/CA/GB linear rows the saved guide leaves without
/// listings (sampled evenly across countries and name styles), and logs whether it has any and whether the `epg_id` it returns is
/// in the full XMLTV. Logs only the row name, country, HTTP status class, elapsed time and counts: never URLs, credentials or ids.
enum LiveTVEPGProbe {
    static let launchArgument = "-PlozzLiveTVEPGProbe"
    static let countries = ["CA", "US", "GB"]
    /// The pause between two requests to the provider, and how many consecutive failures end the run.
    static let requestSpacing: Duration = .milliseconds(250)
    static let consecutiveFailureLimit = 5

    static func sampleSize(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        #if DEBUG
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count,
              let count = Int(arguments[index + 1]), count > 0 else { return 0 }
        return min(count, 200)
        #else
        return 0
        #endif
    }

    private static let takenLock = NSLock()
    private nonisolated(unsafe) static var taken = false
    static func takesRun() -> Bool {
        takenLock.lock()
        defer { takenLock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
    static func resetForTesting() { takenLock.lock(); taken = false; takenLock.unlock() }

    // MARK: Sampling

    /// Name styles the sample spreads over. Plain facts about the displayed name, not provider rules.
    enum Style: String, CaseIterable {
        case callSign, regionalSports, premium, westFeed, other
    }

    struct Row: Equatable {
        let channel: LiveTVPrototypeChannel
        let country: String
        let style: Style
    }

    private static let premiumWords: Set<String> = ["HBO", "SHOWTIME", "STARZ", "CINEMAX", "EPIX", "MGM", "ENCORE", "SUNDANCE"]
    private static let westWords: Set<String> = ["WEST", "PACIFIC"]

    static func style(ofName name: String) -> Style {
        let words = name.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: westWords.contains) { return .westFeed }
        if words.contains(where: premiumWords.contains) { return .premium }
        if words.contains(where: { $0.contains("SPORT") || $0 == "TSN" || $0 == "RDS" }) { return .regionalSports }
        // Call signs: K/W (US) or C (CA) followed by 2-3 letters, optionally followed by a digit-less suffix such as TV/DT/HD.
        if words.contains(where: { isCallSign($0) }) { return .callSign }
        return .other
    }

    private static func isCallSign(_ word: String) -> Bool {
        let letters = Array(word)
        guard (3...6).contains(letters.count), letters.allSatisfy(\.isLetter), let first = letters.first,
              "KWC".contains(first) else { return false }
        var core = word
        for suffix in ["TV", "DT", "HD"] where core.count > 4 && core.hasSuffix(suffix) { core.removeLast(suffix.count) }
        return (3...4).contains(core.count)
    }

    /// Up to `count` of the lineup's unguided linear US/CA/GB rows, evenly spread: one pick per (style, country) bucket in turn, so
    /// every country and every name style is represented before any gets a second pick. Inside a bucket the order is a stable hash
    /// of the row id (spread across the lineup, repeatable between runs). `unguided` must already exclude loops, placeholders,
    /// radio, replay slots and events (`LiveTVGuideCoverage.unmatched`).
    static func sample(unguided: [LiveTVPrototypeChannel], count: Int) -> [Row] {
        guard count > 0 else { return [] }
        var classifier = LiveTVLineupClassifier()
        var buckets: [Style: [String: [Row]]] = [:]
        for channel in unguided {
            guard case .country(let code) = classifier.placement(of: channel), countries.contains(code) else { continue }
            let row = Row(channel: channel, country: code, style: style(ofName: channel.guideName ?? channel.name))
            buckets[row.style, default: [:]][code, default: []].append(row)
        }
        for style in buckets.keys {
            for code in buckets[style]?.keys.map({ $0 }) ?? [] {
                buckets[style]?[code]?.sort { (stableHash($0.channel.id), $0.channel.id) < (stableHash($1.channel.id), $1.channel.id) }
            }
        }
        var picked: [Row] = []
        var round = 0
        while picked.count < count {
            var tookAny = false
            for style in Style.allCases {
                for code in countries {
                    guard picked.count < count, let rows = buckets[style]?[code], round < rows.count else { continue }
                    picked.append(rows[round])
                    tookAny = true
                }
            }
            if !tookAny { break }
            round += 1
        }
        return picked
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    // MARK: Running

    struct CountryTally: Equatable {
        var sampled = 0, withListings = 0, epgIDPresentInXMLTV = 0, epgIDAbsent = 0, noEpgID = 0
    }

    /// Probes the rows one after another, `spacing` apart, stopping after `consecutiveFailureLimit` failures in a row. Returns the
    /// lines it logged. `isInXMLTV` is nil-returning when the full station list is not known in this launch.
    @discardableResult
    static func probe(
        rows: [Row], nativeID: (LiveTVPrototypeChannel) -> String?, unguidedCount: Int,
        request: (String) async -> LiveTVEPGProbeResult, isInXMLTV: (String) -> Bool?,
        spacing: Duration = requestSpacing, pause: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        log: (String) -> Void = LiveTVDiagnosticLog.notice
    ) async -> [String] {
        var lines: [String] = []
        func emit(_ line: String) { lines.append(line); log(line) }
        var tallies: [String: CountryTally] = [:]
        var answered = 0, failures = 0
        var stoppedEarly = false
        for (offset, row) in rows.enumerated() {
            guard let id = nativeID(row.channel) else { continue }
            if offset > 0 { await pause(spacing) }
            if Task.isCancelled { stoppedEarly = true; break }
            let result = await request(id)
            var tally = tallies[row.country] ?? CountryTally()
            tally.sampled += 1
            var epgState = "none"
            if result.outcome == .answered {
                answered += 1
                failures = 0
                if result.listingCount > 0 { tally.withListings += 1 }
                if let epgID = result.epgID {
                    switch isInXMLTV(epgID.lowercased()) {
                    case true?: tally.epgIDPresentInXMLTV += 1; epgState = "presentInXMLTV"
                    case false?: tally.epgIDAbsent += 1; epgState = "absentFromXMLTV"
                    case nil: epgState = "unknown"
                    }
                } else {
                    tally.noEpgID += 1
                }
            } else {
                failures += 1
            }
            tallies[row.country] = tally
            let status = result.statusClass.map { "\($0)xx" } ?? "none"
            emit("EPG_PROBE row=\(LiveTVGuideSnapshot.clean(row.channel.name)) country=\(row.country) style=\(row.style.rawValue)"
                + " outcome=\(result.outcome.rawValue) httpStatus=\(status) ms=\(result.elapsedMilliseconds)"
                + " epg_listings=\(result.listingCount) epgID=\(epgState)")
            if failures >= consecutiveFailureLimit { stoppedEarly = true; break }
        }
        for code in countries {
            let tally = tallies[code] ?? CountryTally()
            emit("EPG_PROBE summary country=\(code) sampled=\(tally.sampled) withListings=\(tally.withListings)"
                + " epgIdPresentInXMLTV=\(tally.epgIDPresentInXMLTV) epgIdAbsent=\(tally.epgIDAbsent) noEpgId=\(tally.noEpgID)")
        }
        emit("EPG_PROBE summary unguidedRows=\(unguidedCount) sampled=\(rows.count) answered=\(answered)"
            + " withListings=\(tallies.values.reduce(0) { $0 + $1.withListings }) stoppedEarly=\(stoppedEarly)")
        return lines
    }

    /// Called after a guide snapshot capture. Does nothing unless the lineup is complete (no provisional last-seen rows), the
    /// saved guide is readable, the station dump (if owed) is written, and this launch has not probed yet.
    static func run(
        provider: any ServerLiveTVProviding, channels: [LiveTVPrototypeChannel], lineupIsComplete: Bool,
        records: [LiveTVGuideSnapshot.GuideRecord], references: [String: LiveTVServerChannelReference]
    ) async {
        let count = sampleSize()
        guard count > 0, lineupIsComplete, !LiveTVGuideSnapshotWriter.stationDumpOwed() else { return }
        var stations: [String: [String]] = [:]
        var withListings = Set<String>()
        for record in records {
            if record.type == "channel", let id = record.id { stations[id] = record.displayNames ?? [] }
            if record.type == "programme", let channel = record.channel { withListings.insert(channel) }
        }
        guard !stations.isEmpty, takesRun() else { return }
        let coverage = LiveTVGuideCoverage.measure(channels: channels, stations: stations, stationsWithListings: withListings)
        let unguided = coverage.unmatched.filter { references[$0.id] != nil }
        let rows = sample(unguided: unguided, count: count)
        await probe(
            rows: rows, nativeID: { references[$0.id]?.channelID }, unguidedCount: unguided.count,
            request: { await provider.liveTVEPGProbe(channelID: $0, limit: 4) },
            isInXMLTV: { LiveTVGuideSnapshotWriter.knowsFullXMLTV ? LiveTVGuideSnapshotWriter.isInFullXMLTV($0) : nil })
    }
}
