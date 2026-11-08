import AppKit
import Canvas

// A row's card, as its kind gives it: what more a row holds than its line says (a column's on delete, an endpoint's
// responses), a line each, under a header that names the row. ⌘↓ in a row shows it, hung from the row (the Card part's view
// in a core card). The kind says what each line is: words typed in a grammar of its own (`field`), on or off (`toggle`), one
// of several (`choice`), or a list of lines (`list`, Return opening one below); each reads the row and writes it back, and a
// line left commits the row as a row's line does, one step the kind names by what changed. The card holds no step.

/// What heads a row's card: the row's name and its gutter's mark.
public struct LineCardHeader: Equatable {
    public var name: String
    public var mark: LineMark?

    public init(name: String, mark: LineMark? = nil) {
        self.name = name
        self.mark = mark
    }
}

/// A row's card: its header and its lines, in order.
@MainActor
public struct LineCard<Row> {
    public var header: LineCardHeader
    public var lines: [LineCardLine<Row>]
    /// How wide it is (view points), where the kind's values are longer than the usual card's (an endpoint's summary); nil for
    /// the usual.
    public var width: CGFloat?

    public init(header: LineCardHeader, lines: [LineCardLine<Row>], width: CGFloat? = nil) {
        self.header = header
        self.lines = lines
        self.width = width
    }
}

/// One line of a row's card: its label and what it holds of the row.
@MainActor
public struct LineCardLine<Row> {
    /// What it's called: "type", "on delete".
    public let label: String
    let kind: Kind

    enum Kind {
        case text(LineCardText<Row>)
        case toggle(get: @MainActor (Row) -> Bool, set: @MainActor (inout Row, Bool) -> Void)
        case choice(options: [String], get: @MainActor (Row) -> String?, set: @MainActor (inout Row, String) -> Void)
    }

    /// Words typed in `grammar` (a type, a default), one line: `get` the value the row holds (nil: none, an empty line),
    /// `set` the row holding the line's value (nil for an empty line).
    public static func field<Grammar: LineGrammar>(_ label: String, grammar: Grammar,
                                                   get: @escaping @MainActor (Row, LineContext) -> Grammar.Row?,
                                                   set: @escaping @MainActor (inout Row, Grammar.Row?, LineContext) -> Void) -> LineCardLine {
        LineCardLine(label: label, kind: .text(LineCardText(grammar: grammar, isList: false,
                                                            get: { row, context in get(row, context).map { [$0] } ?? [] },
                                                            set: { row, values, context in set(&row, values.first, context) })))
    }

    /// On or off ("null"), said yes or no; Space toggles it.
    public static func toggle(_ label: String, get: @escaping @MainActor (Row) -> Bool, set: @escaping @MainActor (inout Row, Bool) -> Void) -> LineCardLine {
        LineCardLine(label: label, kind: .toggle(get: get, set: set))
    }

    /// One of `options` ("on delete": restrict, cascade…); Space opens them, the current checked. With none held (`get` nil), the
    /// first is shown, faint.
    public static func choice(_ label: String, options: [String], get: @escaping @MainActor (Row) -> String?,
                              set: @escaping @MainActor (inout Row, String) -> Void) -> LineCardLine {
        LineCardLine(label: label, kind: .choice(options: options, get: get, set: set))
    }

    /// Lines, each typed in `grammar` (an endpoint's responses): Return after one opens another below it, a line left empty
    /// goes. `get` the values the row holds, in order; `set` the row holding the lines' values.
    public static func list<Grammar: LineGrammar>(_ label: String, grammar: Grammar,
                                                  get: @escaping @MainActor (Row, LineContext) -> [Grammar.Row],
                                                  set: @escaping @MainActor (inout Row, [Grammar.Row], LineContext) -> Void) -> LineCardLine {
        LineCardLine(label: label, kind: .text(LineCardText(grammar: grammar, isList: true, get: get, set: set)))
    }
}

/// A card's line of words, erased from its grammar: the lines the row holds printed, how a line reads (its looks and mark),
/// what fits at the caret, and the row written back from its lines.
@MainActor
struct LineCardText<Row> {
    /// Several lines (a list), or one.
    let isList: Bool
    /// The lines the row holds, printed.
    let lines: @MainActor (Row, LineContext) -> [LineText]
    /// How a line reads: its spans and mark.
    let look: @MainActor (LineText, LineContext) -> (spans: [LineSpan], mark: LineMark?)
    /// What fits at the caret in a line.
    let offers: @MainActor (Int, LineText, LineContext) -> LineOffers?
    /// Whether a line holds nothing the grammar reads as a value (a blank one): a write takes it out.
    let isEmpty: @MainActor (LineText, LineContext) -> Bool
    /// The row holding what `lines` say: empty lines are none.
    let write: @MainActor ([LineText], Row, LineContext) -> Row
    let substitutions: [LineSubstitution]

    init<Grammar: LineGrammar>(grammar: Grammar, isList: Bool, get: @escaping @MainActor (Row, LineContext) -> [Grammar.Row],
                               set: @escaping @MainActor (inout Row, [Grammar.Row], LineContext) -> Void) {
        self.isList = isList
        lines = { row, context in get(row, context).map { grammar.print($0, in: context) } }
        look = { line, context in
            let reading = grammar.read(line, id: context.row ?? PartID(), in: context)
            return (reading.spans, reading.mark)
        }
        offers = { caret, line, context in
            grammar.offers(at: caret, in: line, reading: grammar.read(line, id: context.row ?? PartID(), in: context), context: context)
        }
        isEmpty = { line, context in grammar.read(line, id: context.row ?? PartID(), in: context).row == nil }
        write = { lines, row, context in
            var row = row
            set(&row, lines.compactMap { grammar.read($0, id: context.row ?? PartID(), in: context).row }, context)
            return row
        }
        substitutions = grammar.substitutions
    }
}

/// What shows a row's card: the Card part's, which the module's plugin gives the service.
@MainActor
protocol LineCardShowing: AnyObject {
    /// Shows `card` for `row` of the shape `session` edits, hung from the row; false where it can't show.
    func show<Model: LineModel>(_ card: LineCard<Model.Row>, of row: PartID, in session: LineSession<Model>) -> Bool
    /// The card follows its row (a commit settled, `changes`: also shows what the row holds now) or, with no changes, the layout
    /// moved it (a waiting line opened above it); closes where the row is gone.
    func follow(_ changes: ChangeSet?)
}

/// What a card's commit came to.
enum CardCommit {
    /// The row was written.
    case written
    /// The line was as the row holds it: nothing to write.
    case unchanged
    /// Nothing was written though the person changed something: the file can't take a commit now, the row is gone, or the
    /// shape refused. What they typed stays.
    case refused
}
