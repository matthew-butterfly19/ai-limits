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

    /// To samo, ale poza główną kolejką.
    ///
    /// Okno Keychaina blokuje wątek, który poprosił o sekret. Na głównym
    /// oznaczało to zamrożoną aplikację — nieklikalny panel, wstrzymane
    /// odświeżanie, pasek stojący w miejscu — na cały czas, gdy dialog czeka na
    /// hasło. Sam odczyt jest i tak jednorazowy (dalej działa cache), ale ten
    /// jeden raz nie ma prawa zatrzymać reszty.
    static func readOffMain() async -> String? {
        await Task.detached(priority: .userInitiated) { read() }.value
    }

    /// Zapis lub aktualizacja klucza — usuń istniejący wpis, dodaj nowy.
    static func save(_ key: String) throws {
        lock.lock()
        cached = nil
        lock.unlock()
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw KeychainError.saveFailed
        }
        lock.lock()
        cached = key
        lock.unlock()
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
