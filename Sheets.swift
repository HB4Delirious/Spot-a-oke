import SwiftUI

// MARK: - Search

struct SearchSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.upcoming)

                TextField("Song or artist", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .onSubmit { model.runSearch() }
                    .onChange(of: model.searchQuery) { _, _ in model.runSearch() }

                if model.isSearching {
                    ProgressView().controlSize(.small)
                }

                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.upcoming)
            }
            .padding(16)

            Divider().overlay(Theme.hairline)

            if model.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Text(Credentials.isConfigured ? "Search Spotify's catalogue" : "Add your Spotify keys first")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(Credentials.isConfigured
                         ? "Picking a result starts it in the Spotify app."
                         : "Open Settings and paste in a client ID and secret from the Spotify developer dashboard.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                List(model.searchResults) { result in
                    Button {
                        model.play(result)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: result.artworkURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Theme.backdrop
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("\(result.artist) · \(result.album)")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Theme.upcoming)
                            }
                            .lineLimit(1)

                            Spacer()

                            Text(duration(result.duration))
                                .font(Theme.timecode)
                                .foregroundStyle(Theme.upcoming)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 460)
        .background(Theme.panel)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var songBPMKey = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Spotify credentials")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text("Create an app at developer.spotify.com/dashboard and copy its client ID and secret. These are only used to search the public catalogue — the app never signs in to your account. They're stored in your login keychain.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                labelled("Client ID") {
                    TextField("", text: $clientID)
                }
                labelled("Client secret") {
                    SecureField("", text: $clientSecret)
                }
            }

            Divider().overlay(Theme.hairline)

            Text("Key and tempo")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            // Spotify's audio-features endpoint returns 403 for apps created
            // after November 2024, so key and tempo come from GetSongBPM instead.
            // Their terms require this link to be visible in the app.
            VStack(alignment: .leading, spacing: 6) {
                Text("Optional. Key and tempo are supplied by GetSongBPM — create a free API key and paste it below.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Powered by GetSongBPM", destination: URL(string: "https://getsongbpm.com")!)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.cue)
            }

            labelled("GetSongBPM API key") {
                TextField("", text: $songBPMKey)
            }

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(Theme.label)
                        .foregroundStyle(Theme.cue)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save changes") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel)
        .onAppear {
            clientID = Credentials.read(.clientID) ?? ""
            clientSecret = Credentials.read(.clientSecret) ?? ""
            songBPMKey = Credentials.read(.songBPM) ?? ""
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)
            content()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func save() {
        Credentials.write(clientID.trimmingCharacters(in: .whitespaces), for: .clientID)
        Credentials.write(clientSecret.trimmingCharacters(in: .whitespaces), for: .clientSecret)
        Credentials.write(songBPMKey.trimmingCharacters(in: .whitespaces), for: .songBPM)
        Task { await SpotifyAPI.shared.resetToken() }
        // Drop cached lookups so a new key takes effect on the current track.
        Task { await AnalysisProvider.shared.invalidate() }
        saved = true
        dismiss()
    }
}
