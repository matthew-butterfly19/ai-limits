import AppKit
import SwiftUI

/// Okna aplikacji — szczegóły i ustawienia — trzymane po stronie AppKitu.
///
/// Wcześniej były scenami `Window` SwiftUI, otwieranymi przez `openWindow` ze
/// środowiska widoku. Razem z `MenuBarExtra` zniknęło to środowisko: panel
/// mieszka teraz w `NSPopover`, a ten nie jest sceną, więc `openWindow` nie ma
/// tam czego otworzyć. Własne `NSWindow` są przy okazji przewidywalniejsze —
/// wiadomo, kiedy powstają i co jest na wierzchu.
///
/// `setFrameAutosaveName` używa **tych samych nazw**, co poprzednie sceny
/// (`ailimits-detail`, `ailimits-settings`), więc zapamiętane rozmiary i
/// pozycje okien przechodzą bez zmian.
@MainActor
enum AppWindows {
    private static var detail: NSWindow?
    private static var settings: NSWindow?

    static func showDetail() {
        if detail == nil {
            detail = make(title: DetailWindow.title,
                          autosave: DetailWindow.identifier,
                          size: NSSize(width: 1000, height: 680),
                          content: DetailWindow().environmentObject(AppModel.shared))
        }
        raise(detail)
    }

    static func showSettings() {
        if settings == nil {
            settings = make(title: SettingsWindow.title,
                            autosave: SettingsWindow.identifier,
                            size: NSSize(width: 500, height: 380),
                            content: SettingsWindow().environmentObject(AppModel.shared))
        }
        raise(settings)
    }

    private static func make(title: String, autosave: String, size: NSSize,
                             content: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(autosave)
        if !window.setFrameUsingName(autosave) { window.center() }
        return window
    }

    private static func raise(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
