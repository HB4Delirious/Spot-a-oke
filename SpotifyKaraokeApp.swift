import SwiftUI

@main
struct SpotifyKaraokeApp: App {
    @StateObject private var model = KaraokeModel()

    var body: some Scene {
        WindowGroup("Karaoke") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }

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
            }
        }
    }
}
