import Foundation

enum Glob {
    /// Expands a shell glob the same way Python's `glob.glob` does.
    static func expand(_ pattern: String) -> [String] {
        var results = glob_t()
        defer { globfree(&results) }
        guard glob(pattern, 0, nil, &results) == 0 else { return [] }
        return (0..<Int(results.gl_pathc)).compactMap { index in
            results.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// Every match of every pattern, de-duplicated, newest file first — so a
    /// byte-capped pass always covers the sessions that are running right now.
    static func newestFirst(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for pattern in patterns {
            for path in expand(pattern) where seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths.sorted { modified($0) > modified($1) }
    }

    private static func modified(_ path: String) -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

/// Session metadata collected while scanning one file, flushed in one go
/// instead of issuing an UPSERT per event.
struct SessionAccumulator {
    private var pending: [String: SessionInfo] = [:]

    mutating func note(app: AppKind, sessionID: String,
                       title: String? = nil, cwd: String? = nil,
                       origin: String? = nil, ts: Date? = nil) {
        var info = pending[sessionID] ?? SessionInfo(app: app, sessionID: sessionID,
                                                     title: nil, cwd: nil, origin: nil,
                                                     firstTS: nil, lastTS: nil)
        if let title { info.title = title }
        if let cwd { info.cwd = cwd }
        if let origin { info.origin = origin }
        if let ts {
            info.firstTS = min(info.firstTS ?? ts, ts)
            info.lastTS = max(info.lastTS ?? ts, ts)
        }
        pending[sessionID] = info
    }

    mutating func flush(into store: Store) throws {
        for info in pending.values { try store.touch(session: info) }
        pending.removeAll()
    }

    var isEmpty: Bool { pending.isEmpty }
}
