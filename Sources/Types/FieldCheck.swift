import Canvas

// What the check says of a shape's values, as a value: the answer type every reader shares (the rows,
// the card, the panel, the rule, queries). Its body, the service that keeps it per shape and what a
// problem is made of, is `FieldChecks`'.

/// How bad a problem is: a needed field with no value, or a value that breaks a rule.
public enum FieldClass: Int, Comparable, Sendable {
    case needed = 1, wrong = 2

    public static func < (lhs: FieldClass, rhs: FieldClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct FieldProblem: Hashable, Sendable {
    /// Always a path `FieldBook.field(at:)` resolves, or the root (a rule across fields).
    public var path: FieldPath
    public var kind: FieldClass
    /// The validator's, or `required`, `rule`.
    public var keyword: String
    /// The rows' names from the note down: `["line items", "Plate", "quantity"]`.
    public var place: [String]
    /// In words, with the place: `line items › Plate › quantity must be at least 1`.
    public var message: String

    public init(path: FieldPath, kind: FieldClass, keyword: String, place: [String], message: String) {
        self.path = path
        self.kind = kind
        self.keyword = keyword
        self.place = place
        self.message = message
    }
}

public struct FieldCheck: Equatable, Sendable {
    /// In row order, then by path.
    public var problems: [FieldProblem]

    public init(problems: [FieldProblem] = []) {
        self.problems = problems
    }

    public static let clean = FieldCheck()

    /// The worst class at `path` or anywhere under it: what a row shows (a row above a wrong cell is wrong).
    public func mark(at path: FieldPath) -> FieldClass? {
        problems.filter { path.isPrefix(of: $0.path) }.map(\.kind).max()
    }

    /// The problems exactly at `path`.
    public func problems(at path: FieldPath) -> [FieldProblem] {
        problems.filter { $0.path == path }
    }

    /// Any value that breaks a rule.
    public var isWrong: Bool { problems.contains { $0.kind == .wrong } }
    /// Any needed field with no value.
    public var isIncomplete: Bool { problems.contains { $0.kind == .needed } }

    /// Without the problems at or under `path`: a field being typed in.
    public func leaving(out path: FieldPath) -> FieldCheck {
        FieldCheck(problems: problems.filter { !path.isPrefix(of: $0.path) })
    }
}
