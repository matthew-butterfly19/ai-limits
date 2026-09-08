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

    // MARK: - OpenRouter (dsh koszty)

    /// Czy management key jest zapisany w Keychainie.
    @Published var openRouterKeyConfigured = false
    /// Lista zwykłych kluczy API na koncie — użytkownik wybiera który to Harness.
    @Published var openRouterKeys: [OpenRouterAPI.KeyInfo] = []
    /// Hash wybranego klucza (filtrujemy activity po api_key_hash).
    @Published var openRouterSelectedHash: String?
    /// Surowe wiersze z /activity (ostatnie 30 dni). Koszt per model liczony
    /// na żądanie dla widocznego okresu — patrz `openRouterCost(since:)`.
    @Published private(set) var openRouterActivity: [OpenRouterAPI.ActivityRow] = []
    /// Błąd z OpenRouter — pokazywany w widoku szczegółów.
    @Published var openRouterError: String?
    /// Kiedy ostatnio pobrano koszty (unikać zbędnych zapytań).
    @Published var openRouterLastFetch: Date?
    /// Kiedy ostatnio pobrano listę kluczy (a z nią `usageDaily`).
    @Published var openRouterKeysLastFetch: Date?

    private static let selectedHashKey = "openRouterSelectedKeyHash"
    /// `/activity` wraca tylko zakończone dni UTC — ta historia zmienia się
    /// raz dziennie, więc rzadki cache wystarcza.
    static let openRouterCacheTTL: TimeInterval = 6 * 3600
    /// `usage_daily` na `/keys` to licznik na żywo, nie eksport historii —
    /// odświeżamy go w tym samym rytmie co okna limitu, żeby "dziś" nie stało
    /// się nieaktualne w trakcie pracy.
    static let openRouterKeysTTL: TimeInterval = limitsInterval

    /// Czy minął czas od ostatniego pobrania kosztów — wolno spytać API.
    var openRouterShouldRefresh: Bool {
        guard openRouterKeyConfigured, openRouterSelectedHash != nil else { return false }
        guard let last = openRouterLastFetch else { return true }
        return Date().timeIntervalSince(last) >= Self.openRouterCacheTTL
    }

    var openRouterKeysShouldRefresh: Bool {
        guard openRouterKeyConfigured else { return false }
        guard let last = openRouterKeysLastFetch else { return true }
        return Date().timeIntervalSince(last) >= Self.openRouterKeysTTL
    }

    /// Wydatek na kluczu Harnessa od początku dzisiejszego dnia — jedyna
    /// liczba w tym oknie, której nie blokuje opóźnienie `/activity`.
    var openRouterTodayUsage: Double? {
        guard let hash = openRouterSelectedHash else { return nil }
        return openRouterKeys.first { $0.hash == hash }?.usageDaily
    }

    /// Wydatek na kluczu Harnessa od jego stworzenia — nie tylko dziś.
    var openRouterKeyTotalUsage: Double? {
        guard let hash = openRouterSelectedHash else { return nil }
        return openRouterKeys.first { $0.hash == hash }?.usage
    }

    /// What the menu bar leads with — four independent preferences, not one
    /// combined mode. See `MenuBarTitle` for why that used to be one enum.
    @Published var show5hInBar = true {
        didSet {
            UserDefaults.standard.set(show5hInBar, forKey: Self.show5hKey)
            rebuildTitle()
        }
    }
    @Published var show7dInBar = false {
        didSet {
            UserDefaults.standard.set(show7dInBar, forKey: Self.show7dKey)
            rebuildTitle()
        }
    }
    @Published var showForecastInBar = true {
        didSet {
            UserDefaults.standard.set(showForecastInBar, forKey: Self.showForecastKey)
            rebuildTitle()
        }
    }
    @Published var showTokensInBar = false {
        didSet {
            UserDefaults.standard.set(showTokensInBar, forKey: Self.showTokensKey)
            rebuildTitle()
        }
    }
    /// Whether the line may shorten itself when the bar runs out of room.
    /// See `MenuBarFit` for what "runs out of room" means on macOS — the item
    /// is not truncated, it disappears — and `MenuBarTitle.variants` for the
    /// fixed order in which detail is dropped.
    @Published var autoShortenInBar = true {
        didSet {
            UserDefaults.standard.set(autoShortenInBar, forKey: Self.autoShortenKey)
            fit.reset()
            rebuildTitle()
        }
    }
    private static let autoShortenKey = MenuBarDefaults.autoShorten
    /// Zapasowa ikona w Docku na czas, gdy pasek menu nie narysuje nawet
    /// samego znaku. Nie „drugie miejsce na liczby”, tylko jedyne, w które da
    /// się wtedy kliknąć — patrz `DockIcon`. Znika, gdy tylko pasek znowu
    /// cokolwiek pokazuje.
    @Published var dockFallback = true {
        didSet {
            UserDefaults.standard.set(dockFallback, forKey: Self.dockFallbackKey)
            updateDock()
        }
    }
    private static let dockFallbackKey = MenuBarDefaults.dockFallback

    /// Czy pasek menu odmówił nawet najkrótszego szczebla drabiny — czyli czy
    /// z paska nie da się w tej chwili odczytać ani kliknąć niczego.
    @Published private(set) var barIsHidden = false

    private let fit = MenuBarFit()
    /// Co jest w tej chwili narysowane na ikonie w Docku — żeby nie
    /// przerysowywać jej co trzydzieści sekund bez powodu.
    private var dockLabel: String?

    private static let show5hKey = MenuBarDefaults.show5h
    private static let show7dKey = MenuBarDefaults.show7d
    private static let showForecastKey = MenuBarDefaults.showForecast
    private static let showTokensKey = MenuBarDefaults.showTokens

    /// Which apps get a segment in the menu bar line. Everything else about an
    /// app — the popover section, the detail window — stays visible regardless;
    /// this only thins out what competes for room next to the clock.
    @Published var visibleApps: Set<AppKind> = Set(AppKind.allCases) {
        didSet {
            UserDefaults.standard.set(visibleApps.map(\.rawValue), forKey: Self.visibleAppsKey)
            rebuildTitle()
        }
    }
    private static let visibleAppsKey = MenuBarDefaults.visibleApps

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
    private var openRouterTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?

    init() {
        do {
            let store = try Store()
            self.store = store
            self.stats = StatsEngine(store: store)
        } catch {
            fatalError = "\(error)"
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.show5hKey) != nil {
            show5hInBar = defaults.bool(forKey: Self.show5hKey)
            show7dInBar = defaults.bool(forKey: Self.show7dKey)
            showForecastInBar = defaults.bool(forKey: Self.showForecastKey)
        } else if let allWindows = defaults.object(forKey: "menuBarShowAllWindows") as? Bool {
            // One-time migration from the short-lived two-toggle version:
            // 7 d followed "all windows", 5 h and the forecast were implicit.
            show7dInBar = allWindows
        } else if let old = defaults.string(forKey: "menuBarMode") {
            // One-time migration from the original 4-case picker. "tokens"
            // dropped the forecast back then — that was the bug being fixed,
            // not a preference worth carrying forward.
            show7dInBar = old != "compact"
        }
        if defaults.object(forKey: Self.showTokensKey) != nil {
            showTokensInBar = defaults.bool(forKey: Self.showTokensKey)
        }
        if defaults.object(forKey: Self.autoShortenKey) != nil {
            autoShortenInBar = defaults.bool(forKey: Self.autoShortenKey)
        }
        if defaults.object(forKey: Self.dockFallbackKey) != nil {
            dockFallback = defaults.bool(forKey: Self.dockFallbackKey)
        }
        fit.onHidden = { [weak self] hidden in
            guard let self, self.barIsHidden != hidden else { return }
            self.barIsHidden = hidden
            self.updateDock()
        }
        // No saved preference yet (fresh install, or upgrading from a build
        // before this existed) means "everything visible" — the checkbox
        // starts as a no-op, not as an unexplained app disappearing.
        if let saved = UserDefaults.standard.array(forKey: Self.visibleAppsKey) as? [String] {
            visibleApps = Set(saved.compactMap(AppKind.init(rawValue:)))
        }
        modelColors = ModelColors(models: (try? store?.distinctModels()) ?? [])
        // Samo „czy klucz jest” — bez odczytu sekretu, więc bez okna z hasłem
        // przy każdym starcie.
        openRouterKeyConfigured = OpenRouterKey.exists()
        openRouterSelectedHash = UserDefaults.standard.string(forKey: Self.selectedHashKey)
        loadCachedSnapshots()
        loadCachedOpenRouterCosts()
        rebuildTitle()
    }

    /// Structured concurrency rather than a `Timer`: a run-loop timer in a
    /// menu-bar-only app depends on which mode the loop happens to be in, and
    /// silently stops firing when that changes.
    func start() {
        watchScreenChanges()
        // Dopiero teraz `NSApp` na pewno istnieje i przyjmuje zmianę polityki
        // aktywacji — w inicjalizatorze modelu jest jeszcze za wcześnie.
        updateDock()
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
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    /// Plugging in an external display moves the item to a different bar with a
    /// different amount of room — and, on a screen without a notch, no
    /// measurable left edge at all. Everything the fitter concluded about the
    /// old bar stops being true at that instant.
    ///
    /// Switching apps matters for the same reason without changing anything
    /// about the screens: the menu bar follows the active window to another
    /// display, and the item goes with it. Without this the line would keep the
    /// length it needed on the cramped built-in bar for up to a whole tick
    /// after moving to a roomy external one.
    private func watchScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in
                    self?.fit.reset()
                    self?.rebuildTitle()
                }
            }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor [weak self] in
                    // Tylko gdy pasek naprawdę przeniósł się na inny ekran.
                    // Przełączenie aplikacji w obrębie jednego ekranu nie
                    // zmienia dla dopasowania nic, a przeliczenie przerywa
                    // trwający pomiar sąsiadów — przy otwieraniu okien
                    // terminala takich przełączeń jest kilka pod rząd i linia
                    // nigdy nie dochodziła do końca, tylko w kółko rozwijała
                    // się i kurczyła.
                    guard self?.fit.barMoved() == true else { return }
                    self?.rebuildTitle()
                }
            }
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
            if app.hasLimitWindow {
                windowTotals[app] = (try? stats.currentWindowTotals(snapshot: snapshots[app])) ?? nil
            } else {
                // No vendor window to anchor to (dsh) — a fixed rolling 5 h
                // lookback stands in, so the popover and menu bar still have
                // something to report "what did the last stretch cost".
                windowTotals[app] = (try? store.totals(since: Date().addingTimeInterval(-5 * 3_600)))?[app]
            }
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
        // Dsh nie ma okna limitu — zamiast tego odświeżamy koszty z OpenRoutera.
        // Osobnym zadaniem, nie w tym `await`: pierwszy odczyt klucza z
        // Keychaina potrafi stanąć na systemowym oknie z hasłem, a to okno
        // czeka na użytkownika dowolnie długo. Dopóki to było w jednym ciągu,
        // jedno niezauważone okno zatrzymywało całą pętlę odświeżania i w pasku
        // nie pojawiało się nic — dokładnie „nie widzę zupełnie moich limitów”.
        startOpenRouterRefresh(force: force)
        if ProcessInfo.processInfo.environment["AILIMITS_TRACE"] != nil {
            let stale = snapshots.compactMapValues(\.staleReason)
                .map { "\($0.key.rawValue): \($0.value)" }
            let line = "refresh \(Date()) → \(menuBarTitle)\n  błędy: \(errors)  nieświeże: \(stale)\n"
                + "  pasek: \(fit.diagnostics(title: menuBarTitle))\n"
                + (ProcessInfo.processInfo.environment["AILIMITS_TRACE"] == "2"
                   ? fit.windowDump() + "\n" : "")
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

    // MARK: - OpenRouter

    /// Zapisuje management key, pobiera listę kluczy i koszty.
    func saveOpenRouterKey(_ key: String) throws {
        try OpenRouterKey.save(key)
        openRouterKeyConfigured = true
        openRouterError = nil
        Task { await refreshOpenRouterKeys(force: true) }
        Task { await refreshOpenRouterCosts(force: true) }
    }

    /// Usuwa management key i cały stan pochodny.
    func deleteOpenRouterKey() throws {
        try OpenRouterKey.delete()
        openRouterKeyConfigured = false
        openRouterKeys = []
        openRouterSelectedHash = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedHashKey)
        openRouterActivity = []
        openRouterLastFetch = nil
        openRouterError = nil
        try? FileManager.default.removeItem(at: openRouterCacheURL)
    }

    /// Użytkownik wybrał, który klucz z listy to Harness.
    func selectOpenRouterKey(hash: String) {
        openRouterSelectedHash = hash
        UserDefaults.standard.set(hash, forKey: Self.selectedHashKey)
        Task { await refreshOpenRouterCosts(force: true) }
    }

    /// Pobiera listę kluczy API z OpenRoutera — przy okazji `usageDaily`,
    /// jedyne źródło "ile dziś" (patrz `openRouterTodayUsage`).
    /// Historia (/activity) rzadko, TTL 6h; `usage_daily` na kluczu w rytmie
    /// okien limitu, żeby „dziś” nie stało w miejscu przez pół dnia pracy.
    /// Jedno zadanie naraz — jeśli poprzednie stoi na oknie Keychaina, kolejne
    /// tiknięcie zegara ma je zostawić w spokoju, a nie dokładać drugie.
    private func startOpenRouterRefresh(force: Bool) {
        guard openRouterTask == nil else { return }
        guard force || openRouterKeysShouldRefresh || openRouterShouldRefresh else { return }
        openRouterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.openRouterTask = nil }
            if force || self.openRouterKeysShouldRefresh {
                await self.refreshOpenRouterKeys(force: force)
            }
            if force || self.openRouterShouldRefresh {
                await self.refreshOpenRouterCosts(force: force)
            }
            self.rebuildTitle()
        }
    }

    func refreshOpenRouterKeys(force: Bool = false) async {
        guard openRouterKeyConfigured else { return }
        guard force || openRouterKeysShouldRefresh else { return }
        guard let key = await OpenRouterKey.readOffMain() else {
            openRouterKeyConfigured = false
            openRouterError = "klucz nie znaleziony w Keychainie"
            return
        }
        do {
            let keys = try await OpenRouterAPI.fetchKeys(managementKey: key)
            openRouterKeys = keys
            openRouterKeysLastFetch = Date()
            openRouterError = nil
            // `usage_daily` just arrived (or changed) — the bar shouldn't
            // wait for the next periodic tick to show it.
            rebuildTitle()
        } catch {
            openRouterError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Pobiera koszty z /activity dla wybranego klucza.
    ///
    /// Brak klucza albo brak wyboru który to Harness nie jest błędem — to
    /// funkcja opcjonalna, którą użytkownik jeszcze nie skonfigurował. Czerwony
    /// `openRouterError` jest zarezerwowany dla prawdziwej awarii (odrzucony
    /// klucz, sieć); "jeszcze nieskonfigurowane" ma zostać ciche, zgodnie z tym,
    /// jak tabela modeli traktuje ten sam stan (myślnik, nie komunikat).
    func refreshOpenRouterCosts(force: Bool = false) async {
        guard openRouterKeyConfigured, let hash = openRouterSelectedHash else { return }
        guard let key = await OpenRouterKey.readOffMain() else {
            openRouterKeyConfigured = false
            openRouterError = "klucz nie znaleziony w Keychainie"
            return
        }
        guard force || openRouterShouldRefresh else { return }

        do {
            let rows = try await OpenRouterAPI.fetchActivity(managementKey: key, apiKeyHash: hash)
            openRouterActivity = rows
            openRouterLastFetch = Date()
            openRouterError = nil
            saveCachedOpenRouterActivity()
        } catch {
            openRouterError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Koszty per model dla okresu od `since` — to, co pokazuje tabela modeli.
    func openRouterCosts(since: Date?) -> [String: Double] {
        OpenRouterAPI.costs(rows: openRouterActivity, since: since)
    }

    /// Dopasowuje model z bazy i zwraca realny koszt z OpenRoutera (USD)
    /// dla okresu od `since`. nil = brak dopasowania albo brak danych.
    func costForModel(_ dbModel: String?, since: Date? = nil) -> Double? {
        guard let dbModel else { return nil }
        let costs = costsSince(since)
        let orModel = OpenRouterAPI.openRouterModel(for: dbModel, seenModels: Set(costs.keys))
        return orModel.flatMap { costs[$0] }
    }

    /// Koszty per model od `since`, z cache po stronie modelu, żeby nie liczyć
    /// za każdym razem od zera przy każdym odświeżeniu tabeli.
    private func costsSince(_ since: Date?) -> [String: Double] {
        if let since, let cached = openRouterCostCache[since] { return cached }
        let costs = openRouterCosts(since: since)
        if let since { openRouterCostCache[since] = costs }
        return costs
    }

    private var openRouterCostCache: [Date: [String: Double]] = [:]

    // MARK: - OpenRouter cache

    private var openRouterCacheURL: URL {
        Store.dataDirectory.appendingPathComponent("openrouter-activity.json")
    }

    private func loadCachedOpenRouterCosts() {
        guard let data = try? Data(contentsOf: openRouterCacheURL),
              let rows = try? JSONDecoder().decode([OpenRouterAPI.ActivityRow].self, from: data)
        else { return }
        openRouterActivity = rows
    }

    private func saveCachedOpenRouterActivity() {
        guard let data = try? JSONEncoder().encode(openRouterActivity) else { return }
        try? FileManager.default.createDirectory(at: Store.dataDirectory,
                                                  withIntermediateDirectories: true)
        try? data.write(to: openRouterCacheURL, options: .atomic)
    }

    /// The one funnel for the menu bar line — every toggle, every refresh and
    /// every screen change lands here, so nothing can set the title behind the
    /// fitter's back.
    /// Wszystko, z czego rysowana jest linia paska — i, gdy paska nie ma,
    /// ikona w Docku. Jedno źródło, żeby obie nigdy nie mówiły czego innego.
    private func menuBarInputs() -> MenuBarTitle.Inputs {
        var todayUsage: [AppKind: Double] = [:]
        if let today = openRouterTodayUsage { todayUsage[.dsh] = today }
        return MenuBarTitle.Inputs(snapshots: snapshots, totals: windowTotals,
                                   forecasts: forecasts, todayUsage: todayUsage)
    }

    private func rebuildTitle() {
        let inputs = menuBarInputs()
        let style = MenuBarTitle.Style(show5h: show5hInBar, show7d: show7dInBar,
                                       showForecast: showForecastInBar,
                                       showTokens: showTokensInBar,
                                       apps: AppKind.allCases.filter(visibleApps.contains))
        defer { updateDock() }
        guard autoShortenInBar else {
            menuBarTitle = MenuBarTitle.render(inputs, style: style)
            return
        }
        let variants = MenuBarTitle.variants(inputs, style: style)
        menuBarTitle = fit.fit(variants) { [weak self] title in self?.menuBarTitle = title }
    }

    /// Pokazuje albo chowa ikonę w Docku. Aplikacja startuje jako `LSUIElement`
    /// (bez Docka i bez ⌘-Tab) i taka zostaje — polityka aktywacji zmienia się
    /// tylko na czas, gdy pasek menu nie rysuje nic, bo wtedy bez ikony nie ma
    /// żadnego sposobu, żeby otworzyć panel.
    private func updateDock() {
        guard let app = NSApp else { return }
        guard dockFallback, barIsHidden else {
            if app.activationPolicy() != .accessory {
                app.setActivationPolicy(.accessory)
                app.applicationIconImage = nil
                dockLabel = nil
            }
            return
        }
        // Najpierw polityka, potem ikona: przy przejściu na `.regular` Dock
        // bierze ikonę z pakietu (a pakiet jej nie ma — wychodzi biała
        // kartka), więc podmiana musi nastąpić po tej zmianie, nie przed.
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
            dockLabel = nil
        }
        let headline = MenuBarTitle.headline(menuBarInputs(),
                                             apps: AppKind.allCases.filter(visibleApps.contains))
        let label = "\(headline?.name ?? "—")|\(headline?.percent ?? "—")|\(headline?.alarmed ?? false)"
        guard label != dockLabel else { return }
        app.applicationIconImage = DockIcon.image(name: headline?.name,
                                                  percent: headline?.percent,
                                                  alarmed: headline?.alarmed ?? false)
        dockLabel = label
    }
}
