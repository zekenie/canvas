import Canvas
import Foundation

// What typed text is stored as, and how a stored value shows: the one place rows, cards and the panel
// call, so they cannot disagree. Nothing is refused, clamped or changed: what does not fit is stored as
// typed, and the check calls it wrong. Pure; every function takes the locale dates are read and shown
// in, so a test pins one.

public enum FieldText {
    /// What `typed` is stored as in a field of this plain kind. Nil: empty, which clears the field.
    ///
    /// - text: the string as typed (spaces are a value; a line break pasted in is kept).
    /// - number: a number only when it reads back as typed (`9.50` stores 9.5, `12.00` stores 12), else
    ///   the text typed (`02134`, `1e3`, `1.`, `-`, a 17-digit id).
    /// - date: a full date as `2026-03-03` (however it is usually written), else the text typed (a part
    ///   of a date, `Jan 2024`, included).
    /// - date-time: a full date as UTC midnight, `2026-03-03T00:00:00Z`, which a date-time format accepts.
    /// - yes or no: a `Bool`; a choice: the option's value.
    public static func value(from typed: String, as kind: PlainKind, locale: Locale = .autoupdatingCurrent) -> JSONValue? {
        guard !typed.isEmpty else { return nil }
        return reading(typed, as: kind, locale: locale) ?? .string(typed)
    }

    /// How the row shows a stored value: a date `Mar 3, 2026`, a number `9.5`, a choice its label. A
    /// value of another JSON type shows as its own type would (text as typed, a number by its value): the
    /// check is what calls it wrong.
    public static func shown(_ value: JSONValue, as kind: PlainKind, locale: Locale = .autoupdatingCurrent) -> String {
        switch (kind, value) {
        case (.yesNo, .bool(let bool)): return bool ? "yes" : "no"
        case (.choice(let options), _): return options.first { $0.value == value }?.label ?? generic(value)
        case (.date, .string(let text)), (.dateTime, .string(let text)): return shownDate(text, locale: locale) ?? generic(value)
        default: return generic(value)
        }
    }

    /// A date's stored form (`2026-03-03`), nil when `typed` is not a full date: `2026-03-03`,
    /// `Mar 3, 2026`, `March 3, 2026`, `3 Mar 2026`, `3/3/26` (the order by the locale's region; a
    /// two-digit year is 2000 to 2099).
    public static func date(from typed: String, locale: Locale = .autoupdatingCurrent) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40, text.contains(where: \.isNumber) else { return nil }
        if let found = isoDay(text) ?? written(text, locale: locale) ?? numeric(text, locale: locale) {
            return String(format: "%04d-%02d-%02d", found.year, found.month, found.day)
        }
        return nil
    }

    /// A date field whose format says `date-time` stores a full date as UTC midnight: `2026-03-03T00:00:00Z`.
    public static func dateTime(from typed: String, locale: Locale = .autoupdatingCurrent) -> String? {
        date(from: typed, locale: locale).map { $0 + "T00:00:00Z" }
    }

    /// For a field that takes either of two plain kinds: the kinds that are not text are tried in the order
    /// given (yes or no takes `true` or `false`, any case; a choice an option's label; a number and a date
    /// as above), and the first that reads it as more than text is stored; else the text typed.
    public static func value(from typed: String, asOneOf kinds: [PlainKind], locale: Locale = .autoupdatingCurrent) -> JSONValue? {
        guard !typed.isEmpty else { return nil }
        for kind in kinds where kind != .text {
            if let found = reading(typed, as: kind, locale: locale) { return found }
        }
        return .string(typed)
    }

    /// How the row shows a value of a field that takes either of several kinds: as the first of `kinds`
    /// the value's JSON fits (a number for a number, a `Bool` for yes or no, a string that reads as a date
    /// for a date, an option's value for a choice, a string for text); else as its own type shows.
    public static func shown(_ value: JSONValue, asOneOf kinds: [PlainKind], locale: Locale = .autoupdatingCurrent) -> String {
        for kind in kinds where fits(value, kind, locale: locale) {
            return shown(value, as: kind, locale: locale)
        }
        return generic(value)
    }

    // MARK: Reading

    /// What typed text reads as in `kind`, nil when it reads as no more than text.
    private static func reading(_ typed: String, as kind: PlainKind, locale: Locale) -> JSONValue? {
        switch kind {
        case .text: return .string(typed)
        case .number: return number(typed).map { .number($0) }
        case .date: return date(from: typed, locale: locale).map { .string($0) }
        case .dateTime: return dateTime(from: typed, locale: locale).map { .string($0) }
        case .yesNo:
            switch typed.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return nil
            }
        case .choice(let options):
            return (options.first { $0.label == typed } ?? options.first { generic($0.value) == typed })?.value
        }
    }

    private static func fits(_ value: JSONValue, _ kind: PlainKind, locale: Locale) -> Bool {
        switch (kind, value) {
        case (.number, .number), (.yesNo, .bool), (.text, .string): true
        case (.date, .string(let text)), (.dateTime, .string(let text)): storedDay(text) != nil || date(from: text, locale: locale) != nil
        case (.choice(let options), _): options.contains { $0.value == value }
        default: false
        }
    }

    /// A number when `typed` reads back as it was typed: the form is a sign, digits and optionally a point
    /// and more digits, and dropping a leading `+` and trailing zeros after a point leaves what the number
    /// itself prints as. A decimal comma is text.
    private static func number(_ typed: String) -> Double? {
        let characters = Array(typed.unicodeScalars)
        var place = 0
        if place < characters.count, characters[place] == "+" || characters[place] == "-" { place += 1 }
        let whole = place
        while place < characters.count, ("0"..."9").contains(characters[place]) { place += 1 }
        guard place > whole else { return nil }
        if place < characters.count {
            guard characters[place] == "." else { return nil }
            place += 1
            let fraction = place
            while place < characters.count, ("0"..."9").contains(characters[place]) { place += 1 }
            guard place > fraction, place == characters.count else { return nil }
        }
        var canonical = typed
        if canonical.hasPrefix("+") { canonical.removeFirst() }
        if canonical.contains(".") {
            while canonical.hasSuffix("0") { canonical.removeLast() }
            if canonical.hasSuffix(".") { canonical.removeLast() }
        }
        guard let value = Double(typed), value.isFinite, shortest(value) == canonical else { return nil }
        return value
    }

    /// A number as it prints and reads back: a whole one under 2^53 as an integer, else its shortest
    /// decimal, never in an exponent.
    static func shortest(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        let text = "\(value)"
        guard text.contains("e") || text.contains("E") else { return text }
        // A very small or very large number prints with an exponent: written out, as a person types it.
        return Decimal(string: text).map { "\($0)" } ?? text
    }

    // MARK: Dates

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private typealias Day = (year: Int, month: Int, day: Int)

    /// A day that exists: no 30 February.
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Day? {
        guard (1...9999).contains(year), let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day ? (year, month, day) : nil
    }

    /// `2026-03-03`: four digits, two, two.
    private static func isoDay(_ text: String) -> Day? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return Self.day(year, month, day)
    }

    /// What is built once per locale: the formatters that read a written date, the order a numeric one
    /// is in, and the one that shows a stored day. Building a `DateFormatter` costs far more than using one.
    private final class Formats: @unchecked Sendable {
        let written: [DateFormatter]
        let order: [Character]
        let shown: DateFormatter

        init(locale: Locale) {
            func formatter(_ set: (DateFormatter) -> Void) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = FieldText.calendar
                formatter.timeZone = FieldText.calendar.timeZone
                formatter.isLenient = false
                set(formatter)
                return formatter
            }
            written = [
                formatter { $0.dateStyle = .medium; $0.timeStyle = .none },
                formatter { $0.dateStyle = .long; $0.timeStyle = .none },
                formatter { $0.dateFormat = "d MMM yyyy" },
                formatter { $0.dateFormat = "d MMMM yyyy" },
            ]
            let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "M/d/y"
            order = pattern.filter { "yMd".contains($0) }.reduce(into: [Character]()) { if !$0.contains($1) { $0.append($1) } }
            shown = formatter { $0.dateStyle = .medium; $0.timeStyle = .none }
        }
    }

    private static let formatsLock = NSLock()
    nonisolated(unsafe) private static var formatsByLocale: [String: Formats] = [:]

    private static func formats(for locale: Locale) -> Formats {
        formatsLock.lock()
        defer { formatsLock.unlock() }
        if let kept = formatsByLocale[locale.identifier] { return kept }
        let made = Formats(locale: locale)
        formatsByLocale[locale.identifier] = made
        return made
    }

    /// A date written with the month's name: the locale's medium and long styles, and `d MMM yyyy`.
    private static func written(_ text: String, locale: Locale) -> Day? {
        for formatter in formats(for: locale).written {
            if let date = formatter.date(from: text) {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                if let year = parts.year, let month = parts.month, let day = parts.day { return Self.day(year, month, day) }
            }
        }
        return nil
    }

    /// `3/3/26`, `3.3.2026`: three numbers, in the order the locale writes them.
    private static func numeric(_ text: String, locale: Locale) -> Day? {
        let parts = text.split(whereSeparator: { "/.-".contains($0) }).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let order = formats(for: locale).order
        guard order.count == 3 else { return nil }
        var found: [Character: String] = [:]
        for (letter, part) in zip(order, parts) { found[letter] = part }
        guard let year = found["y"].flatMap({ text -> Int? in
            guard text.count == 2 || text.count == 4 else { return nil }
            return Int(text).map { text.count == 2 ? 2000 + $0 : $0 }
        }), let month = found["M"].flatMap({ Int($0) }), let day = found["d"].flatMap({ Int($0) }) else { return nil }
        return Self.day(year, month, day)
    }

    /// The day of a stored date: a stored `yyyy-MM-dd` or UTC midnight; nil for any other text (a time
    /// of day included).
    private static func storedDay(_ stored: String) -> Day? {
        var text = stored
        if text.count > 10 {
            let tail = text.dropFirst(10)
            guard tail.hasPrefix("T00:00:00"), tail.hasSuffix("Z") else { return nil }
            let fraction = tail.dropFirst(9).dropLast()
            guard fraction.isEmpty || (fraction.hasPrefix(".") && fraction.dropFirst().allSatisfy { $0 == "0" }) else { return nil }
            text = String(text.prefix(10))
        }
        return isoDay(text)
    }

    /// A stored date as the row shows it, `Mar 3, 2026`; any other text as stored.
    private static func shownDate(_ stored: String, locale: Locale) -> String? {
        guard let found = storedDay(stored), let date = calendar.date(from: DateComponents(year: found.year, month: found.month, day: found.day)) else { return nil }
        return formats(for: locale).shown.string(from: date)
    }

    // MARK: Showing

    /// A value as its own type shows: text with each line break one space (the stored value keeps them), a
    /// number by its value, a `Bool` as `true` or `false`, anything else as compact JSON.
    private static func generic(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return oneLine(text)
        case .number(let number): return shortest(number)
        case .bool(let bool): return bool ? "true" : "false"
        case .null: return ""
        case .array, .object: return compact(value)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// The JSON of a value on one line, members in key order.
    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
