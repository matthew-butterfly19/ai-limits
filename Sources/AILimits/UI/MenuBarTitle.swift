import Foundation

/// Renders the menu bar line.
///
/// Four independent preferences, not a combined mode: the 5 h window, the 7 d
/// window, the forecast projection and the token count each show or don't on
/// their own. Earlier versions packed these into one enum with hidden
/// interactions (picking "tokens" silently dropped the forecast, "compact"
/// silently collapsed the 7 d window to an alarm) — every one of those was
/// reported back as confusing. Explicit beats clever here: a window that is
/// switched off is simply gone, with no alarm exception standing in for it.
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
                       todayUsage: [AppKind: Double] = [:],
                       show5h: Bool = true,
                       show7d: Bool = false,
                       showForecast: Bool = true,
                       showTokens: Bool = false,
                       visibleApps: Set<AppKind> = Set(AppKind.allCases),
                       now: Date = Date()) -> String {
        let segments = AppKind.allCases.filter(visibleApps.contains).compactMap { app -> String? in
            segment(app: app, snapshot: snapshots[app], totals: totals[app],
                    forecasts: forecasts[app] ?? [], todayUsage: todayUsage[app],
                    show5h: show5h, show7d: show7d, showForecast: showForecast,
                    showTokens: showTokens, now: now)
        }
        return segments.isEmpty ? "AI limits …" : segments.joined(separator: "  ┃  ")
    }

    private static func segment(app: AppKind,
                                snapshot: LimitsSnapshot?,
                                totals: TokenTotals?,
                                forecasts: [Forecast],
                                todayUsage: Double?,
                                show5h: Bool,
                                show7d: Bool,
                                showForecast: Bool,
                                showTokens: Bool,
                                now: Date) -> String? {
        var parts: [String] = []
        // An app with no vendor rate-limit window (dsh) has no percentage to
        // lead with, so today's real OpenRouter spend stands in as its
        // headline figure. Its token count stays on regardless of the
        // "Tokeny" toggle too, by request — an OpenRouter-billed tool's
        // tokens are read as "what am I being charged for", not as the
        // optional extra detail they are for Claude/Codex's own subscription
        // percentage, so the toggle only ever governs those two.
        if !app.hasLimitWindow, let todayUsage {
            parts.append("\(todayUsage < 0.1 ? "<0.1" : Format.decimal(todayUsage, places: 1))$/d")
        }
        if (showTokens || !app.hasLimitWindow), let totals, totals.total > 0 {
            parts.append("\(Format.tokens(totals.total))/\(Format.tokens(totals.billable))")
        }

        let all = (snapshot?.windows ?? []).sorted { $0.minutes < $1.minutes }
        for window in all {
            if window.minutes <= 300, !show5h { continue }
            if window.minutes > 300, !show7d { continue }

            let forecast = forecasts.first { $0.minutes == window.minutes }
            var cell = "\(Format.percent(window.pct))→\(Format.timeLeft(window.timeLeft(now: now)))"
            if showForecast, let forecast {
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
