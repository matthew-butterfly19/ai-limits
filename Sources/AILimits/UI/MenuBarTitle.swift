import Foundation

/// What the menu bar line leads with.
enum TitleMode: String, CaseIterable, Identifiable {
    /// Will the limit last? — the projection at reset time.
    case forecast
    /// How much has been consumed — the two token numbers.
    case tokens
    /// Both, at the cost of the longest line.
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forecast: return "Prognoza"
        case .tokens:   return "Tokeny"
        case .both:     return "Oba"
        }
    }
}

/// Renders the menu bar line.
///
///     ClaudeCode 48%→2h01m ≈62% · 68%→3d4h ≈81%  ┃  Codex 64%→2h00m ⚠1h12m
///
/// A window the vendor did not report is omitted entirely — never rendered as
/// a dash.
enum MenuBarTitle {
    static func render(snapshots: [AppKind: LimitsSnapshot],
                       totals: [AppKind: TokenTotals],
                       forecasts: [AppKind: [Forecast]] = [:],
                       mode: TitleMode = .forecast,
                       now: Date = Date()) -> String {
        let segments = AppKind.allCases.compactMap { app -> String? in
            segment(app: app, snapshot: snapshots[app], totals: totals[app],
                    forecasts: forecasts[app] ?? [], mode: mode, now: now)
        }
        return segments.isEmpty ? "AI limits …" : segments.joined(separator: "  ┃  ")
    }

    private static func segment(app: AppKind,
                                snapshot: LimitsSnapshot?,
                                totals: TokenTotals?,
                                forecasts: [Forecast],
                                mode: TitleMode,
                                now: Date) -> String? {
        var parts: [String] = []
        if mode != .forecast, let totals, totals.total > 0 {
            parts.append("\(Format.tokens(totals.total))/\(Format.tokens(totals.billable))")
        }
        for window in (snapshot?.windows ?? []).sorted(by: { $0.minutes < $1.minutes }) {
            var cell = "\(Format.percent(window.pct))→\(Format.timeLeft(window.timeLeft(now: now)))"
            if mode != .tokens, let forecast = forecasts.first(where: { $0.minutes == window.minutes }) {
                cell += outlook(forecast, now: now)
            }
            parts.append(cell)
        }
        guard !parts.isEmpty else { return nil }
        let stale = snapshot?.isStale == true ? " ⚠" : ""
        return "\(app.display) \(parts.joined(separator: " · "))\(stale)"
    }

    /// The projection, or — when the window runs out first — how long that takes.
    /// Silent when there is nothing measured to project from.
    private static func outlook(_ forecast: Forecast, now: Date) -> String {
        switch forecast.verdict {
        case .unknown:
            return ""
        case .short:
            guard let exhausted = forecast.exhaustedAt else { return " ⚠" }
            return " ⚠\(Format.timeLeft(exhausted.timeIntervalSince(now)))"
        case .comfortable, .tight:
            guard let projected = forecast.projectedEndPct else { return "" }
            return " ≈\(Int(projected.rounded()))%"
        }
    }
}
