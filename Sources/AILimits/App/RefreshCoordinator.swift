import Foundation

/// One refresh cycle: pull new log lines in, read both vendors' limits, record
/// a sample of each, and hand the result back.
struct RefreshCoordinator {
    let store: Store
    var providers: [LimitsProvider] = [
        CachedLimits(base: ClaudeLiveLimits()),
        CachedLimits(base: CodexLiveLimits()),
    ]

    struct Result {
        var snapshots: [AppKind: LimitsSnapshot] = [:]
        var errors: [AppKind: String] = [:]
        var ingestedFiles = 0
    }

    /// With `fetchLimits` false the vendors are left alone and only the local
    /// logs are read — which is all a screen tick needs.
    func run(fetchLimits: Bool = true) async -> Result {
        var result = Result()

        do {
            result.ingestedFiles = try ClaudeIngest(store: store).run()
            result.ingestedFiles += try CodexIngest(store: store).run()
        } catch {
            result.errors[.claude] = "ingest: \(error)"
        }

        guard fetchLimits else { return result }

        // Both vendors are polled concurrently — the Codex call spawns a
        // process and takes about half a second on its own.
        await withTaskGroup(of: (AppKind, Swift.Result<LimitsSnapshot, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.app, .success(try await provider.fetch())) }
                    catch { return (provider.app, .failure(error)) }
                }
            }
            for await (app, outcome) in group {
                switch outcome {
                case .success(let snapshot):
                    result.snapshots[app] = snapshot
                    record(snapshot)
                case .failure(let error):
                    result.errors[app] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
        return result
    }

    /// A stale snapshot is not re-recorded: its percentages describe the moment
    /// it was taken, and writing them under `now` would flatten the chart.
    private func record(_ snapshot: LimitsSnapshot) {
        guard !snapshot.isStale else { return }
        for window in snapshot.windows {
            try? store.add(limitSample: LimitSample(
                ts: snapshot.takenAt, app: snapshot.app,
                windowMinutes: window.minutes, pct: window.pct, resetsAt: window.resetsAt))
        }
        for scoped in snapshot.scoped {
            try? store.add(scopedSample: LimitSample(
                ts: snapshot.takenAt, app: snapshot.app,
                windowMinutes: scoped.window.minutes, pct: scoped.window.pct,
                resetsAt: scoped.window.resetsAt), label: scoped.label)
        }
    }
}
