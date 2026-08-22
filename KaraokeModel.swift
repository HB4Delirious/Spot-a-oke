import Foundation
import AppKit
import Combine
import QuartzCore

enum LyricsState: Equatable {
    case idle
    case loading
    case synced
    case plain(String)
    case instrumental
    case missing
}

@MainActor
final class KaraokeModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var playerState: SpotifyPlayerState = .stopped
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var lyricsState: LyricsState = .idle
    @Published private(set) var analysis: TrackAnalysis?

    /// Colours lifted from the current cover art. Empty falls back to Theme.
    @Published private(set) var palette: [PaletteColor] = []

    /// Output-device latency, measured and applied without user involvement.
    @Published private(set) var automaticLatencyMilliseconds: Double = 0
    @Published private(set) var connection: ConnectionState = .checking
    @Published var status: String?

    /// Manual sync trim, in milliseconds. Positive = lyrics run ahead of the music.
    @Published var offsetMilliseconds: Double = 0 {
        didSet { persistOffset() }
    }

    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var isSearching = false

    enum ConnectionState: Equatable {
        case checking
        case ready
        case spotifyNotRunning
        case permissionDenied
        case failed(String)
    }

    // MARK: Internals

    let clock = PlaybackClock()

    private var controller: SpotifyController?
    private var pollTimer: Timer?
    private var playbackObserver: NSObjectProtocol?
    private var lyricsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastTrackURI: String?

    private let pollInterval: TimeInterval = 0.5
    private let offsetDefaultsKey = "trackOffsets"

    var isPlaying: Bool { playerState == .playing }

    /// Playback position, automatically compensated for output latency, with the
    /// user's manual trim folded in on top.
    ///
    /// Spotify reports where the playhead is, not what has reached your ears.
    /// Subtracting the measured device latency is what removes the need to dial
    /// the sync slider in by hand every time you put headphones on.
    var lyricPosition: Double {
        clock.position + (offsetMilliseconds - automaticLatencyMilliseconds) / 1000
    }

    // MARK: Lifecycle

    func start() {
        // Both windows call this on appear, and a window can reappear. Without
        // this guard each call would add another observer and leave the previous
        // timer scheduled on the run loop, polling forever.
        guard pollTimer == nil else { return }

        do {
            controller = try SpotifyController()
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }

        // Publishes the virtual MIDI source Logic can learn from.
        MIDIBridge.shared.start()

        // Triggers the one-time macOS consent dialog on first launch.
        //
        // Deliberately off the main thread: with prompting enabled this blocks
        // until the user answers the dialog. Called on the main thread it stalls
        // the app before it draws — which looks exactly like a freeze on any Mac
        // that hasn't granted automation yet, and survives a force quit because
        // the next launch blocks in the same place.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SpotifyController.checkAutomationPermission(prompt: true)
        }

        // Spotify broadcasts on every play, pause, seek and track change.
        // We use it purely as a "poll right now" signal rather than trusting its payload.
        playbackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }

        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // .common keeps polling alive while the user drags the offset slider.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let playbackObserver {
            DistributedNotificationCenter.default().removeObserver(playbackObserver)
            self.playbackObserver = nil
        }
        lyricsTask?.cancel()
        analysisTask?.cancel()
        paletteTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: Polling

    private func poll() {
        guard let controller else { return }

        do {
            let snapshot = try controller.snapshot()
            connection = .ready

            // Assign `track` first: handleTrackChange writes the saved offset, and
            // persistOffset keys off the *current* track.
            let changed = snapshot.track?.uri != lastTrackURI
            lastTrackURI = snapshot.track?.uri
            track = snapshot.track
            if changed { handleTrackChange(snapshot.track) }

            playerState = snapshot.state

            let latency = AudioLatency.currentSeconds() * 1000
            if abs(latency - automaticLatencyMilliseconds) > 1 {
                automaticLatencyMilliseconds = latency
            }

            clock.ingest(sample: snapshot.position,
                         sampledAt: snapshot.sampledAt,
                         playing: snapshot.state == .playing)
        } catch let error as SpotifyControllerError {
            switch error {
            case .notRunning:    connection = .spotifyNotRunning
            case .notAuthorized: connection = .permissionDenied
            default:             connection = .failed(error.localizedDescription)
            }
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func handleTrackChange(_ newTrack: SpotifyTrack?) {
        lyricsTask?.cancel()
        analysisTask?.cancel()
        paletteTask?.cancel()
        lines = []
        analysis = nil
        palette = []
        clock.reset(to: 0, playing: false)

        guard let newTrack else {
            lyricsState = .idle
            offsetMilliseconds = 0
            MIDIBridge.shared.stopClock()
            return
        }

        paletteTask = Task { [weak self] in
            let colours = await PaletteProvider.shared.palette(for: newTrack)
            guard !Task.isCancelled else { return }
            guard let self, self.track?.uri == newTrack.uri else { return }
            self.palette = colours
        }

        analysisTask = Task { [weak self] in
            let result = await AnalysisProvider.shared.analysis(for: newTrack)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.track?.uri == newTrack.uri else { return }
                self.analysis = result
                MIDIBridge.shared.publish(result)
            }
        }

        offsetMilliseconds = storedOffset(for: newTrack.trackID)
        lyricsState = .loading

        lyricsTask = Task { [weak self] in
            let result = await LyricsProvider.shared.lyrics(for: newTrack)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.track?.uri == newTrack.uri else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: LyricsResult) {
        switch result {
        case .synced(let parsed):
            lines = parsed
            lyricsState = .synced
        case .plain(let text):
            lines = []
            lyricsState = .plain(text)
        case .instrumental:
            lines = []
            lyricsState = .instrumental
        case .notFound:
            lines = []
            lyricsState = .missing
        }
    }

    func reloadLyrics() {
        guard let track else { return }
        Task {
            await LyricsProvider.shared.invalidate(trackID: track.trackID)
            handleTrackChange(track)
        }
    }

    // MARK: Transport

    func togglePlayback() { perform { try $0.playPause() } }
    func nextTrack() { perform { try $0.next() } }
    func previousTrack() { perform { try $0.previous() } }
    func revealSpotify() { controller?.activate() }

    func seek(to seconds: Double) {
        perform { try $0.seek(to: seconds) }
        clock.reset(to: seconds, playing: isPlaying)
    }

    /// Jump to the start of a lyric line — handy for practising one verse.
    func jump(to line: LyricLine) {
        seek(to: max(0, line.time - offsetMilliseconds / 1000))
    }

    func play(_ result: SearchResult) {
        perform { try $0.play(uri: result.uri) }
        searchResults = []
        searchQuery = ""
    }

    private func perform(_ action: (SpotifyController) throws -> Void) {
        guard let controller else { return }
        do {
            try action(controller)
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Search

    func runSearch() {
        searchTask?.cancel()
        let query = searchQuery

        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            searchResults = []
            return
        }

        searchTask = Task { [weak self] in
            // Debounce so we don't fire a request per keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { self?.isSearching = true }
            do {
                let results = try await SpotifyAPI.shared.search(query)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.searchResults = results
                    self?.isSearching = false
                    self?.status = results.isEmpty ? "No tracks matched “\(query)”." : nil
                }
            } catch {
                await MainActor.run {
                    self?.isSearching = false
                    self?.status = error.localizedDescription
                }
            }
        }
    }

    // MARK: Offset persistence

    private func storedOffset(for trackID: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: offsetDefaultsKey) as? [String: Double] ?? [:]
        return map[trackID] ?? 0
    }

    private func persistOffset() {
        guard let trackID = track?.trackID else { return }
        var map = UserDefaults.standard.dictionary(forKey: offsetDefaultsKey) as? [String: Double] ?? [:]
        if offsetMilliseconds == 0 {
            map.removeValue(forKey: trackID)
        } else {
            map[trackID] = offsetMilliseconds
        }
        UserDefaults.standard.set(map, forKey: offsetDefaultsKey)
    }

    // MARK: Lyric lookup

    /// Index of the line that should be lit up right now, or nil before the first line.
    func activeIndex(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var found: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
