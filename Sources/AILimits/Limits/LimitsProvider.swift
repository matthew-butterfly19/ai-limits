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
    case throttled(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .keychainDenied:      return "brak dostępu do Keychaina"
        case .tokenExpired:        return "token wygasł – uruchom Claude Code, odświeży go sam"
        case .emptyResponse(let s): return "odpowiedź bez danych o limitach (\(s))"
        case .processFailed(let s): return s
        case .timedOut(let s):     return "\(s) nie odpowiedział w czasie"
        case .throttled(let retry):
            let when = retry.map { " – ponów za \(Format.timeLeft($0))" } ?? ""
            return "za częste odpytywanie limitów\(when)"
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
