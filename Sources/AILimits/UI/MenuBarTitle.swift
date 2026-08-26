import Foundation

/// What the menu bar line leads with.
enum TitleMode: String, CaseIterable, Identifiable {
    /// The 5 h window with its projection; a longer window joins only when it
    /// is the one in trouble. Fits beside a notch.
    case compact
    /// Every window the vendor reports, each with its projection.
    case forecast
    /// Consumption instead of projection.
    case tokens
    /// Everything, at the cost of the longest line.
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:  return "Zwięźle"
        case .forecast: return "Wszystkie okna"
        case .tokens:   return "Tokeny"
        case .both:     return "Wszystko"
        }
    }

    var showsTokens: Bool { self == .tokens || self == .both }
    var showsForecast: Bool { self != .tokens }
}

/// Renders the menu bar line.
///
///     ClaudeCode 57%→1h30m ≈88%  ┃  Codex 70%→1h29m ≈86%
///
/// Two distinct markers, deliberately different glyphs: `⚠` means the window
/// runs out before it resets, `↻` means the numbers came from cache because the
/// last fetch failed. An earlier version used `⚠` for both and nobody could
/// tell which was which.
enum MenuBarTitle {
    static let staleMarker = "↻"

    static func render(snapshots: [AppKind: LimitsSnapshot],
                       totals: [AppKind: TokenTotals],
                       forecasts: [AppKind: [Forecast]] = [:],
                       mode: TitleMode = .compact,
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
        if mode.showsTokens, let totals, totals.total > 0 {
            parts.append("\(Format.tokens(totals.total))/\(Format.tokens(totals.billable))")
        }

        let all = (snapshot?.windows ?? []).sorted { $0.minutes < $1.minutes }
        for window in all {
            let forecast = forecasts.first { $0.minutes == window.minutes }

            // Compact mode spells out the short window and reduces any longer
            // one to its alarm — a weekly window sitting comfortably is not
            // news, and when it is, the hour it dies matters more than the
            // percentage it is at.
            if mode == .compact, window.minutes > 300 {
                guard forecast?.verdict == .short else { continue }
                let left = forecast?.exhaustedAt.map { Format.timeLeft($0.timeIntervalSince(now)) }
                parts.append("⚠\(Format.windowName(window.minutes))\(left.map { " " + $0 } ?? "")")
                continue
            }

            var cell = "\(Format.percent(window.pct))→\(Format.timeLeft(window.timeLeft(now: now)))"
            if mode.showsForecast, let forecast {
                cell += outlook(forecast, now: now)
            }
            parts.append(cell)
        }
        guard !parts.isEmpty else { return nil }

        let stale = snapshot?.isStale == true ? " \(staleMarker)" : ""
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
