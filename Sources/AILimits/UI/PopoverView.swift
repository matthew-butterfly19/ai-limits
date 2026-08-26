import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Limits").font(.headline)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ForEach(AppKind.allCases, id: \.self) { app in
                if let totals = model.windowTotals[app] {
                    Text("\(app.display): \(Format.tokens(totals.total))")
                }
            }
            Divider()
            Button("Odśwież") { Task { await model.refresh() } }
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.refresh() }
    }
}
