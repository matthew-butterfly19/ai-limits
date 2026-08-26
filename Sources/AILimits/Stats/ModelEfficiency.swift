import Foundation

/// What one model actually gives back for what it consumes.
///
/// On a subscription the currency is not dollars — it is percent of a limit
/// window. So the question "which model is worth using" reduces to: how much
/// work per percent burned, and how much of the input can be served from cache.
struct ModelEfficiency: Identifiable {
    var app: AppKind
    var model: String?
    var totals: TokenTotals

    var id: String { "\(app.rawValue):\(model ?? "?")" }

    /// Output tokens per turn — how much the model actually produces per
    /// exchange, which is the closest thing to "work done" the logs carry.
    var outputPerTurn: Double? {
        totals.events > 0 ? Double(totals.output) / Double(totals.events) : nil
    }

    /// Share of input served from cache. High is cheap.
    var cacheHitRate: Double? { totals.cacheHitRate }

    /// How much of the output was thinking rather than answer.
    var reasoningShare: Double? {
        totals.output > 0 ? Double(totals.reasoning) / Double(totals.output) : nil
    }

    /// Percent of the model's own metered window burned per million tokens.
    /// Only Claude meters some models separately, so this is nil for most rows —
    /// and nil means "not measurable", never "free".
    var limitPerMillion: Double?
    /// How many readings that estimate rests on.
    var limitSamples: Int = 0
}

extension StatsEngine {

    /// Per-model breakdown for a period, heaviest first.
    func modelEfficiency(since: Date?, app: AppKind? = nil,
                         now: Date = Date()) throws -> [ModelEfficiency] {
        let scoped = try store.scopedHistory(since: since ?? now.addingTimeInterval(-30 * 86_400))

        var rows: [ModelEfficiency] = []
        for kind in AppKind.allCases where app == nil || app == kind {
            for entry in try store.modelTotals(since: since, app: kind) {
                var row = ModelEfficiency(app: kind, model: entry.model, totals: entry.totals)
                if let model = entry.model,
                   let cost = limitCost(model: model, tokens: entry.totals.total, scoped: scoped) {
                    row.limitPerMillion = cost.perMillion
                    row.limitSamples = cost.samples
                }
                rows.append(row)
            }
        }
        return rows.sorted { $0.totals.total > $1.totals.total }
    }

    /// Matches a metered window to a model id by name, then divides the percent
    /// it moved by the tokens that went through that model.
    private func limitCost(model: String, tokens: Int,
                           scoped: [String: [LimitSample]]) -> (perMillion: Double, samples: Int)? {
        let identifier = model.lowercased()
        // "Fable" ↔ "claude-fable-5". The vendor's display name is a family
        // name, and the model id contains it; anything looser would silently
        // attribute one model's cost to another.
        guard let (_, samples) = scoped.first(where: { label, _ in
            let needle = label.lowercased().replacingOccurrences(of: " ", with: "-")
            return !needle.isEmpty && identifier.contains(needle)
        }) else { return nil }

        let ordered = samples.sorted { $0.ts < $1.ts }
        guard ordered.count >= 2, let first = ordered.first, let last = ordered.last else { return nil }
        // A reset inside the period makes the difference meaningless.
        let delta = last.pct - first.pct
        guard delta > 0, tokens > 0 else { return nil }
        return (delta / (Double(tokens) / 1_000_000), ordered.count)
    }
}

extension Store {
    /// Per-model metered windows, grouped by the vendor's display name.
    func scopedHistory(since: Date) throws -> [String: [LimitSample]] {
        try sync { db in
            var grouped: [String: [LimitSample]] = [:]
            let stmt = try db.prepare("""
                SELECT ts, app, label, window_mins, pct, resets_at
                FROM scoped_limits WHERE ts >= ? ORDER BY ts
                """)
            stmt.bind(1, since.timeIntervalSince1970)
            try stmt.forEachRow { row in
                guard let ts = row.date(0),
                      let app = row.string(1).flatMap(AppKind.init(rawValue:)),
                      let label = row.string(2) else { return }
                grouped[label, default: []].append(
                    LimitSample(ts: ts, app: app, windowMinutes: row.int(3),
                                pct: row.double(4), resetsAt: row.date(5)))
            }
            return grouped
        }
    }
}
