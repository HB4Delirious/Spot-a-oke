import Foundation

struct SearchResult: Identifiable, Hashable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let album: String
    let duration: Double
    let artworkURL: URL?
}

enum SpotifyAPIError: LocalizedError {
    case missingCredentials
    case authFailed(Int)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Add your Spotify client ID and secret in Settings to search."
        case .authFailed(let code):
            return "Spotify rejected those credentials (HTTP \(code)). Check the client ID and secret."
        case .requestFailed(let code):
            return "Spotify search failed (HTTP \(code))."
        }
    }
}

/// Talks to the Spotify Web API using the client-credentials flow.
///
/// Search hits the public catalog, so no user login is needed — the app never
/// touches your account. Playback is handled entirely by the Spotify desktop app
/// via Apple Events, which is why there's no OAuth dance here.
///
/// If you later want your own playlists or library, swap this for Authorization
/// Code + PKCE with a `http://127.0.0.1:PORT/callback` redirect. (Spotify rejects
/// the literal hostname `localhost` — it has to be the loopback IP.)
actor SpotifyAPI {

    static let shared = SpotifyAPI()

    private var accessToken: String?
    private var expiresAt: Date = .distantPast

    // MARK: - Search

    /// Spotify documents `limit` as accepting 0–50, but the search endpoint
    /// rejects anything above 10 with HTTP 400 "Invalid limit". Verified against
    /// the live API: 10 succeeds, 11 and up fail. Clamped below so a caller
    /// passing the documented range doesn't silently break search.
    static let maxSearchLimit = 10

    func search(_ query: String, limit: Int = maxSearchLimit) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(min(limit, Self.maxSearchLimit)))
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 {
            // Token went stale mid-flight; drop it so the next call re-authenticates.
            accessToken = nil
            expiresAt = .distantPast
        }
        guard status == 200 else { throw SpotifyAPIError.requestFailed(status) }

        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return envelope.tracks.items.map { item in
            SearchResult(
                id: item.id,
                uri: item.uri,
                name: item.name,
                artist: item.artists.map(\.name).joined(separator: ", "),
                album: item.album.name,
                duration: Double(item.duration_ms) / 1000,
                artworkURL: item.album.images.last.flatMap { URL(string: $0.url) })
        }
    }

    // MARK: - Token

    private func token() async throws -> String {
        if let accessToken, Date() < expiresAt.addingTimeInterval(-30) {
            return accessToken
        }

        guard let id = Credentials.read(.clientID), !id.isEmpty,
              let secret = Credentials.read(.clientSecret), !secret.isEmpty else {
            throw SpotifyAPIError.missingCredentials
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SpotifyAPIError.authFailed(status) }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = payload.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(payload.expires_in))
        return payload.access_token
    }

    /// Call after the user edits credentials so the next request re-authenticates.
    func resetToken() {
        accessToken = nil
        expiresAt = .distantPast
    }

    // MARK: - Wire format

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private struct SearchEnvelope: Decodable {
        let tracks: Tracks

        struct Tracks: Decodable {
            let items: [Item]
        }

        struct Item: Decodable {
            let id: String
            let uri: String
            let name: String
            let duration_ms: Int
            let artists: [Artist]
            let album: Album
        }

        struct Artist: Decodable {
            let name: String
        }

        struct Album: Decodable {
            let name: String
            let images: [Image]
        }

        struct Image: Decodable {
            let url: String
            let width: Int?
            let height: Int?
        }
    }
}
