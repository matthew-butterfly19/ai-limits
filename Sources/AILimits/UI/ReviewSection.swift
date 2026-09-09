import SwiftUI

/// Sekcja panelu dla AI Review Platform: nie koszt, tylko werdykt „czy klucz
/// jeszcze działa”.
///
/// Platforma review rozlicza się osobnym kluczem OpenRoutera z tygodniowym
/// limitem. Gdy limit się wyczerpie, lane'y skautów umierają po cichu, a
/// recenzja i tak się publikuje — pusta, jakby nie było co zgłaszać. Nikt z
/// zewnątrz nie widzi różnicy między „nic nie znaleziono” a „nie było czym
/// szukać”. Stąd jedna rzecz do sprawdzenia i jedno miejsce, w którym ma być
/// widoczna: klucz włączony, nie wygasł, i ile limitu zostało do resetu.
struct ReviewSection: View {
    @EnvironmentObject private var model: AppModel

    /// Od którego procenta limitu zaczynamy ostrzegać. Tydzień skautów kosztuje
    /// mniej więcej stałą kwotę, więc 80 % w środku tygodnia to już problem.
    private static let warnAt: Double = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let key = model.reviewKey {
                verdict(for: key)
                if let percent = key.limitUsedPercent, let limit = key.limit {
                    limitLine(key: key, percent: percent, limit: limit)
                } else {
                    Text("Klucz bez limitu wydatków — nie ma progu, który mógłby go wyłączyć.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                usageLine(key: key)
            } else if model.openRouterKeys.isEmpty {
                Text(model.openRouterError ?? "Pobieranie listy kluczy…")
                    .font(.system(size: 12))
                    .foregroundStyle(model.openRouterError == nil ? Palette.muted : Palette.serious)
            } else {
                // Hash zapamiętany, ale na koncie nie ma już takiego klucza.
                // To nie jest „brak danych” — to jest dokładnie ta awaria,
                // przed którą sekcja ma ostrzegać.
                Label("Wybranego klucza nie ma już na koncie OpenRoutera — platforma nie ma czym płacić.",
                      systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.critical)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.other).frame(width: 9, height: 9)
            Text("AI Review Platform").font(.system(size: 14, weight: .semibold))
            if let name = model.reviewKey?.name { Chip(text: name) }
            Spacer()
            if let fetched = model.openRouterKeysLastFetch,
               Date().timeIntervalSince(fetched) > AppModel.openRouterKeysTTL * 2 {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                    Text("sprzed \(Format.timeLeft(-fetched.timeIntervalSinceNow))")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.warning)
                .help("Lista kluczy z OpenRoutera nie odświeżyła się od dłuższego czasu — patrz błąd w sekcji Harnessa.")
            }
        }
    }

    // MARK: - werdykt

    private enum Verdict {
        case ok, low, exhausted, disabled, expired

        var text: String {
            switch self {
            case .ok: return "klucz działa"
            case .low: return "limit na wyczerpaniu"
            case .exhausted: return "limit wyczerpany — recenzje wychodzą puste"
            case .disabled: return "klucz wyłączony w OpenRouterze"
            case .expired: return "klucz wygasł"
            }
        }

        var color: Color {
            switch self {
            case .ok: return Palette.good
            case .low: return Palette.warning
            case .exhausted, .disabled, .expired: return Palette.critical
            }
        }

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .low: return "exclamationmark.triangle.fill"
            case .exhausted, .disabled, .expired: return "xmark.octagon.fill"
            }
        }
    }

    private func verdict(_ key: OpenRouterAPI.KeyInfo) -> Verdict {
        if key.disabled == true { return .disabled }
        if let expiry = key.expiryDate, expiry < Date() { return .expired }
        if let remaining = key.limitRemaining, key.limit != nil, remaining <= 0 { return .exhausted }
        if let percent = key.limitUsedPercent, percent >= Self.warnAt { return .low }
        return .ok
    }

    private func verdict(for key: OpenRouterAPI.KeyInfo) -> some View {
        let verdict = verdict(key)
        return Label(verdict.text, systemImage: verdict.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(verdict.color)
            .help("""
                  Sprawdzane z listy kluczy OpenRoutera (management key): czy klucz nie \
                  jest wyłączony, czy nie wygasł i ile zostało z limitu wydatków. \
                  Wyczerpany limit nie zatrzymuje platformy — skauci przestają \
                  działać, a recenzja publikuje się bez uwag.
                  """)
    }

    // MARK: - limit

    private func limitLine(key: OpenRouterAPI.KeyInfo, percent: Double, limit: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(periodName(key.limitReset))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 60, alignment: .leading)
                Text(Format.percent(percent))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                MeterBar(percent: percent, height: 10)
                Text("\(money(key.limitRemaining ?? 0)) z \(money(limit))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .frame(width: 120, alignment: .trailing)
            }
            .help("Ile limitu klucza poszło w bieżącym okresie i ile zostało. Kwota po prawej: pozostało z całego limitu.")
        }
    }

    private func usageLine(key: OpenRouterAPI.KeyInfo) -> some View {
        HStack(spacing: 18) {
            stat("dziś", key.usageDaily)
            if key.limitReset == "weekly" || key.limitReset == "monthly" {
                stat(key.limitReset == "weekly" ? "ten tydzień" : "ten miesiąc", key.usageInPeriod)
            }
            stat("łącznie na kluczu", key.usage)
        }
        .help("Wydatki prosto z licznika klucza w OpenRouterze (usage_daily / usage_weekly / usage) — dzień i tydzień w UTC.")
    }

    private func stat(_ label: String, _ amount: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            Text(amount.map(money) ?? "—")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func periodName(_ reset: String?) -> String {
        switch reset {
        case "weekly": return "tydzień"
        case "monthly": return "miesiąc"
        default: return "limit"
        }
    }

    private func money(_ amount: Double) -> String {
        amount < 0.01 && amount > 0 ? "<0.01 $" : "\(Format.decimal(amount, places: 2)) $"
    }
}
