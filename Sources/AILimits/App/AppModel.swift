import Foundation
import SwiftUI

/// Everything the UI observes. Owns the store and drives the refresh cycle.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var menuBarTitle = "AI…"
    @Published private(set) var snapshots: [AppKind: LimitsSnapshot] = [:]
    @Published private(set) var windowTotals: [AppKind: TokenTotals] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?

    private var store: Store?

    init() {
        do {
            store = try Store()
        } catch {
            lastError = "\(error)"
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            try ClaudeIngest(store: store).run()
            try CodexIngest(store: store).run()
            windowTotals = try store.totals(since: Calendar.current.startOfDay(for: Date()))
            lastRefresh = Date()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        menuBarTitle = MenuBarTitle.render(snapshots: snapshots, totals: windowTotals)
    }
}
