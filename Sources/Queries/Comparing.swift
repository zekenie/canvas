import Canvas
import CanvasRPC
import Foundation
import QueryLanguage

// Comparing an attribute's value with a test, as the property's schema types it (§1.8): text as text
// (`i` ignoring case, no diacritics folded), numbers as numbers (one that isn't finite, stored as
// "nan" or "inf", matches no test), dates as instants (a day written alone is the whole UTC day),
// true|false with an absent value its schema's default, and a list by its items. A value that
// isn't there passes only `[a!=v]` (a `:not`), `[a=""]` on text (no value), and `[a]` for a boolean
// that defaults to true.

extension TypedTest {
    /// Whether a property's value passes: `value` as the shape has it, its text read through its
    /// format (nil when the shape has none), and `shape` what the property's schema says it is.
    func holds(_ value: JSONValue?, shape: KindSchema.PropertyShape, names: (ShapeID) -> String? = { _ in nil }) -> Bool {
        if case .path(let path) = comparison { return path.holds(value, names: names) }
        let value = value == .null ? nil : value
        if case .boolean(let fallback) = shape {
            let actual = value?.boolValue ?? fallback
            switch comparison {
            case .present: return actual
            case .equals(.bool(let wanted)): return actual == wanted
            default: return false
            }
        }
        guard let value else { return comparison == .absent }
        switch comparison {
        case .present:
            return Self.saysSomething(value)
        case .absent:
            return value.stringValue?.isEmpty ?? false
        case .hasItem(let item):
            guard case .array(let items) = value else { return false }
            let itemShape: KindSchema.PropertyShape = if case .array(let items) = shape { items } else { .json }
            return items.contains { equal($0, item, shape: itemShape) }
        case .equals(let wanted):
            return equal(value, wanted, shape: shape)
        case .less(let bound), .lessOrEqual(let bound), .greater(let bound), .greaterOrEqual(let bound):
            return ordered(value, bound)
        case .prefix, .suffix, .substring, .word, .dash:
            guard let text = value.stringValue else { return false }
            return holds(text: text)
        case .path:
            return false
        }
    }

    /// Whether a shape's name passes: text, nil for an untitled shape.
    func holds(name: String?) -> Bool {
        guard let name else { return comparison == .absent }
        switch comparison {
        case .present: return !name.isEmpty
        case .absent: return name.isEmpty
        case .equals(.text(let wanted)): return Self.same(name, wanted, ignoringCase: ignoringCase)
        default: return holds(text: name)
        }
    }

    /// `[a]`: something to say. A number or a date says something whatever it is; text, a list or
    /// an object only when it isn't empty.
    static func saysSomething(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let flag): flag
        case .number: true
        case .string(let text): !text.isEmpty
        case .array(let items): !items.isEmpty
        case .object(let members): !members.isEmpty
        }
    }

    // MARK: Text

    /// The text operators, CSS's way: `^=`, `$=` and `*=` with nothing to find match nothing, and so
    /// does `~=` with a word that's empty or has a space in it.
    private func holds(text: String) -> Bool {
        switch comparison {
        case .equals(.text(let wanted)): return Self.same(text, wanted, ignoringCase: ignoringCase)
        case .prefix(let wanted):
            guard !wanted.isEmpty else { return false }
            return ignoringCase ? text.range(of: wanted, options: [.caseInsensitive, .anchored]) != nil : text.hasPrefix(wanted)
        case .suffix(let wanted):
            guard !wanted.isEmpty else { return false }
            return ignoringCase ? text.range(of: wanted, options: [.caseInsensitive, .anchored, .backwards]) != nil : text.hasSuffix(wanted)
        case .substring(let wanted):
            guard !wanted.isEmpty else { return false }
            return text.range(of: wanted, options: ignoringCase ? [.caseInsensitive] : []) != nil
        case .word(let wanted):
            guard !wanted.isEmpty, !wanted.contains(where: \.isWhitespace) else { return false }
            return text.split(whereSeparator: \.isWhitespace).contains { Self.same(String($0), wanted, ignoringCase: ignoringCase) }
        case .dash(let wanted):
            if Self.same(text, wanted, ignoringCase: ignoringCase) { return true }
            let prefix = wanted + "-"
            return ignoringCase ? text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil : text.hasPrefix(prefix)
        default:
            return false
        }
    }

    static func same(_ a: String, _ b: String, ignoringCase: Bool) -> Bool {
        ignoringCase ? a.caseInsensitiveCompare(b) == .orderedSame : a == b
    }

    // MARK: Values

    /// Whether a value is the literal, as the property's type reads both: text as text (with `i`,
    /// any case), numbers as numbers, an instant as the instant or any instant of a day.
    private func equal(_ value: JSONValue, _ wanted: PlanValue, shape: KindSchema.PropertyShape) -> Bool {
        switch wanted {
        case .text(let text):
            guard let actual = value.stringValue else { return false }
            return Self.same(actual, text, ignoringCase: ignoringCase)
        case .number(let number):
            guard let actual = value.numberValue, actual.isFinite else { return false }
            return actual == number
        case .bool(let flag):
            return value.boolValue == flag
        case .day(let start):
            guard let instant = Self.instant(value) else { return false }
            return instant >= start && instant < start.addingTimeInterval(Self.day)
        case .instant(let wanted):
            return Self.instant(value) == wanted
        case .json(let json):
            if ignoringCase, let actual = value.stringValue, let text = json.stringValue {
                return Self.same(actual, text, ignoringCase: true)
            }
            return value == json
        }
    }

    /// `<`, `<=`, `>`, `>=` between numbers, or dates: against a day, before its start, before its
    /// end, from its end, and from its start.
    private func ordered(_ value: JSONValue, _ bound: PlanValue) -> Bool {
        switch bound {
        case .number(let limit):
            guard let actual = value.numberValue, actual.isFinite else { return false }
            return compare(actual, low: limit, high: limit)
        case .day(let start):
            guard let instant = Self.instant(value) else { return false }
            return compare(instant, low: start, high: start.addingTimeInterval(Self.day))
        case .instant(let limit):
            guard let instant = Self.instant(value) else { return false }
            return compare(instant, low: limit, high: limit)
        default:
            return false
        }
    }

    /// `value` against a span from `low` to `high` (a day; a point when they're equal): `<` before
    /// `low`, `<=` before `high` (or at it, for a point), `>` from `high` (past it, for a point),
    /// `>=` from `low`.
    private func compare<T: Comparable>(_ value: T, low: T, high: T) -> Bool {
        let op: Operator? = switch comparison {
        case .less: .less
        case .lessOrEqual: .lessOrEqual
        case .greater: .greater
        case .greaterOrEqual: .greaterOrEqual
        default: nil
        }
        return op.map { Self.ordering($0, value, low: low, high: high) } ?? false
    }

    /// An ordering's rule, for a test of an attribute and for a path's: see the instance's.
    static func ordering<T: Comparable>(_ op: Operator, _ value: T, low: T, high: T) -> Bool {
        let point = low == high
        switch op {
        case .less: return value < low
        case .lessOrEqual: return point ? value <= high : value < high
        case .greater: return point ? value > high : value >= high
        case .greaterOrEqual: return value >= low
        default: return false
        }
    }

    /// A day's length: dates are compared in UTC, where every day has 24 hours.
    static let day: TimeInterval = 86_400

    /// The instant a date property holds (ISO 8601, as a board writes it).
    static func instant(_ value: JSONValue) -> Date? {
        guard let text = value.stringValue else { return nil }
        switch QueryDates.value(of: text) {
        case .instant(let instant)?: return instant
        case .day(let start)?: return start
        default: return nil
        }
    }
}

// MARK: Text as it reads

extension JSONValue {
    /// Whether any string in it, however deep (a list's items, an object's members), passes `test`.
    func containsString(where test: (String) -> Bool) -> Bool {
        switch self {
        case .string(let text): return test(text)
        case .array(let items): return items.contains { $0.containsString(where: test) }
        case .object(let members): return members.values.contains { $0.containsString(where: test) }
        case .null, .bool, .number: return false
        }
    }

    /// Its strings cut at `limit` characters, each with `…` after it; whether any was.
    func cut(at limit: Int) -> (value: JSONValue, cut: Bool) {
        switch self {
        case .string(let text):
            guard text.count > limit else { return (self, false) }
            return (.string(String(text.prefix(limit)) + "…"), true)
        case .array(let items):
            var cut = false
            let shortened = items.map { item -> JSONValue in
                let (value, was) = item.cut(at: limit)
                cut = cut || was
                return value
            }
            return (.array(shortened), cut)
        case .object(let members):
            var cut = false
            let shortened = members.mapValues { member -> JSONValue in
                let (value, was) = member.cut(at: limit)
                cut = cut || was
                return value
            }
            return (.object(shortened), cut)
        case .null, .bool, .number:
            return (self, false)
        }
    }
}
