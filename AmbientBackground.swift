import SwiftUI

/// Slow ambient colour fields behind the lyrics.
///
/// Driven by the lyric clock, not by audio — Apple Events never expose samples,
/// so there is no spectrum to analyse. The fields drift continuously and swell on
/// each word onset, which keeps the motion tied to the vocal line. Kept dim on
/// purpose: the lit word should stay the brightest thing on screen.
struct AmbientBackground: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum

    var body: some View {
        TimelineView(.animation(minimumInterval: FrameRate.interval(for: targetFPS),
                                paused: !model.isPlaying)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let position = model.lyricPosition
            let index = model.activeIndex(at: position)
            let line = index.flatMap { model.lines.indices.contains($0) ? model.lines[$0] : nil }

            // Take the cover's colours when we have them, the house palette when
            // we don't — a track with no artwork shouldn't lose its background.
            let colours: [Color] = model.palette.isEmpty
                ? [Theme.sung, Theme.cue, Theme.violet]
                : model.palette.map(\.color)

            Canvas(rendersAsynchronously: true) { context, size in
                Self.render(into: &context,
                            size: size,
                            time: now,
                            pulse: Self.pulse(at: position, line: line),
                            colours: colours)
            }
            .animation(.easeInOut(duration: 1.2), value: model.palette)
        }
    }

    /// Sharp attack on each word onset, decaying over about a quarter second.
    private static func pulse(at position: Double, line: LyricLine?) -> Double {
        guard let line else { return 0 }

        var onset = line.time
        if let state = line.wordState(at: position), line.words.indices.contains(state.index) {
            onset = line.words[state.index].time
        }
        let since = position - onset
        guard since >= 0, since < 2 else { return 0 }
        return exp(-4.5 * since)
    }

    private static func render(into context: inout GraphicsContext,
                               size: CGSize, time: Double, pulse: Double,
                               colours: [Color]) {
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }

        // Additive blending gives the plasma bloom where fields overlap, instead
        // of one colour flatly painting over another.
        context.blendMode = .plusLighter

        let span = min(w, h)
        let motion: [(speed: Double, radius: Double, phase: Double)] = [
            (0.11, 0.66, 0.0),
            (0.08, 0.54, 2.1),
            (0.13, 0.74, 4.2),
            (0.06, 0.44, 5.6)
        ]

        for (index, path) in motion.enumerated() {
            let field = (colour: colours[index % colours.count],
                         speed: path.speed, radius: path.radius, phase: path.phase)
            let x = w * (0.5 + 0.32 * sin(time * field.speed + field.phase))
            let y = h * (0.5 + 0.27 * cos(time * field.speed * 0.8 + field.phase * 1.4))
            let r = span * field.radius * (1 + 0.13 * pulse)

            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        field.colour.opacity(0.20 + 0.16 * pulse),
                        field.colour.opacity(0.05),
                        field.colour.opacity(0)
                    ]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }
    }
}
