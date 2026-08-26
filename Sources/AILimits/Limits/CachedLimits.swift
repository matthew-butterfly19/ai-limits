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
        // A throttled endpoint stays throttled for a while; asking again on the
        // next two-minute tick just keeps the door shut.
        if let until = Self.gate.closedUntil(app), until > Date(), var cached = load() {
            cached.staleReason = "odczyt wstrzymany do \(Format.when(until))"
            return cached
        }
        do {
            let snapshot = try await base.fetch()
            Self.gate.open(app)
            save(snapshot)
            return snapshot
        } catch {
            if case LimitsError.throttled(let retryAfter) = error {
                Self.gate.close(app, for: retryAfter ?? Self.defaultCooldown)
            }
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

    /// How long to stay away after a throttle that came without `retry-after`.
    static let defaultCooldown: TimeInterval = 300

    private static let gate = ThrottleGate()

    /// Unix epoch seconds, not Foundation's 2001 reference date. This file is
    /// read by the SwiftBar plugin during the transition, and every other
    /// timestamp in the project is epoch — a second convention here would be a
    /// 31-year error waiting to happen.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func save(_ snapshot: LimitsSnapshot) {
        var value = snapshot
        value.staleReason = nil
        guard let data = try? Self.encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func load() -> LimitsSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? Self.decoder.decode(LimitsSnapshot.self, from: data)
        else { return nil }
        // A day-old set of percentages says nothing useful, and a file written
        // under an older date convention would land decades away.
        guard abs(snapshot.takenAt.timeIntervalSinceNow) < 86_400 else { return nil }
        return snapshot
    }
}

/// Remembers, per app, until when a provider asked to be left alone.
private final class ThrottleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var until: [AppKind: Date] = [:]

    func closedUntil(_ app: AppKind) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return until[app]
    }

    func close(_ app: AppKind, for interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        until[app] = Date().addingTimeInterval(max(interval, 60))
    }

    func open(_ app: AppKind) {
        lock.lock(); defer { lock.unlock() }
        until[app] = nil
    }
}
