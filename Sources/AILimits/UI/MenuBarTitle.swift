import Foundation

/// Renders the menu bar line. Deliberately unabbreviated: both apps, both token
/// numbers, every window the vendor reports, each with its time to reset.
///
///     ClaudeCode 62M/1.1M · 15%→4h28m · 65%→3d6h ┃ Codex 22M/6.0M · 29%→4h27m
///
/// A window the API did not report is omitted entirely — never rendered as a dash.
enum MenuBarTitle {
    static func render(snapshots: [AppKind: LimitsSnapshot],
                       totals: [AppKind: TokenTotals],
                       now: Date = Date()) -> String {
        let segments = AppKind.allCases.compactMap { app -> String? in
            segment(app: app, snapshot: snapshots[app], totals: totals[app], now: now)
        }
        return segments.isEmpty ? "AI limits …" : segments.joined(separator: "  ┃  ")
    }

    private static func segment(app: AppKind,
                                snapshot: LimitsSnapshot?,
                                totals: TokenTotals?,
                                now: Date) -> String? {
        var parts: [String] = []
        if let totals, totals.total > 0 {
            parts.append("\(Format.tokens(totals.total))/\(Format.tokens(totals.billable))")
        }
        for window in (snapshot?.windows ?? []).sorted(by: { $0.minutes < $1.minutes }) {
            parts.append("\(Format.percent(window.pct))→\(Format.timeLeft(window.timeLeft(now: now)))")
        }
        guard !parts.isEmpty else { return nil }
        let stale = snapshot?.isStale == true ? " ⚠" : ""
        return "\(app.display) \(parts.joined(separator: " · "))\(stale)"
    }
}
