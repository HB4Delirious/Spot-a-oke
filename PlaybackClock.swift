import Foundation
import QuartzCore

/// Keeps a smooth, high-resolution estimate of Spotify's playback position.
///
/// Asking Spotify for `player position` over Apple Events costs ~10-20 ms and we only
/// do it a couple of times a second. In between, we run a free-wheeling clock anchored
/// to the last known-good sample. Each new sample nudges the clock back toward truth
/// instead of snapping it, so the lyrics never visibly stutter.
final class PlaybackClock {

    /// Anything larger than this is a seek or a track change, not drift. Snap immediately.
    private let hardSnapThreshold: Double = 0.40
    /// Fraction of the remaining error we absorb per sample. Lower = smoother, slower to converge.
    private let softCorrection: Double = 0.25

    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()

    private(set) var isPlaying: Bool = false

    /// Current estimated position in seconds.
    var position: Double {
        guard isPlaying else { return anchorPosition }
        return anchorPosition + (CACurrentMediaTime() - anchorTime)
    }

    /// Hard reset — use on track change, seek, or first sample.
    func reset(to seconds: Double, playing: Bool) {
        anchorPosition = max(0, seconds)
        anchorTime = CACurrentMediaTime()
        isPlaying = playing
    }

    /// Feed in a fresh reading from Spotify.
    /// - Parameters:
    ///   - sample: position reported by Spotify, in seconds
    ///   - sampledAt: `CACurrentMediaTime()` at the midpoint of the Apple Event round trip
    ///   - playing: whether Spotify reported itself as playing
    func ingest(sample: Double, sampledAt: CFTimeInterval, playing: Bool) {
        let now = CACurrentMediaTime()

        // Play/pause edge: no point smoothing across it.
        guard playing == isPlaying else {
            let corrected = playing ? sample + (now - sampledAt) : sample
            reset(to: corrected, playing: playing)
            return
        }

        guard playing else {
            anchorPosition = sample
            anchorTime = now
            return
        }

        // Age the sample forward to "now", then compare against what we predicted.
        let truth = sample + (now - sampledAt)
        let predicted = anchorPosition + (now - anchorTime)
        let error = truth - predicted

        if abs(error) > hardSnapThreshold {
            anchorPosition = truth
        } else {
            anchorPosition = predicted + error * softCorrection
        }
        anchorTime = now
    }
}
