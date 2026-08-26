import Foundation

/// Number and time formatting shared by the menu bar title, the popover and the
/// detail window, so the same value never renders two ways.
enum Format {

    static let windowNames: [Int: String] = [
        60: "1h", 300: "5h", 1440: "24h", 10080: "7d", 43200: "30d",
    ]

    static func windowName(_ minutes: Int) -> String {
        if let name = windowNames[minutes] { return name }
        return minutes > 0 ? "\(minutes)min" : "?"
    }

    /// 1 234 567 → "1.2M". Short enough for the menu bar.
    static func tokens(_ count: Int) -> String {
        let value = max(count, 0)
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 10_000_000 { return String(format: "%.0fM", Double(value) / 1_000_000) }
        if value >= 1_000_000  { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000      { return String(format: "%.0fk", Double(value) / 1_000) }
        return String(value)
    }

    /// 1 234 567 → "1 234 567", for tooltips and tables where space allows.
    static func tokensFull(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{00A0}"
        return formatter.string(from: NSNumber(value: max(count, 0))) ?? String(count)
    }

    /// Time remaining, in the shortest form that stays unambiguous.
    static func timeLeft(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "?" }
        let total = Int(seconds)
        if total <= 0 { return "teraz" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0  { return "\(days)d\(hours)h" }
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        return "\(minutes)m"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func project(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (trimmed as NSString).lastPathComponent
    }

    /// Model identifiers are long and versioned; the UI wants the family.
    static func model(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "—" }
        var name = identifier
        for prefix in ["anthropic/", "openai/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        // claude-opus-4-1-20250805 → opus-4-1 ; gpt-5-codex → gpt-5-codex
        if name.hasPrefix("claude-") {
            let parts = name.dropFirst("claude-".count).split(separator: "-")
            let meaningful = parts.prefix { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
            return meaningful.joined(separator: "-")
        }
        return name
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()

    static func when(_ date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) { return "dziś \(clock.string(from: date))" }
        return dayClock.string(from: date)
    }

    static let dayNames = ["poniedziałek", "wtorek", "środa", "czwartek",
                           "piątek", "sobota", "niedziela"]

    /// "Wtorek 15:00" — DateFormatter with the C locale would render English.
    static func dayHour(_ date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)   // 1 = Sunday
        let index = (weekday + 5) % 7                                    // 0 = Monday
        let hour = Calendar.current.component(.hour, from: date)
        return "\(dayNames[index].capitalized) \(String(format: "%02d:00", hour))"
    }
}
