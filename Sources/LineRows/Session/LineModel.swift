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

    /// The step of `changes`, named by the first, and by what a delete took along, counted even for one ("Delete Column
    /// and 1 Arrow": the row is the step's noun, what went is how many).
    func stepName(of changes: [LineChange<Row>], along: [KindCount], in registry: Registry) -> String {
        RowSteps.counted(changes.first.map(stepName(of:)) ?? noun.title, along: along, in: registry)
    }

    /// One step of `changes` to shape `id`, named as `stepName(of:along:in:)` names it, and heard by VoiceOver: what a row's
    /// line, a row's card and rows selected on the canvas write. A refusal (a locked shape) writes nothing and shakes it.
    @discardableResult
    func write(_ changes: [LineChange<Row>], to id: ShapeID, in editor: CanvasEditor, coalescing key: AnyHashable? = nil) -> Bool {
        var name = ""
        let registry = editor.registry
        let written: Bool? = editor.transactWhole(nil, coalescing: key, shaking: [id]) { transaction in
            guard apply(changes, to: id, in: &transaction) else { throw Transaction.Refused([id]) }
            name = stepName(of: changes, along: transaction.deletedAlong, in: registry)
            transaction.stepName = name
            return true
        }
        guard written == true else { return false }
        editor.announce(name)
        return true
    }
}
