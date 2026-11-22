import Foundation

/// The place a regional channel feed serves ("CBC HALIFAX HD" is Halifax), read from the row's name against the known places
/// (`LiveTVPlaceNames`). The answer is always a canonical place from that table, never text taken from the row.
///
/// Only linear and FAST rows have a region. An event, a 24/7 show loop, a radio station or a section marker names a team, a title
/// or a venue, not a place it serves.
public enum LiveTVChannelRegion {
    /// The canonical places of the row, in the order the name lists them ("ICI TELE OTTAWA-GATINEAU" → Ottawa, Gatineau); empty when none.
    public static func places(for channel: LiveTVPrototypeChannel) -> [String] {
        places(name: channel.name, groups: channel.groups ?? [channel.category])
    }

    /// One place for a label or a tag: the places joined by a hyphen ("Ottawa-Gatineau"); `nil` when the row has no region.
    public static func region(for channel: LiveTVPrototypeChannel) -> String? {
        label(for: places(for: channel))
    }

    public static func label(for places: [String]) -> String? {
        places.isEmpty ? nil : places.joined(separator: "-")
    }

    public static func places(name: String, groups: [String]) -> [String] {
        switch LiveTVChannelKind.classify(name: name, groups: groups) {
        case .linear, .fast: return LiveTVRegionParser.places(inRawName: name)
        case .sectionMarker, .event, .radio, .showLoop: return []
        }
    }
}
