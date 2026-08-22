import SwiftUI

/// Lyrics as a teleprompter push. The line being sung sits large in the middle
/// with the next line smaller beneath it. When the line changes, the old line
/// pans up and fades, the preview line rises into its place and grows to full
/// size, and a new preview fades in beneath.
///
/// The rise-and-grow only works because each line keeps its identity across the
/// change — the middle line is not replaced, it is restyled, so SwiftUI animates
/// its position and size instead of cross-fading two separate views.
struct LyricsStage: View {
    let lines: [LyricLine]
    let position: Double
    let activeIndex: Int?
    let fontSize: CGFloat
    let onJump: (LyricLine) -> Void

    var body: some View {
        // Every row is laid out at the full font size and only *scaled* visually.
        // Animating the real font size makes FlowLayout re-measure each frame, so
        // words hop between wrapped rows mid-animation — that was the glitch.
        // Slots are positioned explicitly so a scaled row can't disturb layout.
        GeometryReader { geo in
            ZStack {
                if let index = activeIndex, lines.indices.contains(index) {
                    GhostAsides(line: lines[index],
                                position: position,
                                fontSize: fontSize,
                                size: geo.size)
                }

                ForEach(window, id: \.line.id) { entry in
                    LyricRow(
                        line: entry.line,
                        isActive: entry.isActive,
                        fontSize: fontSize,
                        position: position)
                        .frame(width: max(1, geo.size.width - 112))
                        .scaleEffect(entry.isActive ? 1 : 0.42, anchor: .center)
                        .position(x: geo.size.width / 2,
                                  y: geo.size.height * (entry.isActive ? 0.44 : 0.76))
                        .id(entry.line.id)
                        .transition(.asymmetric(
                            // Leaving: pan up and fade. Arriving: fade in below.
                            insertion: .opacity,
                            removal: .offset(y: -fontSize * 1.1).combined(with: .opacity)))
                        .contentShape(Rectangle())
                        .onTapGesture { if entry.isActive { onJump(entry.line) } }
                }
            }
            .animation(.easeInOut(duration: 0.42), value: activeIndex)
        }
    }

    /// The line being sung plus the one after it. Before the first line starts,
    /// the opening line waits in the preview slot so it grows into place rather
    /// than appearing from nothing.
    private var window: [(line: LyricLine, isActive: Bool)] {
        guard !lines.isEmpty else { return [] }

        guard let activeIndex, lines.indices.contains(activeIndex) else {
            return [(lines[0], false)]
        }

        var entries: [(line: LyricLine, isActive: Bool)] = [(lines[activeIndex], true)]
        let next = activeIndex + 1
        if lines.indices.contains(next) {
            entries.append((lines[next], false))
        }
        return entries
    }
}

// MARK: - Rows

private struct LyricRow: View {
    let line: LyricLine
    let isActive: Bool
    let fontSize: CGFloat
    let position: Double

    var body: some View {
        Group {
            if line.isBlank {
                InstrumentalPulse(progress: isActive ? line.progress(at: position) : 0)
            } else {
                words
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Stable identity per word so the row isn't rebuilt as the line is sung.
    private struct Word: Identifiable {
        let id: Int
        let text: String
    }

    private var spoken: [Word] {
        line.words.enumerated().compactMap { index, word in
            guard !word.isAside else { return nil }   // floats separately
            let text = word.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Word(id: index, text: text)
        }
    }

    private var words: some View {
        let state = isActive ? line.wordState(at: position) : nil

        return FlowLayout(spacing: fontSize * 0.30, lineSpacing: fontSize * 0.24) {
            ForEach(spoken) { word in
                WordView(text: word.text, fill: Self.fill(for: word.id, state: state))
            }
        }
        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
    }

    /// 1 once sung, the sweep fraction while being sung, 0 before.
    private static func fill(for offset: Int,
                             state: (index: Int, fraction: Double)?) -> Double {
        guard let state else { return 0 }
        if offset < state.index { return 1 }
        if offset == state.index { return state.fraction }
        return 0
    }
}

/// Backing vocals and ad-libs — the parts written in parentheses — drifting in
/// around the lead line rather than crowding it.
///
/// Placement is hashed from the line and phrase index rather than actually
/// random: it has to be identical on every frame, or they would scatter anew
/// sixty times a second. Positions avoid the middle band where the lead sits.
private struct GhostAsides: View {
    let line: LyricLine
    let position: Double
    let fontSize: CGFloat
    let size: CGSize

    private struct Aside: Identifiable {
        let id: Int
        let text: String
        let start: Double
        let end: Double
    }

    var body: some View {
        ForEach(phrases) { phrase in
            let spot = place(phrase.id)
            Text(phrase.text)
                .font(.system(size: fontSize * 0.46 * spot.scale,
                              weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
                .blur(radius: 0.4)
                .rotationEffect(.degrees(spot.tilt))
                // Drifts slightly larger across its life, so it breathes rather
                // than sitting there like a pasted-on label.
                .scaleEffect(growth(for: phrase))
                .position(x: spot.x, y: spot.y)
                .opacity(opacity(for: phrase))
        }
    }

    /// Gentle swell from just under to just over full size.
    private func growth(for aside: Aside) -> CGFloat {
        let span = max(0.3, aside.end - aside.start)
        let life = min(1.4, max(0, (position - aside.start) / span))
        return 0.93 + 0.15 * life
    }

    /// Contiguous runs of parenthetical words become one floating phrase.
    private var phrases: [Aside] {
        var result: [Aside] = []
        var current: [Int] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map { line.words[$0].text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { current = []; return }

            let end = last + 1 < line.words.count
                ? line.words[last + 1].time
                : line.voicedEnd
            result.append(Aside(id: result.count,
                                text: text,
                                start: line.words[first].time,
                                end: max(line.words[first].time + 0.3, end)))
            current = []
        }

        for index in line.words.indices {
            if line.words[index].isAside {
                current.append(index)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private func opacity(for aside: Aside) -> Double {
        let rise = 0.3, fall = 1.1
        if position < aside.start { return 0 }
        if position < aside.start + rise { return (position - aside.start) / rise }
        if position < aside.end { return 1 }
        let after = position - aside.end
        return after < fall ? 1 - after / fall : 0
    }

    private func place(_ seed: Int) -> (x: CGFloat, y: CGFloat, tilt: Double, scale: CGFloat) {
        let a = hash(Double(line.id) * 7.31 + Double(seed) * 3.17)
        let b = hash(Double(line.id) * 2.71 + Double(seed) * 9.13 + 4.0)
        let c = hash(Double(line.id) * 5.11 + Double(seed) * 1.87 + 9.0)
        let d = hash(Double(line.id) * 3.77 + Double(seed) * 6.29 + 13.0)

        // Keep out of the middle third, where the lead line lives.
        let band = b < 0.5 ? 0.08 + 0.20 * (b * 2) : 0.66 + 0.24 * ((b - 0.5) * 2)
        return (x: size.width * (0.12 + 0.76 * a),
                y: size.height * band,
                tilt: -8 + 16 * c,
                // Spread of sizes so no two ghosts read as the same label.
                scale: CGFloat(0.78 + 0.62 * d))
    }

    private func hash(_ x: Double) -> Double {
        let v = sin(x) * 43758.5453
        return v - floor(v)
    }
}

/// One word of the line.
///
/// Every phase renders the *same* view — a dim word with an amber copy overlaid
/// and masked to `fill`. Branching on phase instead (bare Text when upcoming, a
/// ZStack while singing) makes each word rebuild structurally twice per line,
/// which re-measures the row and shifts it by fractions of a point. It also caps
/// the sweep short: swapping to a flat amber Text at the moment the next word
/// starts means the mask never visibly reaches the end of the word.
private struct WordView: View {
    let text: String
    let fill: Double

    var body: some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.45))
            .overlay(alignment: .leading) {
                Text(text)
                    .foregroundStyle(Theme.sung)
                    // A single word never wraps, so the mask lines up with the
                    // glyphs exactly — this is where scaleEffect is precise.
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: max(0.0001, fill), anchor: .leading)
                    }
            }
    }
}

/// Wraps words across rows and centres each row. Written against the `Layout`
/// protocol rather than a GeometryReader — measurement happens during layout,
/// so there is no second pass for the highlight to fall out of step with.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// SwiftUI calls sizeThatFits and placeSubviews back to back, and this view
    /// rebuilds on every frame at up to 120fps. Measuring each word twice per
    /// frame is wasted work, and re-measuring is where sub-point drift creeps in.
    struct Cache {
        var width: CGFloat = -1
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.width = -1        // subview set changed; measure again
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) -> [Row] {
        if cache.width == maxWidth, !cache.rows.isEmpty { return cache.rows }
        let computed = measure(subviews, maxWidth: maxWidth)
        cache.width = maxWidth
        cache.rows = computed
        return computed
    }

    private func measure(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if !current.items.isEmpty && projected > maxWidth {
                rows.append(current)
                current = Row(items: [(index, size)], width: size.width, height: size.height)
            } else {
                current.items.append((index, size))
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(subviews, maxWidth: maxWidth, cache: &cache)
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(rows.map(\.width).max() ?? 0, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width, cache: &cache) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

/// Blank LRC lines are instrumental gaps. A row that breathes beats a row that
/// looks like the app has frozen.
private struct InstrumentalPulse: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                let phase = min(1, max(0, progress * 3 - Double(index)))
                Circle()
                    .fill(.white.opacity(0.3 + 0.5 * phase))
                    .frame(width: 13, height: 13)
                    .scaleEffect(1 + 0.35 * phase)
            }
        }
    }
}

/// Fills the long gaps — intro, solo, outro — with a countdown to the next line
/// so nobody is left staring at a still screen wondering if the app froze.
struct CueCountdown: View {
    let secondsRemaining: Double

    var body: some View {
        let total = 4.0
        let filled = Int(ceil(min(total, max(0, secondsRemaining))))

        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Theme.cue : Theme.cue.opacity(0.15))
                    .frame(width: 11, height: 11)
                    .scaleEffect(index == filled - 1 ? 1.35 : 1)
                    .animation(.easeOut(duration: 0.2), value: filled)
            }
        }
    }
}
