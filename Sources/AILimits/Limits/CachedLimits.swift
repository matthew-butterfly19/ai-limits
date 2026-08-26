import Foundation

/// Serves the last good snapshot when the live provider fails, marked stale.
///
/// The countdown is never cached: `LimitWindow.timeLeft` is recomputed from
/// `resetsAt` on every read, so a snapshot from ten minutes ago still shows the
/// right time to reset instead of a frozen number.
struct CachedLimits: LimitsProvider {
    let base: LimitsProvider
    var directory: URL = Store.dataDirectory

    var app: AppKind { base.app }

    private var cacheURL: URL {
        directory.appendingPathComponent("limits-\(app.rawValue).json")
    }

    func fetch() async throws -> LimitsSnapshot {
        do {
            let snapshot = try await base.fetch()
            save(snapshot)
            return snapshot
        } catch {
            guard var cached = load() else { throw error }
            cached.staleReason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return cached
        }
    }

    /// The last snapshot on disk, without contacting the provider. Used at
    /// launch so the menu bar has something to show before the first fetch.
    func cachedSnapshot() -> LimitsSnapshot? {
        guard var snapshot = load() else { return nil }
        snapshot.staleReason = "dane z \(Format.when(snapshot.takenAt))"
        return snapshot
    }

    private func save(_ snapshot: LimitsSnapshot) {
        var value = snapshot
        value.staleReason = nil
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func load() -> LimitsSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(LimitsSnapshot.self, from: data)
    }
}
