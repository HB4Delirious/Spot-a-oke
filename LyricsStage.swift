import SwiftUI

/// Lyrics as slides: one line owns the stage, and each new line arrives with a
/// transition. No sweep and no per-word colouring — the line is simply shown,
/// and the artwork and particles behind it carry the motion.
struct LyricsStage: View {
    let lines: [LyricLine]
    let position: Double
    let activeIndex: Int?
    let fontSize: CGFloat
    let onJump: (LyricLine) -> Void

    var body: some View {
        ZStack {
            if let index = activeIndex, lines.indices.contains(index) {
                let line = lines[index]
                LyricPanel(
                    line: line,
                    upcoming: upcoming(after: index),
                    fontSize: fontSize,
                    position: position)
                    .id(index)
                    .transition(Self.transition(for: index))
                    .contentShape(Rectangle())
                    .onTapGesture { onJump(line) }
            } else {
                OpeningPanel(first: lines.first?.text)
                    .id(-1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: activeIndex)
    }

    private func upcoming(after index: Int) -> String? {
        let next = index + 1
        guard lines.indices.contains(next) else { return nil }
        let text = lines[next].text
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    }

    /// Cycled so consecutive slides don't all enter the same way.
    private static func transition(for index: Int) -> AnyTransition {
        switch index % 4 {
        case 0:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity))
        case 1:
            return .asymmetric(
                insertion: .scale(scale: 0.86).combined(with: .opacity),
                removal: .scale(scale: 1.10).combined(with: .opacity))
        case 2:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity))
        default:
            return .scale(scale: 0.96).combined(with: .opacity)
        }
    }
}

// MARK: - Slides

private struct LyricPanel: View {
    let line: LyricLine
    let upcoming: String?
    let fontSize: CGFloat
    let position: Double

    var body: some View {
        VStack(spacing: fontSize * 0.55) {
            Spacer(minLength: 0)

            if line.isBlank {
                InstrumentalPulse(progress: line.progress(at: position))
            } else if line.words.isEmpty {
                Text(line.text)
                    .font(Theme.lyric(fontSize, active: true))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 14, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                litWords
            }

            if let upcoming {
                Text(upcoming)
                    .font(Theme.lyric(fontSize * 0.40, active: false))
                    .foregroundStyle(.white.opacity(0.55))
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each word is its own view, and the letters of the word being sung fill in
    /// left to right as it's sung. No glow and no scaling — the only thing that
    /// changes is whether a letter is lit.
    private var litWords: some View {
        let state = line.wordState(at: position)

        return FlowLayout(spacing: fontSize * 0.30, lineSpacing: fontSize * 0.24) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { offset, word in
                let text = word.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    WordView(text: text, phase: phase(for: offset, state: state))
                }
            }
        }
        .font(Theme.lyric(fontSize, active: true))
        // Plain drop shadow for legibility over arbitrary cover art — not a glow.
        .shadow(color: .black.opacity(0.6), radius: 10, y: 1)
    }

    private func phase(for offset: Int, state: (index: Int, fraction: Double)?) -> WordView.Phase {
        guard let state else { return .upcoming }
        if offset < state.index { return .sung }
        if offset == state.index { return .singing(state.fraction) }
        return .upcoming
    }
}

/// One word of the line. Sung letters stay lit, upcoming ones stay dim, and the
/// word being sung fills in across its own letters.
private struct WordView: View {
    enum Phase: Equatable {
        case sung
        case singing(Double)
        case upcoming
    }

    let text: String
    let phase: Phase

    var body: some View {
        switch phase {
        case .sung:
            Text(text).foregroundStyle(Theme.sung)

        case .upcoming:
            Text(text).foregroundStyle(.white.opacity(0.45))

        case .singing(let fraction):
            ZStack {
                Text(text).foregroundStyle(.white.opacity(0.45))
                Text(text)
                    .foregroundStyle(Theme.sung)
                    // A single word never wraps, so the mask lines up with the
                    // glyphs exactly — this is where scaleEffect is precise.
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: max(0.0001, fraction), anchor: .leading)
                    }
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

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(rows.map(\.width).max() ?? 0, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
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

/// Blank LRC lines are instrumental gaps. A slide that breathes beats a slide
/// that looks like the app has frozen.
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

/// Before the first line lands.
private struct OpeningPanel: View {
    let first: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("Get ready")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black.opacity(0.6), radius: 10)

            if let first {
                Text(first)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 56)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
