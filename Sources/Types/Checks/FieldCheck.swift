import Canvas

// What the check says of a shape's values, as a value: the answer type every reader shares (the rows,
// the card, the panel, the rule, queries). Its body, the service that keeps it per shape and what a
// problem is made of, is `FieldChecks`'.

/// How bad a problem is: a warning (ranked lowest; an end of a relationship that cannot be read, or is not there),
/// a needed field with no value, or a value that breaks a rule. A row's mark is the worst class at or under it,
/// so a warning never hides a needed mark: it draws nothing on a row, and a mark of `.warning` means nothing
/// worse is there.
public enum FieldClass: Int, Comparable, Sendable {
    case warning = 0, needed = 1, wrong = 2

    /// How the class is said to an agent (`canvas draw`'s and `canvas query`'s `problems`).
    public var word: String {
        switch self {
        case .warning: "warning"
        case .needed: "needed"
        case .wrong: "wrong"
        }
    }

    public static func < (lhs: FieldClass, rhs: FieldClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where in a shape a problem is: a field (the value at a path, or the root for a rule across fields), an end of
/// an arrow that is a relationship, or a row of relationships a note has.
public enum FieldLocus: Hashable, Sendable {
    case field(FieldPath)
    /// An end of the arrow; nil: the arrow is not bound at both ends.
    case end(RelationshipSide?)
    case row(RelationshipRowKey)
}

public struct FieldProblem: Hashable, Sendable {
    /// Always a path `FieldBook.field(at:)` resolves, or the root (a rule across fields, an end, a row).
    public var path: FieldPath
    public var locus: FieldLocus
    public var kind: FieldClass
    /// The validator's, or `required`, `rule`.
    public var keyword: String
    /// The rows' names from the note down: `["line items", "Plate", "quantity"]`.
    public var place: [String]
    /// In words, with the place: `line items › Plate › quantity is 0, and should be at least 1`.
    public var message: String

    public init(path: FieldPath, kind: FieldClass, keyword: String, place: [String], message: String, locus: FieldLocus? = nil) {
        self.path = path
        self.locus = locus ?? .field(path)
        self.kind = kind
        self.keyword = keyword
        self.place = place
        self.message = message
    }
}

extension FieldProblem {
    /// The path of the field it is at; nil for an end or a row.
    public var fieldPath: FieldPath? {
        if case .field(let path) = locus { path } else { nil }
    }

    /// The name of where it is that an agent and Validation read (`field`): a field's name, `from` or `to` for an
    /// end, a row's name. Nil for the root, and for an arrow that is not bound at both ends.
    public var placeName: String? {
        switch locus {
        case .field(let path): path.field
        case .end(let side?): side == .from ? "from" : "to"
        case .end(nil): nil
        case .row: place.first
        }
    }

    /// The JSON pointer into the values, for a field that is not the root; nil for the rest.
    public var pointer: String? {
        if case .field(let path) = locus, !path.isRoot { path.pointer } else { nil }
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
        problems.filter { $0.fieldPath.map(path.isPrefix(of:)) == true }.map(\.kind).max()
    }

    /// The problems exactly at `path`.
    public func problems(at path: FieldPath) -> [FieldProblem] {
        problems.filter { $0.fieldPath == path }
    }

    /// The worst class of the problems at an end of the arrow (`nil`: the arrow not bound at both ends).
    public func endMark(_ side: RelationshipSide?) -> FieldClass? {
        problems.filter { $0.locus == .end(side) }.map(\.kind).max()
    }

    /// The worst class of the problems at a relationship row of a note: what the row shows (amber while a Needed row is empty,
    /// red while an Only one row holds more than one). Nothing a field's path reads.
    public func mark(at row: RelationshipRowKey) -> FieldClass? {
        problems.filter { $0.locus == .row(row) }.map(\.kind).max()
    }

    /// The worst class at either end or at no end: what an arrow's chip shows.
    public var worstEnd: FieldClass? {
        problems.filter { if case .end = $0.locus { true } else { false } }.map(\.kind).max()
    }

    /// Whether an end of the arrow is one its relationship type does not allow.
    public var isMisfit: Bool {
        problems.contains { problem in
            if case .end(.some) = problem.locus { problem.kind == .wrong } else { false }
        }
    }

    /// Without what it says of relationships: the committed part, which a run's answer replaces with the one it makes over its own
    /// graph (`RelationshipIndex.graph(in:)`), since the ends it writes are not committed.
    public func removingRelations() -> FieldCheck {
        FieldCheck(problems: problems.filter { if case .field = $0.locus { true } else { false } })
    }

    /// With `extra` after its own problems (the relationship part, in the order given).
    func merging(_ extra: [FieldProblem]) -> FieldCheck {
        extra.isEmpty ? self : FieldCheck(problems: problems + extra)
    }

    /// Any value that breaks a rule.
    public var isWrong: Bool { problems.contains { $0.kind == .wrong } }
    /// Any needed field with no value.
    public var isIncomplete: Bool { problems.contains { $0.kind == .needed } }
    /// Any warning.
    public var hasWarnings: Bool { problems.contains { $0.kind == .warning } }

    /// Without the problems at or under `path`: a field being typed in.
    public func leaving(out path: FieldPath) -> FieldCheck {
        FieldCheck(problems: problems.filter { $0.fieldPath.map { !path.isPrefix(of: $0) } ?? true })
    }
}
