import SwiftUI

struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            // 11 pt rather than the menu bar default — the first lever for a
            // line that does not fit. It is no longer the only one: macOS
            // hides a status item that does not fit rather than truncating it,
            // and 11 pt does not buy nearly enough room, so `MenuBarFit` also
            // picks a shorter rung of `MenuBarTitle.variants` when it has to.
            Text(model.menuBarTitle)
                .font(.system(size: 11))
                .monospacedDigit()
                // Okno szczegółów otwiera `openWindow`, a ten żyje tylko w
                // środowisku SwiftUI — delegat aplikacji (kliknięcie w ikonę w
                // Docku) nie ma do niego dostępu, więc prosi przez
                // powiadomienie. Etykieta paska jest jedynym widokiem, który
                // istnieje przez cały czas działania aplikacji, więc to ona
                // słucha; panel bywa zamknięty, okno szczegółów bywa niestworzone.
                .onReceive(NotificationCenter.default.publisher(for: .aiLimitsShowDetail)) { _ in
                    openWindow(id: DetailWindow.identifier)
                    // Okno powstaje w tej samej pętli, w której o nie prosimy, i
                    // potrafi wylądować za oknem aplikacji, z której przyszło
                    // kliknięcie. Wyciągnięcie go na wierzch musi więc nastąpić
                    // dopiero wtedy, gdy już istnieje.
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first { $0.title == DetailWindow.title }?
                            .makeKeyAndOrderFront(nil)
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window(DetailWindow.title, id: DetailWindow.identifier) {
            DetailWindow()
                .environmentObject(model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 900, height: 680)

        Window("Ustawienia — OpenRouter", id: SettingsWindow.identifier) {
            SettingsWindow()
                .environmentObject(model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 500, height: 380)
    }
}

/// The refresh loop has to start when the app launches, not when the popover is
/// first opened — the menu bar title is the whole point of the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !yieldToOlderInstance() else { return }
        Task { @MainActor in AppModel.shared.start() }
    }

    /// Kliknięcie w ikonę w Docku. Ta ikona pojawia się tylko wtedy, gdy pasek
    /// menu nie rysuje już nawet samego znaku (patrz `DockIcon`) — czyli
    /// dokładnie wtedy, gdy jest jedynym sposobem, żeby dostać się do liczb.
    /// Bez tej metody kliknięcie nie robi nic i awaryjna ikona wygląda na
    /// zepsutą.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .aiLimitsShowDetail, object: nil)
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

extension Notification.Name {
    /// „Pokaż szczegóły” z miejsca, które nie jest widokiem SwiftUI.
    static let aiLimitsShowDetail = Notification.Name("dev.ailimits.showDetail")
}
