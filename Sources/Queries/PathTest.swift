import Canvas
import CanvasRPC
import Foundation
import QueryLanguage

// `[a.b.c]`: a test of what's inside an object attribute, at the members the path names. Untyped:
// a schema can't say what's there (an object's members are whatever the shape holds), so each test
// is typed by the JSON value found, shape by shape, and the literal read as that value takes it:
// text on a string (`i` ignoring case; the text operators, `~=` a word), a number on a number
// (`=` and the orderings, when the literal is one), a date on a date string (the orderings, when the
// literal reads as a date), `true` or `false` on a boolean. A list met on the way, or at the end, is
// searched: a test holds when it holds for any item. A value of another sort, or none (a member that
// isn't there, a path through something that isn't an object or a list, null), matches no test but
// `[a=""]`, which passes when nothing found says anything, and `[a!=v]`, which is `:not` of the test.

/// A path test, resolved: the members, the operator (nil for `[a.b]`, never `!=`: its node is a
/// `:not` of `=`) and the literal as written, with what it reads as when it's a number or a
/// boolean.
struct PathTest: Sendable, Equatable {
    /// The members inside the attribute's value, in order. At least one.
    let members: [String]
    let op: Operator?
    let literal: String
    /// The `i` flag.
    let ignoringCase: Bool
    /// The literal as a finite decimal number, when it is one.
    let number: Double?
    /// The literal as `true` or `false`, when it is one.
    let flag: Bool?
    /// The literal as a date (a day, or an instant), when it is one and no number: an ordering
    /// compares these.
    let date: PlanValue?

    init(members: [String], op: Operator?, literal: String, ignoringCase: Bool) {
        self.members = members
        self.op = op == .notEquals ? .equals : op
        self.literal = literal
        self.ignoringCase = ignoringCase
        number = Self.number(literal)
        flag = Bool(literal)
        date = Self.number(literal) == nil ? QueryDates.value(of: literal) : nil
    }

    /// A finite number written in decimal (`3`, `-2.5`, `1e3`), not hex, `nan` or `inf`.
    static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// The values at the members inside `root` (the attribute's value): a list met at any step, or
    /// at the end, gives each of its items (lists in lists too), so a path goes into a list and a
    /// test holds when any item does. `inList` is whether one came out of a list. None where there
    /// is nothing: a step that isn't an object or lacks the member, null.
    func reached(in root: JSONValue?) -> [(value: JSONValue, inList: Bool)] {
        var found: [(value: JSONValue, inList: Bool)] = []
        func walk(_ value: JSONValue?, _ step: Int, _ inList: Bool) {
            switch value {
            case .array(let items)?:
                for item in items { walk(item, step, true) }
            case .object(let object)? where step < members.count:
                walk(object[members[step]], step + 1, inList)
            case .null?, nil:
                break
            case let value?:
                if step == members.count { found.append((value, inList)) }
            }
        }
        walk(root, 0, false)
        return found
    }

    /// Whether the shape's attribute passes: any value reached passes, and `[a.b=""]` when none
    /// says anything.
    func holds(_ root: JSONValue?) -> Bool {
        let values = reached(in: root)
        guard let op else { return values.contains { TypedTest.saysSomething($0.value) } }
        switch op {
        case .equals, .notEquals:
            if literal.isEmpty { return !values.contains { TypedTest.saysSomething($0.value) } }
            return values.contains { equals($0.value) }
        case .hasWord:
            return values.contains { reached in
                switch reached.value {
                case .string: text(reached.value)
                case .number, .bool: reached.inList && equals(reached.value)
                default: false
                }
            }
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            if let number {
                return values.contains { reached in
                    guard case .number(let actual) = reached.value, actual.isFinite else { return false }
                    return TypedTest.ordering(op, actual, low: number, high: number)
                }
            }
            guard let date else { return false }
            return values.contains { ordered($0.value, by: op, date) }
        case .startsWith, .endsWith, .contains, .dashMatch:
            return values.contains { text($0.value) }
        }
    }

    /// A stored date or date-time against a date literal: a day is its whole UTC day, as a date
    /// attribute's is. A string that is no date matches no ordering.
    private func ordered(_ value: JSONValue, by op: Operator, _ bound: PlanValue) -> Bool {
        guard let instant = TypedTest.instant(value) else { return false }
        switch bound {
        case .day(let start): return TypedTest.ordering(op, instant, low: start, high: start.addingTimeInterval(TypedTest.day))
        case .instant(let limit): return TypedTest.ordering(op, instant, low: limit, high: limit)
        default: return false
        }
    }

    /// A scalar is the literal, as its sort reads it.
    private func equals(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let actual): TypedTest.same(actual, literal, ignoringCase: ignoringCase)
        case .number(let actual): number.map { actual.isFinite && actual == $0 } ?? false
        case .bool(let actual): flag == actual
        case .null, .array, .object: false
        }
    }

    /// A string passes the text operator, as an attribute's text does.
    private func text(_ value: JSONValue?) -> Bool {
        guard case .string? = value, let op else { return false }
        return TypedTest(comparison: op.textComparison(literal), ignoringCase: ignoringCase).holds(value, shape: .json)
    }

    var planDescription: String {
        let at = "at " + members.joined(separator: ".") + ": "
        guard let op else { return at + "present" }
        let flag = ignoringCase ? " ignoring case" : ""
        let written = quotedForPlan(literal)
        let what: String = switch op {
        case .equals, .notEquals: literal.isEmpty ? "absent or empty" : "= \(written)\(flag)"
        case .startsWith: "starts with \(written)\(flag)"
        case .endsWith: "ends with \(written)\(flag)"
        case .contains: "holds \(written)\(flag)"
        case .hasWord: "has the word or item \(written)\(flag)"
        case .dashMatch: "is or starts \(quotedForPlan(literal + "-"))\(flag)"
        case .less: "< \(literal)"
        case .lessOrEqual: "<= \(literal)"
        case .greater: "> \(literal)"
        case .greaterOrEqual: ">= \(literal)"
        }
        return at + what
    }
}
