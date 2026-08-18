import AppKit
import ApplicationServices
import QuartzCore

// MARK: - Model

struct SpotifyTrack: Equatable {
    var uri: String          // spotify:track:xxxxx
    var name: String
    var artist: String
    var album: String
    var duration: Double     // seconds
    var artworkURL: URL?

    var trackID: String { uri.components(separatedBy: ":").last ?? uri }
}

enum SpotifyPlayerState: String {
    case playing, paused, stopped
}

struct SpotifySnapshot {
    var state: SpotifyPlayerState
    var track: SpotifyTrack?
    var position: Double
    /// `CACurrentMediaTime()` at the midpoint of the Apple Event round trip.
    var sampledAt: CFTimeInterval
}

enum SpotifyControllerError: LocalizedError {
    case notRunning
    case notAuthorized
    case scriptFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Spotify isn't running. Open Spotify and start a track."
        case .notAuthorized:
            return "Karaoke needs permission to control Spotify. Grant it in System Settings › Privacy & Security › Automation."
        case .scriptFailed(let detail):
            return "Spotify didn't respond: \(detail)"
        case .malformedResponse:
            return "Spotify returned something unreadable."
        }
    }
}

// MARK: - Controller

final class SpotifyController {

    static let bundleID = "com.spotify.client"

    /// One compiled script, reused for every poll. Compiling on each call would cost ~50 ms.
    private let snapshotScript: NSAppleScript

    /// Fields are joined with U+001F (unit separator) so track titles containing
    /// tabs, pipes or commas can't corrupt the parse.
    private static let snapshotSource = """
    set d to character id 31
    tell application id "com.spotify.client"
        set ps to player state as text
        if ps is "stopped" then return "stopped"
        set t to current track
        set aw to ""
        try
            set aw to artwork url of t
        end try
        return ps & d & (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as text) & d & ((player position) as text) & d & aw
    end tell
    """

    init() throws {
        guard let script = NSAppleScript(source: Self.snapshotSource) else {
            throw SpotifyControllerError.malformedResponse
        }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        if let error {
            throw SpotifyControllerError.scriptFailed(Self.describe(error))
        }
        self.snapshotScript = script
    }

    // MARK: Availability & permission

    static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Asks macOS whether we're allowed to send Apple Events to Spotify.
    /// Pass `prompt: true` once at launch to trigger the system consent dialog.
    @discardableResult
    static func checkAutomationPermission(prompt: Bool) -> Bool {
        var target = AEAddressDesc()
        let idData = Data(bundleID.utf8)
        // AECreateDesc returns OSErr (Int16); widen so it compares against noErr (OSStatus).
        let created = idData.withUnsafeBytes { buffer -> OSStatus in
            OSStatus(AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target))
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        return status == noErr
    }

    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Reading state

    func snapshot() throws -> SpotifySnapshot {
        guard Self.isSpotifyRunning else { throw SpotifyControllerError.notRunning }

        let start = CACurrentMediaTime()
        var error: NSDictionary?
        let result = snapshotScript.executeAndReturnError(&error)
        let end = CACurrentMediaTime()

        if let error { throw Self.mapError(error) }
        guard let raw = result.stringValue else { throw SpotifyControllerError.malformedResponse }

        // Charge half the round trip to the reading — the value was true somewhere in the middle.
        let sampledAt = start + (end - start) / 2

        if raw == "stopped" {
            return SpotifySnapshot(state: .stopped, track: nil, position: 0, sampledAt: sampledAt)
        }

        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else { throw SpotifyControllerError.malformedResponse }

        let state = SpotifyPlayerState(rawValue: fields[0]) ?? .paused
        let rawDuration = Double(fields[5]) ?? 0
        // Spotify reports duration in milliseconds; guard anyway in case that ever changes.
        let duration = rawDuration > 3600 ? rawDuration / 1000 : rawDuration
        let position = Double(fields[6]) ?? 0
        let artwork = fields.count > 7 ? URL(string: fields[7]) : nil

        let track = SpotifyTrack(
            uri: fields[1],
            name: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: duration,
            artworkURL: artwork
        )

        return SpotifySnapshot(state: state, track: track, position: position, sampledAt: sampledAt)
    }

    // MARK: Transport

    func playPause() throws { try run("playpause") }
    func next() throws { try run("next track") }
    func previous() throws { try run("previous track") }

    func seek(to seconds: Double) throws {
        try run("set player position to \(max(0, seconds))")
    }

    func play(uri: String) throws {
        guard Self.isValidTrackURI(uri) else { throw SpotifyControllerError.malformedResponse }
        try run("play track \"\(uri)\"")
    }

    func activate() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .first?
            .activate()
    }

    // MARK: Plumbing

    private func run(_ command: String) throws {
        guard Self.isSpotifyRunning else { throw SpotifyControllerError.notRunning }
        let source = "tell application id \"com.spotify.client\" to \(command)"
        guard let script = NSAppleScript(source: source) else {
            throw SpotifyControllerError.malformedResponse
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error { throw Self.mapError(error) }
    }

    /// Only ever interpolate strings we've validated into AppleScript source.
    static func isValidTrackURI(_ uri: String) -> Bool {
        guard uri.hasPrefix("spotify:track:") else { return false }
        let id = uri.dropFirst("spotify:track:".count)
        return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func mapError(_ dict: NSDictionary) -> SpotifyControllerError {
        let code = (dict[NSAppleScript.errorNumber] as? Int) ?? 0
        switch code {
        case -1743, -1744:  return .notAuthorized
        case -600, -609:    return .notRunning
        default:            return .scriptFailed(describe(dict))
        }
    }

    private static func describe(_ dict: NSDictionary) -> String {
        (dict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
    }
}
