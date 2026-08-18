# Karaoke for macOS

A SwiftUI sing-along display. Spotify plays the track; this app shows the lyrics and
sweeps a highlight across each line in time with the vocal.

## How it works

```
Spotify desktop app ──Apple Events──▶ SpotifyController   (position, track, transport)
                                             │
                                        PlaybackClock     (smooths 2 Hz samples to 30 fps)
                                             │
LRCLIB ──HTTPS──▶ LyricsProvider ──▶ LRCParser ──▶ LyricsStage
                                             │
Spotify Web API ──▶ SpotifyAPI (search only, client credentials)
```

Three decisions worth knowing about, because they're not the obvious ones:

**Playback runs through Apple Events, not the Web Playback SDK.** The SDK needs
Widevine DRM, which neither Electron nor WKWebView ships on macOS. Driving the
Spotify desktop app sidesteps DRM entirely and gets you `player position` as a
float, which is what the sync engine actually needs.

**Position is sampled at 2 Hz and extrapolated in between.** Each Apple Event costs
10–20 ms, so polling at frame rate would be wasteful and jittery. `PlaybackClock`
anchors to the last sample and free-wheels off `CACurrentMediaTime()`, nudging 25%
of the error per sample instead of snapping. Errors over 400 ms are treated as a
seek and snapped immediately. Round-trip latency is halved and added back to the
sample, since the reading was true somewhere in the middle of the call.

**Search uses client credentials, not OAuth.** Search hits the public catalogue, so
no user login is needed and there's no local redirect server to run. If you later
want your own playlists or library, that's the point where you'd add Authorization
Code + PKCE — note the redirect URI has to be `http://127.0.0.1:PORT/callback`,
because Spotify rejects the literal hostname `localhost` now.

## Setup

### 1. Create the Xcode project

New project → **macOS → App**, interface **SwiftUI**, language **Swift**.
Set the deployment target to **macOS 14.0** (the code uses the two-parameter
`onChange` and `NSRunningApplication.activate()`).

Delete the generated `ContentView.swift` and `<Name>App.swift`, then drag in:

```
SpotifyKaraokeApp.swift
KaraokeModel.swift
Services/PlaybackClock.swift
Services/SpotifyController.swift
Services/LRCParser.swift
Services/LyricsProvider.swift
Services/SpotifyAPI.swift
Services/Credentials.swift
Views/Theme.swift
Views/LyricsStage.swift
Views/ContentView.swift
Views/Sheets.swift
```

### 2. Turn off App Sandbox

Target → **Signing & Capabilities** → remove the **App Sandbox** capability.

A sandboxed app can only send Apple Events to another app with a
`com.apple.security.temporary-exception.apple-events` entitlement, which is a
dead end for App Store distribution anyway. For a personal build, off is simpler.

Leave **Hardened Runtime** on, but tick **Apple Events** under its checkboxes
(that's `com.apple.security.automation.apple-events`) — without it the Apple
Event is blocked before TCC even asks.

### 3. Add the usage string

Target → **Info** tab → add key:

| Key | Value |
|---|---|
| `NSAppleEventsUsageDescription` | Karaoke reads the current track and playback position from Spotify to keep the lyrics in sync. |

macOS shows this text in the consent dialog. If it's missing, the app crashes
the first time it talks to Spotify.

### 4. Get Spotify keys (optional)

Only needed for in-app search. Everything else works without it — the app follows
whatever you play in Spotify directly.

1. developer.spotify.com/dashboard → **Create app**
2. Any name; the redirect URI field is required by the form but unused here —
   put `http://127.0.0.1:8888/callback`
3. Copy the client ID and secret into the app's Settings sheet

They go into your login keychain, not into source or `UserDefaults`.

### 5. Run

Launch Spotify, start a track, then run the app. Approve the automation prompt
on first launch. If you dismiss it by mistake:
**System Settings → Privacy & Security → Automation → Karaoke → Spotify**.

## Using it

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `⌘←` `⌘→` | Previous / next track |
| `[` `]` | Nudge lyrics 50 ms later / earlier |
| `⌘0` | Reset sync |
| `⌘R` | Re-fetch lyrics for this track |

Click any lyric line to seek there. The sync trim is saved per track, so once
you've dialled a song in it stays dialled in.

## Lyrics quality

LRCLIB is community-contributed, so coverage varies: strong on popular Western
tracks, thinner on new releases and non-English catalogues. Some entries carry
word-level timing (`<mm:ss.xx>` tags) and get a true per-word sweep; the rest are
line-timed and sweep at a constant rate across the line.

The provider strips the noise Spotify puts in titles before searching —
`- 2011 Remaster`, `(feat. …)`, `- Radio Edit` — and falls back from the exact-match
endpoint to a search that picks whichever result's runtime is closest to what's
playing. When the match is still wrong, `⌘R` clears the cache and tries again.

Cached `.lrc` files live in
`~/Library/Application Support/SpotifyKaraoke/Lyrics/`.

## Troubleshooting

**Lyrics drift steadily over a song.** That's an LRC file mastered against a
different release. Set the trim once; it's remembered.

**Lyrics are right but lag ~200 ms.** Bluetooth headphones. AirPods add roughly
150–200 ms of audio latency that the app can't see, so trim negative.

**"Karaoke can't reach Spotify" after granting permission.** Check the Apple Events
box under Hardened Runtime, then delete derived data and rebuild — TCC caches the
decision against the code signature.

**Nothing happens when you pick a search result.** Playback via `play track` needs
the Spotify app running and signed in.

## Credits

Timed lyrics come from [LRCLIB](https://lrclib.net).

Key and tempo are **Powered by [GetSongBPM](https://getsongbpm.com)**. Spotify's
own `audio-features` endpoint returns 403 for any app created after November
2024, so it isn't a usable source. GetSongBPM's API is free and asks only for a
visible link back to their site in return — that link appears in the app's
Settings sheet, and above.

## One thing this deliberately doesn't do

There's no vocal removal. Spotify's Developer Terms prohibit modifying or
separating their audio, so this is a sing-along over the original recording, the
same as Spotify's own lyrics view. If you want true instrumental karaoke, that has
to run on local audio files — Demucs handles the separation well — and would be a
separate playback path from the Spotify one.
