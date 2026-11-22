import Foundation

/// The on-disk format of a Live TV guide snapshot: the raw INPUT of the lineup and tag parsing, captured by the DEBUG launch
/// argument `-PlozzLiveTVMetadataAudit`, so deterministic tests can replay it. Version 1.
///
/// Files, under `Documents/live-tv-snapshot/` in the app container (JSON Lines are one object per line, dates ISO 8601 UTC):
/// - `manifest.json`: one `Manifest`.
/// - `channels.jsonl`: one `Channel` per row the provider's list held, read before any lineup cut.
/// - `guide.jsonl`: one `GuideRecord` per XMLTV channel (`type == "channel"`) and per programme of a 48 hour window
///   (`type == "programme"`), taken from the guide store.
///
/// Never present: stream URLs, logo or artwork URLs, tokens, credentials. Text that looks like a URL is replaced (`clean`).
/// The latest read replaces the snapshot; a later read of a different source replaces it too.
public enum LiveTVGuideSnapshot {
    public static let schemaVersion = 1
    public static let directoryName = "live-tv-snapshot"
    public static let manifestFileName = "manifest.json"
    public static let channelsFileName = "channels.jsonl"
    public static let guideFileName = "guide.jsonl"
    /// The programme window captured: 48 hours from the capture time.
    public static let guideWindow: TimeInterval = 48 * 3_600

    public struct Manifest: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var capturedAt: Date
        /// "server" or "playlist": which read produced `channels.jsonl`.
        public var sourceKind: String
        /// Rows the provider's list held (all of them are in `channels.jsonl` unless `truncated`).
        public var channelCount: Int
        public var guideChannelCount: Int
        public var programmeCount: Int
        public var guideWindowStart: Date?
        public var guideWindowEnd: Date?
        /// A file stopped at its size cap.
        public var truncated: Bool

        public init(
            schemaVersion: Int = LiveTVGuideSnapshot.schemaVersion, capturedAt: Date, sourceKind: String, channelCount: Int,
            guideChannelCount: Int = 0, programmeCount: Int = 0, guideWindowStart: Date? = nil, guideWindowEnd: Date? = nil,
            truncated: Bool = false
        ) {
            self.schemaVersion = schemaVersion
            self.capturedAt = capturedAt
            self.sourceKind = sourceKind
            self.channelCount = channelCount
            self.guideChannelCount = guideChannelCount
            self.programmeCount = programmeCount
            self.guideWindowStart = guideWindowStart
            self.guideWindowEnd = guideWindowEnd
            self.truncated = truncated
        }
    }

    /// One row of the provider's list as it was read.
    public struct Channel: Codable, Equatable, Sendable {
        /// The id the app gives the row (what programmes and favourites refer to). Not a stream URL.
        public var stableID: String
        public var number: String?
        public var name: String
        /// The provider's group titles, as written.
        public var groups: [String]
        /// `tvg-id` / `epg_channel_id`, and `tvg-name`.
        public var epgID: String?
        public var tvgName: String?
        /// The provider's own country value, when it sends one.
        public var country: String?
        /// "linear", "event", "showLoop" or "fast" (`LiveTVChannelKind`).
        public var kind: String
        /// The provider says it is radio.
        public var isRadio: Bool
        /// The lineup read it as adult (group or name).
        public var isAdult: Bool

        public init(
            stableID: String, number: String?, name: String, groups: [String], epgID: String?, tvgName: String?, country: String?,
            kind: String, isRadio: Bool, isAdult: Bool
        ) {
            self.stableID = stableID
            self.number = number
            self.name = name
            self.groups = groups
            self.epgID = epgID
            self.tvgName = tvgName
            self.country = country
            self.kind = kind
            self.isRadio = isRadio
            self.isAdult = isAdult
        }
    }

    /// A line of `guide.jsonl`: `type` is "channel" (`id`, `displayNames`) or "programme" (the rest).
    public struct GuideRecord: Codable, Equatable, Sendable {
        public var type: String
        public var id: String?
        public var displayNames: [String]?
        /// The app's channel id (`Channel.stableID`) the programme belongs to.
        public var channel: String?
        public var start: Date?
        public var end: Date?
        public var title: String?
        public var subTitle: String?
        public var categories: [String]?
        /// The XMLTV `<video><quality>`; the importer does not keep it, so this is nil in every capture so far.
        public var quality: String?
        public var episode: String?

        public init(
            type: String, id: String? = nil, displayNames: [String]? = nil, channel: String? = nil, start: Date? = nil,
            end: Date? = nil, title: String? = nil, subTitle: String? = nil, categories: [String]? = nil, quality: String? = nil,
            episode: String? = nil
        ) {
            self.type = type
            self.id = id
            self.displayNames = displayNames
            self.channel = channel
            self.start = start
            self.end = end
            self.title = title
            self.subTitle = subTitle
            self.categories = categories
            self.quality = quality
            self.episode = episode
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Decodes a JSON Lines file's contents.
    public static func decodeLines<Value: Decodable>(_ type: Value.Type, from text: String) throws -> [Value] {
        let decoder = makeDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(Value.self, from: Data($0.utf8)) }
    }

    /// `text` with every word that looks like a URL replaced by `[url]`, so no address, credential or token reaches a snapshot.
    public static func clean(_ text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("://") || lower.contains("http") || lower.contains("www.") else { return text }
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let value = word.lowercased()
            return value.contains("://") || value.contains("http") || value.hasPrefix("www.") ? "[url]" : String(word)
        }.joined(separator: " ")
    }
}
