import Foundation

/// Owns the SQLite file and serialises every access onto one queue.
///
/// The schema is byte-for-byte the one the Python collector created, and the
/// app opens the same file — the 40 913 events already recorded are adopted,
/// not re-derived.
final class Store {
    static let dataDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AILimits", isDirectory: true)

    static let defaultPath = dataDirectory.appendingPathComponent("stats.db").path

    private let db: Database
    private let queue = DispatchQueue(label: "dev.ailimits.store")

    init(path: String = Store.defaultPath) throws {
        try FileManager.default.createDirectory(at: Store.dataDirectory,
                                                withIntermediateDirectories: true)
        db = try Database(path: path)
        try db.execute(Store.schema)
        // Added after the first release; the column may already be there, and
        // SQLite has no ADD COLUMN IF NOT EXISTS.
        try? db.execute("ALTER TABLE sessions ADD COLUMN title_custom INTEGER NOT NULL DEFAULT 0")
    }

    /// Runs `body` with exclusive access to the connection.
    func sync<T>(_ body: (Database) throws -> T) rethrows -> T {
        try queue.sync { try body(db) }
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS files (
        path   TEXT PRIMARY KEY,
        app    TEXT NOT NULL,
        size   INTEGER NOT NULL,
        offset INTEGER NOT NULL,
        mtime  REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS usage_events (
        app         TEXT NOT NULL,
        uniq        TEXT NOT NULL,
        session_id  TEXT NOT NULL,
        ts          REAL NOT NULL,
        model       TEXT,
        input       INTEGER NOT NULL DEFAULT 0,
        output      INTEGER NOT NULL DEFAULT 0,
        cache_read  INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        reasoning   INTEGER NOT NULL DEFAULT 0,
        sidechain   INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (app, uniq)
    );
    CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events (ts);
    CREATE INDEX IF NOT EXISTS idx_events_session ON usage_events (app, session_id);

    CREATE TABLE IF NOT EXISTS sessions (
        app        TEXT NOT NULL,
        session_id TEXT NOT NULL,
        title      TEXT,
        cwd        TEXT,
        origin     TEXT,
        first_ts   REAL,
        last_ts    REAL,
        PRIMARY KEY (app, session_id)
    );

    CREATE TABLE IF NOT EXISTS limit_samples (
        ts          REAL NOT NULL,
        app         TEXT NOT NULL,
        window_mins INTEGER NOT NULL,
        pct         REAL NOT NULL,
        resets_at   REAL,
        PRIMARY KEY (ts, app, window_mins)
    );
    CREATE INDEX IF NOT EXISTS idx_limits_ts ON limit_samples (ts);

    -- Kompaktowanie kontekstu. Osobna tabela, nie usage_events: własnego kosztu
    -- kompaktu żaden log nie raportuje jako zużycia, więc to szacunek z
    -- metadanych i nie wolno mu wsiąkać w liczby, które zgadzają się co do tokena.
    CREATE TABLE IF NOT EXISTS compactions (
        app         TEXT NOT NULL,
        session_id  TEXT NOT NULL,
        ts          REAL NOT NULL,
        trigger     TEXT,
        pre_tokens  INTEGER NOT NULL DEFAULT 0,
        post_tokens INTEGER NOT NULL DEFAULT 0,
        dropped     INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (app, session_id, ts)
    );
    CREATE INDEX IF NOT EXISTS idx_compactions_ts ON compactions (ts);

    -- Okna, które dostawca mierzy osobno per model (Claude: weekly_scoped).
    -- To jedyny bezpośredni sygnał „ile limitu kosztuje ten konkretny model",
    -- więc zbieramy go od teraz, żeby za tydzień było z czego liczyć.
    CREATE TABLE IF NOT EXISTS scoped_limits (
        ts          REAL NOT NULL,
        app         TEXT NOT NULL,
        label       TEXT NOT NULL,
        window_mins INTEGER NOT NULL,
        pct         REAL NOT NULL,
        resets_at   REAL,
        PRIMARY KEY (ts, app, label, window_mins)
    );
    CREATE INDEX IF NOT EXISTS idx_scoped_ts ON scoped_limits (ts);
    """
}

/// Where in a log file the last ingest stopped.
struct FileCursor: Sendable {
    var offset: Int
    var size: Int
    var mtime: Double
}

extension Store {

    // MARK: - file cursors

    /// How many bytes of `path` are already ingested, or nil when the file is
    /// unchanged since the last pass and can be skipped entirely.
    func cursor(for path: String, app: AppKind) -> FileCursor? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let mtime = modified.timeIntervalSince1970

        return sync { db -> FileCursor? in
            guard let stmt = try? db.prepare(
                "SELECT size, offset, mtime FROM files WHERE path = ?") else {
                return FileCursor(offset: 0, size: size, mtime: mtime)
            }
            stmt.bind(1, path)
            guard (try? stmt.step()) == true else {
                return FileCursor(offset: 0, size: size, mtime: mtime)
            }
            let storedOffset = stmt.int(1)
            let storedMtime = stmt.double(2)
            stmt.reset()

            // Rotated or truncated — the offsets no longer mean anything.
            if size < storedOffset { return FileCursor(offset: 0, size: size, mtime: mtime) }
            // Same size and same mtime: nothing was appended.
            if size == storedOffset, abs(mtime - storedMtime) < 1 { return nil }
            return FileCursor(offset: storedOffset, size: size, mtime: mtime)
        }
    }

    func saveCursor(path: String, app: AppKind, cursor: FileCursor) throws {
        try sync { db in
            let stmt = try db.prepare("""
                INSERT INTO files (path, app, size, offset, mtime) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    app = excluded.app, size = excluded.size,
                    offset = excluded.offset, mtime = excluded.mtime
                """)
            stmt.bindAll([path, app.rawValue, cursor.size, cursor.offset, cursor.mtime])
            try stmt.run()
        }
    }

    // MARK: - writes

    /// Inserts events, ignoring ones already present. Returns how many were new.
    @discardableResult
    func add(events: [UsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try sync { db in
            try db.transaction {
                // Idempotent as before, with one exception: a row whose model
                // was never recorded takes one when a later pass can name it.
                // Codex keeps the model in `turn_context`, so events ingested
                // before that was understood have a NULL here. Nothing else is
                // ever overwritten — the token counts stay untouched.
                let stmt = try db.prepare("""
                    INSERT INTO usage_events
                        (app, uniq, session_id, ts, model,
                         input, output, cache_read, cache_write, reasoning, sidechain)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(app, uniq) DO UPDATE SET
                        model = COALESCE(usage_events.model, excluded.model)
                    WHERE usage_events.model IS NULL AND excluded.model IS NOT NULL
                    """)
                var inserted = 0
                for event in events {
                    stmt.bindAll([event.app.rawValue, event.uniq, event.sessionID,
                                  event.ts, event.model,
                                  event.input, event.output, event.cacheRead,
                                  event.cacheWrite, event.reasoning, event.sidechain])
                    try stmt.run()
                    inserted += db.changes
                }
                return inserted
            }
        }
    }

    /// Upserts session metadata. Existing non-empty titles win over nil, and the
    /// timestamp range only ever widens.
    func touch(session: SessionInfo) throws {
        try sync { db in
            let stmt = try db.prepare("""
                INSERT INTO sessions
                    (app, session_id, title, cwd, origin, first_ts, last_ts, title_custom)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(app, session_id) DO UPDATE SET
                    title = CASE
                        WHEN excluded.title IS NULL      THEN sessions.title
                        WHEN excluded.title_custom = 1   THEN excluded.title
                        WHEN sessions.title_custom = 1   THEN sessions.title
                        ELSE excluded.title
                    END,
                    title_custom = MAX(sessions.title_custom, excluded.title_custom),
                    cwd      = COALESCE(excluded.cwd, sessions.cwd),
                    origin   = COALESCE(excluded.origin, sessions.origin),
                    first_ts = MIN(COALESCE(sessions.first_ts, excluded.first_ts),
                                   COALESCE(excluded.first_ts, sessions.first_ts)),
                    last_ts  = MAX(COALESCE(sessions.last_ts, excluded.last_ts),
                                   COALESCE(excluded.last_ts, sessions.last_ts))
                """)
            stmt.bindAll([session.app.rawValue, session.sessionID, session.title,
                          session.cwd, session.origin, session.firstTS, session.lastTS,
                          session.titleIsCustom ? 1 : 0])
            try stmt.run()
        }
    }

    @discardableResult
    func add(compactions rows: [Compaction]) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try sync { db in
            try db.transaction {
                let stmt = try db.prepare("""
                    INSERT OR IGNORE INTO compactions
                        (app, session_id, ts, trigger, pre_tokens, post_tokens, dropped, duration_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                var inserted = 0
                for row in rows {
                    stmt.bindAll([row.app.rawValue, row.sessionID, row.ts, row.trigger,
                                  row.preTokens, row.postTokens, row.dropped, row.durationMs])
                    try stmt.run()
                    inserted += db.changes
                }
                return inserted
            }
        }
    }

    func add(limitSample sample: LimitSample) throws {
        try sync { db in
            let stmt = try db.prepare("""
                INSERT OR REPLACE INTO limit_samples (ts, app, window_mins, pct, resets_at)
                VALUES (?, ?, ?, ?, ?)
                """)
            stmt.bindAll([sample.ts, sample.app.rawValue, sample.windowMinutes,
                          sample.pct, sample.resetsAt])
            try stmt.run()
        }
    }

    func add(scopedSample sample: LimitSample, label: String) throws {
        try sync { db in
            let stmt = try db.prepare("""
                INSERT OR REPLACE INTO scoped_limits (ts, app, label, window_mins, pct, resets_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            stmt.bindAll([sample.ts, sample.app.rawValue, label, sample.windowMinutes,
                          sample.pct, sample.resetsAt])
            try stmt.run()
        }
    }

    /// Drops limit history older than `days`. Usage events are never pruned.
    func pruneLimits(olderThan days: Int = 30) throws {
        try sync { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            for table in ["limit_samples", "scoped_limits"] {
                let stmt = try db.prepare("DELETE FROM \(table) WHERE ts < ?")
                stmt.bind(1, cutoff)
                try stmt.run()
            }
        }
    }
}
