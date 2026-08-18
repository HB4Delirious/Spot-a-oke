import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage("lyricFontSize") private var fontSize: Double = 42
    @State private var showSearch = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingHeader()
            Divider().overlay(Theme.hairline)
            stage
            Divider().overlay(Theme.hairline)
            ControlBar(fontSize: $fontSize, showSearch: $showSearch)
        }
        // A background never influences its parent's layout, so artwork can't
        // push the control bar off-screen the way a ZStack sibling could.
        .background {
            ZStack {
                Theme.backdrop
                if model.track != nil {
                    ArtworkBackground()
                }
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 720, minHeight: 520)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSearch) { SearchSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.connection {
        case .checking:
            StageMessage(title: "Looking for Spotify…", detail: nil)

        case .spotifyNotRunning:
            StageMessage(
                title: "Spotify isn't open",
                detail: "Launch Spotify and press play. Karaoke follows whatever you're listening to.",
                action: ("Open Spotify", {
                    guard let url = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: SpotifyController.bundleID) else { return }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }))

        case .permissionDenied:
            StageMessage(
                title: "Karaoke can't reach Spotify",
                detail: "macOS gates app-to-app control. Turn on Spotify under Privacy & Security › Automation, then reopen Karaoke.",
                action: ("Open Automation settings", { SpotifyController.openAutomationSettings() }))

        case .failed(let message):
            StageMessage(title: "Something went wrong", detail: message)

        case .ready:
            lyricStage
        }
    }

    @ViewBuilder
    private var lyricStage: some View {
        switch model.lyricsState {
        case .idle:
            StageMessage(title: "Nothing playing", detail: "Start a track in Spotify, or search for one below.")

        case .loading:
            StageMessage(title: "Fetching lyrics…", detail: nil)

        case .missing:
            StageMessage(
                title: "No timed lyrics for this one",
                detail: "LRCLIB doesn't have a synced version yet. Try another track, or re-check in case the match failed.",
                action: ("Look again", { model.reloadLyrics() }))

        case .instrumental:
            StageMessage(title: "Instrumental", detail: "This track has no vocal line to follow.")

        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(Theme.lyric(20, active: false))
                    .foregroundStyle(Theme.upcoming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(44)
            }
            .overlay(alignment: .top) {
                Text("Untimed lyrics — these won't follow the music")
                    .font(Theme.label)
                    .foregroundStyle(Theme.cue)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.panel, in: Capsule())
                    .padding(.top, 12)
            }

        case .synced:
            // TimelineView drives redraws off the display refresh instead of
            // republishing position 30x a second through Combine.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isPlaying)) { _ in
                let position = model.lyricPosition
                let index = model.activeIndex(at: position)

                ZStack(alignment: .top) {
                    LyricsStage(
                        lines: model.lines,
                        position: position,
                        activeIndex: index,
                        fontSize: CGFloat(fontSize),
                        onJump: { model.jump(to: $0) })

                    if let gap = upcomingGap(at: position, activeIndex: index) {
                        CueCountdown(secondsRemaining: gap)
                            .padding(.top, 22)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Seconds until the next line, but only once we're inside the final 4 seconds
    /// of a gap long enough to feel like dead air.
    private func upcomingGap(at position: Double, activeIndex: Int?) -> Double? {
        let nextIndex = (activeIndex.map { $0 + 1 }) ?? 0
        guard nextIndex < model.lines.count else { return nil }

        let next = model.lines[nextIndex]
        let gapStart = activeIndex.map { model.lines[$0].end } ?? 0
        guard next.time - gapStart >= 4 else { return nil }

        let remaining = next.time - position
        return (remaining > 0 && remaining <= 4) ? remaining : nil
    }
}

// MARK: - Header

private struct NowPlayingHeader: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 14) {
                artwork

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.track?.name ?? "Nothing playing")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.track?.artist ?? "—")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                        .lineLimit(1)
                }

                Spacer()
            }

            if model.track != nil {
                Scrubber()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let url = model.track?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.backdrop
                }
            } else {
                Theme.backdrop
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline))
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Position bar you can drag to seek. Redraws off its own TimelineView because
/// the clock isn't @Published — polling only republishes twice a second, which
/// would make the playhead visibly step rather than glide.
private struct Scrubber: View {
    @EnvironmentObject private var model: KaraokeModel
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isPlaying)) { _ in
            let duration = max(1, model.track?.duration ?? 1)
            let live = min(1, max(0, model.clock.position / duration))
            let fraction = scrub ?? live

            VStack(spacing: 4) {
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.hairline)
                            .frame(height: 4)
                        Capsule()
                            .fill(Theme.sung)
                            .frame(width: width * fraction, height: 4)
                        Circle()
                            .fill(.white)
                            .frame(width: scrub == nil ? 8 : 11, height: scrub == nil ? 8 : 11)
                            .offset(x: width * fraction - (scrub == nil ? 4 : 5.5))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance 0 so a plain click seeks too.
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub = min(1, max(0, value.location.x / width))
                            }
                            .onEnded { value in
                                let target = min(1, max(0, value.location.x / width))
                                // Seek only on release — every seek is an Apple
                                // Event, and firing one per drag sample floods it.
                                model.seek(to: target * duration)
                                scrub = nil
                            })
                }
                .frame(height: 12)

                HStack {
                    Text(Self.timecode(fraction * duration))
                    Spacer()
                    Text(Self.timecode(duration))
                }
                .font(Theme.timecode)
                .foregroundStyle(scrub == nil ? Theme.upcoming : Theme.cue)
            }
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Controls

private struct ControlBar: View {
    @EnvironmentObject private var model: KaraokeModel
    @Binding var fontSize: Double
    @Binding var showSearch: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.status {
                Text(status)
                    .font(Theme.label)
                    .foregroundStyle(Theme.cue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack(spacing: 18) {
                Button { showSearch = true } label: {
                    Label("Find a song", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 18).overlay(Theme.hairline)

                HStack(spacing: 10) {
                    transport("backward.end.fill") { model.previousTrack() }
                    transport(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }
                    transport("forward.end.fill") { model.nextTrack() }
                }

                Spacer()

                musicalInfo
                syncTrim
                fontStepper
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.panel)
    }

    private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
    }

    /// Key and tempo, hidden entirely when GetSongBPM has nothing for the track —
    /// an empty readout is worse than no readout.
    @ViewBuilder
    private var musicalInfo: some View {
        if let analysis = model.analysis, !analysis.isEmpty {
            HStack(spacing: 12) {
                if let key = analysis.key {
                    labelledValue("KEY", key)
                }
                if let tempo = analysis.tempo, tempo > 0 {
                    labelledValue("BPM", String(format: "%.0f", tempo))
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func labelledValue(_ caption: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var syncTrim: some View {
        HStack(spacing: 8) {
            Text("SYNC")
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)

            Slider(value: $model.offsetMilliseconds, in: -2000...2000, step: 25)
                .frame(width: 160)

            Text(model.offsetMilliseconds == 0
                 ? "0 ms"
                 : String(format: "%+.0f ms", model.offsetMilliseconds))
                .font(Theme.timecode)
                .foregroundStyle(model.offsetMilliseconds == 0 ? Theme.upcoming : Theme.cue)
                .frame(width: 66, alignment: .trailing)
                .onTapGesture { model.offsetMilliseconds = 0 }
                .help("Click to reset. Saved per track.")
        }
    }

    private var fontStepper: some View {
        HStack(spacing: 6) {
            Button { fontSize = max(24, fontSize - 4) } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(.borderless)
            Button { fontSize = min(96, fontSize + 4) } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.upcoming)
    }
}

// MARK: - Empty states

struct StageMessage: View {
    let title: String
    var detail: String?
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if let detail {
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.sung)
                    .foregroundStyle(Theme.backdrop)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
