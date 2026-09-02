import AppKit

/// Ikona w Docku na czas, gdy pasek menu nie chce narysować nawet samego
/// znaku.
///
/// Powód istnienia: macOS nie skraca elementu paska, który się nie mieści —
/// chowa go w całości (patrz `MenuBarFit`). Gdy po prawej stronie ekranu
/// wbudowanego nie zostaje nawet ~47 pt, w pasku nie ma nie tylko liczb, ale
/// też niczego, w co dałoby się kliknąć, żeby otworzyć panel. Dock jest jedynym
/// miejscem, którego żaden inny program nie potrafi zająć, więc to tam trafia
/// awaryjna kopia: ikona z jedną liczbą i kliknięcie otwierające szczegóły.
///
/// Rysowana, a nie wczytywana z zasobu, z dwóch powodów: aplikacja nie ma
/// żadnego pliku ikony (bez tego Dock pokazałby pustą kartkę), a liczba i tak
/// musi się zmieniać co odświeżenie. `dockTile.badgeLabel` odpadł — czerwony
/// bąbel na pustej kartce czyta się jak nieprzeczytana poczta, nie jak stan
/// limitu.
enum DockIcon {
    /// `percent` to liczba do pokazania (np. „44%”), `name` podpis pod nią.
    /// Bez odczytu limitów zostaje sam znak — ikona ma być rozpoznawalna
    /// także wtedy, gdy nie ma jeszcze czego pokazać.
    static func image(name: String?, percent: String?, alarmed: Bool) -> NSImage {
        let side: CGFloat = 512
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 40
            let box = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            let body = NSBezierPath(roundedRect: box, xRadius: 96, yRadius: 96)
            // Ciemne tło zamiast jasnego: w Docku ikona sąsiaduje z ikonami
            // aplikacji, a te są w większości jasne — ciemny prostokąt z jedną
            // liczbą daje się rozpoznać kątem oka.
            (alarmed ? NSColor(calibratedRed: 0.42, green: 0.13, blue: 0.10, alpha: 1)
                     : NSColor(calibratedWhite: 0.13, alpha: 1)).setFill()
            body.fill()
            (alarmed ? NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.30, alpha: 0.9)
                     : NSColor(calibratedWhite: 0.45, alpha: 0.8)).setStroke()
            body.lineWidth = 6
            body.stroke()

            let headline = percent ?? "AI"
            // Rozmiar dobrany do długości: „100%” musi się zmieścić w tej samej
            // szerokości co „7%”, a przeskalowanie po fakcie rozmywa cyfry.
            let size: CGFloat = headline.count >= 4 ? 150 : 190
            let title = NSMutableParagraphStyle()
            title.alignment = .center
            let headlineFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            let baseline = name == nil ? side / 2 - size * 0.38 : side / 2 - size * 0.28
            (headline as NSString).draw(
                in: NSRect(x: inset, y: baseline, width: side - 2 * inset, height: size * 1.3),
                withAttributes: [.font: headlineFont,
                                 .foregroundColor: NSColor.white,
                                 .paragraphStyle: title])
            if let name {
                let caption = NSFont.systemFont(ofSize: 62, weight: .medium)
                (name as NSString).draw(
                    in: NSRect(x: inset, y: inset + 46, width: side - 2 * inset, height: 84),
                    withAttributes: [.font: caption,
                                     .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1),
                                     .paragraphStyle: title])
            }
            return true
        }
    }
}
