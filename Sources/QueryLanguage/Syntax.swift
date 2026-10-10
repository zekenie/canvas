import Foundation

// The tree a query reads into. Every type is Equatable by synthesis, spans included, so a tree
// compares whole: the printer's canonical form reads back to the tree it was printed from
// (`SelectorList(parsing: list.canonical) == list` for any list read from its own canonical form).

/// A query, read: complex selectors joined by commas. It matches what any of them matches (OR),
/// each shape once.
public struct SelectorList: Sendable, Equatable {
    public var selectors: [ComplexSelector]

    public init(_ selectors: [ComplexSelector]) {
        self.selectors = selectors
    }
}

/// Compounds joined by combinators, `"Payments" > card[rank>3]`. Its subject is the last compound,
/// as in CSS: what it matches is what the selector answers with; the compounds before it say what
/// the subject is inside.
public struct ComplexSelector: Sendable, Equatable {
    /// At least one.
    public var compounds: [Compound]
    /// One fewer than the compounds: `combinators[i]` joins `compounds[i]` to `compounds[i + 1]`.
    public var combinators: [Combinator]
    public var span: QuerySpan

    public init(compounds: [Compound], combinators: [Combinator] = [], span: QuerySpan) {
        self.compounds = compounds
        self.combinators = combinators
        self.span = span
    }
}

/// How a compound stands to the one before it.
public enum Combinator: Sendable, Equatable {
    /// `A B`: inside what A matches, at any depth.
    case descendant
    /// `A > B`: directly inside what A matches.
    case child
}

/// One shape's conditions, all of which it meets: at most one head, first, then filters. Never
/// empty: a compound with no head has a filter.
public struct Compound: Sendable, Equatable {
    public var head: Head?
    public var filters: [Filter]
    public var span: QuerySpan

    public init(head: Head? = nil, filters: [Filter] = [], span: QuerySpan) {
        self.head = head
        self.filters = filters
        self.span = span
    }
}

/// What a compound names first: a kind, every shape, a title, a kind and a title, or an id.
public enum Head: Sendable, Equatable {
    /// `card`: an identifier, exactly as written (kinds are ids, so case counts).
    case kind(String, QuerySpan)
    /// `*`.
    case any
    /// `"Payments"`: the title as written, escapes undone. Never blank.
    case title(String, QuerySpan)
    /// `card"Payments"`: a kind with a title right after it, no space between (as CSS writes
    /// `div#id`), the shapes of that kind with that title: the kind and the title as `kind` and
    /// `title` hold them, each where it is.
    case kindTitle(String, QuerySpan, title: String, QuerySpan)
    /// `#7C1E2A04-…`: the span holds the `#`.
    case id(UUID, QuerySpan)
}

/// A condition after the head.
public enum Filter: Sendable, Equatable {
    case attribute(AttributeTest)
    case pseudo(PseudoClass)
}

/// `[name]`, `[name op value]` or `[name op value i]`: a test of an attribute, typed later by its
/// property's schema. `[name]` alone has no operator, value or flag; the rest have an operator and a
/// value, and maybe a flag. `[name.a.b]` tests what is found at `a`, then `b`, inside the
/// attribute's object: typed later by the value found there, not by a schema.
public struct AttributeTest: Sendable, Equatable {
    /// As written, or as quoted (`["my attr"]`), escapes undone. The attribute itself; with a
    /// `path`, the one whose object the path goes into.
    public var name: String
    /// The members inside the attribute's value, in order: `["a", "b"]` for `[name.a.b]`. Each is an
    /// identifier (a letter or `_`, then letters, digits, `-` and `_`), and only an unquoted name
    /// has any. Empty for the attribute alone.
    public var path: [String]
    public var op: Operator?
    public var value: Literal?
    public var flag: CaseFlag?
    /// From `[` to `]`.
    public var span: QuerySpan

    public init(name: String, path: [String] = [], op: Operator? = nil, value: Literal? = nil, flag: CaseFlag? = nil, span: QuerySpan) {
        self.name = name
        self.path = path
        self.op = op
        self.value = value
        self.flag = flag
        self.span = span
    }
}

/// CSS's attribute operators, and jQuery's `!=`.
public enum Operator: String, Sendable, CaseIterable {
    case equals = "="
    case notEquals = "!="
    case startsWith = "^="
    case endsWith = "$="
    case contains = "*="
    case hasWord = "~="
    case dashMatch = "|="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
}

/// `i` or `s` after a value: compare ignoring case, or with it (the default).
public enum CaseFlag: String, Sendable, CaseIterable {
    case insensitive = "i"
    case sensitive = "s"
}

/// A value in an attribute test, as written: typed by the property it's compared with, so
/// `[rank=3]` and `[rank="3"]` read alike.
public enum Literal: Sendable, Equatable {
    /// A run of characters other than whitespace, `]` and quotes: `3`, `2026-10-01`, `done`.
    case bare(String)
    /// `"…"` or `'…'`, escapes undone.
    case quoted(String)

    /// The text either way.
    public var text: String {
        switch self {
        case .bare(let text), .quoted(let text): text
        }
    }
}

/// `:name` or `:name(argument)`.
public struct PseudoClass: Sendable, Equatable {
    /// Lowercased (ASCII), without the colon.
    public var name: String
    public var argument: PseudoArgument
    /// From the colon to the closing parenthesis, or the end of the name.
    public var span: QuerySpan
    /// The colon and the name.
    public var nameSpan: QuerySpan

    public init(name: String, argument: PseudoArgument = .none, span: QuerySpan, nameSpan: QuerySpan) {
        self.name = name
        self.argument = argument
        self.span = span
        self.nameSpan = nameSpan
    }

    /// The language's own word, if it's one.
    public var word: Word? { Word(rawValue: name) }
}

/// A pseudo-class's argument, read by its word's signature (`Word.signature`).
public enum PseudoArgument: Sendable, Equatable {
    /// No parentheses.
    case none
    /// `:not`, `:is`, `:where`, `:inside`: commas are OR.
    case selectors(SelectorList)
    /// `:has`: its items, commas OR.
    case has([HasItem])
    /// The edge words: one anchor, or `:between`'s two, then the edge types after a comma (nil
    /// without; never empty).
    case anchored([ComplexSelector], types: [TypeTerm]?)
    /// `:dangling(…)`: never empty.
    case types([TypeTerm])
    /// `:contains("…")`: never empty.
    case text(String)
    /// A word the language doesn't know: the text between its parentheses as written (possibly
    /// empty), and where that is. It ends where it ends as shapes when it reads so (`[text*=:)]`
    /// holds a parenthesis), else at the `)` that balances its `(`. Resolution decides: a plugin's
    /// relation reads it as selectors (`SelectorList(argumentOf:)`), and anything else is refused.
    case raw(String, QuerySpan)
}

/// An edge type in a type list: `T`, or `only T` for the type alone, without those under it.
public struct TypeTerm: Sendable, Equatable {
    /// As written (edge types are ids, so case counts).
    public var name: String
    public var only: Bool
    /// From `only`, or the name, to the name's end.
    public var span: QuerySpan

    public init(name: String, only: Bool = false, span: QuerySpan) {
        self.name = name
        self.only = only
        self.span = span
    }
}

/// One item of `:has(…)`: `> S`, a shape directly inside the subject, or `S`, one inside it at any
/// depth. (A struct, since tuples aren't Equatable.)
public struct HasItem: Sendable, Equatable {
    public var child: Bool
    public var compound: Compound

    public init(child: Bool = false, compound: Compound) {
        self.child = child
        self.compound = compound
    }
}

/// Where something is in the query as sent: an offset from its start and a length, both in
/// Characters (grapheme clusters). Not `Span`, the standard library's.
public struct QuerySpan: Sendable, Equatable {
    public var offset: Int
    public var length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    /// Just past its last character.
    public var end: Int { offset + length }
}
