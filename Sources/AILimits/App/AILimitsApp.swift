import SwiftUI

struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

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
                .onAppear { delegate.activate() }
        }
        .defaultSize(width: 900, height: 680)
    }

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.pendingModel = model
    }
}

/// The refresh loop has to start when the app launches, not when the popover is
/// first opened — the menu bar title is the whole point of the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppDelegate.pendingModel?.start() }
    }

    /// `LSUIElement` apps open windows behind everything else unless asked.
    func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
