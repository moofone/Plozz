import Foundation

/// A provider event stamp that is always upcoming. Event rows whose `(YYYY-MM-DD HH:MM:SS)` stamp is more than a slot's
/// duration in the past are ended placeholders and leave the catalog (`LiveTVPlaceholder`), so a fixed date in a fixture turns
/// a test about live events into one about ended events once that date passes.
struct LiveTVEventStamp {
    /// The stamp's text, `yyyy-MM-dd HH:mm:ss` without the brackets.
    let stamp: String
    /// The same wall-clock time as providers write it in a title, `6:00PM`.
    let clock: String
    /// The instant the stamp names when read in its zone.
    let date: Date

    /// The next whole hour at least `hoursAhead` hours after `now`, written in `zone`, with `seconds` on the stamp (providers
    /// write `18:00:15`).
    static func upcoming(hoursAhead: Int = 2, in zone: TimeZone = .current, seconds: Int = 0, now: Date = Date()) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let later = now.addingTimeInterval(TimeInterval(hoursAhead) * 3_600)
        let hour = calendar.dateInterval(of: .hour, for: later)!.start
        let date = hour.addingTimeInterval(TimeInterval(seconds))
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        return Self(stamp: format("yyyy-MM-dd HH:mm:ss"), clock: format("h:mma"), date: date)
    }
}
