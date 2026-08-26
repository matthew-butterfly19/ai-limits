import Foundation

/// The two products whose usage this app tracks. Raw values are the `app`
/// column already written by the Python collector — do not rename them.
enum AppKind: String, CaseIterable, Sendable, Codable {
    case claude
    case codex

    /// Name as it appears in the menu bar. The user rejected abbreviations.
    var display: String {
        switch self {
        case .claude: return "ClaudeCode"
        case .codex:  return "Codex"
        }
    }
}

/// One billed API response. `uniq` is the app-specific dedup key:
/// Claude `<message.id>:<requestId>`, Codex `<session_id>:<ordinal>`.
struct UsageEvent: Sendable {
    var app: AppKind
    var uniq: String
    var sessionID: String
    var ts: Date
    var model: String?
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var reasoning: Int
    /// Claude subagent transcript — the tokens are real, but they also roll up
    /// into the parent session, so the UI can separate them.
    var sidechain: Bool

    var total: Int { input + output + cacheRead + cacheWrite }
    /// Total minus cache reads: the headline's second number. Cache reads are
    /// ~97% of raw volume and are not proportional to limit burn.
    var billable: Int { input + output + cacheWrite }
}

struct SessionInfo: Sendable {
    var app: AppKind
    var sessionID: String
    var title: String?
    var cwd: String?
    /// Free-form provenance string ("cli", "vscode", …) as found in the log.
    var origin: String?
    var firstTS: Date?
    var lastTS: Date?
    /// The user named this thread with `/rename`. A generated title must never
    /// overwrite a chosen one, whichever arrives later in the log.
    var titleIsCustom = false

    /// Last path component of `cwd` — what the UI shows as the project.
    var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

/// One context compaction.
///
/// Neither vendor logs the compaction request's own token usage: Claude Code
/// writes a `compact_boundary` record with no usage block, and Codex emits a
/// `token_count` of literally zero next to its `compacted` record. The cost is
/// real — the call re-reads the whole conversation — but it is invisible in the
/// usage stream, which is why these numbers live apart from it and are labelled
/// as an estimate wherever they are shown.
struct Compaction: Sendable {
    var app: AppKind
    var sessionID: String
    var ts: Date
    /// "manual" / "auto" for Claude; nil for Codex, which does not say.
    var trigger: String?
    /// Context size going in — roughly what the compaction call had to read.
    var preTokens: Int
    /// Context size coming out.
    var postTokens: Int
    var dropped: Int
    var durationMs: Int
}

/// One reading of a rate-limit window, as reported by the vendor.
struct LimitSample: Sendable {
    var ts: Date
    var app: AppKind
    var windowMinutes: Int
    var pct: Double
    var resetsAt: Date?
}

/// Everything one provider knows right now.
struct LimitsSnapshot: Sendable, Codable {
    var app: AppKind
    var takenAt: Date
    var windows: [LimitWindow]
    var planName: String?
    /// Windows the vendor meters per model, shown alongside the main ones.
    var scoped: [ScopedLimit] = []
    /// Set when the snapshot came from cache because the live fetch failed.
    var staleReason: String?

    var isStale: Bool { staleReason != nil }

    func window(minutes: Int) -> LimitWindow? { windows.first { $0.minutes == minutes } }
}

struct LimitWindow: Sendable, Identifiable, Codable {
    var minutes: Int
    var pct: Double
    var resetsAt: Date?

    var id: Int { minutes }

    /// Recomputed from `resetsAt` on every read, never a stored countdown —
    /// a cached snapshot must keep counting down correctly.
    func timeLeft(now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }

    /// Start of the window this percentage describes.
    func windowStart(now: Date = Date()) -> Date {
        let end = resetsAt ?? now
        return end.addingTimeInterval(-Double(minutes) * 60)
    }
}
