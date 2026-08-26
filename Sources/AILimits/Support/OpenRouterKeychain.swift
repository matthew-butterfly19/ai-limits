import Foundation
import Security

/// Management key dla OpenRoutera — własny item tej aplikacji, przez natywne
/// `SecItem*`, nie przez `/usr/bin/security`.
///
/// Odczyt tokena Claude'a (`ClaudeLiveLimits`) musi iść przez `security`, bo to
/// cudzy item w cudzej access-group. Tu tworzymy własny wpis od zera — access
/// group nie ma znaczenia, więc natywne API działa bez obejść i, w
/// przeciwieństwie do `add-generic-password -w <sekret>`, nigdy nie stawia
/// samego klucza w argumentach procesu, gdzie inny proces na tej maszynie
/// mógłby go odczytać przez `ps` w czasie trwania wywołania.
enum OpenRouterKeychain {
    static let service = "dev.ailimits.openrouter-management-key"
    private static let account = "openrouter"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Wyciągnięcie klucza z Keychaina. Zwraca nil, gdy nie ma wpisu (pierwsze
    /// uruchomienie, użytkownik jeszcze nie skonfigurował).
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Zapis lub aktualizacja klucza — usuń istniejący wpis, dodaj nowy.
    static func save(_ key: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw KeychainError.saveFailed
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // errSecItemNotFound: klucza już nie ma — z perspektywy użytkownika to
        // nie błąd, chciał żeby go nie było.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed
        }
    }

    enum KeychainError: LocalizedError {
        case saveFailed
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed:   return "nie udało się zapisać klucza do Keychaina"
            case .deleteFailed: return "nie udało się usunąć klucza z Keychaina"
            }
        }
    }
}
