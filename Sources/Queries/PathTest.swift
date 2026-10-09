import Canvas
import Foundation
import QueryLanguage

// `[a.b.c]`: a test of what's inside an object attribute, at the members the path names. Untyped:
// a schema can't say what's there (an object's members are whatever the shape holds), so each test
// is typed by the JSON value found, shape by shape, and the literal read as that value takes it:
// text on a string (`i` ignoring case; the text operators, `~=` a word), a number on a number
// (`=` and the orderings, when the literal is one), `true` or `false` on a boolean, `~=` an item on
// an array. A value of another sort, or none (a member that isn't there, a path through something
// that isn't an object, null), matches no test but `[a=""]`, which a missing member passes as an
// absent text does, and `[a!=v]`, which is `:not` of the test.

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

    init(members: [String], op: Operator?, literal: String, ignoringCase: Bool) {
        self.members = members
        self.op = op == .notEquals ? .equals : op
        self.literal = literal
        self.ignoringCase = ignoringCase
        number = Self.number(literal)
        flag = Bool(literal)
    }

    /// A finite number written in decimal (`3`, `-2.5`, `1e3`), not hex, `nan` or `inf`.
    static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// The value at the members inside `root` (the attribute's value); nil where there is none: a
    /// step that isn't an object or lacks the member, or null.
    func found(in root: JSONValue?) -> JSONValue? {
        var value = root
        for member in members {
            guard case .object(let object)? = value, let next = object[member] else { return nil }
            value = next
        }
        return value == .null ? nil : value
    }

    /// Whether the shape's attribute passes.
    func holds(_ root: JSONValue?) -> Bool {
        let value = found(in: root)
        guard let op else { return value.map(TypedTest.saysSomething) ?? false }
        switch op {
        case .equals, .notEquals:
            // No value: absent or empty text.
            if literal.isEmpty { return value == nil || value == .string("") }
            return value.map(equals) ?? false
        case .hasWord:
            switch value {
            case .array(let items)?: return items.contains(where: equals)
            case .string?: return text(value)
            default: return false
            }
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            guard let number, case .number(let actual)? = value, actual.isFinite else { return false }
            switch op {
            case .less: return actual < number
            case .lessOrEqual: return actual <= number
            case .greater: return actual > number
            default: return actual >= number
            }
        case .startsWith, .endsWith, .contains, .dashMatch:
            return text(value)
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
