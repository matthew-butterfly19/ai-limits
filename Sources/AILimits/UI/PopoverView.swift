import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fatal = model.fatalError {
                Label(fatal, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.critical)
                    .padding(14)
            }

            ForEach(Array(AppKind.allCases.enumerated()), id: \.element) { index, app in
                if index > 0 { Divider().padding(.vertical, 2) }
                AppSection(app: app)
            }

            Divider()
            footer
        }
        .frame(width: 420)
        .environmentObject(model)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            }
            Text(model.lastRefresh.map { "odświeżono \(Format.when($0))" } ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
            Spacer()
            Button("Szczegóły…") { openWindow(id: DetailWindow.identifier) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Odśwież teraz")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Zakończ AI Limits")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One app's block: headline numbers, limit meters, model split, top threads.
struct AppSection: View {
    @EnvironmentObject private var model: AppModel
    let app: AppKind

    private var snapshot: LimitsSnapshot? { model.snapshots[app] }
    private var totals: TokenTotals? { model.windowTotals[app] }
    private var threads: [StatsEngine.ThreadRow] { model.threads.filter { $0.thread.app == app } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let error = model.errors[app] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.serious)
            }
            meters
            if !threads.isEmpty {
                sectionLabel("Wątki w tym oknie")
                ForEach(threads.prefix(5)) { row in
                    BarRow(title: row.thread.displayTitle,
                           subtitle: subtitle(for: row),
                           value: row.thread.totals.total,
                           fraction: row.share,
                           color: Palette.color(for: app))
                }
            }
            if let models = modelSegments(), !models.isEmpty {
                sectionLabel("Modele")
                StackedBar(segments: models)
                FlowLegend(segments: models)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Palette.color(for: app)).frame(width: 8, height: 8)
            Text(app.display).font(.system(size: 13, weight: .semibold))
            if let plan = snapshot?.planName { Chip(text: plan) }
            Spacer()
            if let totals {
                (Text(Format.tokens(totals.total)).font(.system(size: 15, weight: .semibold))
                 + Text(" / ").foregroundColor(Palette.muted)
                 + Text(Format.tokens(totals.billable)).font(.system(size: 13)))
                    .monospacedDigit()
                    .help("""
                          \(Format.tokensFull(totals.total)) tokenów łącznie
                          \(Format.tokensFull(totals.billable)) bez odczytów z cache
                          """)
            }
        }
    }

    @ViewBuilder private var meters: some View {
        let windows = (snapshot?.windows ?? []).sorted { $0.minutes < $1.minutes }
        if windows.isEmpty {
            Text("brak danych o limitach").font(.system(size: 10)).foregroundStyle(Palette.muted)
        } else {
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Format.windowName(window.minutes))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 22, alignment: .leading)
                        MeterBar(percent: window.pct)
                        Text(Format.percent(window.pct))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        Text("→ \(Format.timeLeft(window.timeLeft()))")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .frame(width: 56, alignment: .trailing)
                    }
                    if window.minutes == 300, let burn = model.burnRates[app] {
                        Text(burnText(burn))
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.muted)
                            .padding(.leading, 28)
                    }
                }
            }
            ForEach(snapshot?.scoped ?? []) { scoped in
                HStack(spacing: 6) {
                    Text(scoped.label)
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        .frame(width: 90, alignment: .leading).lineLimit(1)
                    MeterBar(percent: scoped.window.pct, height: 5)
                    Text(Format.percent(scoped.window.pct))
                        .font(.system(size: 10)).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private func burnText(_ burn: StatsEngine.BurnRate) -> String {
        let rate = String(format: "%.1f", burn.percentPerHour)
        guard let exhausted = burn.exhaustedAt else { return "≈ \(rate) %/h" }
        return "≈ \(rate) %/h · wyczerpanie ok. \(Format.when(exhausted))"
    }

    private func subtitle(for row: StatsEngine.ThreadRow) -> String? {
        var parts: [String] = []
        if let project = row.thread.project { parts.append(project) }
        if let top = row.models.first?.model { parts.append(Format.model(top)) }
        if row.thread.subagentTokens > 0 {
            parts.append("subagenci \(Format.tokens(row.thread.subagentTokens))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func modelSegments() -> [StackedBar.Segment]? {
        let rows = model.threads.filter { $0.thread.app == app }.flatMap(\.models)
        guard !rows.isEmpty else { return nil }
        var byModel: [String: Int] = [:]
        for row in rows { byModel[row.model ?? "—", default: 0] += row.totals.total }
        let colors = ModelColors(models: Array(byModel.keys))
        return byModel
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { StackedBar.Segment(id: $0.key, value: $0.value,
                                      color: colors.color(for: $0.key),
                                      label: Format.model($0.key)) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.top, 2)
    }
}

/// Legend for a stacked bar. Always present, so identity never rests on colour.
struct FlowLegend: View {
    var segments: [StackedBar.Segment]

    private var total: Int { max(segments.reduce(0) { $0 + $1.value }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(segments) { segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.label).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.tokens(segment.value))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Text("\(Int((Double(segment.value) / Double(total) * 100).rounded()))%")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }
}
