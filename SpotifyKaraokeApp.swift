import SwiftUI

@main
struct SpotifyKaraokeApp: App {

    static let controlsWindowID = "controls"
    static let lyricsWindowID = "lyrics"

    @StateObject private var model = KaraokeModel()

    var body: some Scene {
        // Declared first, so this is what opens at launch: the controls belong on
        // your main display, and the lyrics are opened onto whichever screen you
        // want them on.
        Window("Controls", id: Self.controlsWindowID) {
            ControlsWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 820, height: 200)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            PlaybackCommands(model: model)
        }

        // The lyrics stand alone so this window can be dragged to a second
        // screen and made full-screen without carrying the chrome along.
        //
        // Window, not WindowGroup: a WindowGroup spawns a fresh instance on every
        // openWindow call, so the toolbar button kept stacking up new displays.
        // A Window brings the existing one forward instead.
        Window("Lyrics", id: Self.lyricsWindowID) {
            LyricsWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 620)
        // Without this a Window defaults to .automatic, which sizes to content
        // and leaves the window non-resizable — which also disables zoom and
        // full screen. WindowGroup defaulted differently, so this only became
        // necessary when the lyrics scene became single-instance.
        .windowResizability(.contentMinSize)
    }
}

private struct PlaybackCommands: Commands {
    @ObservedObject var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play or pause") { model.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next track") { model.nextTrack() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous track") { model.previousTrack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

            Divider()

            Button("Nudge lyrics later") { model.offsetMilliseconds -= 50 }
                .keyboardShortcut("[", modifiers: [])
            Button("Nudge lyrics earlier") { model.offsetMilliseconds += 50 }
                .keyboardShortcut("]", modifiers: [])
            Button("Reset sync") { model.offsetMilliseconds = 0 }
                .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Button("Reload lyrics") { model.reloadLyrics() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Bring Spotify forward") { model.revealSpotify() }

            Divider()

            Button("Lyrics window") {
                openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Controls window") {
                openWindow(id: SpotifyKaraokeApp.controlsWindowID)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }
}
