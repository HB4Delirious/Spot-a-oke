import Foundation

/// Musical key and tempo for a track.
struct TrackAnalysis: Equatable, Sendable {
    var key: String?
    var tempo: Double?

    var isEmpty: Bool { key == nil && tempo == nil }
}

/// Fetches key and tempo from GetSongBPM (https://getsongbpm.com).
///
/// Spotify's `audio-features` endpoint is the usual source for this, but it
/// returns 403 for every app created after November 2024 — including ours — so
/// it isn't an option. GetSongBPM is free, but it needs a personal API key and
/// its terms require a visible link back to their site; that link lives in the
/// Settings sheet next to the key field.
actor AnalysisProvider {

    static let shared = AnalysisProvider()

    private var cache: [String: TrackAnalysis] = [:]
    private let base = "https://api.getsong.co"
    private let userAgent = "SpotifyKaraoke/1.0 (macOS; personal karaoke client)"

    func analysis(for track: SpotifyTrack) async -> TrackAnalysis? {
        let cacheKey = track.trackID
        if let hit = cache[cacheKey] { return hit }

        guard let apiKey = Credentials.read(.songBPM), !apiKey.isEmpty else { return nil }

        let title = LyricsProvider.normalizeTitle(track.name)
        let artist = LyricsProvider.normalizeArtist(track.artist)
        guard !title.isEmpty else { return nil }

        guard let hit = await search(title: title, artist: artist, apiKey: apiKey) else { return nil }

        // Some responses carry only an id; follow up for the detail record.
        var analysis = hit.analysis
        if analysis.isEmpty, let id = hit.id, let detail = await song(id: id, apiKey: apiKey) {
            analysis = detail
        }

        guard !analysis.isEmpty else { return nil }
        cache[cacheKey] = analysis
        return analysis
    }

    func invalidate() { cache.removeAll() }

    // MARK: - Requests

    private func search(title: String, artist: String,
                        apiKey: String) async -> (id: String?, analysis: TrackAnalysis)? {
        var components = URLComponents(string: base + "/search/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "type", value: "both"),
            URLQueryItem(name: "lookup", value: "song:\(title) artist:\(artist)")
        ]
        guard let url = components.url, let object = await json(url) else { return nil }

        // `search` is an array of hits, or an object carrying an error when
        // nothing matched. Tolerate both rather than failing the decode.
        guard let hits = object["search"] as? [[String: Any]] else { return nil }

        // GetSongBPM matches loosely on title: asking for "Hello" by Adele will
        // happily return "Hello Babe" by Madeleine Peyroux. Take the first hit
        // whose artist actually corresponds, and show nothing rather than
        // someone else's key and tempo.
        guard let hit = hits.first(where: { Self.artist($0, matches: artist) }) else { return nil }
        return (hit["id"] as? String, Self.analysis(from: hit))
    }

    private func song(id: String, apiKey: String) async -> TrackAnalysis? {
        var components = URLComponents(string: base + "/song/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "id", value: id)
        ]
        guard let url = components.url, let object = await json(url),
              let song = object["song"] as? [String: Any] else { return nil }
        let analysis = Self.analysis(from: song)
        return analysis.isEmpty ? nil : analysis
    }

    /// Hand-parsed rather than Codable: the API returns tempo as a string on some
    /// records and a number on others, and swaps `search` between array and object.
    private func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Parsing

    private static func analysis(from record: [String: Any]) -> TrackAnalysis {
        TrackAnalysis(key: prettyKey(record["key_of"]), tempo: number(record["tempo"]))
    }

    /// Whole-word comparison, deliberately not substring: "Madeleine" contains
    /// the letters of "Adele", which is exactly how a search for Adele ends up
    /// returning Madeleine Peyroux's key and tempo.
    private static func artist(_ record: [String: Any], matches wanted: String) -> Bool {
        guard let name = (record["artist"] as? [String: Any])?["name"] as? String else { return false }
        let found = words(in: name)
        let target = words(in: wanted)
        guard !found.isEmpty, !target.isEmpty else { return false }
        if found == target { return true }
        // Allows "Simon & Garfunkel" to match "Simon and Garfunkel" without
        // letting unrelated names through.
        let (fewer, more) = found.count <= target.count ? (found, target) : (target, found)
        return fewer.isSubset(of: more)
    }

    private static func words(in raw: String) -> Set<String> {
        let expanded = raw.lowercased().replacingOccurrences(of: "&", with: " and ")
        return Set(expanded.split { !$0.isLetter && !$0.isNumber }
                           .map(String.init)
                           .filter { $0.count > 1 })
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// "F#m" reads better as "F♯m" at a glance.
    private static func prettyKey(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "#", with: "♯")
            .replacingOccurrences(of: "b ", with: "♭ ")
    }
}
