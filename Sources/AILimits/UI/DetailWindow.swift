import SwiftUI
import Charts

enum Period: String, CaseIterable, Identifiable {
    case window = "Okno 5h"
    case day = "24 h"
    case week = "7 dni"
    case all = "Wszystko"

    var id: String { rawValue }

    @MainActor func start(model: AppModel, now: Date = Date()) -> Date? {
        switch self {
        case .window: return model.earliestWindowStart(now: now)
        case .day:    return now.addingTimeInterval(-24 * 3_600)
        case .week:   return now.addingTimeInterval(-7 * 86_400)
        case .all:    return nil
        }
    }
}

struct DetailWindow: View {
    static let identifier = "ailimits-detail"

    @EnvironmentObject private var model: AppModel
    @State private var period: Period = .day
    @State private var rows: [StatsEngine.ThreadRow] = []
    @State private var hours: [HourBucket] = []
    @State private var limits: [LimitSample] = []
    @State private var projects: [StatsEngine.ProjectShare] = []
    @State private var models: [ModelEfficiency] = []
    @State private var tokensPerPercent: [AppKind: Double] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hourlyChart
                    limitChart
                    modelTable
                    projectList
                    threadTable
                }
                .padding(18)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task(id: period) { await reload() }
        .task(id: model.lastRefresh) { await reload() }
    }

    private var header: some View {
        HStack {
            Text("Zużycie tokenów").font(.system(size: 16, weight: .semibold))
            Spacer()
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - charts

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tokeny w godzinach (czas lokalny)").font(.system(size: 14, weight: .semibold))
            Chart(hours, id: \.hourStart) { bucket in
                BarMark(
                    x: .value("Godzina", bucket.hourStart, unit: .hour),
                    y: .value("Tokeny", bucket.totals.total))
                .foregroundStyle(by: .value("Aplikacja", bucket.app.display))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(appScale)
            .chartYAxis { AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(Format.tokens(count)) }
                }
            } }
            .frame(height: 190)
        }
    }

    private var limitChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wykorzystanie limitów").font(.system(size: 14, weight: .semibold))
            Chart {
                ForEach(limitSeries, id: \.key) { series in
                    ForEach(series.points, id: \.ts) { point in
                        LineMark(x: .value("Czas", point.ts),
                                 y: .value("Procent", point.pct),
                                 series: .value("Seria", series.key))
                        .foregroundStyle(by: .value("Aplikacja", series.app.display))
                        .lineStyle(StrokeStyle(lineWidth: 2,
                                               dash: series.minutes >= 10_080 ? [4, 3] : []))
                    }
                }
            }
            .chartForegroundStyleScale(appScale)
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
            } }
            .frame(height: 190)
            Text("linia ciągła — okno 5 h, przerywana — okno tygodniowe")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var appScale: KeyValuePairs<String, Color> {
        [AppKind.claude.display: Palette.color(for: .claude),
         AppKind.codex.display: Palette.color(for: .codex)]
    }

    /// One line per (app, window). A gap longer than 30 minutes breaks the line
    /// instead of interpolating across a period when nothing was sampled.
    private struct Series {
        var key: String
        var app: AppKind
        var minutes: Int
        var points: [LimitSample]
    }

    private var limitSeries: [Series] {
        var grouped: [String: [LimitSample]] = [:]
        for sample in limits {
            grouped["\(sample.app.rawValue)|\(sample.windowMinutes)", default: []].append(sample)
        }
        var series: [Series] = []
        for (key, samples) in grouped.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "|")
            guard let app = AppKind(rawValue: String(parts[0])),
                  let minutes = Int(parts[1]) else { continue }
            var segment: [LimitSample] = []
            var index = 0
            for sample in samples.sorted(by: { $0.ts < $1.ts }) {
                if let last = segment.last, sample.ts.timeIntervalSince(last.ts) > 1_800 {
                    series.append(Series(key: "\(key)#\(index)", app: app,
                                         minutes: minutes, points: segment))
                    index += 1
                    segment = []
                }
                segment.append(sample)
            }
            if !segment.isEmpty {
                series.append(Series(key: "\(key)#\(index)", app: app,
                                     minutes: minutes, points: segment))
            }
        }
        return series
    }

    /// The "which model is worth using" table.
    ///
    /// Everything here is measured, nothing is priced: on a subscription the
    /// cost is limit percent, and only some windows are metered per model.
    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Modele — co za co").font(.system(size: 14, weight: .semibold))
                Spacer()
                ForEach(AppKind.allCases, id: \.self) { app in
                    if let perPercent = tokensPerPercent[app] {
                        Text("\(app.display): 1% ≈ \(Format.tokens(Int(perPercent)))")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }
            HStack(spacing: 0) {
                head("model", 150, .leading)
                head("tokeny", 70)
                head("wyjście", 70)
                head("wyjście/turę", 80)
                head("cache", 55)
                head("myślenie", 65)
                head("tury", 55)
                head("% limitu / Mtok", 100)
            }
            ForEach(models.prefix(14)) { row in
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(model.modelColors.color(for: row.model))
                            .frame(width: 8, height: 8)
                        Text(Format.model(row.model)).font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(width: 150, alignment: .leading)
                    cell(Format.tokens(row.totals.total))
                    cell(Format.tokens(row.totals.output))
                    cell(row.outputPerTurn.map { Format.tokens(Int($0)) } ?? "—", width: 80)
                    cell(share(row.cacheHitRate), width: 55)
                    cell(share(row.reasoningShare), width: 65)
                    cell("\(row.totals.events)", width: 55)
                    cell(row.limitPerMillion.map { Format.decimal($0, places: 2) } ?? "—", width: 100)
                }
                .help(tooltip(for: row))
            }
            Text("Kolumna „% limitu / Mtok” wypełnia się tylko dla modeli, którym dostawca "
                 + "liczy osobne okno — u reszty nie da się tego zmierzyć, "
                 + "a zgadywać nie będziemy.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private func head(_ text: String, _ width: CGFloat,
                      _ alignment: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: width, alignment: alignment)
    }

    private func cell(_ text: String, width: CGFloat = 70) -> some View {
        Text(text)
            .font(.system(size: 12)).monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }

    private func share(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func tooltip(for row: ModelEfficiency) -> String {
        var lines = ["\(row.model ?? "—") · \(row.app.display)",
                     "łącznie \(Format.tokensFull(row.totals.total)), "
                     + "bez cache \(Format.tokensFull(row.totals.billable))"]
        if let cost = row.limitPerMillion {
            lines.append("\(Format.decimal(cost, places: 2)) % okna tygodniowego na milion "
                         + "tokenów (z \(row.limitSamples) odczytów)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - tables

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Udział projektów").font(.system(size: 14, weight: .semibold))
            ForEach(projects.prefix(8)) { share in
                BarRow(title: share.project,
                       subtitle: share.app.display,
                       value: share.tokens,
                       fraction: share.share,
                       color: Palette.color(for: share.app))
            }
        }
    }

    private var threadTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wątki i modele").font(.system(size: 14, weight: .semibold))
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded.contains(row.id) { expanded.remove(row.id) }
                        else { expanded.insert(row.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded.contains(row.id)
                                  ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Circle().fill(Palette.color(for: row.thread.app))
                                .frame(width: 7, height: 7)
                            Text(row.thread.displayTitle).lineLimit(1).font(.system(size: 12))
                            if let project = row.thread.project { Chip(text: project) }
                            Spacer()
                            Text(Format.tokens(row.thread.totals.total))
                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Text(Format.tokens(row.thread.totals.billable))
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(Palette.muted)
                                .frame(width: 54, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded.contains(row.id) { detail(for: row) }
                }
                Divider().opacity(0.4)
            }
        }
    }

    private func detail(for row: StatsEngine.ThreadRow) -> some View {
        let totals = row.thread.totals
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 18) {
                stat("input", Format.tokensFull(totals.input))
                stat("output", Format.tokensFull(totals.output))
                stat("cache read", Format.tokensFull(totals.cacheRead))
                stat("cache write", Format.tokensFull(totals.cacheWrite))
            }
            HStack(spacing: 18) {
                stat("myślenie", Format.tokensFull(totals.reasoning))
                stat("trafienia cache", totals.cacheHitRate.map {
                    "\(Int(($0 * 100).rounded()))%"
                } ?? "—")
                stat("tury", "\(totals.events)")
                stat("subagenci", Format.tokens(row.thread.subagentTokens))
                stat("aktywny", "\(Format.when(row.thread.firstTS)) – \(Format.when(row.thread.lastTS))")
            }
            ForEach(row.models) { entry in
                HStack(spacing: 6) {
                    Text(Format.model(entry.model)).font(.system(size: 12))
                        .frame(width: 140, alignment: .leading)
                    Text(Format.tokensFull(entry.totals.total))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.leading, 22)
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
    }

    // MARK: - loading

    private func reload() async {
        guard let stats = model.statsEngine else { return }
        let since = period.start(model: model)
        rows = (try? stats.threadRows(since: since, limit: 40)) ?? []
        projects = (try? stats.projectShares(since: since)) ?? []
        hours = (try? stats.hourly(hours: period == .week ? 168 : 24)) ?? []
        models = (try? stats.modelEfficiency(since: since)) ?? []
        var perPercent: [AppKind: Double] = [:]
        for app in AppKind.allCases {
            perPercent[app] = (try? stats.forecast(app: app, snapshot: model.snapshots[app],
                                                   minutes: 300))??.tokensPerPercent
        }
        tokensPerPercent = perPercent
        limits = (try? model.store?.limitHistory(
            since: since ?? Date().addingTimeInterval(-7 * 86_400))) ?? []
    }
}
