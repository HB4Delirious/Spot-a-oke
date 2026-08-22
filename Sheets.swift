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
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var songBPMKey = ""
    @State private var saved = false
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(MIDIBridge.clockKey) private var midiClock = false

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

            Divider().overlay(Theme.hairline)

            Text("Send to Logic")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Send key and tempo as MIDI", isOn: $midiEnabled)
                    .font(.system(size: 12, design: .rounded))

                Text("Publishes a MIDI source named “Spot-a-oke”. In Logic, open Controller Assignments (⌘L), touch a plug-in parameter, then change track — CC 20 carries the key, 21 major/minor, 22 the tempo.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                // Learn Mode has to receive a message while it's listening, and
                // track changes are awkward to time. These send on demand.
                HStack(spacing: 8) {
                    Text("Send for Learn:")
                        .font(Theme.label)
                        .foregroundStyle(Theme.upcoming)
                    Button("Key") { MIDIBridge.shared.sendForLearn(model.analysis, control: .key) }
                    Button("Major/minor") { MIDIBridge.shared.sendForLearn(model.analysis, control: .mode) }
                    Button("Tempo") { MIDIBridge.shared.sendForLearn(model.analysis, control: .tempo) }
                }
                .controlSize(.small)
                .disabled(!midiEnabled)

                Toggle("Also send MIDI beat clock", isOn: $midiClock)
                    .font(.system(size: 12, design: .rounded))
                    .disabled(!midiEnabled)

                Text("Only followed when Logic is set to external sync — which slaves its transport as well as its tempo. Leave off if you're tracking into an arranged session.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Theme.hairline)

            Text("Display")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Frame rate")
                        .font(Theme.label)
                        .foregroundStyle(Theme.upcoming)
                    Spacer()
                    Text("\(Int(targetFPS)) fps")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }

                if FrameRate.isAdjustable {
                    Slider(value: $targetFPS,
                           in: FrameRate.minimum...FrameRate.displayMaximum,
                           step: 10)
                    Text("This display supports up to \(Int(FrameRate.displayMaximum)) fps. Higher rates are smoother but cost more GPU.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A 60 Hz panel has nothing to choose between.
                    Text("This display runs at \(Int(FrameRate.displayMaximum)) fps, so there's nothing above 60 to unlock.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
