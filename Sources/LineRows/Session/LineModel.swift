import AppKit
import Canvas
import Selection

// What a kind gives to have its rows written as lines: its rows in order (each a part of its shape, by its `PartID`), a
// grammar a role, where each line is drawn, how a change is written (the props and whatever goes with them, in one
// transaction) and what a change is called, which names its step ("Rename Column" exactly when only the name changed).

/// What a kind's rows are called, for VoiceOver and the steps: "column", "columns".
public struct LineNoun: Hashable, Sendable {
    public var singular: String
    public var plural: String

    public init(_ singular: String, plural: String? = nil) {
        self.singular = singular
        self.plural = plural ?? singular + "s"
    }

    /// "Column", "Columns".
    public var title: String { singular.prefix(1).uppercased() + singular.dropFirst() }
    public var pluralTitle: String { plural.prefix(1).uppercased() + plural.dropFirst() }
}

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
}

extension LineModel {
    public func merged(_ read: Row, onto held: Row) -> Row { read }

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
            return item.count == 1 ? label : "\(item.count) \(DeleteSteps.plural(label))"
        }
        return "\(name) and \(DeleteSteps.list(parts))"
    }
}
