import SwiftUI

struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            // 11 pt rather than the menu bar default: the agreed lever for a
            // line that does not fit is type size, not dropping content.
            Text(model.menuBarTitle)
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Window("AI Limits — szczegóły", id: DetailWindow.identifier) {
            DetailWindow()
                .environmentObject(model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 900, height: 680)
    }
}

/// The refresh loop has to start when the app launches, not when the popover is
/// first opened — the menu bar title is the whole point of the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !yieldToOlderInstance() else { return }
        Task { @MainActor in AppModel.shared.start() }
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
