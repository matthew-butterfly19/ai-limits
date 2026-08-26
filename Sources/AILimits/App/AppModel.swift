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
    @Published private(set) var forecasts: [AppKind: [Forecast]] = [:]
    @Published private(set) var threads: [StatsEngine.ThreadRow] = []
    @Published private(set) var compactions: [AppKind: [Compaction]] = [:]
    @Published private(set) var weekOverWeek: [AppKind: StatsEngine.WeekOverWeek] = [:]
    /// Tokens per one percent of the 5 h window, per app — the exchange rate
    /// between what the logs measure and what the limit actually charges.
    @Published private(set) var tokensPerPercent: [AppKind: Double] = [:]
    /// Fixed once from the whole history, never re-derived per view.
    @Published private(set) var modelColors = ModelColors(models: [])
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errors: [AppKind: String] = [:]
    @Published private(set) var fatalError: String?
    @Published var isRefreshing = false

    /// What the menu bar leads with. Persisted, because it is a preference.
    @Published var titleMode: TitleMode = .compact {
        didSet {
            UserDefaults.standard.set(titleMode.rawValue, forKey: Self.titleModeKey)
            rebuildTitle()
        }
    }
    private static let titleModeKey = "menuBarMode"

    /// The screen ticks far more often than the network does.
    ///
    /// Time-to-reset is recomputed locally from `resetsAt`, and pulling new log
    /// lines is a few kilobytes off local disk — neither needs a vendor. The
    /// limit endpoints do, and asking them every two minutes is what earned the
    /// stream of 429s, so they get five.
    static let tickInterval: TimeInterval = 30
    static let limitsInterval: TimeInterval = 300

    private(set) var store: Store?
    private var stats: StatsEngine?

    var statsEngine: StatsEngine? { stats }
    private var loop: Task<Void, Never>?
    private var lastLimitsFetch: Date?

    init() {
        do {
            let store = try Store()
            self.store = store
            self.stats = StatsEngine(store: store)
        } catch {
            fatalError = "\(error)"
        }
        titleMode = UserDefaults.standard.string(forKey: Self.titleModeKey)
            .flatMap(TitleMode.init(rawValue:)) ?? .compact
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
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
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

    /// `force` is the manual refresh button: it asks the vendors regardless of
    /// how recently they were last asked.
    func refresh(force: Bool = false) async {
        guard let store, let stats, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let due = force || lastLimitsFetch.map {
            Date().timeIntervalSince($0) >= Self.limitsInterval
        } ?? true

        let coordinator = RefreshCoordinator(store: store)
        let result = await coordinator.run(fetchLimits: due)
        if due { lastLimitsFetch = Date() }

        for (app, snapshot) in result.snapshots { snapshots[app] = snapshot }
        if due { errors = result.errors }

        var rates: [AppKind: Double] = [:]
        for app in AppKind.allCases {
            windowTotals[app] = (try? stats.currentWindowTotals(snapshot: snapshots[app])) ?? nil
            let windows = (try? stats.forecasts(app: app, snapshot: snapshots[app])) ?? []
            forecasts[app] = windows
            rates[app] = windows.first { $0.minutes == 300 }?.tokensPerPercent
        }
        tokensPerPercent = rates
        for app in AppKind.allCases {
            weekOverWeek[app] = (try? stats.weekOverWeek(app: app, snapshot: snapshots[app],
                                                         tokensPerPercent: rates[app])) ?? nil
        }
        // Per app, from that app's own window start. Sharing one start date
        // across both would let a thread's tokens fall outside the window its
        // percentage is computed against, and the percentages would stop adding
        // up to the window's own figure.
        var rows: [StatsEngine.ThreadRow] = []
        for app in AppKind.allCases {
            let start = snapshots[app]?.window(minutes: 300)?.windowStart()
                ?? Date().addingTimeInterval(-5 * 3_600)
            rows += (try? stats.threadRows(since: start, app: app, limit: 8,
                                           tokensPerPercent: rates)) ?? []
        }
        threads = rows
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
        menuBarTitle = MenuBarTitle.render(snapshots: snapshots, totals: windowTotals,
                                           forecasts: forecasts, mode: titleMode)
    }
}
