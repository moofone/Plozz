import CoreGraphics
import FeatureLiveTVCore
import Foundation

/// The My Channels set-up page's geometry (the mockup's `lineupLayout`, 1080p units): the tag picker's sheet with a subtitle line, so the
/// search row sits 48 lower.
enum LiveTVGlassLineupMetrics {
    typealias Base = LiveTVGlassTagPickerMetrics
    static let subtitleSize: CGFloat = 25
    static let subtitleTop: CGFloat = Base.padding + Base.titleHeight + 10
    static let sublabelSize: CGFloat = 23
    static let keepRowHeight: CGFloat = 60
    static let keepRowHeightWithNote: CGFloat = 76
    static let keepRowRadius: CGFloat = 22

    /// The search row's top: padding, the title row, 14, the subtitle line (34) and 22.
    static var fixedRowTop: CGFloat { Base.padding + Base.titleHeight + 14 + 34 + 22 }
    static var fixedHeight: CGFloat { fixedRowTop + Base.chipHeight + 18 }
}

/// What the page says, in one place so the copy can be reviewed and tested.
enum LiveTVGlassLineupText {
    static var title: String { String(localized: "My Channels") }
    static var subtitle: String { String(localized: "Only these channels are loaded, given guides and searched.") }
    static var findCountry: String { String(localized: "Find a country") }
    static var apply: String { String(localized: "Apply") }
    static var withoutCountryNote: String { String(localized: "Kept unless you remove them — the 4K groups are here.") }
    static var adultNote: String { String(localized: "Off unless turned on with the Parental PIN. Never on Kids profiles.") }
    static var alwaysKeep: String { String(localized: "Always Keep") }

    static func count(kept: Int, total: Int) -> String {
        String(localized: "\(kept.formatted()) of \(total.formatted()) channels")
    }

    static func noMatch(_ query: String) -> String { String(localized: "No countries match “\(query)”") }

    struct KeepRow: Equatable {
        let keep: LiveTVLineupKeep
        let title: String
        let note: String?
        var height: CGFloat { note == nil ? LiveTVGlassLineupMetrics.keepRowHeight : LiveTVGlassLineupMetrics.keepRowHeightWithNote }
    }

    static var keepRows: [KeepRow] {
        [
            KeepRow(keep: .favouritesAndRecents, title: String(localized: "Favourites and Recently Watched"), note: nil),
            KeepRow(keep: .liveEvents, title: String(localized: "All Live Events"), note: String(localized: "From every country")),
            KeepRow(keep: .searchLeftOut, title: String(localized: "Left-out Channels in Search"), note: String(localized: "By name only, without guide"))
        ]
    }
}
