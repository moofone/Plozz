import Foundation

/// The resolution label Live TV shows for a channel once its real resolution is known.
///
/// A label is only ever made from decoded pixels. Upscaled content cannot be detected, so a label is never better than the decoded
/// height, and it replaces the provider's name claim (`HD`, `FHD`, `UHD`, `4K`), which is untrusted.
public enum LiveChannelResolutionLabel: String, Codable, Equatable, Sendable {
    case ultraHD, fullHD, hd, sd

    /// ≥ 2000 lines is 4K, ≥ 1000 is 1080p, ≥ 700 is 720p, anything else SD.
    public init(height: Int) {
        switch height {
        case 2_000...: self = .ultraHD
        case 1_000...: self = .fullHD
        case 700...: self = .hd
        default: self = .sd
        }
    }

    /// Verbatim tokens: `4K`, `1080p`, `720p`, `SD`.
    public var text: String {
        switch self {
        case .ultraHD: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .sd: "SD"
        }
    }

    public var isUltraHD: Bool { self == .ultraHD }
}

/// Finds the resolution one play held longest: samples of the decoded height over time, ignoring the first 10 s of the play, so a
/// brief adaptive dip or spike does not win. Playback only; it never requests anything.
public struct LiveChannelResolutionRecorder: Sendable {
    public static let settleSeconds: TimeInterval = 10

    private var start: Date?
    private var lastSample: (time: Date, height: Int)?
    private var held: [Int: TimeInterval] = [:]

    public init() {}

    /// Records the decoded height seen at `time`. A height of 0 or less (nothing decoded yet) ends the current run without counting.
    public mutating func record(height: Int, at time: Date) {
        if start == nil { start = time }
        if let last = lastSample, last.height > 0 {
            let from = max(last.time, (start ?? time).addingTimeInterval(Self.settleSeconds))
            if time > from { held[last.height, default: 0] += time.timeIntervalSince(from) }
        }
        lastSample = (time, height)
    }

    /// The height held longest after the settle period, or `nil` when nothing was held long enough to count.
    public func steadyHeight(endingAt end: Date) -> Int? {
        var copy = self
        if let last = lastSample { copy.record(height: last.height, at: max(end, last.time)) }
        return copy.held.filter { $0.value > 0 }
            .max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }
}

/// The measured resolution of each channel: the most common steady-state height over its last five plays. Not profile data and holds
/// no personal information, only a source ID, a channel ID and heights.
public final class LiveChannelMeasuredQualityStore: @unchecked Sendable {
    public static let playsKept = 5
    private static let version = 1

    public static let shared = LiveChannelMeasuredQualityStore(fileURL: defaultFileURL())

    private struct Document: Codable {
        var version = LiveChannelMeasuredQualityStore.version
        /// `sourceID|channelID` → heights of the last plays, oldest first.
        var plays: [String: [Int]] = [:]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var document = Document()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Document.self, from: data),
           stored.version == Self.version { document = stored }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true).appendingPathComponent("LiveTVQuality", isDirectory: true)
            .appendingPathComponent("measured.json")
    }

    private static func key(_ sourceID: String, _ channelID: String) -> String { "\(sourceID)|\(channelID)" }

    /// Adds one play's steady-state height and keeps the last five.
    public func record(height: Int, sourceID: String, channelID: String) {
        guard height > 0 else { return }
        lock.withLock {
            var plays = document.plays[Self.key(sourceID, channelID), default: []]
            plays.append(height)
            document.plays[Self.key(sourceID, channelID)] = Array(plays.suffix(Self.playsKept))
            if let data = try? JSONEncoder().encode(document) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// The channel's measured height: the most common height among its last five plays (a tie goes to the most recent), or `nil`.
    public func measuredHeight(sourceID: String, channelID: String) -> Int? {
        let plays = lock.withLock { document.plays[Self.key(sourceID, channelID)] ?? [] }
        var counts: [Int: Int] = [:]
        for height in plays { counts[height, default: 0] += 1 }
        guard let best = counts.values.max() else { return nil }
        return plays.last { counts[$0] == best }
    }

    public func label(sourceID: String, channelID: String) -> LiveChannelResolutionLabel? {
        measuredHeight(sourceID: sourceID, channelID: channelID).map(LiveChannelResolutionLabel.init(height:))
    }
}

extension IPTVChannelTag {
    /// Whether the tag is a resolution claim the name makes.
    public var isResolutionClaim: Bool { self == .hd || self == .fhd || self == .uhd || self == .k4 || self == .k8 }

    /// The tags to show: the name's resolution claims (`HD`, `FHD`, `UHD`, `4K`, `8K`) are replaced by the measured label once there is
    /// one, and kept as claimed before. Returns display text in the original order, the label in place of the first claim.
    public static func displayTexts(for tags: [IPTVChannelTag], measured: LiveChannelResolutionLabel?) -> [String] {
        // A package label says where the provider filed the row, not what the feed is: it is never a badge.
        let tags = tags.filter { $0.package == nil }
        guard let measured else { return tags.map(\.badgeText) }
        var texts: [String] = []
        var placed = false
        for tag in tags {
            if tag.isResolutionClaim {
                if !placed { texts.append(measured.text); placed = true }
            } else {
                texts.append(tag.badgeText)
            }
        }
        if !placed { texts.append(measured.text) }
        return texts
    }

    /// The guide plate's 4K badge: the name's claim, unless the channel was measured below 2000 lines, which removes it.
    public static func guideBadge(in tags: [IPTVChannelTag], measured: LiveChannelResolutionLabel?) -> IPTVChannelTag? {
        if let measured, !measured.isUltraHD { return nil }
        return ultraHighDefinitionBadge(in: tags)
    }
}
