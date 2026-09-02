import Foundation

/// Management key do OpenRoutera — trzymany w pliku obok bazy, nie w Keychainie.
///
/// **Dlaczego nie Keychain.** Wpis w keychainie „login” ma listę dostępu
/// przypiętą do konkretnego pliku binarnego. Ta aplikacja jest instalowana z
/// lokalnego builda, więc plik zmienia się przy każdej instalacji, a system
/// pyta wtedy o hasło do keychaina — raz po raz, mimo że zmieniła się tylko
/// wersja tej samej aplikacji. „Zawsze zezwalaj” tego nie kończy: zgoda
/// zapisuje się dla poprzedniego odcisku. Próba przepisania właściciela wpisu
/// z kodu okazała się jeszcze gorsza — dokładała drugie pytanie („wants to
/// change the owner”). Poza Keychainem problem znika w całości.
///
/// **Dlaczego nie na stałe w kodzie**, o co padło pytanie: to repozytorium ma
/// zdalne repo, a klucz w źródłach wyszedłby na zewnątrz przy pierwszym
/// `git push` — z kluczem management ktoś obcy czyta i kasuje klucze API na
/// koncie OpenRoutera. Plik daje dokładnie to samo z perspektywy użytkownika
/// (nigdy więcej okna z hasłem), a nie wychodzi poza ten komputer.
///
/// Prawa `0600` — czyta tylko właściciel konta. To ten sam poziom ochrony, co
/// `~/.claude/.credentials.json`, z którego aplikacja i tak korzysta.
enum OpenRouterKey {
    static let url = Store.dataDirectory.appendingPathComponent("openrouter-key")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: String?
    /// Migracja ze starego wpisu w Keychainie kosztuje jedno okno z hasłem.
    /// Jeśli użytkownik je odrzuci, nie pytamy drugi raz w tym procesie.
    private nonisolated(unsafe) static var migrationFailed = false

    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let fromFile = readFile() {
            cached = fromFile
            return cached
        }
        // Jednorazowe przejęcie klucza zapisanego przez starsze wersje.
        guard !migrationFailed, let legacy = OpenRouterKeychain.read() else {
            migrationFailed = true
            return nil
        }
        try? write(legacy)
        cached = legacy
        return legacy
    }

    /// Poza główną kolejką — dopóki klucz siedzi jeszcze w Keychainie, jeden
    /// odczyt może stanąć na oknie systemowym, a to okno czeka na użytkownika
    /// dowolnie długo.
    static func readOffMain() async -> String? {
        await Task.detached(priority: .userInitiated) { read() }.value
    }

    /// Czy klucz jest skonfigurowany — bez sięgania po sam sekret, więc bez
    /// żadnego okna.
    static func exists() -> Bool {
        lock.lock()
        let haveCached = cached != nil
        lock.unlock()
        if haveCached { return true }
        return FileManager.default.fileExists(atPath: url.path) || OpenRouterKeychain.exists()
    }

    static func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(key)
        cached = key
    }

    static func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        migrationFailed = true
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Stary wpis też, żeby „usuń klucz” naprawdę usuwał klucz, a nie tylko
        // jego kopię. To jedyne miejsce, gdzie okno systemowe jest w porządku:
        // użytkownik właśnie o to poprosił.
        try? OpenRouterKeychain.delete()
    }

    private static func readFile() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func write(_ key: String) throws {
        try FileManager.default.createDirectory(at: Store.dataDirectory,
                                                withIntermediateDirectories: true)
        try Data(key.utf8).write(to: url, options: [.atomic])
        // Po `.atomic` plik powstaje od nowa, więc prawa ustawiamy po zapisie,
        // nie przed — inaczej dotyczyłyby pliku, którego już nie ma.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
