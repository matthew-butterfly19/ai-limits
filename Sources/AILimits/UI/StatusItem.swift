import AppKit
import Combine
import SwiftUI

/// Element w pasku menu — własny `NSStatusItem`, nie `MenuBarExtra`.
///
/// Powód zamiany jest jeden i zmierzony. `MenuBarExtra` nie daje żadnego
/// uchwytu do elementu, a system ustawiał go **na lewo od notcha**: slot
/// 993…1026 pt przy rysowalnej krawędzi na 1010. Nic się tam nie rysuje i
/// żadne skracanie tego nie ruszy — prawa krawędź slotu jest przybita, więc
/// krótszy tekst przesuwa tylko lewą. Ten sam element z zapisaną pozycją
/// (`NSStatusItem Preferred Position <autosaveName>`) siada na 1419…1477 i
/// jest rysowany. Ta pozycja jest do zapisania tylko dla własnego
/// `NSStatusItem`.
///
/// Pozycję zapisujemy raz, przy pierwszym uruchomieniu. Potem należy do
/// użytkownika: ⌘-przeciągnięcie elementu nadpisuje ten sam klucz i od tej
/// pory to jego wybór obowiązuje.
@MainActor
final class StatusItem {
    static let shared = StatusItem()

    /// Nazwa, pod którą AppKit zapisuje pozycję elementu w `UserDefaults`.
    private static let autosaveName = "ailimits"
    private static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }
    /// Ta sama czcionka, którą `MenuBarFit` mierzy szerokość linii.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Margines dookoła tekstu. `MenuBarExtra` narzucał 37 pt — na belce
    /// laptopa, gdzie całe wolne miejsce to około 57 pt, sam margines nie
    /// pozwalał pokazać nawet dwucyfrowego procentu. Własny element ma jawnie
    /// ustawianą szerokość, więc margines jest tylko taki, żeby liczba nie
    /// dotykała sąsiadów.
    static let margin: CGFloat = 10

    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var titleObserver: AnyCancellable?

    /// Okno przycisku — `MenuBarFit` mierzy na nim slot i pyta window servera,
    /// czy element jest naprawdę narysowany.
    var window: NSWindow? { item?.button?.window }

    func install(model: AppModel) {
        guard item == nil else { return }
        seedPosition()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.button?.font = Self.font
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        apply(model.menuBarTitle)

        titleObserver = model.$menuBarTitle.sink { [weak self] title in
            self?.apply(title)
        }
    }

    /// Szerokość elementu ustawiana wprost, nie `variableLength`: to jedyny
    /// sposób, żeby slot był tylko tak szeroki, jak tekst plus `margin`.
    private func apply(_ title: String) {
        item?.button?.title = title
        item?.length = Self.width(of: title)
    }

    /// Ile miejsca w pasku zajmie ta linia. Jedno miejsce, z którego korzysta i
    /// element, i `MenuBarFit` — inaczej budżet liczyłby co innego, niż pasek
    /// naprawdę rezerwuje.
    static func width(of title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + margin
    }

    /// Pierwsze uruchomienie: postaw element po prawej stronie paska, między
    /// ikonami innych aplikacji. Bez tego system daje mu skrajnie lewe miejsce
    /// w grupie — czyli na tym Macu miejsce pod notchem, gdzie nic nie widać.
    /// Klucz zapisany (przez nas albo przez ⌘-przeciągnięcie) zostaje nietknięty.
    private func seedPosition() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.positionKey) == nil,
              let screen = NSScreen.screens.first else { return }
        defaults.set(Double(screen.frame.maxX - 200), forKey: Self.positionKey)
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        let popover = self.popover ?? makePopover()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // Bez tego panel bywa nieaktywny do pierwszego kliknięcia w niego —
            // pola tekstowe nie łapią klawiatury.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(AppModel.shared))
        self.popover = popover
        return popover
    }
}
