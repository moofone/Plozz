import Foundation

/// A fact a provider put in a channel name: its country or language prefix, or a feed descriptor such as
/// `HD`, `4K`, `HDR`, `RAW`, `60fps` or the backup mark `BK`. Parsed by `IPTVChannelName.split`.
public enum IPTVChannelTag: Hashable, Codable, Sendable {
    /// ISO 3166-1 alpha-2, upper case (`UK` is stored as `GB`).
    case country(String)
    /// ISO 639-1, upper case.
    case language(String)
    case hd, fhd, uhd, k4, k8, hdr, raw, backup
    case fps(Int)
    /// The provider's package label a name carries before its station (`PRIME` in `PRIME: NAME`); see `IPTVChannelName.packagePrefix`.
    case package(String)

    /// The text a badge shows: `4K`, `60fps`, `HDR`, `EN`…
    public var badgeText: String {
        switch self {
        case let .country(code), let .language(code): code
        case .hd: "HD"
        case .fhd: "FHD"
        case .uhd: "UHD"
        case .k4: "4K"
        case .k8: "8K"
        case .hdr: "HDR"
        case .raw: "RAW"
        case .backup: "BK"
        case let .fps(rate): "\(rate)fps"
        case let .package(label): label
        }
    }

    /// 4K and 8K feeds, whichever way the provider wrote them.
    public var isUltraHighDefinition: Bool { self == .uhd || self == .k4 || self == .k8 }

    /// The only badge the guide plate draws: `4K`, `8K` or `nil`. Every other tag stays on the hero and the channel panel.
    public static func ultraHighDefinitionBadge(in tags: [IPTVChannelTag]) -> IPTVChannelTag? {
        if tags.contains(.k8) { return .k8 }
        return tags.contains(where: \.isUltraHighDefinition) ? .k4 : nil
    }

    public var country: String? { if case let .country(code) = self { code } else { nil } }
    public var language: String? { if case let .language(code) = self { code } else { nil } }
    public var package: String? { if case let .package(label) = self { label } else { nil } }
}
