import Foundation

/// Pure formatting for the Live TV glass browse screen: counts and time left,
/// read at a glance. Shared by the hero, the heading pill and the panels so a
/// number is never spelled two ways.
public enum LiveTVGlassFormatting {
    /// A start time as the mockup's `hm` draws it: `7:00`, with no AM/PM (24-hour locales keep their 24-hour form).
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        if !formatter.dateFormat.contains("'") {
            formatter.dateFormat = formatter.dateFormat
                .replacingOccurrences(of: "a", with: "")
                .replacingOccurrences(of: "\u{202f}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return formatter.string(from: date)
    }

    /// Exact below a thousand, then thousands with one decimal (14,835 → "14.8k").
    /// The decimal stays ("4.0k", never "4k", which would read as a 4K badge) and
    /// the value rounds down, so it never promises more than there is.
    public static func shortCount(_ count: Int) -> String {
        let count = max(0, count)
        if count < 1_000 { return String(count) }
        if count < 100_000 {
            let tenths = count / 100
            return "\(tenths / 10).\(tenths % 10)k"
        }
        return "\(count / 1_000)k"
    }

    /// Whole minutes left, rounded down, or nil once the programme is over or
    /// less than a minute remains.
    static func minutesLeft(_ remaining: TimeInterval) -> Int? {
        guard remaining.isFinite else { return nil }
        let minutes = Int(remaining / 60)
        return minutes > 0 ? minutes : nil
    }

    /// "8m left", "1h 5m left", "1h left"; nil when nothing is left to say.
    public static func leftShort(remaining: TimeInterval) -> LocalizedStringResource? {
        guard let total = minutesLeft(remaining) else { return nil }
        let hours = total / 60, minutes = total % 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes)m left"
        case (_, 0): return "\(hours)h left"
        default: return "\(hours)h \(minutes)m left"
        }
    }

    /// "42 min left", "1 hr 5 min left", "1 hr left", for the channel panel.
    public static func leftLong(remaining: TimeInterval) -> LocalizedStringResource? {
        guard let total = minutesLeft(remaining) else { return nil }
        let hours = total / 60, minutes = total % 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes) min left"
        case (_, 0): return "\(hours) hr left"
        default: return "\(hours) hr \(minutes) min left"
        }
    }
}
