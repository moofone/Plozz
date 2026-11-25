import CryptoKit
import Foundation

/// How far behind live one source's Automatic cushion currently sits. The ladder starts at the
/// engine's normal holdback (step 0, `nil`) so a first tune joins as fast as before; every stall
/// moves up one step and sustained stable playback moves back down one. Only Automatic adapts:
/// an explicit `LivePlaybackBuffer` choice never consults this type.
public struct LiveBufferAdaptation: Codable, Equatable, Sendable {
    /// Cushion per step in seconds; step 0 is the engine's own holdback. 30 s is the cap: it is
    /// the largest cushion HLS retains without a user-chosen DVR policy and costs ~15-30 MB.
    public static let steps: [TimeInterval?] = [nil, 4, 8, 15, 30]
    /// One growth step per this many seconds, however many stalls land inside it.
    public static let growthDebounceSeconds: TimeInterval = 60
    /// Stall-free playback needed to give one step back.
    public static let stableSecondsPerDecay: TimeInterval = 600
    /// A buffering spell shorter than this is not counted as a stall.
    public static let minimumStallSeconds: TimeInterval = 1.5

    public private(set) var stepIndex = 0
    public private(set) var lastGrowthAt: Date?
    public private(set) var stableSeconds: TimeInterval = 0

    public init() {}

    public var targetSeconds: TimeInterval? { Self.steps[stepIndex] }

    /// A stall always restarts the stable-playback clock; it grows the cushion at most once per debounce window.
    public mutating func recordStall(at date: Date) {
        stableSeconds = 0
        if let lastGrowthAt, date.timeIntervalSince(lastGrowthAt) < Self.growthDebounceSeconds,
           date >= lastGrowthAt { return }
        guard stepIndex < Self.steps.count - 1 else { return }
        stepIndex += 1
        lastGrowthAt = date
    }

    public mutating func recordStablePlayback(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, stepIndex > 0 else { return }
        stableSeconds += seconds
        while stableSeconds >= Self.stableSecondsPerDecay, stepIndex > 0 {
            stableSeconds -= Self.stableSecondsPerDecay
            stepIndex -= 1
        }
        if stepIndex == 0 { stableSeconds = 0 }
    }
}

/// Device-local adaptation state per profile and source. Keys are salted hashes, so neither a
/// provider id, a URL nor a channel name is stored. Bounded to the most recently updated sources.
public struct LiveBufferAdaptationStore {
    public static let storageKey = "com.plozz.liveBufferAdaptation"
    public static let capacity = 64
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(namespace: String?, sourceID: String) -> String {
        let digest = SHA256.hash(data: Data("plozz.liveBuffer.v1|\(namespace ?? "")|\(sourceID)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The Automatic cushion for the next tune, `nil` meaning the engine's normal holdback.
    public func targetSeconds(namespace: String?, sourceID: String) -> TimeInterval? {
        entries()[Self.key(namespace: namespace, sourceID: sourceID)]?.adaptation.targetSeconds
    }

    public func recordStall(namespace: String?, sourceID: String, at date: Date = Date()) {
        update(namespace: namespace, sourceID: sourceID, at: date) { $0.recordStall(at: date) }
    }

    public func recordStablePlayback(namespace: String?, sourceID: String, seconds: TimeInterval, at date: Date = Date()) {
        update(namespace: namespace, sourceID: sourceID, at: date) { $0.recordStablePlayback(seconds: seconds) }
    }

    private struct Entry: Codable {
        var adaptation: LiveBufferAdaptation
        var updatedAt: Date
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }

    private func update(
        namespace: String?, sourceID: String, at date: Date, _ change: (inout LiveBufferAdaptation) -> Void
    ) {
        var all = entries()
        let key = Self.key(namespace: namespace, sourceID: sourceID)
        var entry = all[key] ?? Entry(adaptation: LiveBufferAdaptation(), updatedAt: date)
        change(&entry.adaptation)
        entry.updatedAt = date
        // A source back at the engine's holdback with no pending decay carries no information.
        if entry.adaptation.stepIndex == 0, entry.adaptation.stableSeconds == 0 {
            all[key] = nil
        } else {
            all[key] = entry
        }
        if all.count > Self.capacity {
            let stale = all.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(all.count - Self.capacity)
            for (staleKey, _) in stale { all[staleKey] = nil }
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One playback's view of the store: the profile and source it belongs to.
public struct LiveBufferAdaptationScope {
    public let namespace: String?
    public let sourceID: String
    private let store: LiveBufferAdaptationStore

    public init(namespace: String?, sourceID: String, store: LiveBufferAdaptationStore = .init()) {
        self.namespace = namespace
        self.sourceID = sourceID
        self.store = store
    }

    public func targetSeconds() -> TimeInterval? {
        store.targetSeconds(namespace: namespace, sourceID: sourceID)
    }

    public func recordStall() {
        store.recordStall(namespace: namespace, sourceID: sourceID)
    }

    public func recordStablePlayback(seconds: TimeInterval) {
        store.recordStablePlayback(namespace: namespace, sourceID: sourceID, seconds: seconds)
    }
}
