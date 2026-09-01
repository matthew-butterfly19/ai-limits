import AppKit
import Foundation

/// Entry point. With no arguments the menu bar app starts; with `--…` the
/// binary behaves as a command line tool, which is what makes the collector
/// testable without launching a UI.
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first?.hasPrefix("--") == true {
            exit(CommandLineTool.run(arguments))
        }
        AILimitsApp.main()
    }
}

enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        var options: [String: String] = [:]
        var command = ""
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                let next = index + 1 < arguments.count ? arguments[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    options[key] = next
                    index += 1
                } else {
                    options[key] = ""
                }
                if command.isEmpty { command = key }
            }
            index += 1
        }

        do {
            let store = try Store(path: options["db"].flatMap { $0.isEmpty ? nil : $0 }
                                  ?? Store.defaultPath)
            switch command {
            case "ingest":  try ingest(store)
            case "backfill":
                try store.resetCursors()
                print("kursory wyzerowane — pełne przejście po logach")
                try ingest(store)
                try compactionsReport(store)
            case "compactions": try compactionsReport(store)
            case "totals":  try totals(store, since: options["since"])
            case "threads": try threads(store, since: options["since"])
            case "models":  try modelsReport(store, since: options["since"])
            case "check":   try check(store)
            case "limits":  try limits(store)
            case "menubar": try menuBar(store)
            case "help":    usage()
            default:
                FileHandle.standardError.write(Data("nieznane polecenie: --\(command)\n".utf8))
                usage()
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("błąd: \(error)\n".utf8))
            return 1
        }
    }

    private static func usage() {
        print("""
        AILimits — kolektor statystyk Claude Code, Codeksa i DeepSeek Harness

          --ingest  [--db PATH]              wczytaj nowe linie logów
          --totals  [--db PATH] [--since ISO] sumy tokenów per aplikacja
          --threads [--db PATH] [--since ISO] najcięższe wątki
          --models  [--db PATH] [--since ISO] co który model daje za co zużywa
          --limits                            odczytaj limity na żywo
          --menubar                           drabina skrótów linii paska menu
          --check   [--db PATH]               co widzi okno szczegółów (diagnostyka)
          --compactions [--db PATH]           kompakty kontekstu i ich szacowany koszt
          --backfill    [--db PATH]           wyzeruj kursory i przejdź logi od nowa
        """)
    }

    private static func ingest(_ store: Store) throws {
        var previous = Date()
        for (label, run) in [("claude", { try ClaudeIngest(store: store).run() }),
                             ("codex ", { try CodexIngest(store: store).run() }),
                             ("dsh   ", { try DshIngest(store: store).run() })] {
            let files = try run()
            let now = Date()
            print(String(format: "%@: %d plików w %.1fs", label, files, now.timeIntervalSince(previous)))
            previous = now
        }
        if !Zstd.isAvailable {
            print("dsh: libzstd nie znaleziony — pomijam (brew install zstd)")
        }
    }

    private static func parseSince(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let days = Double(text) { return Date().addingTimeInterval(-days * 86_400) }
        return Timestamps.parse(text)
    }

    private static func totals(_ store: Store, since: String?) throws {
        let result = try store.totals(since: parseSince(since))
        for app in AppKind.allCases {
            guard let totals = result[app] else { continue }
            print("""
            \(app.display)
              total       \(Format.tokensFull(totals.total))
              bez cache   \(Format.tokensFull(totals.billable))
              input       \(Format.tokensFull(totals.input))
              output      \(Format.tokensFull(totals.output))
              cache read  \(Format.tokensFull(totals.cacheRead))
              cache write \(Format.tokensFull(totals.cacheWrite))
              reasoning   \(Format.tokensFull(totals.reasoning))
              zdarzenia   \(totals.events) w \(totals.sessions) wątkach
            """)
        }
    }

    private static func threads(_ store: Store, since: String?) throws {
        for thread in try store.threads(since: parseSince(since), limit: 20) {
            print(String(format: "%-11@ %8@  %-22@ %@",
                         thread.app.display as NSString,
                         Format.tokens(thread.totals.total) as NSString,
                         Format.project(thread.cwd) as NSString,
                         String(thread.displayTitle.prefix(70)) as NSString))
        }
    }

    /// Prints what each section of the detail window would receive. Faster
    /// than guessing from a screenshot why a chart came out blank.
    private static func check(_ store: Store) throws {
        let stats = StatsEngine(store: store)
        let day = Date().addingTimeInterval(-24 * 3_600)
        let week = Date().addingTimeInterval(-7 * 86_400)
        func line(_ label: String, _ count: Int) {
            print("  \(count == 0 ? "PUSTE" : "  ok "). \(label): \(count)")
        }
        line("hourly(24 h) — kubełki", (try? stats.hourly(hours: 24).count) ?? -1)
        line("hourly(168 h) — kubełki", (try? stats.hourly(hours: 168).count) ?? -1)
        line("weekComparison — dni", (try? stats.weekComparison().count) ?? -1)
        line("limitHistory(7 dni) — próbki", (try? store.limitHistory(since: week).count) ?? -1)
        line("modelEfficiency(7 dni) — wiersze", (try? stats.modelEfficiency(since: week).count) ?? -1)
        line("projectShares(24 h) — wiersze", (try? stats.projectShares(since: day).count) ?? -1)
        line("threadRows(24 h) — wiersze", (try? stats.threadRows(since: day, limit: 40).count) ?? -1)
    }

    private static func modelsReport(_ store: Store, since: String?) throws {
        let stats = StatsEngine(store: store)
        let rows = try stats.modelEfficiency(since: parseSince(since))
        func pad(_ text: String, _ width: Int, right: Bool = true) -> String {
            let missing = max(0, width - text.count)
            let filler = String(repeating: " ", count: missing)
            return right ? filler + text : text + filler
        }
        func share(_ value: Double?) -> String {
            value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
        print(pad("aplikacja", 11, right: false) + pad("model", 16, right: false)
              + pad("tokeny", 9) + pad("wyjście", 9) + pad("wyj/turę", 10)
              + pad("cache", 7) + pad("myślenie", 10) + pad("tury", 7)
              + pad("%/Mtok", 9))
        for row in rows.prefix(20) where row.totals.total > 0 {
            print(pad(row.app.display, 11, right: false)
                  + pad(Format.model(row.model), 16, right: false)
                  + pad(Format.tokens(row.totals.total), 9)
                  + pad(Format.tokens(row.totals.output), 9)
                  + pad(row.outputPerTurn.map { Format.tokens(Int($0)) } ?? "—", 10)
                  + pad(share(row.cacheHitRate), 7)
                  + pad(share(row.reasoningShare), 10)
                  + pad("\(row.totals.events)", 7)
                  + pad(row.limitPerMillion.map { Format.decimal($0, places: 2) } ?? "—", 9))
        }
    }

    private static func compactionsReport(_ store: Store) throws {
        let rows = try store.compactions()
        guard !rows.isEmpty else { print("brak zarejestrowanych kompaktów"); return }
        for app in AppKind.allCases {
            let mine = rows.filter { $0.app == app }
            guard !mine.isEmpty else { continue }
            let pre = mine.reduce(0) { $0 + $1.preTokens }
            print("\(app.display): \(mine.count) kompaktów, "
                  + "~\(Format.tokensFull(pre)) tokenów kontekstu przepuszczonego "
                  + "(nie ma tego w usage_events)")
            for row in mine.prefix(5) {
                print("  \(Format.when(row.ts))  \(row.trigger ?? "—")  "
                      + "\(Format.tokens(row.preTokens)) → \(Format.tokens(row.postTokens))")
            }
        }
    }

    /// Everything the menu bar line is rendered from, gathered the same way
    /// the app gathers it — so the diagnostics show the real line, not an
    /// approximation of it.
    private static func inputs(store: Store,
                               snapshots: [AppKind: LimitsSnapshot]) -> MenuBarTitle.Inputs {
        let stats = StatsEngine(store: store)
        var forecasts: [AppKind: [Forecast]] = [:]
        for app in AppKind.allCases {
            forecasts[app] = (try? stats.forecasts(app: app, snapshot: snapshots[app])) ?? []
        }
        let totals = (try? store.totals(since: Date().addingTimeInterval(-5 * 3_600))) ?? [:]
        return MenuBarTitle.Inputs(snapshots: snapshots, totals: totals, forecasts: forecasts)
    }

    /// Prints the whole ladder with the width of every rung, the way
    /// `MenuBarFit` sees it. Answers "why is the bar showing the short line"
    /// without guessing from a screenshot — the same job `--check` does for
    /// the detail window.
    ///
    /// Run from a terminal there is no status item to measure, so the slot and
    /// the budget stay unknown; the widths and the notch are real. For the live
    /// numbers run the app itself with `AILIMITS_TRACE=1`.
    private static func menuBar(_ store: Store) throws {
        // The limits fetch has to finish before anything can be measured, and
        // the measuring itself is main-actor work — so the wait happens first
        // and the printing after it, never inside the task. A `MainActor.run`
        // in there would deadlock against this very semaphore.
        let collected = Box<[String]>([])
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await RefreshCoordinator(store: store).run()
            let readings = inputs(store: store, snapshots: result.snapshots)
            collected.value = MenuBarTitle.variants(readings, style: MenuBarDefaults.style())
            semaphore.signal()
        }
        semaphore.wait()

        MainActor.assumeIsolated {
            let fit = MenuBarFit()
            print(fit.diagnostics())
            if let screen = NSScreen.main {
                print(String(format: "ekran %.0f pt, po prawej od notcha: %@",
                             screen.frame.width,
                             screen.auxiliaryTopRightArea.map {
                                 String(format: "%.0f…%.0f pt", $0.minX, $0.maxX)
                             } ?? "brak notcha — lewej krawędzi nie da się zmierzyć"))
            }
            let budget = fit.budget()
            for (index, variant) in collected.value.enumerated() {
                let width = fit.width(of: variant)
                let fits = budget.map { width <= $0 ? "✓" : "✗" } ?? " "
                print(String(format: "%@ %d  %4.0f pt  %@", fits, index, width, variant))
            }
        }
    }

    /// Carries a value out of a detached task to the thread waiting on it.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private static func limits(_ store: Store) throws {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await RefreshCoordinator(store: store).run()
            for app in AppKind.allCases {
                if let snapshot = result.snapshots[app] {
                    let plan = snapshot.planName.map { " (\($0))" } ?? ""
                    let stale = snapshot.isStale ? "  ⚠ \(snapshot.staleReason ?? "")" : ""
                    print("\(app.display)\(plan)\(stale)")
                    for window in snapshot.windows {
                        print("  \(Format.windowName(window.minutes))  "
                              + "\(Format.percent(window.pct))  →  "
                              + "\(Format.timeLeft(window.timeLeft()))")
                    }
                    for scoped in snapshot.scoped {
                        print("  \(Format.windowName(scoped.window.minutes)) \(scoped.label)  "
                              + "\(Format.percent(scoped.window.pct))")
                    }
                }
                if let error = result.errors[app] { print("\(app.display): \(error)") }
            }
            print("")
            print(MenuBarTitle.render(inputs(store: store, snapshots: result.snapshots)))
            semaphore.signal()
        }
        semaphore.wait()
    }
}
