//
//  KeychainStore.swift
//  Logbuch Loader
//
//  Speichert die Anmeldedaten sicher im macOS-Schlüsselbund, damit sie nach
//  einem Neustart nicht erneut eingegeben werden müssen.
//

import Foundation
import Security

/// Gespeicherte Anmeldedaten.
struct Credentials: Codable, Equatable {
    let username: String
    let password: String
}

/// Kleiner Wrapper um die Keychain-`SecItem`-APIs für genau ein Login-Item.
enum KeychainStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "Logbuch-Loader") + ".login"
    private static let account = "credentials"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Speichert (oder aktualisiert) die Anmeldedaten.
    static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Zugriff nur, solange der Mac entsperrt ist – restriktiver als
            // AfterFirstUnlock (kein Zugriff mehr, sobald wieder gesperrt).
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Lädt die gespeicherten Anmeldedaten, falls vorhanden.
    static func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return nil
        }
        return credentials
    }

    /// Löscht die gespeicherten Anmeldedaten.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
