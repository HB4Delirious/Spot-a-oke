import Foundation
import Security

/// Client ID and secret live in the login keychain, not in source and not in UserDefaults.
enum Credentials {

    private static let service = "SpotifyKaraoke.SpotifyAPI"

    enum Key: String {
        case clientID
        case clientSecret
        case songBPM
    }

    static var isConfigured: Bool {
        !(read(.clientID) ?? "").isEmpty && !(read(.clientSecret) ?? "").isEmpty
    }

    static func read(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, for key: Key) -> Bool {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard !value.isEmpty else { return true }

        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
