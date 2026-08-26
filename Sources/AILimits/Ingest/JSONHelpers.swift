import Foundation

/// Small accessors over `JSONSerialization` output. The logs are heterogeneous
/// and evolve between vendor releases, so decoding into fixed `Codable` structs
/// would break on every new field; dictionary access degrades to nil instead.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func string(_ key: String) -> String? { self[key] as? String }

    /// Numbers arrive as Int, Double or occasionally as a numeric string.
    func int(_ key: String) -> Int? {
        switch self[key] {
        case let v as Int:    return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let v as Double: return v
        case let v as Int:    return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool {
        switch self[key] {
        case let v as Bool: return v
        case let v as Int:  return v != 0
        default: return false
        }
    }
}

enum Timestamps {
    /// Parses the ISO-8601 shapes these logs actually use, without the cost of
    /// `ISO8601DateFormatter` — this runs once per event across tens of
    /// thousands of events per full pass.
    ///
    /// Accepts `YYYY-MM-DDTHH:MM:SS`, optional `.fff`, and an optional `Z` or
    /// `±HH:MM` offset. Falls back to `ISO8601DateFormatter` for anything else.
    static func parse(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let bytes = Array(text.utf8)

        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard index < bytes.count else { return nil }
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[13] == 0x3A, bytes[16] == 0x3A,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return fallback(text) }

        var seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
                      + hour * 3_600 + minute * 60 + second

        // Microseconds are accumulated as an integer and divided **once** at the
        // end. Summing 0.1 + 0.02 + 0.003 instead lands one ULP away, which is
        // invisible in a chart but enough to break a (ts, …) primary key when a
        // second collector writes the same sample.
        var microseconds = 0
        var fractionDigits = 0
        var index = 19
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while index < bytes.count, (48...57).contains(bytes[index]) {
                if fractionDigits < 6 {
                    microseconds = microseconds * 10 + Int(bytes[index]) - 48
                    fractionDigits += 1
                }
                index += 1
            }
            while fractionDigits < 6 { microseconds *= 10; fractionDigits += 1 }
        }

        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            guard let offsetHours = number(index + 1, 2), let offsetMinutes = number(index + 4, 2) else {
                return fallback(text)
            }
            let sign = bytes[index] == 0x2B ? -1 : 1
            seconds -= sign * (offsetHours * 3_600 + offsetMinutes * 60)
        }
        // Anything else (a trailing `Z`, or nothing at all) means UTC, which is
        // what the arithmetic above already assumed.

        return Date(timeIntervalSince1970: Double(seconds * 1_000_000 + microseconds) / 1_000_000)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func fallback(_ text: String) -> Date? {
        isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Days since 1970-01-01 (Howard Hinnant's civil-date algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
