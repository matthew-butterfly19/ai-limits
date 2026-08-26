import SwiftUI

/// The answer to "will this last until it resets", in one line.
///
/// The pace is always shown against the pace the remaining budget affords,
/// because a rate on its own decides nothing: 3 %/h is comfortable with four
/// hours to go and fatal with one.
struct ForecastLine: View {
    var forecast: Forecast

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            // One short sentence. The pace-against-budget arithmetic is
            // reference material and lives in the tooltip — squeezed onto this
            // row it truncated both halves and said nothing.
            Text(headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(tooltip)
    }

    private var color: Color {
        switch forecast.verdict {
        case .unknown:     return Palette.muted
        case .comfortable: return Palette.good
        case .tight:       return Palette.warning
        case .short:       return Palette.critical
        }
    }

    /// Icon plus wording, so the verdict never rests on colour alone.
    private var icon: String {
        switch forecast.verdict {
        case .unknown:     return "questionmark.circle"
        case .comfortable: return "checkmark.circle.fill"
        case .tight:       return "exclamationmark.circle.fill"
        case .short:       return "xmark.octagon.fill"
        }
    }

    private var headline: String {
        switch forecast.verdict {
        case .unknown:
            return "za mało próbek na prognozę"
        case .short:
            guard let exhausted = forecast.exhaustedAt else { return "zabraknie przed resetem" }
            let toExhaustion = exhausted.timeIntervalSinceNow
            // The useful second number is the *margin* — how early the window
            // runs dry — not the time to reset, which the row already shows.
            let margin = forecast.hoursLeft * 3_600 - toExhaustion
            return "zabraknie za \(Format.timeLeft(toExhaustion))"
                + " — \(Format.timeLeft(margin)) przed resetem"
        case .tight:
            return "na styk — na koniec ≈\(percent(forecast.projectedEndPct))\(spare)"
        case .comfortable:
            return "starczy — na koniec ≈\(percent(forecast.projectedEndPct))\(spare)"
        }
    }

    /// Only when it fits in a couple of words — the full arithmetic is in the
    /// tooltip.
    private var spare: String {
        guard let tokens = forecast.tokensLeft, forecast.verdict != .short else { return "" }
        return ", zapas ~\(Format.tokens(tokens))"
    }

    private var tooltip: String {
        var lines = ["Okno \(Format.windowName(forecast.minutes)): \(percent(forecast.pct)) "
                     + "zużyte, \(Format.timeLeft(forecast.hoursLeft * 3_600)) do resetu."]
        if let pace = forecast.pace, let ratio = forecast.paceRatio {
            lines.append("Tempo \(rate(pace)) %/h (\(forecast.paceBasis)) wobec "
                         + "\(rate(forecast.allowedPace)) %/h, które starczyłoby dokładnie "
                         + "do resetu — \(Format.decimal(ratio))× budżetu.")
            if let recent = forecast.recentPace, let average = forecast.averagePace {
                lines.append("Ostatnia godzina \(rate(recent)) %/h, "
                             + "średnia okna \(rate(average)) %/h.")
            }
        }
        if let perPercent = forecast.tokensPerPercent {
            lines.append("W tym oknie ~\(Format.tokensFull(Int(perPercent))) tokenów na 1 % limitu "
                         + "— przy dotychczasowym miksie modeli i trafień w cache.")
        }
        if forecast.pace == nil {
            lines.append("Prognoza pojawi się po kilku próbkach limitu w tym oknie.")
        }
        return lines.joined(separator: "\n")
    }

    /// Polish decimals use a comma; `String(format:)` is stuck on the C locale.
    private func rate(_ value: Double) -> String { Format.decimal(value) }
    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}
