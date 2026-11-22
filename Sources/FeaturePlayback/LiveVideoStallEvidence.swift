#if canImport(AVFoundation)
import Foundation

/// "The audio plays, the engine reports a video track, and no frame was ever presented."
///
/// The engine's own watchdogs never see this: AVPlayer keeps playing audio and drops every video
/// frame the decoder rejects. Evidence is the audio position advancing `requiredPlayedSeconds` since
/// the first playing sample of an attempt, so it follows media time, not the wall clock.
struct LiveVideoStallEvidence {
    static let requiredPlayedSeconds: TimeInterval = 6

    private var baseline: TimeInterval?

    /// Forget the attempt's baseline: a new load, a retry or a programme boundary.
    mutating func reset() { baseline = nil }

    /// True once the evidence is complete. A presented frame, a paused or buffering engine, or a
    /// stream without a video track clears it: those are other failures with their own limits.
    mutating func observe(_ snapshot: LiveChannelEngineSnapshot, hasVideoTrack: Bool) -> Bool {
        guard snapshot.phase == .playing, !snapshot.firstFrameReady, hasVideoTrack,
              snapshot.position.isFinite else {
            baseline = nil
            return false
        }
        guard let start = baseline, snapshot.position >= start else {
            baseline = snapshot.position
            return false
        }
        return snapshot.position - start >= Self.requiredPlayedSeconds
    }
}
#endif
