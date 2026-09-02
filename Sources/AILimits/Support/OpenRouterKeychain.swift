import Foundation
import Security

/// Stary wpis management key w Keychainie — dziś już **tylko źródło migracji**
/// dla `OpenRouterKey`, który trzyma klucz w pliku.
///
/// Powód przeprowadzki jest opisany w `OpenRouterKey`: lista dostępu wpisu jest
/// przypięta do konkretnego pliku binarnego, więc każda instalacja lokalnego
/// builda kończyła się kolejnym oknem z hasłem do keychaina. Zostaje tu tyle,
/// ile trzeba, żeby raz przeczytać klucz zapisany przez starszą wersję i wpis
/// usunąć, gdy użytkownik kasuje klucz.
enum OpenRouterKeychain {
    static let service = "dev.ailimits.openrouter-management-key"
    private static let account = "openrouter"

    /// Klucz raz odczytany zostaje w pamięci procesu do końca jego życia.
    ///
    /// Nie optymalizacja — naprawa. macOS pyta o hasło do Keychaina przy
    /// każdym odczycie, którego nie pokrywa jeszcze zgoda „Zawsze zezwalaj”, a
    /// czytaliśmy przy każdym odświeżeniu, czyli co pięć minut. Jedno pytanie
    /// na uruchomienie zamiast dwunastu na godzinę. W pamięci, nigdy na dysku
    /// i nigdy w logu.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: String?

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Wyciągnięcie klucza z Keychaina. Zwraca nil, gdy nie ma wpisu (pierwsze
    /// uruchomienie, użytkownik jeszcze nie skonfigurował).
    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        cached = String(data: data, encoding: .utf8)
        return cached
    }

    /// Czy wpis w ogóle istnieje — bez sięgania po sam sekret.
    ///
    /// Zapytanie o same atrybuty nie rusza listy dostępu, więc nie wywołuje
    /// okna z hasłem. Dzięki temu start aplikacji („czy klucz jest
    /// skonfigurowany?”) jest cichy, a o sekret pytamy dopiero wtedy, gdy
    /// naprawdę idziemy z nim do OpenRoutera.
    static func exists() -> Bool {
        lock.lock()
        let haveCached = cached != nil
        lock.unlock()
        if haveCached { return true }

        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func delete() throws {
        lock.lock()
        cached = nil
        lock.unlock()
        let status = SecItemDelete(baseQuery as CFDictionary)
        // errSecItemNotFound: klucza już nie ma — z perspektywy użytkownika to
        // nie błąd, chciał żeby go nie było.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed
        }
    }

    enum KeychainError: LocalizedError {
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .deleteFailed: return "nie udało się usunąć klucza z Keychaina"
            }
        }
    }
}
