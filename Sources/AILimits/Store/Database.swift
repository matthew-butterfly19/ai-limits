import Foundation
import SQLite3

/// SQLite's "copy this string, I may free it" destructor. Swift does not
/// import the C macro, so it has to be reconstructed.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)

    var description: String {
        switch self {
        case .open(let m):         return "nie udało się otworzyć bazy: \(m)"
        case .sql(let q, let m):   return "SQL: \(m) — \(q)"
        }
    }
}

/// Thin wrapper over the system libsqlite3. No third-party dependency, so the
/// app stays a single binary with nothing to vendor.
///
/// Not thread-safe by itself: every caller goes through `Store`, which owns a
/// serial queue.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        handle = db
        // A concurrent reader (the Python prototype, during the transition)
        // must never make a write fail outright.
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    /// Rows touched by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw DatabaseError.sql(sql, message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.sql(sql, String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt, sql: sql, db: handle)
    }

    /// Runs `body` inside one transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// One prepared statement. Reusable across many rows via `reset()`.
final class Statement {
    private let stmt: OpaquePointer
    private let sql: String
    private weak var owner: AnyObject?
    private let db: OpaquePointer?

    fileprivate init(_ stmt: OpaquePointer, sql: String, db: OpaquePointer?) {
        self.stmt = stmt
        self.sql = sql
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    // MARK: binding (1-based, as in SQLite)

    @discardableResult func bind(_ index: Int32, _ value: Int) -> Statement {
        sqlite3_bind_int64(stmt, index, Int64(value)); return self
    }

    @discardableResult func bind(_ index: Int32, _ value: Double) -> Statement {
        sqlite3_bind_double(stmt, index, value); return self
    }

    @discardableResult func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
        return self
    }

    @discardableResult func bind(_ index: Int32, _ value: Double?) -> Statement {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
        return self
    }

    @discardableResult func bind(_ index: Int32, _ value: Bool) -> Statement {
        sqlite3_bind_int(stmt, index, value ? 1 : 0); return self
    }

    /// Binds positionally, left to right. `nil` binds NULL.
    @discardableResult func bindAll(_ values: [Any?]) -> Statement {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let v as Int:    bind(index, v)
            case let v as Double: bind(index, v)
            case let v as String: bind(index, v)
            case let v as Bool:   bind(index, v)
            case let v as Date:   bind(index, v.timeIntervalSince1970)
            case nil:             sqlite3_bind_null(stmt, index)
            default:              sqlite3_bind_text(stmt, index, "\(value!)", -1, SQLITE_TRANSIENT)
            }
        }
        return self
    }

    // MARK: stepping

    /// True while a row is available.
    @discardableResult func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw DatabaseError.sql(sql, String(cString: sqlite3_errmsg(db)))
    }

    /// Runs a statement expected to produce no rows.
    func run() throws {
        _ = try step()
        reset()
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Iterates every row, calling `body` once per row.
    func forEachRow(_ body: (Statement) throws -> Void) throws {
        defer { reset() }
        while try step() { try body(self) }
    }

    // MARK: reading (0-based, as in SQLite)

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(stmt, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int(stmt, column) != 0 }

    func string(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, column))
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }
}
