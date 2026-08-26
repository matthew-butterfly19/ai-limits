import Foundation

/// Token counts broken out the four ways the vendors bill them.
struct TokenTotals: Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0
    var events = 0
    var sessions = 0

    var total: Int { input + output + cacheRead + cacheWrite }
    /// The headline's second number — total without cache reads.
    var billable: Int { input + output + cacheWrite }
    /// Share of input that was served from cache. nil when nothing was read in.
    var cacheHitRate: Double? {
        let inbound = input + cacheRead + cacheWrite
        guard inbound > 0 else { return nil }
        return Double(cacheRead) / Double(inbound)
    }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    reasoning: lhs.reasoning + rhs.reasoning,
                    events: lhs.events + rhs.events,
                    sessions: max(lhs.sessions, rhs.sessions))
    }
}

/// One thread's consumption, joined with whatever metadata the logs carried.
struct ThreadUsage: Identifiable, Sendable {
    var app: AppKind
    var sessionID: String
    var totals: TokenTotals
    var subagentTokens: Int
    var firstTS: Date?
    var lastTS: Date?
    var title: String?
    var cwd: String?
    var origin: String?

    var id: String { "\(app.rawValue):\(sessionID)" }
    var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }
    var displayTitle: String { title ?? project ?? String(sessionID.prefix(8)) }
}

/// Tokens for one (thread, model) pair — the attribution the user asked for.
struct ThreadModelUsage: Identifiable, Sendable {
    var app: AppKind
    var sessionID: String
    var model: String?
    var totals: TokenTotals
    var id: String { "\(app.rawValue):\(sessionID):\(model ?? "?")" }
}

struct HourBucket: Sendable {
    var app: AppKind
    var hourStart: Date
    var totals: TokenTotals
}

extension Store {

    // MARK: - ingest support

    /// Codex sessions that already carry a title, so the ingest can stop
    /// scanning user messages for one.
    func codexTitledSessions() throws -> Set<String> {
        try sync { db in
            var ids = Set<String>()
            let stmt = try db.prepare(
                "SELECT session_id FROM sessions WHERE app = 'codex' AND title IS NOT NULL")
            try stmt.forEachRow { row in
                if let id = row.string(0) { ids.insert(id) }
            }
            return ids
        }
    }

    /// Every model that has ever appeared in the logs, sorted. Used to pin one
    /// palette slot per model for the lifetime of the app, so a filter that
    /// changes which models are on screen never repaints the survivors.
    func distinctModels() throws -> [String] {
        try sync { db in
            var models: [String] = []
            let stmt = try db.prepare(
                "SELECT DISTINCT model FROM usage_events WHERE model IS NOT NULL ORDER BY model")
            try stmt.forEachRow { row in
                if let model = row.string(0) { models.append(model) }
            }
            return models
        }
    }

    // MARK: - reads

    func totals(since: Date? = nil, until: Date? = nil) throws -> [AppKind: TokenTotals] {
        var sql = """
            SELECT app, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write),
                   SUM(reasoning), COUNT(*), COUNT(DISTINCT session_id)
            FROM usage_events WHERE 1 = 1
            """
        var bindings: [Any?] = []
        if let since { sql += " AND ts >= ?"; bindings.append(since) }
        if let until { sql += " AND ts < ?"; bindings.append(until) }
        sql += " GROUP BY app"

        return try sync { db in
            var result: [AppKind: TokenTotals] = [:]
            let stmt = try db.prepare(sql)
            stmt.bindAll(bindings)
            try stmt.forEachRow { row in
                guard let app = row.string(0).flatMap(AppKind.init(rawValue:)) else { return }
                result[app] = TokenTotals(input: row.int(1), output: row.int(2),
                                          cacheRead: row.int(3), cacheWrite: row.int(4),
                                          reasoning: row.int(5), events: row.int(6),
                                          sessions: row.int(7))
            }
            return result
        }
    }

    func threads(since: Date? = nil, app: AppKind? = nil, limit: Int? = nil) throws -> [ThreadUsage] {
        var sql = """
            SELECT e.app, e.session_id,
                   SUM(e.input), SUM(e.output), SUM(e.cache_read), SUM(e.cache_write),
                   SUM(e.reasoning), COUNT(*),
                   SUM(CASE WHEN e.sidechain
                            THEN e.input + e.output + e.cache_read + e.cache_write
                            ELSE 0 END),
                   MIN(e.ts), MAX(e.ts), s.title, s.cwd, s.origin
            FROM usage_events e
            LEFT JOIN sessions s ON s.app = e.app AND s.session_id = e.session_id
            WHERE 1 = 1
            """
        var bindings: [Any?] = []
        if let since { sql += " AND e.ts >= ?"; bindings.append(since) }
        if let app { sql += " AND e.app = ?"; bindings.append(app.rawValue) }
        sql += """
             GROUP BY e.app, e.session_id
             ORDER BY SUM(e.input) + SUM(e.output) + SUM(e.cache_read) + SUM(e.cache_write) DESC
            """
        if let limit { sql += " LIMIT \(limit)" }

        return try sync { db in
            var rows: [ThreadUsage] = []
            let stmt = try db.prepare(sql)
            stmt.bindAll(bindings)
            try stmt.forEachRow { row in
                guard let app = row.string(0).flatMap(AppKind.init(rawValue:)),
                      let sessionID = row.string(1) else { return }
                rows.append(ThreadUsage(
                    app: app, sessionID: sessionID,
                    totals: TokenTotals(input: row.int(2), output: row.int(3),
                                        cacheRead: row.int(4), cacheWrite: row.int(5),
                                        reasoning: row.int(6), events: row.int(7), sessions: 1),
                    subagentTokens: row.int(8),
                    firstTS: row.date(9), lastTS: row.date(10),
                    title: row.string(11), cwd: row.string(12), origin: row.string(13)))
            }
            return rows
        }
    }

    /// Thread × model, the matrix behind "which model burned how much, where".
    func threadModelMatrix(since: Date? = nil, app: AppKind? = nil) throws -> [ThreadModelUsage] {
        var sql = """
            SELECT app, session_id, model,
                   SUM(input), SUM(output), SUM(cache_read), SUM(cache_write),
                   SUM(reasoning), COUNT(*)
            FROM usage_events WHERE 1 = 1
            """
        var bindings: [Any?] = []
        if let since { sql += " AND ts >= ?"; bindings.append(since) }
        if let app { sql += " AND app = ?"; bindings.append(app.rawValue) }
        sql += """
             GROUP BY app, session_id, model
             ORDER BY SUM(input) + SUM(output) + SUM(cache_read) + SUM(cache_write) DESC
            """

        return try sync { db in
            var rows: [ThreadModelUsage] = []
            let stmt = try db.prepare(sql)
            stmt.bindAll(bindings)
            try stmt.forEachRow { row in
                guard let app = row.string(0).flatMap(AppKind.init(rawValue:)),
                      let sessionID = row.string(1) else { return }
                rows.append(ThreadModelUsage(
                    app: app, sessionID: sessionID, model: row.string(2),
                    totals: TokenTotals(input: row.int(3), output: row.int(4),
                                        cacheRead: row.int(5), cacheWrite: row.int(6),
                                        reasoning: row.int(7), events: row.int(8), sessions: 1)))
            }
            return rows
        }
    }

    /// Per-model totals, collapsed across threads.
    func modelTotals(since: Date? = nil, app: AppKind? = nil) throws -> [(model: String?, totals: TokenTotals)] {
        var byModel: [String: TokenTotals] = [:]
        var order: [String] = []
        for row in try threadModelMatrix(since: since, app: app) {
            let key = row.model ?? ""
            if byModel[key] == nil { order.append(key) }
            byModel[key] = (byModel[key] ?? TokenTotals()) + row.totals
        }
        return order
            .map { (model: $0.isEmpty ? nil : $0, totals: byModel[$0]!) }
            .sorted { $0.totals.total > $1.totals.total }
    }

    /// Hourly buckets in **local** time — the day boundaries have to match what
    /// the user sees on their own clock.
    func hourly(since: Date) throws -> [HourBucket] {
        var buckets: [String: HourBucket] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        try sync { db in
            let stmt = try db.prepare("""
                SELECT app, ts, input, output, cache_read, cache_write, reasoning
                FROM usage_events WHERE ts >= ? ORDER BY ts
                """)
            stmt.bind(1, since.timeIntervalSince1970)
            try stmt.forEachRow { row in
                guard let app = row.string(0).flatMap(AppKind.init(rawValue:)),
                      let timestamp = row.date(1) else { return }
                let hour = calendar.dateInterval(of: .hour, for: timestamp)?.start ?? timestamp
                let key = "\(app.rawValue)|\(hour.timeIntervalSince1970)"
                var bucket = buckets[key] ?? HourBucket(app: app, hourStart: hour, totals: TokenTotals())
                bucket.totals = bucket.totals + TokenTotals(
                    input: row.int(2), output: row.int(3), cacheRead: row.int(4),
                    cacheWrite: row.int(5), reasoning: row.int(6), events: 1, sessions: 0)
                buckets[key] = bucket
            }
        }
        return buckets.values.sorted { $0.hourStart < $1.hourStart }
    }

    /// Compactions in the period, newest first.
    func compactions(since: Date? = nil, app: AppKind? = nil) throws -> [Compaction] {
        var sql = """
            SELECT app, session_id, ts, trigger, pre_tokens, post_tokens, dropped, duration_ms
            FROM compactions WHERE 1 = 1
            """
        var bindings: [Any?] = []
        if let since { sql += " AND ts >= ?"; bindings.append(since) }
        if let app { sql += " AND app = ?"; bindings.append(app.rawValue) }
        sql += " ORDER BY ts DESC"

        return try sync { db in
            var rows: [Compaction] = []
            let stmt = try db.prepare(sql)
            stmt.bindAll(bindings)
            try stmt.forEachRow { row in
                guard let app = row.string(0).flatMap(AppKind.init(rawValue:)),
                      let sessionID = row.string(1), let ts = row.date(2) else { return }
                rows.append(Compaction(app: app, sessionID: sessionID, ts: ts,
                                       trigger: row.string(3), preTokens: row.int(4),
                                       postTokens: row.int(5), dropped: row.int(6),
                                       durationMs: row.int(7)))
            }
            return rows
        }
    }

    /// Wipes the byte cursors so the next pass re-reads every log from the
    /// start. Safe by construction: every insert is keyed and ignored on
    /// conflict, so a re-read adds only what was missing.
    func resetCursors() throws {
        try sync { db in try db.execute("DELETE FROM files") }
    }

    func limitHistory(since: Date, app: AppKind? = nil) throws -> [LimitSample] {
        var sql = "SELECT ts, app, window_mins, pct, resets_at FROM limit_samples WHERE ts >= ?"
        var bindings: [Any?] = [since]
        if let app { sql += " AND app = ?"; bindings.append(app.rawValue) }
        sql += " ORDER BY ts"

        return try sync { db in
            var rows: [LimitSample] = []
            let stmt = try db.prepare(sql)
            stmt.bindAll(bindings)
            try stmt.forEachRow { row in
                guard let timestamp = row.date(0),
                      let app = row.string(1).flatMap(AppKind.init(rawValue:)) else { return }
                rows.append(LimitSample(ts: timestamp, app: app, windowMinutes: row.int(2),
                                        pct: row.double(3), resetsAt: row.date(4)))
            }
            return rows
        }
    }
}
