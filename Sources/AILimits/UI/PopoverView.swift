import SwiftUI

/// The panel behind the menu bar item.
///
/// Deliberately short. An earlier version stacked six type sizes down to 8 pt
/// and nobody could scan it; everything that is reference material rather than
/// a decision now lives in the detail window. Nothing here is below 11 pt.
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fatal = model.fatalError {
                Label(fatal, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.critical)
                    .padding(16)
            }

            ForEach(Array(AppKind.allCases.enumerated()), id: \.element) { index, app in
                if index > 0 { Divider() }
                AppSection(app: app)
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .background(Palette.surface)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            }
            Text(model.lastRefresh.map { "odświeżono \($0, formatter: Format.clockFormatter)" } ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            Spacer()
            Menu {
                Picker("W pasku menu", selection: $model.titleMode) {
                    ForEach(TitleMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("Co pokazywać w pasku menu")

            Button("Szczegóły…") { openWindow(id: DetailWindow.identifier) }
                .font(.system(size: 12))
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Odśwież teraz")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Zakończ AI Limits")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One app: limits with a verdict, then what ate them.
struct AppSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let app: AppKind

    private var snapshot: LimitsSnapshot? { model.snapshots[app] }
    private var threads: [StatsEngine.ThreadRow] {
        model.threads.filter { $0.thread.app == app && $0.thread.totals.total > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error = model.errors[app] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.serious)
            }
            windows
            if !threads.isEmpty { threadList }
            weekLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.color(for: app)).frame(width: 9, height: 9)
            Text(app.display).font(.system(size: 14, weight: .semibold))
            if let plan = snapshot?.planName { Chip(text: plan) }
            Spacer()
            // An unlabelled icon says nothing. If the numbers are old, say so
            // and say how old.
            if snapshot?.isStale == true, let takenAt = snapshot?.takenAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                    Text("sprzed \(Format.timeLeft(-takenAt.timeIntervalSinceNow))")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.warning)
                .help("""
                      Te liczby pochodzą z ostatniego udanego odczytu \
                      (\(Format.when(takenAt))), bo bieżący się nie powiódł.
                      \(snapshot?.staleReason ?? "")
                      Czas do resetu i tak leci dalej — liczy się z godziny resetu, \
                      nie z zapamiętanego odliczania.
                      """)
            }
        }
    }

    @ViewBuilder private var windows: some View {
        let sorted = (snapshot?.windows ?? []).sorted { $0.minutes < $1.minutes }
        if sorted.isEmpty {
            Text("brak danych o limitach").font(.system(size: 12)).foregroundStyle(Palette.muted)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sorted) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(Format.windowName(window.minutes))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 26, alignment: .leading)
                            Text(Format.percent(window.pct))
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                            MeterBar(percent: window.pct, height: 10)
                            Text(Format.timeLeft(window.timeLeft()))
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(Palette.muted)
                                .frame(width: 58, alignment: .trailing)
                        }
                        if let forecast = model.forecasts[app]?.first(where: { $0.minutes == window.minutes }) {
                            ForecastLine(forecast: forecast).padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    /// The thread list is denominated in percent of the limit, not tokens:
    /// percent is what the user is actually spending.
    private var threadList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Na co poszło to okno")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if let totals = model.windowTotals[app], totals.total > 0 {
                    Text(Format.tokens(totals.total))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .help("\(Format.tokensFull(totals.total)) tokenów łącznie, "
                              + "\(Format.tokensFull(totals.billable)) bez odczytów z cache")
                }
            }
            ForEach(threads.prefix(4)) { row in
                ThreadLine(row: row)
            }
            if threads.count > 4 {
                Button("jeszcze \(threads.count - 4) — pokaż wszystkie") {
                    openWindow(id: DetailWindow.identifier)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    @ViewBuilder private var weekLine: some View {
        if let week = model.weekOverWeek[app], let change = week.change {
            HStack(spacing: 6) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(change >= 0 ? Palette.serious : Palette.good)
                Text("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))% wobec tego samego "
                     + "momentu tydzień temu")
                    .font(.system(size: 12))
                Spacer()
                Text("\(Format.tokens(week.current)) / \(Format.tokens(week.previous))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            .help(weekTooltip(week))
        }
    }

    private func weekTooltip(_ week: StatsEngine.WeekOverWeek) -> String {
        var lines = ["Od otwarcia okna tygodniowego minęło "
                     + "\(Format.timeLeft(week.elapsed)) — porównanie obejmuje "
                     + "dokładnie tyle samo czasu tydzień wcześniej.",
                     "Teraz \(Format.tokensFull(week.current)), "
                     + "tydzień temu \(Format.tokensFull(week.previous))."]
        if let percent = week.previousPercent {
            lines.append("Tamten tydzień to byłoby ≈\(Int(percent.rounded()))% limitu przy "
                         + "dzisiejszym przeliczniku tokenów na procent — szacunek, bo próbek "
                         + "limitu sprzed tygodnia jeszcze nie ma.")
        }
        return lines.joined(separator: "\n")
    }
}

/// One thread, priced in percent of the limit window.
struct ThreadLine: View {
    var row: StatsEngine.ThreadRow

    var body: some View {
        HStack(spacing: 10) {
            // No proportional bar here: sitting directly under the title it
            // read as a link underline, and the percentage beside it already
            // carries the magnitude.
            Text(row.thread.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let percent = row.limitPercent {
                Text(percent >= 1 ? "\(Int(percent.rounded()))%"
                                  : "\(Format.decimal(percent))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            Text(Format.tokens(row.thread.totals.total))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(width: 48, alignment: .trailing)
        }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [row.thread.displayTitle]
        if let project = row.thread.project { lines.append("projekt: \(project)") }
        if let percent = row.limitPercent {
            lines.append("≈\(Format.decimal(percent)) % okna 5 h")
            lines.append("To udział wątku w tokenach okna przeliczony na procenty limitu. "
                         + "Zakłada, że token kosztuje tyle samo niezależnie od modelu — "
                         + "suma po wątkach zgadza się co do procenta, ale podział między nie "
                         + "przesuwa się, jeśli wątki korzystały z różnych modeli. "
                         + "Dostawcy nie podają wag per model.")
        }
        lines.append("\(Format.tokensFull(row.thread.totals.total)) tokenów, "
                     + "\(row.thread.totals.events) tur")
        if let top = row.models.first?.model { lines.append("głównie \(Format.model(top))") }
        if row.thread.subagentTokens > 0 {
            lines.append("w tym subagenci: \(Format.tokens(row.thread.subagentTokens))")
        }
        return lines.joined(separator: "\n")
    }
}
