import Foundation

/// Answers the only question that matters mid-window: **will the limit last
/// until it resets?**
///
/// A raw burn rate ("3.1 %/h") does not answer it — 3 %/h is comfortable with
/// 40 % left and four hours to go, and fatal with 8 % left and one. So the rate
/// is always compared against the rate the remaining budget actually affords.
struct Forecast: Identifiable {
    var minutes: Int
    var pct: Double
    var hoursLeft: Double

    /// %/h the remaining budget affords if it is to last exactly to the reset.
    var allowedPace: Double
    /// %/h measured over the last hour of samples.
    var recentPace: Double?
    /// %/h averaged over the whole window so far.
    var averagePace: Double?
    /// Where the window lands at reset time if the current pace holds.
    var projectedEndPct: Double?
    /// When the window hits 100 %, if it does so before the reset.
    var exhaustedAt: Date?

    /// Tokens burned per percent of this window, from the window's own totals.
    var tokensPerPercent: Double?
    /// Tokens still affordable before the window is full, at the same mix.
    var tokensLeft: Int?

    var id: Int { minutes }

    /// The pace the projection is built on.
    ///
    /// For a window of a day or more, a rate measured over the last few hours
    /// and extrapolated across days ignores the daily duty cycle — nobody works
    /// through the night at the afternoon's pace. The window's own average
    /// already contains the nights and the breaks, so it leads there. Short
    /// windows are the opposite case: within five hours what matters is what is
    /// happening right now.
    var pace: Double? {
        minutes >= 1_440 ? (averagePace ?? recentPace) : (recentPace ?? averagePace)
    }

    /// Which measurement the projection actually used — shown, because the two
    /// can disagree a lot and the user should know which one is speaking.
    var paceBasis: String {
        minutes >= 1_440
            ? (averagePace != nil ? "średnia od otwarcia okna" : "ostatnie godziny")
            : (recentPace != nil ? "ostatnia godzina" : "średnia od otwarcia okna")
    }

    /// How many times faster than affordable the current pace is.
    /// 1.0 means exactly on budget; 2.0 means running out at half time.
    var paceRatio: Double? {
        guard let pace, allowedPace > 0 else { return nil }
        return pace / allowedPace
    }

    enum Verdict {
        case unknown
        /// Lands under 85 % — real headroom.
        case comfortable
        /// Lands between 85 % and 100 % — makes it, but only just.
        case tight
        /// Runs out before the reset.
        case short
    }

    var verdict: Verdict {
        guard let projectedEndPct else { return .unknown }
        if projectedEndPct > 100 { return .short }
        return projectedEndPct > 85 ? .tight : .comfortable
    }
}

extension StatsEngine {

    /// How far back to measure the current pace. A weekly window moves so
    /// slowly that an hour of samples is indistinguishable from noise, so the
    /// lookback scales with the window — a tenth of it, never under an hour.
    static func lookback(for windowMinutes: Int) -> TimeInterval {
        max(3_600, Double(windowMinutes) * 60 / 10)
    }

    /// Builds the forecast for one window of one app.
    ///
    /// Everything degrades to nil rather than to a guess: with fewer than three
    /// samples in the last hour there is no recent pace, and with the window
    /// barely open there is no average either.
    func forecast(app: AppKind, snapshot: LimitsSnapshot?, minutes: Int,
                  now: Date = Date()) throws -> Forecast? {
        guard let window = snapshot?.window(minutes: minutes),
              let secondsLeft = window.timeLeft(now: now)
        else { return nil }

        let hoursLeft = secondsLeft / 3_600
        let start = window.windowStart(now: now)
        let hoursElapsed = max(now.timeIntervalSince(start) / 3_600, 0)

        var result = Forecast(
            minutes: minutes, pct: window.pct, hoursLeft: hoursLeft,
            allowedPace: hoursLeft > 0 ? (100 - window.pct) / hoursLeft : 0,
            recentPace: try burnRate(app: app, minutes: minutes,
                                     lookback: Self.lookback(for: minutes),
                                     now: now)?.percentPerHour,
            averagePace: hoursElapsed > 0.25 ? window.pct / hoursElapsed : nil,
            projectedEndPct: nil, exhaustedAt: nil,
            tokensPerPercent: nil, tokensLeft: nil)

        // A pace of zero is a real answer ("nothing is being consumed"), so it
        // must not be filtered out the way a missing measurement is.
        if let pace = result.pace {
            let projected = window.pct + pace * hoursLeft
            result.projectedEndPct = projected
            if projected > 100, pace > 0 {
                result.exhaustedAt = now.addingTimeInterval((100 - window.pct) / pace * 3_600)
            }
        }

        // Below one percent the ratio explodes — 0.4 % of a window is not a
        // usable denominator for extrapolating a token budget.
        if window.pct >= 1, let totals = try store.totals(since: start)[app], totals.total > 0 {
            let perPercent = Double(totals.total) / window.pct
            result.tokensPerPercent = perPercent
            result.tokensLeft = Int(max(0, (100 - window.pct) * perPercent))
        }

        return result
    }

    func forecasts(app: AppKind, snapshot: LimitsSnapshot?, now: Date = Date()) throws -> [Forecast] {
        try (snapshot?.windows ?? [])
            .sorted { $0.minutes < $1.minutes }
            .compactMap { try forecast(app: app, snapshot: snapshot, minutes: $0.minutes, now: now) }
    }
}
