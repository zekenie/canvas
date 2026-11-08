import AppKit
import Canvas
import Selection

// What a kind gives to have its rows written as lines: its rows in order (each a part of its shape, by its `PartID`), a
// grammar a role, where each line is drawn, how a change is written (the props and whatever goes with them, in one
// transaction) and what a change is called, which names its step ("Rename Column" exactly when only the name changed).

/// A change to a kind's rows, as a commit makes it.
public enum LineChange<Row> {
    /// Rows put in at an index: one typed ("Add Column"), or a block pasted ("Paste Columns").
    case add([Row], at: Int)
    /// A row written over: what it was, what it is ("Rename Column" when only its name changed, else "Change Column").
    case change(from: Row, to: Row)
    /// Rows taken out ("Delete Column").
    case delete([Row])
    /// A row moved to another index in its shape ("Move Column").
    case move(Row, to: Int)
}

/// A kind written as lines: its rows, their grammars and their look, and how a change is written and named.
@MainActor
public protocol LineModel {
    associatedtype Props: ShapeProps
    associatedtype Row: Equatable
    /// What its rows are called.
    var noun: LineNoun { get }
    /// How its lines look while they're typed.
    var style: LineStyle { get }
    /// Its rows, in order.
    func rows(of props: Props) -> [Row]
    /// `props` holding `rows`, in that order.
    func setRows(_ rows: [Row], in props: inout Props)
    /// A row's id, its shape's own.
    func id(of row: Row) -> PartID
    /// What kind of row it is.
    func role(of row: Row) -> LineRole
    /// What kind of row a new line at `index` is.
    func roleOfNewRow(at index: Int, in props: Props) -> LineRole
    /// The grammar rows of a role are written in.
    func grammar(for role: LineRole) -> any LineGrammar<Row>
    /// Line `line` of a shape laid out at `frame` (world units): the rows' rects as the kind draws them, the waiting line
    /// one of them.
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect
    /// A row read from its line joined onto the row it was: what the line doesn't say (a card's fields) kept. By default
    /// the row read.
    func merged(_ read: Row, onto held: Row) -> Row
    /// Writes `changes` to shape `id` in `transaction`: its props and whatever goes with them. By default the rows set
    /// in order and each row taken out handed to the core (`removeParts`), so nothing stays bound to it. False writes
    /// nothing and the shape shakes.
    func apply(_ changes: [LineChange<Row>], to id: ShapeID, in transaction: inout Transaction) -> Bool
    /// What a change is called, as its step is.
    func stepName(of change: LineChange<Row>) -> String
    /// The rows a fold to its marks keeps (⌃⌘↑: a table's keys and unique columns), as `reading` lays the shape out. By
    /// default none, so a fold keeps the first two rows.
    func marked(_ shape: ShapeRecord<Props>, in reading: LayoutReading) -> Set<PartID>
    /// Whether a row heads the rows after it, up to the next that does (a path prefix's header): a fold can close it. By
    /// default none does.
    func isHeader(_ row: Row) -> Bool
    /// The widest the shape is laid out while a line typed in it is wider than it is (world units), past which the line
    /// slides in its field; nil, by default, for no limit.
    var widestLine: CGFloat? { get }
    /// A row's card, ⌘↓ in its line: what more it holds than the line says (a column's on delete), a line each. Nil, by
    /// default, for a row with nothing more (an enum's value): ⌘↓ does nothing there.
    func card(of row: Row, in context: LineContext) -> LineCard<Row>?
    /// Whether the row with the caret shows a "›" at its right that a click opens its card by (an endpoint's, E3 panel 1);
    /// false by default (a column's card is ⌘↓'s alone, as the frames draw a table).
    var showsCardChevron: Bool { get }
    /// The line every shape of the kind has above its rows, never a row (an API's server, `LineFixedLine`): a stop after the
    /// title, typed as a row's line is in a grammar of its own and written as its stop is left. Nil, by default, for none.
    var fixedLine: LineFixedLine<Props>? { get }
    /// How far in from the line's text inset the text of the row at `index` of `rows` starts (a header's members are
    /// indented under it); `isNew` for a new line put in at `index` (the waiting line). 0 by default.
    func indent(at index: Int, of rows: [Row], isNew: Bool) -> CGFloat
}

extension LineModel {
    public func merged(_ read: Row, onto held: Row) -> Row { read }
    public func marked(_ shape: ShapeRecord<Props>, in reading: LayoutReading) -> Set<PartID> { [] }
    public func isHeader(_ row: Row) -> Bool { false }
    public var widestLine: CGFloat? { nil }
    public func card(of row: Row, in context: LineContext) -> LineCard<Row>? { nil }
    public var showsCardChevron: Bool { false }
    public var fixedLine: LineFixedLine<Props>? { nil }
    public func indent(at index: Int, of rows: [Row], isNew: Bool) -> CGFloat { 0 }

    public func apply(_ changes: [LineChange<Row>], to id: ShapeID, in transaction: inout Transaction) -> Bool {
        guard let record = transaction.document[id]?.typed(as: Props.self) else { return false }
        var rows = rows(of: record.props)
        var removed: Set<PartAddress> = []
        for change in changes {
            switch change {
            case .add(let added, let index):
                rows.insert(contentsOf: added, at: min(max(0, index), rows.count))
            case .change(let from, let to):
                guard let at = rows.firstIndex(where: { self.id(of: $0) == self.id(of: from) }) else { return false }
                rows[at] = to
            case .delete(let gone):
                let ids = Set(gone.map(self.id(of:)))
                rows.removeAll { ids.contains(self.id(of: $0)) }
                removed.formUnion(ids.map { PartAddress(id, part: $0) })
            case .move(let row, let index):
                guard let at = rows.firstIndex(where: { self.id(of: $0) == self.id(of: row) }) else { return false }
                let moved = rows.remove(at: at)
                rows.insert(moved, at: min(max(0, index), rows.count))
            }
        }
        var refused = false
        transaction.update(id, as: Props.self) { setRows(rows, in: &$0.props) }
        if transaction.document[id]?.typed(as: Props.self).map({ self.rows(of: $0.props) != rows }) ?? true { refused = true }
        guard !refused else { return false }
        transaction.removeParts(removed)
        return true
    }

    /// The step of `changes`, named by the first, and by what a delete took along: "Delete Column and 1 Arrow".
    func stepName(of changes: [LineChange<Row>], along: [KindCount], in registry: Registry) -> String {
        let name = changes.first.map(stepName(of:)) ?? noun.title
        let counted = along.filter { $0.count > 0 }
        guard !counted.isEmpty else { return name }
        let parts = counted.map { item in
            let label = registry.label(of: item.kind).name
            // Counted even for one ("Delete Column and 1 Arrow"): the row is the step's noun, what went is how many.
            return "\(item.count) \(item.count == 1 ? label : DeleteSteps.plural(label))"
        }
        return "\(name) and \(DeleteSteps.list(parts))"
    }
}

/// A kind's fixed first line (an API's server, `host[/path] [bearer]`): above its rows, never a row, always there, so nothing
/// adds or takes it out. Typed as a row's line is, in a grammar of its own (looks, offers, `->` as `→`), with a faint
/// placeholder while it's empty; a stop after the title (↑ from the first row comes to it, Return goes on to the waiting line);
/// written as its stop is left, if it changed, one step the kind names ("Change Server"). The kind draws it at rest and leaves
/// it to the field while it has the caret (`LineRowsLayout.fixed`).
@MainActor
public struct LineFixedLine<Props: ShapeProps> {
    /// What VoiceOver calls it: "Server".
    public let name: String
    /// What it shows, faint, while it's empty: "server".
    public let placeholder: String
    /// Its step: "Change Server".
    public let stepName: String
    /// Where it's drawn on a shape laid out at a frame, world units.
    let rect: @MainActor (CGRect) -> CGRect
    let print: @MainActor (Props, LineContext) -> LineText
    let look: @MainActor (LineText, LineContext) -> (spans: [LineSpan], mark: LineMark?)
    let offers: @MainActor (Int, LineText, LineContext) -> LineOffers?
    let write: @MainActor (LineText, inout Props, LineContext) -> Void
    let substitutions: [LineSubstitution]

    /// The line, in `grammar`: `get` the value the shape holds (nil: none, an empty line), `set` the shape holding the line's
    /// value (nil for an empty line); `rect` where it's drawn in a frame.
    public init<Grammar: LineGrammar>(name: String, placeholder: String, stepName: String, grammar: Grammar,
                                      rect: @escaping @MainActor (CGRect) -> CGRect,
                                      get: @escaping @MainActor (Props) -> Grammar.Row?,
                                      set: @escaping @MainActor (inout Props, Grammar.Row?) -> Void) {
        self.name = name
        self.placeholder = placeholder
        self.stepName = stepName
        self.rect = rect
        print = { props, context in get(props).map { grammar.print($0, in: context) } ?? LineText("") }
        look = { line, context in
            let reading = grammar.read(line, id: context.row ?? PartID(), in: context)
            return (reading.spans, reading.mark)
        }
        offers = { caret, line, context in
            grammar.offers(at: caret, in: line, reading: grammar.read(line, id: context.row ?? PartID(), in: context), context: context)
        }
        write = { line, props, context in set(&props, grammar.read(line, id: context.row ?? PartID(), in: context).row) }
        substitutions = grammar.substitutions
    }
}
