import CoreModels
import Foundation

/// An IPTV slot that carries one live event at a time (PPV, sports packs) instead of a channel.
public struct LiveTVEventSlot: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// No event is streaming, or the slot names no event.
        case idle
        /// An event with its title; `start` is nil when the provider gave none or only a placeholder date.
        case active(title: String, start: Date?)
    }

    public let state: State
    public init(state: State) { self.state = state }

    public var isIdle: Bool { state == .idle }
    public var title: String? { if case let .active(title, _) = state { title } else { nil } }
    public var start: Date? { if case let .active(_, start) = state { start } else { nil } }

    /// A slot's synthetic programme lasts this long: the name carries a start but no end.
    public static let defaultDuration: TimeInterval = 3 * 3_600
}

/// Decides which playlist entries are event slots, once per catalog build. The rules:
///
/// **Event slot** (never a regular channel):
/// - a provider group with the token `PPV` (case-insensitive, superscripts folded), or
/// - a group naming an event pack: the phrases `SUPER SPORTS PACK` or `LIVE EVENTS`, or the token `EVENT`/`EVENTS`, or
/// - a name starting with `- NO EVENT STREAMING -`.
/// The channel's own name is never searched for `PPV`: `PPV Movies` in a normal group stays a channel.
///
/// **Idle**: the name says `NO EVENT STREAMING`, or no title remains once the brand, slot number and
/// stamp are removed (`:TSN+  109`, `(Victory+ 025) |  (2098-12-31 08:00:24)`).
///
/// **Active**: the rest. The title is what follows the first `|` (or ` : `), without a leading `BRAND:` and
/// without a trailing duplicate in parentheses. A trailing `(YYYY-MM-DD HH:MM:SS)` is the start; years of 2090 or later are placeholders and give none.
/// Without a stamp, a trailing `@ Nov 16 19:00` (24-hour, or `7:00 PM`) is the start; it has no year, so the year is the one
/// that puts it within the six months before to six months after `reference`.
///
/// **Time zone assumption**: the stamp has no zone. It is read as wall-clock time in `timeZone` (the viewer's zone
/// by default). One export row pairs `6:00PM ET` in the title with the stamp `18:00:15`, so providers may write
/// Eastern time; nothing in the playlist declares it, so no correction is applied.
public enum LiveTVEventSlotClassifier {
    /// The `LiveTVPrototypeModel.category` value that selects the Events filter. Never a provider group.
    public static let filterName = "\u{1}plozz.events"

    public static func classify(
        name: String, groups: [String], timeZone: TimeZone = .current, reference: Date = Date()
    ) -> LiveTVEventSlot? {
        let text = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let placeholder = text.range(of: "NO EVENT STREAMING", options: .caseInsensitive) != nil
        guard isEventSlot(name: name, groups: groups) else { return nil }
        if placeholder { return LiveTVEventSlot(state: .idle) }
        let parsed = title(in: text, timeZone: timeZone, reference: reference)
        guard let title = parsed.title, !title.isEmpty else { return LiveTVEventSlot(state: .idle) }
        return LiveTVEventSlot(state: .active(title: title, start: parsed.start))
    }

    /// Whether the entry is an event slot at all: the one rule for the Events filter and for logo matching (an event is not a channel,
    /// so no logo is matched for it). A provider group that names events, or a name that is `NO EVENT STREAMING`, a `PPV EVENT`,
    /// a `SPORTS PACK` bundle, a numbered `LIVE EVENTS 3` slot (`isNumberedLiveEventSlot`) or carries a `(YYYY-MM-DD HH:MM)` stamp.
    public static func isEventSlot(name: String, groups: [String]) -> Bool {
        groups.contains(where: isEventGroup) || eventName.matches(name) || numberedSlot.matches(name)
    }

    private static let eventName = LiveTVNameRegex(
        #"\(\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?\)|NO EVENT STREAMING|\bPPV EVENT\b|\bSPORTS PACK\b"#, caseInsensitive: true
    )

    /// A numbered slot a network names for its own live coverage (`CTV NEWS LIVE EVENTS 3`): an event slot for the guide and the
    /// Events filter, but the network's brand still names it, so logo matching reads it as a channel.
    public static func isNumberedLiveEventSlot(name: String) -> Bool { numberedSlot.matches(name) }

    private static let numberedSlot = LiveTVNameRegex(#"\bLIVE EVENTS?\s+\d{1,2}\b"#, caseInsensitive: true)

    /// A cheap superset of what `classify` accepts, so a catalog build only classifies the few candidates:
    /// a provider group that names events, or a name containing `EVENT` (for `NO EVENT STREAMING`).
    static func isCandidate(name: String, groups: [String], groupIsEvent: (String) -> Bool) -> Bool {
        groups.contains(where: groupIsEvent) || mentionsEvent(name)
    }

    private static func mentionsEvent(_ name: String) -> Bool {
        var matched = 0
        let word: [UInt8] = Array("EVENT".utf8)
        for byte in name.utf8 {
            let upper = byte >= 97 && byte <= 122 ? byte - 32 : byte
            if upper == word[matched] {
                matched += 1
                if matched == word.count { return true }
            } else {
                matched = upper == word[0] ? 1 : 0
            }
        }
        return false
    }

    static func isEventGroup(_ group: String) -> Bool {
        let tokens = IPTVChannelName.foldingSuperscripts(group).uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains("PPV") || tokens.contains("EVENT") || tokens.contains("EVENTS") { return true }
        let phrase = tokens.joined(separator: " ")
        return eventPackPhrases.contains { phrase.contains($0) }
    }

    private static let eventPackPhrases = ["SUPER SPORTS PACK", "LIVE EVENTS"]

    private static let stampPattern = #"\s*\((\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\)\s*$"#
    private static let trailingSlotPattern = #"\s+:[^:|]*?\s+\d{1,3}\s*$"#
    private static let brandPrefixPattern = #"^[A-Za-z0-9+]{2,16}:\s+"#

    private static let atStartPattern = #"\s+@\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})\s+(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?\s*$"#
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func title(in name: String, timeZone: TimeZone, reference: Date) -> (title: String?, start: Date?) {
        var text = name
        var start: Date?
        var hasStamp = false
        if let range = text.range(of: stampPattern, options: .regularExpression) {
            hasStamp = true
            start = date(from: String(text[range]), timeZone: timeZone)
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        var title: String
        if let bar = text.firstIndex(of: "|") {
            title = String(text[text.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix(":") {
            return (nil, start) // ":TSN+  109": a bare slot
        } else {
            if let range = text.range(of: trailingSlotPattern, options: .regularExpression) { text.removeSubrange(range) }
            var hasAtStart = false
            if let range = text.range(of: atStartPattern, options: .regularExpression),
               let parsed = atStart(String(text[range]), timeZone: timeZone, reference: reference) {
                hasAtStart = true
                start = parsed
                text.removeSubrange(range)
            }
            if let colon = text.range(of: " : ") {
                title = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if hasStamp || hasAtStart {
                title = text
            } else if IPTVChannelName.looksLikeEvent(text) {
                title = text
            } else {
                return (nil, start)
            }
        }
        if let range = title.range(of: brandPrefixPattern, options: .regularExpression) { title.removeSubrange(range) }
        title = withoutDuplicateParenthetical(title)
        return (title.isEmpty ? nil : title, start)
    }

    /// The service an event slot streams on, as the provider wrote it: the trailing `:TSN+ 29` of a name such as
    /// `2025 STIHL Timbersports @ Nov 17 13:30 :TSN+ 29`, or the `(Victory+ 025)` that leads `(Victory+ 025) | Title`. Nil when the name has neither.
    public static func service(in name: String) -> String? {
        let text = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let range = text.range(of: trailingSlotPattern, options: .regularExpression) {
            let service = text[range].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return service.isEmpty ? nil : service
        }
        if let range = text.range(of: #"^(?:[A-Z]{2} )?\(([^)]+? \d{1,3})\) \|"#, options: .regularExpression) {
            let inner = text[range].drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            return inner.isEmpty ? nil : String(inner)
        }
        return nil
    }

    /// `@ Nov 16 19:00` or `@ Nov 16 7:00 PM`.
    private static func atStart(_ text: String, timeZone: TimeZone, reference: Date) -> Date? {
        let parts = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // parts: month, day, hour, minute, optional AM/PM
        guard parts.count >= 4, let month = months.firstIndex(of: String(parts[0].lowercased().prefix(3))),
              let day = Int(parts[1]), var hour = Int(parts[2]), let minute = Int(parts[3]),
              (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if parts.count >= 5 {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (parts[4].lowercased() == "pm" ? 12 : 0)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: reference)
        let candidates = [year - 1, year, year + 1].compactMap {
            calendar.date(from: DateComponents(year: $0, month: month + 1, day: day, hour: hour, minute: minute))
        }
        return candidates.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    /// `Tennessee vs. Belmont (Tennessee vs. Belmont)` becomes `Tennessee vs. Belmont`.
    private static func withoutDuplicateParenthetical(_ title: String) -> String {
        guard title.hasSuffix(")"), let open = title.lastIndex(of: "("), open > title.startIndex else { return title }
        let head = title[..<open].trimmingCharacters(in: .whitespaces)
        let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
        return head == inner ? head : title
    }

    private static func date(from stamp: String, timeZone: TimeZone) -> Date? {
        let numbers = stamp.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 6, numbers[0] < 2090 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5]))
    }
}

/// Infers the zone a playlist source writes its event stamps in, once per catalog build.
///
/// A source's event names that carry both a stamp `(YYYY-MM-DD HH:MM:SS)` and an explicit zone
/// (`6:00PM ET`, `19:00 UTC`; `ET`/`EST`/`EDT`, `PT`, `CT`, `MT`, `GMT`/`UTC`, `AST`) are samples. A sample matches when the
/// stamp's wall-clock hour and minute equal the named time. When one zone has at least `minimumSamples` samples and at least
/// `agreement` of them match, that zone reads every stamp of the source; otherwise the answer is nil and the viewer's zone applies.
public enum LiveTVEventTimeZoneInference {
    public struct Result: Equatable, Sendable {
        public let timeZone: TimeZone
        public let abbreviation: String
        public let matches: Int
        public let samples: Int
    }

    public static let minimumSamples = 5
    public static let agreement = 0.8

    public static func infer(from names: some Sequence<String>) -> Result? {
        var tally: [String: (matches: Int, samples: Int)] = [:]
        for name in names {
            guard let sample = sample(in: name) else { continue }
            var entry = tally[sample.zone, default: (0, 0)]
            entry.samples += 1
            if sample.matches { entry.matches += 1 }
            tally[sample.zone] = entry
        }
        // Ties (same samples) resolve by name so the answer never depends on dictionary order.
        let best = tally
            .filter { $0.value.samples >= minimumSamples && Double($0.value.matches) >= agreement * Double($0.value.samples) }
            .max { ($0.value.matches, $1.key) < ($1.value.matches, $0.key) }
        guard let best, let identifier = zoneIdentifiers[best.key], let timeZone = TimeZone(identifier: identifier) else { return nil }
        return Result(timeZone: timeZone, abbreviation: best.key, matches: best.value.matches, samples: best.value.samples)
    }

    private static let zoneIdentifiers = [
        "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
        "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
        "MT": "America/Denver", "MST": "America/Denver", "MDT": "America/Denver",
        "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "AST": "America/Halifax", "GMT": "UTC", "UTC": "UTC"
    ]

    private static let stampPattern = #"\((\d{4})-\d{2}-\d{2} (\d{2}):(\d{2}):\d{2}\)\s*$"#
    private static let namedTimePattern = #"\b(\d{1,2})(?::(\d{2}))?\s?([AaPp][Mm])?\s+(ET|EST|EDT|CT|CST|CDT|MT|MST|MDT|PT|PST|PDT|AST|GMT|UTC)\b"#

    /// The named zone (as `ET`, `PT`…, one tally per spelling family) and whether the stamp equals the named time.
    private static func sample(in name: String) -> (zone: String, matches: Bool)? {
        guard let stampRange = name.range(of: stampPattern, options: .regularExpression) else { return nil }
        let stamp = name[stampRange].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard stamp.count == 6, stamp[0] < 2090 else { return nil }
        let title = name[..<stampRange.lowerBound]
        guard let namedRange = title.range(of: namedTimePattern, options: .regularExpression) else { return nil }
        let words = title[namedRange].split(whereSeparator: { $0 == " " })
        guard let zoneWord = words.last else { return nil }
        let zone = canonicalZone(String(zoneWord))
        let digits = title[namedRange].dropLast(zoneWord.count).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard var hour = digits.first else { return nil }
        let minute = digits.count > 1 ? digits[1] : 0
        let lower = title[namedRange].lowercased()
        let hasMeridiem = lower.contains("am") || lower.contains("pm")
        if hasMeridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (lower.contains("pm") ? 12 : 0)
        } else if digits.count < 2 || hour > 23 {
            return nil // a bare number before a zone ("Channel 5 ET") is not a time
        }
        return (zone, hour == stamp[3] && minute == stamp[4])
    }

    /// `EST`/`EDT` count as `ET`, and so on: the stamp is wall-clock time in the named region, summer or winter.
    private static func canonicalZone(_ word: String) -> String {
        switch word {
        case "EST", "EDT": "ET"
        case "CST", "CDT": "CT"
        case "MST", "MDT": "MT"
        case "PST", "PDT": "PT"
        case "GMT": "UTC"
        default: word
        }
    }
}
