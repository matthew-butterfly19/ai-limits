import AppKit

/// Cała aplikacja to jeden element w pasku menu i dwa okna — więc i cała
/// powłoka jest AppKitowa, bez `SwiftUI.App`.
///
/// Wcześniej był tu `MenuBarExtra`. Zabrał go pomiar: system stawiał element
/// tej sceny na lewo od notcha (slot 993…1026 przy krawędzi rysowania na
/// 1010), gdzie nie jest rysowany niezależnie od długości tekstu, a
/// `MenuBarExtra` nie daje żadnego sposobu, żeby go stamtąd ruszyć. Własny
/// `NSStatusItem` ma `autosaveName`, a z nim zapisywaną pozycję — patrz
/// `StatusItem`. Widoki zostały te same; zmieniło się tylko to, kto je trzyma.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !yieldToOlderInstance() else { return }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let model = AppModel.shared
            StatusItem.shared.install(model: model)
            model.start()
        }
    }

    /// Kliknięcie w ikonę w Docku. Ta ikona pojawia się tylko wtedy, gdy pasek
    /// menu nie rysuje już nawet samego znaku (patrz `DockIcon`) — czyli
    /// dokładnie wtedy, gdy jest jedynym sposobem, żeby dostać się do liczb.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in AppWindows.showDetail() }
        return true
    }

    /// Two copies of a menu bar app mean two icons and two pollers hitting the
    /// same rate-limited endpoint — which is exactly how the 429s showed up.
    /// The instance that started first keeps the bar; this one steps aside.
    private func yieldToOlderInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != mine.processIdentifier }
        guard !others.isEmpty else { return false }

        let myStart = mine.launchDate ?? Date()
        let anyOlder = others.contains { other in
            guard let theirStart = other.launchDate else {
                return other.processIdentifier < mine.processIdentifier
            }
            return theirStart < myStart
        }
        guard anyOlder else { return false }

        FileHandle.standardError.write(Data("AILimits już działa — zamykam tę kopię\n".utf8))
        NSApp.terminate(nil)
        return true
    }
}
