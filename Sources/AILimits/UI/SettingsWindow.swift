import SwiftUI

/// Ustawienia OpenRoutera: management key + wybór klucza Harnessa.
struct SettingsWindow: View {
    static let identifier = "ailimits-settings"
    static let title = "Ustawienia — OpenRouter"

    @EnvironmentObject private var model: AppModel
    @State private var keyInput = ""
    @State private var showKeyInput = false
    @State private var keyError: String?
    @State private var isSaving = false
    /// Lokalna kopia wybranego hasha — synchronizowana z modelem przy zmianie.
    @State private var localSelectedHash = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenRouter — klucz zarządzania")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            Aby wyświetlić realne koszty Harnessa (dsh), potrzebny jest management key \
            z OpenRoutera — osobny typ klucza, nie ten sam, którym dsh wykonuje zapytania.
            """)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if model.openRouterKeyConfigured {
                keyConfiguredView
            } else {
                keyMissingView
            }

            if let error = model.openRouterError ?? keyError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.serious)
            }

            if model.openRouterKeyConfigured {
                Divider()
                keySelectionView
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 380)
        .background(Palette.surface)
        .onAppear {
            localSelectedHash = model.openRouterSelectedHash ?? ""
            if model.openRouterKeyConfigured, model.openRouterKeys.isEmpty {
                Task { await model.refreshOpenRouterKeys() }
            }
        }
    }

    // MARK: - key configured

    private var keyConfiguredView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.good)
                Text("Klucz management skonfigurowany")
                    .font(.system(size: 12))
                Spacer()
                if showKeyInput {
                    Button("Anuluj") { showKeyInput = false; keyError = nil }
                        .font(.system(size: 12))
                } else {
                    Button("Zmień klucz") { showKeyInput = true }
                        .font(.system(size: 12))
                    Button("Usuń klucz", role: .destructive) {
                        try? model.deleteOpenRouterKey()
                    }
                    .font(.system(size: 12))
                }
            }
            if showKeyInput {
                keyEntryField
            }
        }
    }

    private var keyMissingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Management key nie jest ustawiony")
                .font(.system(size: 12))
            Link("openrouter.ai/settings/management-keys",
                 destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                .font(.system(size: 12))
            keyEntryField
        }
    }

    private var keyEntryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Wklej management key", text: $keyInput)
                .font(.system(size: 12))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Zapisz") { saveKey() }
                    .font(.system(size: 12))
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                if isSaving { ProgressView().controlSize(.small).scaleEffect(0.5) }
            }
        }
    }

    // MARK: - key selection

    @ViewBuilder private var keySelectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Który klucz API to Harness?")
                .font(.system(size: 12, weight: .semibold))
            Text("""
            Wybierz z listy zwykły klucz API (nie management key), \
            którego dsh używa do zapytań. Koszty będą filtrowane tylko do niego.
            """)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if model.openRouterKeys.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                    Text("Pobieranie listy kluczy…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Odśwież") {
                        Task { await model.refreshOpenRouterKeys(force: true) }
                    }
                    .font(.system(size: 12))
                }
            } else {
                Picker("Klucz Harnessa", selection: $localSelectedHash) {
                    Text("— wybierz —").tag("")
                    ForEach(model.openRouterKeys, id: \.hash) { key in
                        // `label` w odpowiedzi OpenRoutera to zamaskowana wartość
                        // klucza ("sk-or-v1-abc...123"), nie nazwa — `name` to
                        // nazwa, którą użytkownik nadał kluczowi. Pokazujemy oba,
                        // tak jak w ich własnym dashboardzie: nazwa, potem maska.
                        let masked = key.label ?? key.hash.prefix(12).description
                        let text = key.name.map { "\($0) — \(masked)" } ?? masked
                        Text(text).tag(key.hash)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
                .onChange(of: localSelectedHash) { _, hash in
                    guard !hash.isEmpty else { return }
                    model.selectOpenRouterKey(hash: hash)
                }
            }
        }
    }

    // MARK: - actions

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        keyError = nil
        do {
            try model.saveOpenRouterKey(trimmed)
            keyInput = ""
            showKeyInput = false
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        isSaving = false
    }
}