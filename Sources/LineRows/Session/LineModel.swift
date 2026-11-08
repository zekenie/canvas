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
    /// `row` under another id: a row moved into a shape that already holds its id.
    func renaming(_ row: Row, to id: PartID) -> Row
    /// The props of a new shape holding `rows` taken out of `shape` (⌘X then ⌘V on the board, the take-out in the selection's
    /// menu): by default the shape's own props holding only them, so a new shape of its kind, untitled. A table's has its
    /// `id uuid pk` first.
    func takeOut(_ rows: [Row], from shape: ShapeRecord<Props>) -> Props
    /// Whether a shape taken out has its name typed at once (T5: "Name it addresses"). False by default.
    var takeOutEditsTitle: Bool { get }
    /// Whether the row with the caret shows a "›" at its right that a click opens its card by (an endpoint's, E3 panel 1);
    /// false by default (a column's card is ⌘↓'s alone, as the frames draw a table).
    var showsCardChevron: Bool { get }
    /// The line every shape of the kind has above its rows, never a row (an API's server, `LineFixedLine`): a stop after the
    /// title, typed as a row's line is in a grammar of its own and written as its stop is left. Nil, by default, for none.
    var fixedLine: LineFixedLine<Props>? { get }
    /// How far in from the line's text inset the text of the row at `index` of `rows` starts (a header's members are
    /// indented under it); `isNew` for a new line put in at `index` (the waiting line). 0 by default.
    func indent(at index: Int, of rows: [Row], isNew: Bool) -> CGFloat
    /// One change made to `rows`, as `apply` makes each: false refuses it (nothing is written, the shape shakes). By default
    /// a row put in, written over, taken out or moved plainly; a kind whose rows mean something by their neighbors (an API's
    /// path prefixes: a row's full path is its header's and its own) overrides it, so what a change leaves under another
    /// neighbor still says what it did.
    func applying(_ change: LineChange<Row>, to rows: inout [Row]) -> Bool
    /// The changes that put the pasted rows `made` in, the block wanted at `index` of `rows`: by default the block itself, there.
    /// A kind whose rows say where they go (a full path under its header) places each where it belongs.
    func placing(pasted made: [Row], at index: Int, among rows: [Row]) -> [LineChange<Row>]
    /// What VoiceOver calls the row at `index` of `rows`: by default "Column 2 of 5", the noun and its place.
    func accessibleLabel(of row: Row, at index: Int, among rows: [Row]) -> String
    /// `rows` with those `moved` names taken out and put back as one block at `index` among the rest, in their order: what ⌥↑
    /// ⌥↓ on rows selected as items and a drag within the shape write (a header moved comes with the rows it heads, in `moved`
    /// already). By default the block there, plainly; a kind whose rows mean something by their neighbors keeps what they mean,
    /// as `applying` does for one row (an API: an endpoint that leaves every group takes its prefix along, one moved under
    /// another header keeps its own path, and those a header lands among or leaves keep their full paths).
    func reordering(_ moved: Set<PartID>, to index: Int, in rows: [Row]) -> [Row]
    /// Where the lead of row `index` of `rows` is drawn, world units, its line at `line` (a column's key mark, an endpoint's
    /// method chip): a press there drags the row at once, selected or not, and a click selects it as a click on the shape
    /// would. Nil, by default, for none.
    func lead(of row: Row, at index: Int, among rows: [Row], line: CGRect, in context: LineContext) -> CGRect?
}

extension LineModel {
    public func merged(_ read: Row, onto held: Row) -> Row { read }
    public func marked(_ shape: ShapeRecord<Props>, in reading: LayoutReading) -> Set<PartID> { [] }
    public func isHeader(_ row: Row) -> Bool { false }
    public var widestLine: CGFloat? { nil }
    public func card(of row: Row, in context: LineContext) -> LineCard<Row>? { nil }
    public func takeOut(_ rows: [Row], from shape: ShapeRecord<Props>) -> Props {
        var props = shape.props
        setRows(rows, in: &props)
        return props
    }
    public var takeOutEditsTitle: Bool { false }
    public var showsCardChevron: Bool { false }
    public var fixedLine: LineFixedLine<Props>? { nil }
    public func indent(at index: Int, of rows: [Row], isNew: Bool) -> CGFloat { 0 }
    public func placing(pasted made: [Row], at index: Int, among rows: [Row]) -> [LineChange<Row>] { [.add(made, at: index)] }
    public func accessibleLabel(of row: Row, at index: Int, among rows: [Row]) -> String { "\(noun.title) \(index + 1) of \(rows.count)" }
    public func lead(of row: Row, at index: Int, among rows: [Row], line: CGRect, in context: LineContext) -> CGRect? { nil }

    public func reordering(_ moved: Set<PartID>, to index: Int, in rows: [Row]) -> [Row] {
        var rest = rows.filter { !moved.contains(id(of: $0)) }
        rest.insert(contentsOf: rows.filter { moved.contains(id(of: $0)) }, at: min(max(0, index), rest.count))
        return rest
    }

    /// `rows` with `gone` taken out as `applying` takes rows out (an API's endpoints keeping their full paths): what's left of a
    /// shape whose rows move away, and, the rest taken out, what moves (a copy's, a cut's, a take-out's rows, each saying what
    /// it said where it was).
    func removing(_ gone: Set<PartID>, from rows: [Row]) -> [Row] {
        let taken = rows.filter { gone.contains(id(of: $0)) }
        guard !taken.isEmpty else { return rows }
        var left = rows
        guard applying(.delete(taken), to: &left) else { return rows.filter { !gone.contains(id(of: $0)) } }
        return left
    }

    /// `rows` with `added` put in, the block wanted at `index`, as a paste puts rows in (`placing`, then `applying`): nil where the
    /// kind refuses a change.
    func inserting(_ added: [Row], at index: Int, into rows: [Row]) -> [Row]? {
        var held = rows
        for change in placing(pasted: added, at: min(max(0, index), rows.count), among: rows) {
            guard applying(change, to: &held) else { return nil }
        }
        return held
    }

    public func applying(_ change: LineChange<Row>, to rows: inout [Row]) -> Bool {
        switch change {
        case .add(let added, let index):
            rows.insert(contentsOf: added, at: min(max(0, index), rows.count))
        case .change(let from, let to):
            guard let at = rows.firstIndex(where: { self.id(of: $0) == self.id(of: from) }) else { return false }
            rows[at] = to
        case .delete(let gone):
            let ids = Set(gone.map(self.id(of:)))
            rows.removeAll { ids.contains(self.id(of: $0)) }
        case .move(let row, let index):
            guard let at = rows.firstIndex(where: { self.id(of: $0) == self.id(of: row) }) else { return false }
            let moved = rows.remove(at: at)
            rows.insert(moved, at: min(max(0, index), rows.count))
        }
        return true
    }

    public func apply(_ changes: [LineChange<Row>], to id: ShapeID, in transaction: inout Transaction) -> Bool {
        guard let record = transaction.document[id]?.typed(as: Props.self) else { return false }
        var rows = rows(of: record.props)
        var removed: Set<PartAddress> = []
        for change in changes {
            guard applying(change, to: &rows) else { return false }
            if case .delete(let gone) = change { removed.formUnion(gone.map { PartAddress(id, part: self.id(of: $0)) }) }
        }
        var refused = false
        transaction.update(id, as: Props.self) { setRows(rows, in: &$0.props) }
        if transaction.document[id]?.typed(as: Props.self).map({ self.rows(of: $0.props) != rows }) ?? true { refused = true }
        guard !refused else { return false }
        transaction.removeParts(removed)
        return true
    }

    /// The step of `changes`, named by the first, and by what a delete took along, counted even for one ("Delete Column
    /// and 1 Arrow": the row is the step's noun, what went is how many).
    func stepName(of changes: [LineChange<Row>], along: [KindCount], in registry: Registry) -> String {
        RowSteps.counted(changes.first.map(stepName(of:)) ?? noun.title, along: along, in: registry)
    }

    /// One step of `changes` to shape `id`, named as `stepName(of:along:in:)` names it (by `naming` where the changes are how a
    /// kind placed one, a paste placed under its headers), and heard by VoiceOver: what a row's line, a row's card and rows
    /// selected on the canvas write. A refusal (a locked shape) writes nothing and shakes it.
    @discardableResult
    func write(_ changes: [LineChange<Row>], to id: ShapeID, in editor: CanvasEditor, coalescing key: AnyHashable? = nil,
               named naming: LineChange<Row>? = nil) -> Bool {
        var name = ""
        let registry = editor.registry
        let written: Bool? = editor.transactWhole(nil, coalescing: key, shaking: [id]) { transaction in
            guard apply(changes, to: id, in: &transaction) else { throw Transaction.Refused([id]) }
            name = stepName(of: naming.map { [$0] } ?? changes, along: transaction.deletedAlong, in: registry)
            transaction.stepName = name
            return true
        }
        guard written == true else { return false }
        editor.announce(name)
        return true
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
