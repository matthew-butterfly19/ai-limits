import Foundation

/// Pure reads over the store. Keeping this out of the views means the popover,
/// the detail window and any future export all quote the same numbers.
struct StatsEngine {
    let store: Store

    // MARK: - current window

    /// Tokens consumed inside the window the given percentage describes, so the
    /// token count and the percentage always cover the same interval.
    func currentWindowTotals(snapshot: LimitsSnapshot?, minutes: Int = 300,
                             now: Date = Date()) throws -> TokenTotals? {
        guard let window = snapshot?.window(minutes: minutes) else { return nil }
        return try store.totals(since: window.windowStart(now: now))[snapshot!.app]
    }

    /// How fast a limit window is filling, and when it would be exhausted.
    struct BurnRate {
        var percentPerHour: Double
        var exhaustedAt: Date?
        var sampleCount: Int
    }

    /// nil when the recent history is too thin to say anything — a projection
    /// from two samples is a guess dressed up as a measurement.
    func burnRate(app: AppKind, minutes: Int, lookback: TimeInterval = 3_600,
                  now: Date = Date()) throws -> BurnRate? {
        let samples = try store.limitHistory(since: now.addingTimeInterval(-lookback), app: app)
            .filter { $0.windowMinutes == minutes }
            .sorted { $0.ts < $1.ts }
        guard samples.count >= 3, let first = samples.first, let last = samples.last else { return nil }

        let hours = last.ts.timeIntervalSince(first.ts) / 3_600
        guard hours > 0.05 else { return nil }

        // A reset inside the lookback makes the slope meaningless.
        guard last.pct >= first.pct else { return nil }

        let rate = (last.pct - first.pct) / hours
        guard rate > 0.01 else {
            return BurnRate(percentPerHour: rate, exhaustedAt: nil, sampleCount: samples.count)
        }
        let hoursLeft = (100 - last.pct) / rate
        return BurnRate(percentPerHour: rate,
                        exhaustedAt: now.addingTimeInterval(hoursLeft * 3_600),
                        sampleCount: samples.count)
    }

    // MARK: - attribution

    /// Threads in the window, heaviest first, with their per-model split.
    struct ThreadRow: Identifiable {
        var thread: ThreadUsage
        var models: [ThreadModelUsage]
        var id: String { thread.id }
        /// Share of the app's total in the same window, 0…1.
        var share: Double = 0
        /// Percent of the limit window this thread ate. This is the number the
        /// user actually pays in — tokens are only the unit it is measured in.
        var limitPercent: Double?
    }

    /// `tokensPerPercent` converts each thread's tokens into the currency that
    /// matters on a subscription: percent of the window it consumed.
    func threadRows(since: Date?, app: AppKind? = nil, limit: Int = 12,
                    tokensPerPercent: [AppKind: Double] = [:]) throws -> [ThreadRow] {
        let threads = try store.threads(since: since, app: app, limit: limit)
        let matrix = try store.threadModelMatrix(since: since, app: app)
        var byThread: [String: [ThreadModelUsage]] = [:]
        for row in matrix { byThread["\(row.app.rawValue):\(row.sessionID)", default: []].append(row) }

        let totalsByApp = try store.totals(since: since)
        return threads.map { thread in
            let appTotal = totalsByApp[thread.app]?.total ?? 0
            let perPercent = tokensPerPercent[thread.app]
            return ThreadRow(
                thread: thread,
                models: (byThread[thread.id] ?? []).sorted { $0.totals.total > $1.totals.total },
                share: appTotal > 0 ? Double(thread.totals.total) / Double(appTotal) : 0,
                limitPercent: perPercent.map { Double(thread.totals.total) / $0 })
        }
    }

    /// Per-project share of tokens burned in the window — answers "what did the
    /// limit actually go on".
    struct ProjectShare: Identifiable {
        var project: String
        var app: AppKind
        var tokens: Int
        var share: Double
        var id: String { "\(app.rawValue):\(project)" }
    }

    func projectShares(since: Date?, app: AppKind? = nil) throws -> [ProjectShare] {
        let threads = try store.threads(since: since, app: app)
        var byProject: [String: (AppKind, Int)] = [:]
        for thread in threads {
            let key = "\(thread.app.rawValue)|\(thread.project ?? "—")"
            byProject[key] = (thread.app, (byProject[key]?.1 ?? 0) + thread.totals.total)
        }
        let total = byProject.values.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return byProject
            .map { key, value in
                ProjectShare(project: String(key.split(separator: "|").last ?? "—"),
                             app: value.0, tokens: value.1,
                             share: Double(value.1) / Double(total))
            }
            .sorted { $0.tokens > $1.tokens }
    }

    // MARK: - time

    /// Local-hour buckets for the last `hours`, one series per app.
    func hourly(hours: Int = 24, now: Date = Date()) throws -> [HourBucket] {
        try store.hourly(since: now.addingTimeInterval(-Double(hours) * 3_600))
    }

    /// day × local-hour grid, for the "when do I actually work" heat map.
    struct HourMapCell: Identifiable {
        var day: Date
        var hour: Int
        var tokens: Int
        var id: String { "\(day.timeIntervalSince1970)-\(hour)" }
    }

    func hourMap(days: Int = 14, now: Date = Date()) throws -> [HourMapCell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86_400))

        var cells: [String: HourMapCell] = [:]
        for bucket in try store.hourly(since: start) {
            let day = calendar.startOfDay(for: bucket.hourStart)
            let hour = calendar.component(.hour, from: bucket.hourStart)
            let key = "\(day.timeIntervalSince1970)-\(hour)"
            var cell = cells[key] ?? HourMapCell(day: day, hour: hour, tokens: 0)
            cell.tokens += bucket.totals.total
            cells[key] = cell
        }
        return cells.values.sorted { ($0.day, $0.hour) < ($1.day, $1.hour) }
    }

    /// This week against the same stretch of last week.
    ///
    /// Compared at the same *phase* of the window, not week-to-date against a
    /// whole week — three days in, the honest comparison is against the first
    /// three days of the previous week.
    struct WeekOverWeek {
        var app: AppKind
        var elapsed: TimeInterval
        var current: Int
        var previous: Int
        /// Relative change, or nil when the earlier week has nothing to compare.
        var change: Double? {
            previous > 0 ? Double(current) / Double(previous) - 1 : nil
        }
        /// The earlier week expressed in percent of the limit, at the current
        /// window's token-per-percent rate. An estimate, and labelled as one.
        var previousPercent: Double?
    }

    func weekOverWeek(app: AppKind, snapshot: LimitsSnapshot?,
                      tokensPerPercent: Double? = nil,
                      now: Date = Date()) throws -> WeekOverWeek? {
        let start = snapshot?.window(minutes: 10_080)?.windowStart(now: now)
            ?? now.addingTimeInterval(-7 * 86_400)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 3_600 else { return nil }

        let week: TimeInterval = 7 * 86_400
        let current = try store.totals(since: start, until: now)[app]?.total ?? 0
        let previous = try store.totals(since: start.addingTimeInterval(-week),
                                        until: now.addingTimeInterval(-week))[app]?.total ?? 0
        guard current > 0 || previous > 0 else { return nil }

        return WeekOverWeek(app: app, elapsed: elapsed, current: current, previous: previous,
                            previousPercent: tokensPerPercent.map { Double(previous) / $0 })
    }

    /// One day of the current week beside the same weekday a week earlier.
    struct DayComparison: Identifiable {
        var day: Date
        var byApp: [AppKind: Int]
        var previousTotal: Int
        var id: TimeInterval { day.timeIntervalSince1970 }
        var total: Int { byApp.values.reduce(0, +) }
    }

    /// The last `days` days, each paired with its counterpart a week earlier.
    ///
    /// Aligned by weekday rather than by offset, because a Tuesday compares to
    /// a Tuesday — weekends are not interchangeable with working days.
    func weekComparison(days: Int = 7, now: Date = Date()) throws -> [DayComparison] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let week: TimeInterval = 7 * 86_400

        var rows: [DayComparison] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let current = try store.totals(since: day, until: next)
            let previous = try store.totals(since: day.addingTimeInterval(-week),
                                            until: next.addingTimeInterval(-week))
            rows.append(DayComparison(
                day: day,
                byApp: current.mapValues { $0.total },
                previousTotal: previous.values.reduce(0) { $0 + $1.total }))
        }
        return rows
    }

    /// Today against the mean of the preceding `days` days, per app.
    struct Comparison {
        var today: Int
        var average: Int
        /// nil when there is no history to compare against.
        var ratio: Double?
    }

    func comparisonToAverage(days: Int = 7, now: Date = Date()) throws -> [AppKind: Comparison] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -days, to: todayStart) ?? todayStart

        let today = try store.totals(since: todayStart)
        let history = try store.totals(since: historyStart, until: todayStart)

        var result: [AppKind: Comparison] = [:]
        for app in AppKind.allCases {
            let todayTotal = today[app]?.total ?? 0
            let average = (history[app]?.total ?? 0) / max(days, 1)
            result[app] = Comparison(today: todayTotal, average: average,
                                     ratio: average > 0 ? Double(todayTotal) / Double(average) : nil)
        }
        return result
    }
}

private func < (lhs: (Date, Int), rhs: (Date, Int)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
