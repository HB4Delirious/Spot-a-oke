import Foundation

struct LyricsRecord: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsResult {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// Fetches timed lyrics from LRCLIB (https://lrclib.net) — open, free, no API key.
/// Results are cached on disk so replaying a track is instant and offline-safe.
actor LyricsProvider {

    static let shared = LyricsProvider()

    private let base = URL(string: "https://lrclib.net")!
    private let userAgent = "SpotifyKaraoke/1.0 (macOS; personal karaoke client)"
    private var memoryCache: [String: LyricsResult] = [:]

    private lazy var cacheDirectory: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyKaraoke/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - Public

    func lyrics(for track: SpotifyTrack) async -> LyricsResult {
        let key = track.trackID

        if let cached = memoryCache[key] { return cached }
        if let disk = readDisk(key) {
            let parsed = LRCParser.parse(disk)
            if !parsed.isEmpty {
                let result = LyricsResult.synced(parsed)
                memoryCache[key] = result
                return result
            }
        }

        let result = await fetch(track)
        memoryCache[key] = result
        return result
    }

    /// Force a re-fetch, e.g. when the auto match is obviously the wrong song.
    func invalidate(trackID: String) {
        memoryCache[trackID] = nil
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(trackID).lrc"))
    }

    // MARK: - Fetching

    private func fetch(_ track: SpotifyTrack) async -> LyricsResult {
        let title = Self.normalizeTitle(track.name)
        let artist = Self.normalizeArtist(track.artist)

        // Exact match first — this is the endpoint that returns the best-quality record.
        if let record = try? await exactMatch(title: title, artist: artist,
                                              album: track.album, duration: track.duration),
           let result = interpret(record, key: track.trackID) {
            return result
        }

        // Fall back to search and pick the closest by duration.
        if let record = try? await bestSearchMatch(title: title, artist: artist,
                                                   duration: track.duration),
           let result = interpret(record, key: track.trackID) {
            return result
        }

        return .notFound
    }

    private func exactMatch(title: String, artist: String,
                            album: String, duration: Double) async throws -> LyricsRecord? {
        var components = URLComponents(url: base.appendingPathComponent("api/get"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LyricsRecord.self, from: data)
    }

    private func bestSearchMatch(title: String, artist: String,
                                 duration: Double) async throws -> LyricsRecord? {
        var components = URLComponents(url: base.appendingPathComponent("api/search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let records = try? JSONDecoder().decode([LyricsRecord].self, from: data) else { return nil }

        // Prefer synced lyrics whose runtime is within a couple of seconds of what Spotify plays.
        return records
            .filter { ($0.syncedLyrics?.isEmpty == false) || ($0.instrumental == true) }
            .min { lhs, rhs in
                abs((lhs.duration ?? 0) - duration) < abs((rhs.duration ?? 0) - duration)
            }
            ?? records.first
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    private func interpret(_ record: LyricsRecord?, key: String) -> LyricsResult? {
        guard let record else { return nil }
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            writeDisk(key, contents: synced)
            let lines = LRCParser.parse(synced)
            return lines.isEmpty ? nil : .synced(lines)
        }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return nil
    }

    // MARK: - Disk cache

    private func readDisk(_ key: String) -> String? {
        try? String(contentsOf: cacheDirectory.appendingPathComponent("\(key).lrc"), encoding: .utf8)
    }

    private func writeDisk(_ key: String, contents: String) {
        try? contents.write(to: cacheDirectory.appendingPathComponent("\(key).lrc"),
                            atomically: true, encoding: .utf8)
    }

    // MARK: - Title cleanup
    //
    // Spotify titles carry a lot of baggage that LRCLIB doesn't index:
    // "Song - 2011 Remaster", "Song (feat. Someone)", "Song - Radio Edit".

    static func normalizeTitle(_ raw: String) -> String {
        var title = raw
        let dashSuffixes = ["remaster", "remastered", "radio edit", "single version",
                            "album version", "live", "mono", "stereo", "deluxe",
                            "bonus track", "explicit", "edit"]
        if let dash = title.range(of: " - ") {
            let tail = title[dash.upperBound...].lowercased()
            if dashSuffixes.contains(where: { tail.contains($0) }) {
                title = String(title[..<dash.lowerBound])
            }
        }
        for marker in ["(feat.", "(ft.", "(with ", "[feat.", "[ft."] {
            if let range = title.range(of: marker, options: .caseInsensitive) {
                title = String(title[..<range.lowerBound])
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    static func normalizeArtist(_ raw: String) -> String {
        // Spotify joins collaborators; LRCLIB indexes on the primary artist.
        for separator in ["; ", " & ", ", ", " feat. ", " ft. "] where raw.contains(separator) {
            return raw.components(separatedBy: separator)[0].trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}
