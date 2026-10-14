import Canvas

// The title from a field: a type's `"$title": {"x-canvas-from": "name"}` says which field titles a note that
// is one. Pure: it reads a chain's resolution (`Resolved`) and nothing else, so the writer, the pill's look
// and the type's own check ask the same question and get the same answer.

/// Which field titles a note that is one: the chain's `title` directive, resolved.
public struct TitleSource: Equatable, Sendable {
    /// The field's key.
    public var key: String
    /// Text, a date, a date-time, a number or a choice.
    public var kind: PlainKind
    /// The type whose `$title` won (`Resolved.Directive.source`).
    public var type: ShapeID

    public init(key: String, kind: PlainKind, type: ShapeID) {
        self.key = key
        self.kind = kind
        self.type = type
    }

    /// The directive's name and the member that names the field.
    public static let directive = "title", from = "x-canvas-from"

    /// The plain kind a field of this kind titles by; nil for one that can't title: a yes or no (a name is
    /// never "yes"), and everything that is not plain (a list, a group, another type's fields,
    /// pairs, an either even of two plain kinds, what no control suits).
    public static func titles(_ kind: FieldKind) -> PlainKind? {
        guard case .plain(let plain) = kind, plain != .yesNo else { return nil }
        return plain
    }

    /// nil: no `$title`, or it names no field, or a field that can't title. A `$title` that is no object, or
    /// has no `x-canvas-from` string, names none; so does a name only a rule or `patternProperties` gives.
    public static func of(_ resolved: Resolved) -> TitleSource? {
        guard let directive = resolved.directives.first(where: { $0.name == Self.directive }) else { return nil }
        switch reading(directive, in: resolved) {
        case .works(let source): return source
        case .fails: return nil
        }
    }

    /// Why `of` is nil though `type` itself wrote a `$title`; nil when it wrote none (an inherited one is
    /// the type that wrote it's), or it works.
    public static func problem(_ resolved: Resolved, writtenBy type: ShapeID) -> TitleSourceProblem? {
        guard let directive = resolved.directives.first(where: { $0.name == Self.directive }), directive.source == type else { return nil }
        switch reading(directive, in: resolved) {
        case .works: return nil
        case .fails(let problem): return problem
        }
    }

    private enum Reading {
        case works(TitleSource), fails(TitleSourceProblem)
    }

    private static func reading(_ directive: Resolved.Directive, in resolved: Resolved) -> Reading {
        guard let key = directive.value[from]?.string else { return .fails(.namesNothing) }
        guard let field = resolved.field(named: key) else { return .fails(.noField(key)) }
        guard let kind = titles(FieldKindReader.kind(of: field.field)) else { return .fails(.cannotTitle(key)) }
        return .works(TitleSource(key: key, kind: kind, type: directive.source))
    }
}

/// What is wrong with a `$title`, for the words on the type that wrote it.
public enum TitleSourceProblem: Equatable, Sendable {
    /// No `x-canvas-from`, or not a string.
    case namesNothing
    /// It names a field the type has none of.
    case noField(String)
    /// It names a field that is not text, a number, a date or a choice.
    case cannotTitle(String)
}
