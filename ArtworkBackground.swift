import SwiftUI

/// Full-bleed album artwork behind the lyrics.
struct ArtworkBackground: View {
    @EnvironmentObject private var model: KaraokeModel
    @State private var drift = false

    var body: some View {
        ZStack {
            artwork
            scrim
        }
    }

    /// Slow Ken Burns push so a static cover doesn't feel like a still frame.
    private var artwork: some View {
        // Color.clear takes exactly the proposed size and an overlay can't grow
        // its parent — without this, scaledToFill reports a size bigger than the
        // window and inflates whatever contains it.
        Color.clear
            .overlay {
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
            .scaleEffect(drift ? 1.14 : 1.02)
            .animation(.easeInOut(duration: 20).repeatForever(autoreverses: true), value: drift)
            .onAppear { drift = true }
            .clipped()
    }

    /// Artwork is whatever the label shipped — it can be white, busy, or both.
    /// Lyrics have to stay readable on top of all of them.
    private var scrim: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.backdrop.opacity(0.62),
                    Theme.backdrop.opacity(0.40),
                    Theme.backdrop.opacity(0.78)
                ],
                startPoint: .top, endPoint: .bottom)

            RadialGradient(
                colors: [Theme.backdrop.opacity(0), Theme.backdrop.opacity(0.55)],
                center: .center, startRadius: 120, endRadius: 620)
        }
    }
}
