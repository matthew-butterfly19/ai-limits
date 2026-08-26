import Foundation
import SwiftUI

/// Everything the UI observes. Owns the store and drives the refresh cycle.
@MainActor
final class AppModel: ObservableObject {
    /// One instance for the whole process. SwiftUI re-creates the `App` struct
    /// whenever its state changes, so an `AppModel()` in a property initialiser
    /// produces throwaway copies — and the refresh loop would end up running on
    /// a model no view is observing.
    static let shared = AppModel()

    @Published private(set) var menuBarTitle = "AI limits …"
    @Published private(set) var snapshots: [AppKind: LimitsSnapshot] = [:]
    @Published private(set) var windowTotals: [AppKind: TokenTotals] = [:]
    @Published private(set) var burnRates: [AppKind: StatsEngine.BurnRate] = [:]
    @Published private(set) var threads: [StatsEngine.ThreadRow] = []
    @Published private(set) var compactions: [AppKind: [Compaction]] = [:]
    /// Fixed once from the whole history, never re-derived per view.
    @Published private(set) var modelColors = ModelColors(models: [])
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [AppKind: String] = [:]
    @Published private(set) var fatalError: String?
    @Published var isRefreshing = false

    /// How often the cycle runs on its own. Two minutes matches the cadence the
    /// SwiftBar plugin ran at, which proved frequent enough to catch a window
    /// filling up without hammering either backend.
    static let refreshInterval: TimeInterval = 120

    private(set) var store: Store?
    private var stats: StatsEngine?

    var statsEngine: StatsEngine? { stats }
    private var loop: Task<Void, Never>?

    init() {
        do {
            let store = try Store()
            self.store = store
            self.stats = StatsEngine(store: store)
        } catch {
            fatalError = "\(error)"
        }
        modelColors = ModelColors(models: (try? store?.distinctModels()) ?? [])
        loadCachedSnapshots()
        rebuildTitle()
    }

    /// Structured concurrency rather than a `Timer`: a run-loop timer in a
    /// menu-bar-only app depends on which mode the loop happens to be in, and
    /// silently stops firing when that changes.
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Shows whatever the last run left on disk, so the menu bar is populated
    /// before the first network round trip finishes.
    private func loadCachedSnapshots() {
        for provider in [CachedLimits(base: ClaudeLiveLimits()), CachedLimits(base: CodexLiveLimits())] {
            if let snapshot = provider.cachedSnapshot() { snapshots[provider.app] = snapshot }
        }
    }

    func refresh() async {
        guard let store, let stats, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let coordinator = RefreshCoordinator(store: store)
        let result = await coordinator.run()

        for (app, snapshot) in result.snapshots { snapshots[app] = snapshot }
        errors = result.errors

        for app in AppKind.allCases {
            windowTotals[app] = (try? stats.currentWindowTotals(snapshot: snapshots[app])) ?? nil
            burnRates[app] = (try? stats.burnRate(app: app, minutes: 300)) ?? nil
        }
        threads = (try? stats.threadRows(since: earliestWindowStart(), limit: 12)) ?? []
        let compacted = (try? store.compactions(since: earliestWindowStart())) ?? []
        compactions = Dictionary(grouping: compacted, by: \.app)
        if let models = try? store.distinctModels(), models.count != modelColors.count {
            modelColors = ModelColors(models: models)
        }

        lastRefresh = Date()
        try? store.pruneLimits()
        rebuildTitle()
        if ProcessInfo.processInfo.environment["AILIMITS_TRACE"] != nil {
            let stale = snapshots.compactMapValues(\.staleReason)
                .map { "\($0.key.rawValue): \($0.value)" }
            let line = "refresh \(Date()) → \(menuBarTitle)\n  błędy: \(errors)  nieświeże: \(stale)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// Start of the earliest active 5-hour window across both apps — the
    /// interval the popover's thread list covers.
    func earliestWindowStart(now: Date = Date()) -> Date {
        let starts = AppKind.allCases.compactMap {
            snapshots[$0]?.window(minutes: 300)?.windowStart(now: now)
        }
        return starts.min() ?? now.addingTimeInterval(-5 * 3_600)
    }

    private func rebuildTitle() {
        menuBarTitle = MenuBarTitle.render(snapshots: snapshots, totals: windowTotals)
    }
}
