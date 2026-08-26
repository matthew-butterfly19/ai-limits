import SwiftUI

/// The chart palette, taken as-is from the validated reference set: every
/// adjacent pair clears the colour-vision-deficiency separation target and the
/// normal-vision floor in both light and dark mode. Do not re-step these by eye.
enum Palette {

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Categorical slots, in the fixed order. Never cycled: a ninth series folds
    /// into "inne" rather than inventing a hue.
    static let categorical: [Color] = [
        adaptive(light: "#2a78d6", dark: "#3987e5"),   // 1 blue
        adaptive(light: "#eb6834", dark: "#d95926"),   // 2 orange
        adaptive(light: "#1baf7a", dark: "#199e70"),   // 3 aqua
        adaptive(light: "#eda100", dark: "#c98500"),   // 4 yellow
        adaptive(light: "#e87ba4", dark: "#d55181"),   // 5 magenta
        adaptive(light: "#008300", dark: "#008300"),   // 6 green
        adaptive(light: "#4a3aa7", dark: "#9085e9"),   // 7 violet
        adaptive(light: "#e34948", dark: "#e66767"),   // 8 red
    ]

    static let other = adaptive(light: "#898781", dark: "#898781")

    /// Each app owns the categorical slot it is introduced with.
    static func color(for app: AppKind) -> Color {
        categorical[app == .claude ? 0 : 1]
    }

    /// Status steps are fixed — never themed, never reused for a series. They
    /// always ship with the number beside them, so colour never carries the
    /// meaning on its own.
    static let good     = Color(nsColor: NSColor(hex: "#0ca30c"))
    static let warning  = Color(nsColor: NSColor(hex: "#fab219"))
    static let serious  = Color(nsColor: NSColor(hex: "#ec835a"))
    static let critical = Color(nsColor: NSColor(hex: "#d03b3b"))

    /// Meter colour by how full the window is.
    static func severity(_ percent: Double) -> Color {
        switch percent {
        case ..<70:  return good
        case ..<90:  return warning
        case ..<100: return serious
        default:     return critical
        }
    }

    static let gridline = adaptive(light: "#e1e0d9", dark: "#2c2c2a")
    static let muted    = adaptive(light: "#898781", dark: "#898781")
}

/// Maps a model identifier to a fixed palette slot.
///
/// The slot follows the model, never its current rank — filtering the list must
/// not repaint the models that survive.
struct ModelColors {
    private var slots: [String: Int] = [:]

    init(models: [String]) {
        // Sorted, so the same set of models always yields the same assignment
        // regardless of the order they happen to arrive in.
        for (index, model) in Set(models).sorted().enumerated() {
            slots[model] = index
        }
    }

    var count: Int { slots.count }

    func color(for model: String?) -> Color {
        guard let model, let slot = slots[model] else { return Palette.other }
        return slot < Palette.categorical.count ? Palette.categorical[slot] : Palette.other
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
