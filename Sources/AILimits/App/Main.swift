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
            case "limits":  try limits(store)
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
        AILimits — kolektor statystyk Claude Code i Codeksa

          --ingest  [--db PATH]              wczytaj nowe linie logów
          --totals  [--db PATH] [--since ISO] sumy tokenów per aplikacja
          --threads [--db PATH] [--since ISO] najcięższe wątki
          --limits                            odczytaj limity na żywo
          --compactions [--db PATH]           kompakty kontekstu i ich szacowany koszt
          --backfill    [--db PATH]           wyzeruj kursory i przejdź logi od nowa
        """)
    }

    private static func ingest(_ store: Store) throws {
        let started = Date()
        let claudeFiles = try ClaudeIngest(store: store).run()
        let claudeDone = Date()
        let codexFiles = try CodexIngest(store: store).run()
        let finished = Date()
        print(String(format: "claude: %d plików w %.1fs", claudeFiles,
                     claudeDone.timeIntervalSince(started)))
        print(String(format: "codex:  %d plików w %.1fs", codexFiles,
                     finished.timeIntervalSince(claudeDone)))
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
            print(MenuBarTitle.render(snapshots: result.snapshots,
                                      totals: (try? store.totals(since: Date().addingTimeInterval(-5 * 3600))) ?? [:]))
            semaphore.signal()
        }
        semaphore.wait()
    }
}
