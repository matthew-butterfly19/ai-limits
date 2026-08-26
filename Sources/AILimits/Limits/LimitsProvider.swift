import Foundation

/// A per-model window the vendor meters separately (Claude reports one per
/// model family on the weekly window).
struct ScopedLimit: Identifiable, Sendable, Codable {
    var label: String
    var window: LimitWindow
    var id: String { "\(label)-\(window.minutes)" }
}

enum LimitsError: LocalizedError {
    case keychainDenied
    case tokenExpired
    case emptyResponse(String)
    case processFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .keychainDenied:      return "brak dostępu do Keychaina"
        case .tokenExpired:        return "token wygasł – uruchom Claude Code, odświeży go sam"
        case .emptyResponse(let s): return "odpowiedź bez danych o limitach (\(s))"
        case .processFailed(let s): return s
        case .timedOut(let s):     return "\(s) nie odpowiedział w czasie"
        }
    }
}

/// One source of live limit data.
///
/// Everything that can fail — a missing binary, an expired token, an empty
/// response — fails here, so the UI only ever deals with a snapshot that is
/// either fresh or explicitly marked stale.
protocol LimitsProvider: Sendable {
    var app: AppKind { get }
    func fetch() async throws -> LimitsSnapshot
}
