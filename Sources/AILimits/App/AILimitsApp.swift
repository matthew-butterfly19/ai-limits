import SwiftUI

struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.menuBarTitle).monospacedDigit()
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
        Task { @MainActor in AppModel.shared.start() }
    }
}
