import Foundation

/// Where one live start spent its time, as milliseconds only: no URLs, hosts or channel names.
/// `selectedAt` is when the model took the channel; `addressAt` is when it handed the delivery
/// address to the engine; the relay's first upstream byte arrives as an offset from relay start.
struct LiveStartTiming {
    /// Opaque correlation id for one start.
    let id: String
    private let selectedAt: TimeInterval
    private var addressAt: TimeInterval?
    private var firstFrameAt: TimeInterval?
    private var stallStartedAt: TimeInterval?
    private(set) var rebuffers = 0

    init(selectedAt: TimeInterval, id: String = String(UUID().uuidString.prefix(8))) {
        self.selectedAt = selectedAt
        self.id = id
    }

    var hasPresentedFirstFrame: Bool { firstFrameAt != nil }

    /// The first address wins: a retry does not move the start of the address-to-byte span.
    mutating func markAddressResolved(at uptime: TimeInterval) {
        if addressAt == nil { addressAt = uptime }
    }

    /// Returns the summary line the first time a frame is presented, otherwise nil.
    mutating func markFirstFrame(at uptime: TimeInterval, relayFirstByteMilliseconds: Int?) -> String? {
        guard firstFrameAt == nil else { return nil }
        firstFrameAt = uptime
        let address = min(max(addressAt ?? selectedAt, selectedAt), uptime)
        let selectToAddress = Self.milliseconds(address - selectedAt)
        let total = Self.milliseconds(uptime - selectedAt)
        let afterAddress = Self.milliseconds(uptime - address)
        guard let relayFirstByteMilliseconds else {
            return "LIVE_START id=\(id) select→address=\(selectToAddress)ms"
                + " address→firstUpstreamByte=unknown firstByte→firstFrame=unknown"
                + " address→firstFrame=\(afterAddress)ms total=\(total)ms rebuffers=\(rebuffers)"
        }
        let toByte = min(max(0, relayFirstByteMilliseconds), afterAddress)
        return "LIVE_START id=\(id) select→address=\(selectToAddress)ms"
            + " address→firstUpstreamByte=\(toByte)ms firstByte→firstFrame=\(afterAddress - toByte)ms"
            + " address→firstFrame=\(afterAddress)ms total=\(total)ms rebuffers=\(rebuffers)"
    }

    /// Feeds the buffering state after the first frame. Returns a line when a stall ends.
    mutating func observeBuffering(_ isBuffering: Bool, at uptime: TimeInterval) -> String? {
        guard firstFrameAt != nil else { return nil }
        if isBuffering {
            if stallStartedAt == nil {
                stallStartedAt = uptime
                rebuffers += 1
            }
            return nil
        }
        guard let started = stallStartedAt else { return nil }
        stallStartedAt = nil
        return "LIVE_STALL id=\(id) n=\(rebuffers) duration=\(Self.milliseconds(uptime - started))ms"
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(86_400_000, max(0, (seconds * 1_000).rounded())))
    }
}
