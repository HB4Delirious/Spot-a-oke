import AppKit

/// Redraw rate for the animated surfaces — lyrics, background, scrubber.
///
/// `TimelineView(.animation(minimumInterval:))` sets a floor on the gap between
/// updates, not the rate itself; the display link still decides when to draw. So
/// asking for 1/120 permits up to 120fps on a display that can do it, and simply
/// draws slower on one that can't.
enum FrameRate {

    static let defaultsKey = "targetFPS"
    static let minimum: Double = 60

    /// What the current display can actually deliver. A 60 Hz panel reports 60,
    /// ProMotion reports 120.
    static var displayMaximum: Double {
        Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    /// True when the display can do better than the 60fps floor, i.e. when
    /// offering a choice is meaningful at all.
    static var isAdjustable: Bool { displayMaximum > minimum }

    /// Clamped so a stored preference can never exceed the panel or drop below 60.
    static func interval(for requested: Double) -> Double {
        let ceiling = max(minimum, displayMaximum)
        return 1.0 / min(max(minimum, requested), ceiling)
    }
}
