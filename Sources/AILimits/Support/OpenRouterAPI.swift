import Foundation

/// Klient do OpenRouter API — pobiera rzeczywiste koszty rozliczeniowe.
///
/// Wymaga management key (OAuth, nie ten sam, którym dsh robi inferencję).
/// Endpointy:
///   GET /api/v1/activity — koszty per (data, model), z opcjonalnym filtrem api_key_hash
///   GET /api/v1/keys     — lista zwykłych kluczy API na koncie (hash + etykieta)
enum OpenRouterAPI {
    private static let base = URL(string: "https://openrouter.ai/api/v1")!

    // MARK: - modele danych

    struct ActivityRow: Codable {
        var date: String
        var model: String
        var usage: Double

        /// Reszta pól, które API może zwracać — nie wymagane, ale przydatne
        /// do weryfikacji podczas implementacji.
        var modelPermaslug: String?
        var providerName: String?
        var requests: Int?
        var promptTokens: Int?
        var completionTokens: Int?
        var reasoningTokens: Int?
        var apiKeyHash: String?
        var byokUsageInference: Double?
    }

    struct KeyInfo: Decodable {
        var hash: String
        /// Zamaskowana wartość klucza od OpenRoutera, np. "sk-or-v1-abc...123"
        /// — mimo nazwy pola to nie jest ludzka etykieta.
        var label: String?
        /// Nazwa nadana kluczowi przez użytkownika — to pokazujemy w pickerze.
        var name: String?
        /// Wydatek od początku bieżącego dnia — jedyne pole w tym API, które
        /// mówi cokolwiek o "dziś". `/activity` obejmuje tylko zakończone dni
        /// UTC, więc dzisiejszy dzień nigdy się tam nie pojawi; to pole nie ma
        /// tego ograniczenia, bo to licznik na kluczu, nie eksport historii.
        var usageDaily: Double?
        /// Wydatek od stworzenia klucza — cały czas, nie tylko dziś.
        var usage: Double?
        /// Pola, z których składa się „czy ten klucz jeszcze działa”: klucz
        /// wyłączony ręcznie, limit wydatków i ile z niego zostało, jak często
        /// limit się zeruje (`weekly`/`monthly`/nil — jednorazowy) i data
        /// wygaśnięcia. Wszystkie opcjonalne, bo klucz bez limitu ma tu same
        /// `null`e.
        var disabled: Bool?
        var limit: Double?
        var limitRemaining: Double?
        var limitReset: String?
        var usageWeekly: Double?
        var usageMonthly: Double?
        var expiresAt: String?

        /// Wydatek w bieżącym okresie limitu — tygodniowym albo miesięcznym,
        /// zależnie od tego, jak klucz się zeruje. Dla klucza bez okresu
        /// (limit jednorazowy albo brak limitu) — od początku.
        var usageInPeriod: Double? {
            switch limitReset {
            case "weekly": return usageWeekly
            case "monthly": return usageMonthly
            default: return usage
            }
        }

        /// Ile procent limitu poszło. `nil` bez limitu — wtedy nie ma czego
        /// mierzyć i pasek nie ma sensu.
        var limitUsedPercent: Double? {
            guard let limit, limit > 0, let remaining = limitRemaining else { return nil }
            return max(0, min(100, (limit - remaining) / limit * 100))
        }

        /// Data wygaśnięcia, jeśli OpenRouter ją podał (ISO 8601).
        var expiryDate: Date? {
            guard let expiresAt else { return nil }
            return ISO8601DateFormatter.withFractions.date(from: expiresAt)
                ?? ISO8601DateFormatter().date(from: expiresAt)
        }
    }

    /// Odpowiedź API dla /keys może być listą lub obiektem z polem `data`.
    private struct KeysResponse: Decodable {
        var data: [KeyInfo]?
        /// Niektóre API zwracają listę na wierzchu.
    }

    /// Odpowiedź API dla /activity — może być listą lub obiektem z polem `data`.
    private struct ActivityResponse: Decodable {
        var data: [ActivityRow]?
    }

    // MARK: - fetch

    /// Pobiera listę kluczy API z konta. Każdy ma hash i etykietę — użytkownik
    /// wybiera, który z nich to ten używany przez Harness.
    static func fetchKeys(managementKey: String) async throws -> [KeyInfo] {
        let url = base.appendingPathComponent("keys")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.badResponse("nie HTTP")
        }
        try checkHTTPStatus(http)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Próbuj parsować jako listę na wierzchu
        if let rows = try? decoder.decode([KeyInfo].self, from: data) {
            return rows
        }
        // Albo jako obiekt z polem data
        if let wrapped = try? decoder.decode(KeysResponse.self, from: data),
           let rows = wrapped.data {
            return rows
        }
        throw OpenRouterError.decodeFailed("nieoczekiwany format /keys")
    }

    /// Pobiera koszty rozliczeniowe. Jeśli `apiKeyHash` nie jest nil, filtruje
    /// tylko wiersze dla tego konkretnego klucza.
    static func fetchActivity(managementKey: String,
                              apiKeyHash: String? = nil) async throws -> [ActivityRow] {
        guard var components = URLComponents(url: base.appendingPathComponent("activity"),
                                             resolvingAgainstBaseURL: false) else {
            throw OpenRouterError.badResponse("nieprawidłowy URL")
        }
        if let hash = apiKeyHash {
            components.queryItems = [URLQueryItem(name: "api_key_hash", value: hash)]
        }
        guard let url = components.url else {
            throw OpenRouterError.badResponse("nieprawidłowy URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.badResponse("nie HTTP")
        }
        try checkHTTPStatus(http)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Próbuj parsować jako listę na wierzchu
        if let rows = try? decoder.decode([ActivityRow].self, from: data) {
            return rows
        }
        // Albo jako obiekt z polem data
        if let wrapped = try? decoder.decode(ActivityResponse.self, from: data),
           let rows = wrapped.data {
            return rows
        }
        throw OpenRouterError.decodeFailed("nieoczekiwany format /activity")
    }

    // MARK: - model matching

    /// Dopasowuje nazwę modelu z bazy do sluga z OpenRoutera.
    ///
    /// baza vs OpenRouter:
    ///   google/gemini-3.7-flash → google/gemini-3.7-flash (to samo)
    ///   deepseek-v4-flash       → deepseek/deepseek-v4-flash (dodaj prefiks)
    ///
    /// Jeśli dopasowanie nie jest pewne, zwraca nil — lepiej nic nie pokazać
    /// niż pokazać koszt cudzego modelu.
    static func openRouterModel(for dbModel: String, seenModels: Set<String>) -> String? {
        if dbModel.contains("/") {
            // Ma już prefiks — powinien pasować wprost.
            return seenModels.contains(dbModel) ? dbModel : nil
        }
        // Bez prefiksu: deepseek/<nazwa>
        let candidate = "deepseek/\(dbModel)"
        if seenModels.contains(candidate) {
            return candidate
        }
        // W ostateczności — sama nazwa, gdyby OpenRouter zwracał bez prefiksu.
        if seenModels.contains(dbModel) {
            return dbModel
        }
        return nil
    }

    /// Suma `usage` per model, tylko dla dni od `since` (nil = całe okno
    /// zwrócone przez API). Porównanie na stringach: `YYYY-MM-DD` sortuje się
    /// leksykograficznie, a dzień w odpowiedzi jest w UTC.
    static func costs(rows: [ActivityRow], since: Date?) -> [String: Double] {
        let sinceDay = since.map(utcDay)
        var costs: [String: Double] = [:]
        for row in rows {
            if let sinceDay, row.date < sinceDay { continue }
            costs[row.model, default: 0] += row.usage
        }
        return costs
    }

    /// `YYYY-MM-DD` w UTC dla daty — do porównania z polem `date` /activity.
    static func utcDay(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - helpers


    private static func checkHTTPStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200: return
        case 401: throw OpenRouterError.unauthorized
        case 429: throw OpenRouterError.throttled
        case let code where code >= 500: throw OpenRouterError.serverError(code)
        default: throw OpenRouterError.httpError(http.statusCode)
        }
    }

    enum OpenRouterError: LocalizedError {
        case unauthorized
        case throttled
        case serverError(Int)
        case httpError(Int)
        case badResponse(String)
        case decodeFailed(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "klucz management odrzucony (401) — sprawdź ważność"
            case .throttled:
                return "OpenRouter ogranicza zapytania — odczekaj chwilę"
            case .serverError(let code):
                return "OpenRouter błąd serwera (\(code))"
            case .httpError(let code):
                return "OpenRouter odpowiedział \(code)"
            case .badResponse(let s):
                return "nieprawidłowa odpowiedź: \(s)"
            case .decodeFailed(let s):
                return "błąd parsowania: \(s)"
            case .networkError(let s):
                return "błąd sieci: \(s)"
            }
        }
    }
}

private extension ISO8601DateFormatter {
    /// OpenRouter pisze daty z ułamkami sekund (`2026-06-23T13:35:16.186Z`),
    /// których domyślny formatter nie przyjmuje.
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
