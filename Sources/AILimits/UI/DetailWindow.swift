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
    @State private var weekDays: [StatsEngine.DayComparison] = []
    @State private var tokensPerPercent: [AppKind: Double] = [:]
    @State private var expanded: Set<String> = []
    @State private var hourHover: HoverPoint?
    @State private var weekHover: HoverPoint?
    @State private var limitHover: HoverPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hourlyChart
                    weekChart
                    limitChart
                    modelTable
                    projectList
                    threadTable
                }
                .padding(18)
            }
        }
        .background(Palette.surface)
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
            Chart {
                ForEach(hours, id: \.hourStart) { bucket in
                    BarMark(
                        x: .value("Godzina", bucket.hourStart, unit: .hour),
                        y: .value("Tokeny", bucket.totals.total))
                    .foregroundStyle(by: .value("Aplikacja", bucket.app.display))
                    .cornerRadius(3)
                    .opacity(dimmed(bucket.hourStart, hover: hourHover, unit: .hour) ? 0.35 : 1)
                }
            }
            .chartForegroundStyleScale(appScale)
            .chartOverlayHover($hourHover)
            .chartTooltip(at: hourHover) { hourTooltip }
            .chartYAxis { AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(Format.tokens(count)) }
                }
            } }
            .frame(height: 190)
        }
    }

    /// Bars are this week, the tick is the same weekday a week ago.
    ///
    /// A benchmark marker rather than a second set of bars: the two week series
    /// would need their own colours, and those are already spoken for by the
    /// two apps.
    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tydzień do tygodnia").font(.system(size: 14, weight: .semibold))
            Chart {
                ForEach(weekDays) { day in
                    ForEach(AppKind.allCases, id: \.self) { app in
                        if let tokens = day.byApp[app], tokens > 0 {
                            BarMark(x: .value("Dzień", day.day, unit: .day),
                                    y: .value("Tokeny", tokens))
                            .foregroundStyle(by: .value("Aplikacja", app.display))
                            .cornerRadius(3)
                        }
                    }
                    if day.previousTotal > 0 {
                        // A flat tick across the bar, not a rule: RuleMark with
                        // both x and y collapses to a point.
                        RectangleMark(x: .value("Dzień", day.day, unit: .day),
                                      y: .value("Tydzień wcześniej", day.previousTotal),
                                      width: .ratio(0.85), height: .fixed(2))
                        .foregroundStyle(Palette.muted)
                    }
                }
            }
            .chartForegroundStyleScale(appScale)
            .chartOverlayHover($weekHover)
            .chartTooltip(at: weekHover) { weekTooltip }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(Format.weekday(date)) }
                }
            } }
            .chartYAxis { AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(Format.tokens(count)) }
                }
            } }
            .frame(height: 190)
            Text("słupki — ten tydzień, pozioma kreska — ten sam dzień tygodnia siedem dni wcześniej")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var limitChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wykorzystanie limitów").font(.system(size: 14, weight: .semibold))
            Chart {
                if let hover = limitHover {
                    RuleMark(x: .value("Czas", hover.date))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Palette.muted)
                }
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
            .chartOverlayHover($limitHover)
            .chartTooltip(at: limitHover) { limitTooltip }
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

    /// Bars away from the pointer recede rather than disappear — the shape of
    /// the whole series has to stay readable while one bar is being inspected.
    private func dimmed(_ date: Date, hover: HoverPoint?, unit: Calendar.Component) -> Bool {
        guard let hover else { return false }
        return !Calendar.current.isDate(date, equalTo: hover.date, toGranularity: unit)
    }

    @ViewBuilder private var hourTooltip: some View {
        if let hover = hourHover {
            let bucket = hours.filter {
                Calendar.current.isDate($0.hourStart, equalTo: hover.date, toGranularity: .hour)
            }
            Text(Format.dayHour(hover.date)).font(.system(size: 11, weight: .semibold))
            if bucket.isEmpty {
                Text("nic w tej godzinie").font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                ForEach(bucket, id: \.app) { row in
                    TooltipRow(color: Palette.color(for: row.app), label: row.app.display,
                               value: Format.tokensFull(row.totals.total))
                }
                TooltipRow(color: nil, label: "wyjście",
                           value: Format.tokensFull(bucket.reduce(0) { $0 + $1.totals.output }))
            }
        }
    }

    @ViewBuilder private var weekTooltip: some View {
        if let hover = weekHover,
           let day = weekDays.first(where: {
               Calendar.current.isDate($0.day, equalTo: hover.date, toGranularity: .day)
           }) {
            Text(Format.dayDate(day.day)).font(.system(size: 11, weight: .semibold))
            ForEach(AppKind.allCases, id: \.self) { app in
                if let tokens = day.byApp[app], tokens > 0 {
                    TooltipRow(color: Palette.color(for: app), label: app.display,
                               value: Format.tokensFull(tokens))
                }
            }
            Divider()
            TooltipRow(color: nil, label: "tydzień wcześniej",
                       value: day.previousTotal > 0 ? Format.tokensFull(day.previousTotal) : "—")
            if day.previousTotal > 0, day.total > 0 {
                let change = Double(day.total) / Double(day.previousTotal) - 1
                TooltipRow(color: nil, label: "zmiana",
                           value: "\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))%")
            }
        }
    }

    @ViewBuilder private var limitTooltip: some View {
        if let hover = limitHover {
            Text(Format.when(hover.date)).font(.system(size: 11, weight: .semibold))
            ForEach(nearestSamples(to: hover.date), id: \.id) { entry in
                TooltipRow(color: Palette.color(for: entry.sample.app),
                           label: "\(entry.sample.app.display) · "
                                  + "\(Format.windowName(entry.sample.windowMinutes))",
                           value: Format.percent(entry.sample.pct))
            }
        }
    }

    private struct NearestSample: Identifiable {
        var id: String
        var sample: LimitSample
    }

    /// The reading closest to the pointer for each (app, window), and only when
    /// it is close enough in time to be describing the same moment.
    private func nearestSamples(to date: Date) -> [NearestSample] {
        var best: [String: LimitSample] = [:]
        for sample in limits {
            let key = "\(sample.app.rawValue)|\(sample.windowMinutes)"
            let distance = abs(sample.ts.timeIntervalSince(date))
            guard distance < 1_800 else { continue }
            if let current = best[key], abs(current.ts.timeIntervalSince(date)) <= distance { continue }
            best[key] = sample
        }
        return best.keys.sorted().compactMap { key in
            best[key].map { NearestSample(id: key, sample: $0) }
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
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
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
        weekDays = (try? stats.weekComparison()) ?? []
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
