import Foundation

/// Renders the menu bar line — and the ladder of shorter versions of it that
/// `MenuBarFit` picks from when the bar has no room for the full one.
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
///
/// What the old "compact" mode got wrong was not that it dropped content — it
/// was that it dropped content the user had explicitly switched on, at a moment
/// nobody could predict. `variants` drops content too, but only when the
/// alternative is macOS hiding the whole line (which it does — see
/// `MenuBarFit`), in a fixed published order, and it says so with `…` the
/// moment a whole app falls off. The two alarm glyphs survive every rung but
/// the last one, which is a single character wide and keeps only the alarm.
enum MenuBarTitle {
    static let staleMarker = "↻"
    static let wideSeparator = "  ┃  "
    static let tightSeparator = " ┃ "
    /// Appended once the line has stopped being the complete picture — a whole
    /// app's segment gone, or the names dropped — and has to admit it.
    static let truncationMarker = " …"

    /// Everything the line is rendered from. Grouped so that the ladder can
    /// re-render the same readings a dozen ways without a dozen arguments.
    struct Inputs {
        var snapshots: [AppKind: LimitsSnapshot] = [:]
        var totals: [AppKind: TokenTotals] = [:]
        var forecasts: [AppKind: [Forecast]] = [:]
        var todayUsage: [AppKind: Double] = [:]
        /// AI Review Platform: dzisiejszy wydatek jej klucza i czy klucz
        /// jeszcze płaci. To nie jest aplikacja z logami ani limitem — tylko
        /// jedna liczba z OpenRoutera, pokazywana tak samo jak koszt Harnessa.
        var reviewToday: Double?
        var reviewDead = false
        var now = Date()
    }

    /// How much of it to render. Defaults are the user's own preferences; the
    /// ladder turns them off one by one, never on.
    struct Style {
        var show5h = true
        var show7d = false
        var showForecast = true
        var showTokens = false
        /// Time to reset (`→1h30m`). Off, the cell is the bare percentage.
        var showTimeLeft = true
        /// Harness bills through OpenRouter, so its tokens are normally on
        /// regardless of `showTokens` — but they are still detail, and detail
        /// is what the ladder sheds before it sheds a whole app.
        var showDshTokens = true
        /// Nazwa aplikacji przed liczbami. Zdejmowana dopiero na samym dole
        /// drabiny: nazwy nie skracamy do inicjałów (to było odrzucone), ale
        /// gdy wybór jest między samym procentem a niepokazaniem niczego,
        /// procent wygrywa — kolejność aplikacji jest stała, ta sama co w
        /// panelu.
        var showNames = true
        var separator = wideSeparator
        /// Which apps get a segment. Order of appearance is always
        /// `AppKind.allCases`; this set only says who is present.
        var apps: [AppKind] = AppKind.allCases
        /// Segment AI Review Platform na końcu linii. Bez własnego limitu i
        /// bez prognozy, więc na drabinie odpada przed pierwszą aplikacją.
        var showReview = true
        var truncated = false
    }

    static func render(_ inputs: Inputs, style: Style = Style()) -> String {
        var segments = AppKind.allCases.filter(style.apps.contains).compactMap { app in
            segment(app: app, inputs: inputs, style: style)
        }
        if let review = reviewSegment(inputs, style: style) {
            segments.append(review)
        }
        guard !segments.isEmpty else { return "AI limits …" }
        return segments.joined(separator: style.separator)
            + (style.truncated ? truncationMarker : "")
    }

    /// The same line at every length, longest first, deduplicated.
    ///
    /// The order is fixed and shrinks by what costs least to lose: separator
    /// padding, then the projection, then token counts, then the 7 d window
    /// (the 5 h one is the urgent one), then time to reset, then whole apps —
    /// least urgent first, which always starts with Harness: it has no vendor
    /// limit window, so it can never be the app about to run dry. The bottom
    /// two rungs give up the app names as well, for a bar so crowded that
    /// nothing else would be drawn at all.
    static func variants(_ inputs: Inputs, style: Style) -> [String] {
        var texts: [String] = []
        var seen = Set<String>()
        var current = style

        func add() {
            let text = render(inputs, style: current)
            if seen.insert(text).inserted { texts.append(text) }
        }

        add()
        current.separator = tightSeparator
        add()
        current.showForecast = false
        add()
        current.showTokens = false
        current.showDshTokens = false
        add()
        if current.show5h {
            current.show7d = false
            add()
        }
        current.showTimeLeft = false
        add()
        // Review odpada przed pierwszą aplikacją: nie ma limitu z resetem,
        // więc nigdy nie jest tym, co zaraz się skończy — chyba że jej klucz
        // umarł, ale wtedy zostaje sam „⚠”, bo alarm nie schodzi z linii.
        if current.showReview, reviewSegment(inputs, style: current) != nil {
            current.showReview = false
            current.truncated = !inputs.reviewDead
            add()
        }

        // Only apps that actually render something can be dropped — an app
        // that is silent (no limits read yet, no tokens) is already absent, and
        // "dropping" it would add the `…` marker without freeing a pixel.
        let present = style.apps.filter { segment(app: $0, inputs: inputs, style: current) != nil }
        let ranked = ranking(present, inputs: inputs)
        for keep in stride(from: ranked.count - 1, through: 1, by: -1) {
            current.truncated = true
            current.apps = Array(ranked.prefix(keep))
            add()
        }

        // Ostatnia deska ratunku: same liczby. Sensowne tylko dlatego, że pasek
        // i tak chowa całą linię, gdy się nie mieści — „21% ⚠” mówi więcej niż
        // nic, a panel po kliknięciu i tak podpisuje wszystko z nazwy.
        current.showNames = false
        current.truncated = true
        current.apps = ranked
        add()
        for keep in stride(from: ranked.count - 1, through: 1, by: -1) {
            current.truncated = true
            current.apps = Array(ranked.prefix(keep))
            add()
        }

        // Poniżej drabina przestaje być skracaniem, a zaczyna być obecnością.
        // Na belce wbudowanego ekranu zmierzony prześwit to około sześćdziesiąt
        // punktów, a najkrótszy szczebel z `…` ma siedemdziesiąt trzy — czyli
        // nie mieści się o kilkanaście punktów i nie widać nic. Sam znacznik
        // `…` kosztuje 14 pt, więc tutaj znika: przy jednej liczbie i tak
        // widać, że to nie jest cała prawda.
        current.truncated = false
        current.apps = Array(ranked.prefix(1))
        add()
        // I absolutnie ostatni szczebel: sam znak, bez liczby. Nie mówi nic
        // poza „aplikacja żyje”, ale jest najwęższym elementem, jaki da się
        // postawić w pasku (≈47 pt, z czego 37 to nieusuwalny margines
        // przycisku) — i wystarczy, żeby dało się w niego kliknąć i zobaczyć
        // resztę w panelu. Alarm ma tu własny znak, więc jedyna rzecz, której
        // drabina obiecuje nie zgubić, nie ginie nawet tutaj.
        let last = lastResort(inputs)
        if seen.insert(last).inserted { texts.append(last) }
        return texts
    }

    /// Najkrótsza możliwa treść elementu paska: sam znak. `⚠`, jeśli
    /// którekolwiek okno kończy się przed resetem — inaczej neutralny romb.
    static func lastResort(_ inputs: Inputs) -> String {
        let alarmed = inputs.forecasts.values.contains { forecasts in
            forecasts.contains { $0.verdict == .short }
        }
        return alarmed ? "⚠" : "◆"
    }

    /// Jedna liczba warta pokazania, gdy nie ma jej gdzie pokazać w pasku —
    /// ta sama aplikacja, która przeżywa na ostatnim szczeblu drabiny. Używa
    /// tego ikona w Docku (patrz `DockIcon`).
    static func headline(_ inputs: Inputs,
                         apps: [AppKind]) -> (name: String, percent: String, alarmed: Bool)? {
        // Ta sama lista, co w drabinie: aplikacja odznaczona w „Widoczne w
        // pasku menu” nie ma prawa wrócić bocznymi drzwiami na ikonę w Docku.
        let apps = apps.filter { inputs.snapshots[$0]?.window(minutes: 300) != nil }
        guard let app = ranking(apps, inputs: inputs).first,
              let window = inputs.snapshots[app]?.window(minutes: 300) else { return nil }
        let alarmed = (inputs.forecasts[app] ?? []).contains { $0.verdict == .short }
        return (app.display, Format.percent(window.pct), alarmed)
    }

    /// Most important first — the order in which apps *survive*, not the order
    /// they are shown in. An app whose window runs out before it resets is
    /// never the one dropped; after that the fuller window wins, and an app
    /// with no limit window at all (Harness) goes first.
    private static func ranking(_ apps: [AppKind], inputs: Inputs) -> [AppKind] {
        func rank(_ app: AppKind) -> (Int, Double) {
            let alarmed = (inputs.forecasts[app] ?? []).contains { $0.verdict == .short }
            let pct = (inputs.snapshots[app]?.windows ?? []).map(\.pct).max() ?? 0
            let tier = alarmed ? 2 : (app.hasLimitWindow ? 1 : 0)
            return (tier, pct)
        }
        return apps.sorted { left, right in
            let (leftTier, leftPct) = rank(left)
            let (rightTier, rightPct) = rank(right)
            if leftTier != rightTier { return leftTier > rightTier }
            if leftPct != rightPct { return leftPct > rightPct }
            let order = AppKind.allCases
            return (order.firstIndex(of: left) ?? 0) < (order.firstIndex(of: right) ?? 0)
        }
    }

    /// `Review 11,3$/d`, jak koszt Harnessa. Martwy klucz zostawia sam alarm
    /// nawet wtedy, gdy drabina zdjęła już cały segment: to jest ta jedna
    /// informacja, po którą ten segment w ogóle istnieje.
    private static func reviewSegment(_ inputs: Inputs, style: Style) -> String? {
        guard let usage = inputs.reviewToday else { return nil }
        let alarm = inputs.reviewDead ? " ⚠" : ""
        guard style.showReview else { return inputs.reviewDead ? "Review ⚠" : nil }
        let name = style.showNames ? "Review " : ""
        return "\(name)\(usage < 0.1 ? "<0.1" : Format.decimal(usage, places: 1))$/d\(alarm)"
    }

    private static func segment(app: AppKind, inputs: Inputs, style: Style) -> String? {
        var parts: [String] = []
        // An app with no vendor rate-limit window (dsh) has no percentage to
        // lead with, so today's real OpenRouter spend stands in as its
        // headline figure. Its token count stays on regardless of the
        // "Tokeny" toggle too, by request — an OpenRouter-billed tool's
        // tokens are read as "what am I being charged for", not as the
        // optional extra detail they are for Claude/Codex's own subscription
        // percentage, so the toggle only ever governs those two.
        if !app.hasLimitWindow, let usage = inputs.todayUsage[app] {
            parts.append("\(usage < 0.1 ? "<0.1" : Format.decimal(usage, places: 1))$/d")
        }
        let wantsTokens = app.hasLimitWindow ? style.showTokens : style.showDshTokens
        if wantsTokens, let totals = inputs.totals[app], totals.total > 0 {
            parts.append("\(Format.tokens(totals.total))/\(Format.tokens(totals.billable))")
        }

        let snapshot = inputs.snapshots[app]
        let all = (snapshot?.windows ?? []).sorted { $0.minutes < $1.minutes }
        for window in all {
            if window.minutes <= 300, !style.show5h { continue }
            if window.minutes > 300, !style.show7d { continue }

            let forecast = (inputs.forecasts[app] ?? []).first { $0.minutes == window.minutes }
            var cell = Format.percent(window.pct)
            if style.showTimeLeft {
                cell += "→\(Format.timeLeft(window.timeLeft(now: inputs.now)))"
            }
            if let forecast {
                cell += outlook(forecast, style: style, now: inputs.now)
            }
            parts.append(cell)
        }
        guard !parts.isEmpty else { return nil }

        let stale = snapshot?.isStale == true ? " \(staleMarker)" : ""
        let name = style.showNames ? "\(app.display) " : ""
        return "\(name)\(parts.joined(separator: " · "))\(stale)"
    }

    /// The projection, or — when the window runs out first — how long that
    /// takes. The alarm outlives every shortening step; only the projection is
    /// optional, because "will run out at 18:40" is the reason to look at the
    /// bar at all and "will land at 88%" is not.
    private static func outlook(_ forecast: Forecast, style: Style, now: Date) -> String {
        switch forecast.verdict {
        case .unknown:
            return ""
        case .short:
            guard style.showTimeLeft, let exhausted = forecast.exhaustedAt else { return " ⚠" }
            return " ⚠\(Format.timeLeft(exhausted.timeIntervalSince(now)))"
        case .comfortable, .tight:
            guard style.showForecast, let projected = forecast.projectedEndPct else { return "" }
            return " ≈\(Int(projected.rounded()))%"
        }
    }
}

/// Where the menu bar preferences live on disk, and how to read them back
/// outside the app — named in one place so `AppModel` and the `--menubar`
/// diagnostic can never describe two different bars.
enum MenuBarDefaults {
    static let show5h = "menuBarShow5h"
    static let show7d = "menuBarShow7d"
    static let showForecast = "menuBarShowForecast"
    static let showTokens = "menuBarShowTokens"
    static let autoShorten = "menuBarAutoShorten"
    static let dockFallback = "menuBarDockFallback"
    static let visibleApps = "menuBarVisibleApps"
    static let showReview = "menuBarShowReview"

    /// The saved preferences as a style. Missing keys mean "never touched the
    /// settings" and fall back to the same defaults the app starts with.
    static func style(_ defaults: UserDefaults = .standard) -> MenuBarTitle.Style {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let saved = defaults.array(forKey: visibleApps) as? [String]
        let apps = saved.map { Set($0.compactMap(AppKind.init(rawValue:))) } ?? Set(AppKind.allCases)
        return MenuBarTitle.Style(show5h: flag(show5h, true),
                                  show7d: flag(show7d, false),
                                  showForecast: flag(showForecast, true),
                                  showTokens: flag(showTokens, false),
                                  apps: AppKind.allCases.filter(apps.contains),
                                  showReview: flag(showReview, true))
    }
}
