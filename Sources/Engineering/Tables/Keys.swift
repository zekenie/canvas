import AppKit
import Canvas
import Connections
import Draw
import LineRows
import Mentions
import Palette
import Titles
import Topology

// Keys: a key is its arrow, on the `foreign-key` channel, from a column to the column it references, bound to both rows. A
// table's columns have ports on it both ways (`partPorts`), so a drag from a row's dot draws one onto another table's row,
// and `canvas draw`'s `edge "orders".customer_id -> "customers".id` makes one. Nothing about a key is stored on the column:
// the key index reads the arrows' edges (Topology's, with each end's part) and keeps, per table, which of its columns have a
// key and to which row, worked out again only for the tables a change to the keys touched. The column's link mark reads it,
// and the far row's live name says where the key goes, so a rename follows with nothing written.

/// A key, column to column: the kit's channel, with no title (no pill on the line, as the frames draw keys). Kinds open to
/// every channel (a subboard) take none; only the columns of tables do, either way.
public enum ForeignKey {}

extension ForeignKey: Channel {
    public static let id: ChannelID = "foreign-key"
    /// Its dots: the link's blue, the frames' (the column's link mark is the same hue made to read on the paper).
    public static var color: NSColor { NSColor(KitStyle.linkBlue) }
    public static let summary: String? = "a key: an arrow from a column to the column it references, bound to both rows"
    public static var isOnEveryChannel: Bool { false }
}

/// Each table's keys, read from Topology's `foreign-key` edges with their parts: which of its columns start one, and the row
/// each goes to. Kept per table and worked out when asked, again only after a change to the keys touched that table (a key
/// drawn, re-aimed or deleted; the table or the far one deleted), and all of them after the file is read afresh. A frame asks
/// it for the tables in view only.
@MainActor
final class KeyIndex {
    unowned let editor: CanvasEditor
    private var following: TopologyFollowing?
    /// The file's folds, which show a table's keys when it's folded to its marks.
    private weak var rowFolds: RowFolds?
    /// A table's keys: the far row of each column that starts one (the first, should a column start several), and the arrows that
    /// start at it.
    private var kept: [ShapeID: [PartID: Key]] = [:]
    struct Key {
        var target: PartAddress
        var arrows: [ShapeID]
    }
    private let type = EdgeTypeID(rawValue: ForeignKey.id.rawValue)

    init(editor: CanvasEditor) {
        self.editor = editor
        rowFolds = editor.rowFolds
        following = editor.topology?.follow { [weak self] change in self?.heard(change) }
    }

    private func heard(_ change: TopologyChange) {
        let folds = rowFolds.flatMap { $0.folded.isEmpty ? nil : $0 }
        guard !kept.isEmpty || folds != nil else { return }
        if change.cause == .rebuild {
            kept.removeAll()
            folds?.marksMayHaveChanged(folds?.folded ?? [])
            return
        }
        guard let topology = editor.topology else { return }
        let touched = change.touched(types: .only(type), in: topology.types)
        for id in touched { kept[id] = nil }
        // A key drawn or deleted is a mark of its table's: a table folded to its marks shows it, or hides it, at once.
        folds?.marksMayHaveChanged(touched)
    }

    /// The columns of `table` that start a key, each with the row it goes to and its arrows.
    private func held(_ table: ShapeID) -> [PartID: Key] {
        if let keys = kept[table] { return keys }
        var keys: [PartID: Key] = [:]
        // Resolved: a key into a pill for a table on another board is a key to the column its binding names, of that table.
        editor.topology?.forEachEdge(of: table, .outgoing, types: .only(type), view: .resolved) { edge in
            guard edge.isConnection, let part = edge.sourcePart else { return }
            if keys[part] == nil {
                keys[part] = Key(target: PartAddress(edge.target, part: edge.targetPart), arrows: [edge.carrier])
            } else if keys[part]?.arrows.contains(edge.carrier) == false {
                keys[part]?.arrows.append(edge.carrier)
            }
        }
        kept[table] = keys
        return keys
    }

    /// The columns of `table` that start a key, each with the row it goes to.
    func keys(of table: ShapeID) -> [PartID: PartAddress] { held(table).mapValues(\.target) }

    /// The columns of `table` that start a key, as `reading` reads the file: mid-transaction, the keys the transaction wrote as well
    /// (a key typed in the step that folds it to its marks), and without those it deleted or re-aimed, which the index, of the
    /// committed file, hasn't heard (review R41); what `makeRoom` measures a folded table by.
    func keys(of table: ShapeID, in reading: LayoutReading) -> [PartID: PartAddress] {
        let committed = held(table)
        guard !reading.isCommitted, !reading.changes.isEmpty else { return committed.mapValues(\.target) }
        let step = absorbing(reading)
        // A column whose every arrow the step wrote is a key only if one of them, as written, still starts there.
        var keys = committed.filter { _, key in !key.arrows.allSatisfy(step.names.contains) }.mapValues(\.target)
        for (_, key) in step.arrows where key.table == table && keys[key.part] == nil { keys[key.part] = key.target }
        return keys
    }

    /// The key arrows a transaction has written, read off its log (`LayoutReading.changes`) as far as it has been asked: each
    /// where it starts and goes as written last, and every arrow of the log, so a key let go is known. Read again from the entries
    /// since the last ask, of a reading of the same run.
    private struct StepKeys {
        var run: Int
        var cursor = 0
        var names: Set<ShapeID> = []
        var arrows: [ShapeID: (table: ShapeID, part: PartID, target: PartAddress)] = [:]
    }
    private var step: StepKeys?

    private func absorbing(_ reading: LayoutReading) -> StepKeys {
        let log = reading.changes
        var state = step.flatMap { $0.run == reading.runID && $0.cursor <= log.count ? $0 : nil } ?? StepKeys(run: reading.runID)
        let registry = editor.registry
        for id in log[state.cursor...] {
            state.names.insert(id)
            state.arrows[id] = nil
            guard let record = reading.shape(inFile: id) else { continue }
            for edge in registry.edges(of: record) where edge.type == type && edge.isConnection {
                guard let part = edge.sourcePart else { continue }
                state.arrows[id] = (edge.source, part, PartAddress(edge.target, part: edge.targetPart))
                break
            }
        }
        state.cursor = log.count
        step = state
        return state
    }

    /// The row `column` of `table`'s key goes to, by address, so its name is read live where it's said
    /// (`editor.accessibleName(of:)`: "id in customers"); nil for a column with no key.
    func target(of column: PartID, in table: ShapeID) -> PartAddress? { held(table)[column]?.target }

    /// The arrows of the keys `column` of `table` starts: the first the one its line says.
    func arrows(of column: PartID, in table: ShapeID) -> [ShapeID] { held(table)[column]?.arrows ?? [] }
}

extension KeyIndex: EditorService {
    /// Another file read in: nothing kept is its.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { kept.removeAll() }
    }
}

extension ShapeContext {
    /// The kit's key index, while one is installed.
    var keys: KeyIndex? { service(KeyIndex.self) }
}

// How a key looks (Connections' `ConnectionLooks`, the kit's answer for its channel): a crow's foot at the column's end, two
// bars when the column is unique (T3 panel 4), and at the row it references two bars, a bar and a circle when the column may be
// null; the line 2.5 wide (`KitStyle.keyLineWidth`) and ink, as every line is. Worked out from the column as the arrow's geometry
// is, through the shapes it reads, so a column made unique or nullable redraws its keys with nothing written to them. A key
// whose start isn't at a row (drawn to a table as a whole) has the marks of a column that is neither.
enum KeyLooks {
    @MainActor
    static func look(_ query: ConnectionLookQuery) -> ConnectionLook? {
        guard query.channel == ForeignKey.id else { return nil }
        let column = query.from.flatMap { from in
            from.part.flatMap { part in query.shapes.shape(from.shape)?.typed(as: DatabaseTable.self)?.props.columns.first { $0.id == part } }
        }
        let table = query.from.flatMap { query.shapes.shape($0.shape)?.typed(as: DatabaseTable.self)?.props }
        return ConnectionLook(start: column.map { isUnique($0, in: table) } == true ? .one : .many,
                              end: column?.nullable == true ? .zeroOrOne : .one,
                              lineWidth: KitStyle.keyLineWidth)
    }

    /// Whether no two rows may hold one value of `column`: it says unique, or it is its table's one primary key column.
    static func isUnique(_ column: Column, in table: DatabaseTable?) -> Bool {
        column.unique || (column.primaryKey && (table?.columns.filter(\.primaryKey).count ?? 1) == 1)
    }
}

/// A line's key, written with its column in the row's transaction (`TableLines.apply`): the arrow made, its far end moved to the
/// row the line names (a re-aim keeps the arrow, its bend and its id), or the column's arrows deleted where the line names none.
/// A row of a table on another board is reached through a pill for that table on this one, the column on the arrow's binding
/// (T6 panel 3): the board's pill for it in the table's container if it has one, else a new one landed beside the table, in the
/// row's step, as ⌘L's pick puts one (`StandInRoute.placePill`). Typing never makes a shape public: a table no pill can stand for
/// as it is makes no key.
@MainActor
enum KeyArrows {
    /// Writes `key` for `column` of `table`, as the board has it now (`keys`); false where the arrow can't be made (the connector
    /// refuses the pair, or no pill can reach a table on another board), so the row's commit writes nothing and the table shakes. A
    /// column as stored writes nothing.
    static func write(_ key: ColumnKey, from column: PartID, of table: ShapeID, keys: KeyIndex?, in transaction: inout Transaction) -> Bool {
        let held = keys?.arrows(of: column, in: table).filter { transaction.document[$0] != nil } ?? []
        let current = keys?.target(of: column, in: table)
        switch key {
        case .stored:
            return true
        case .none:
            // A key the line couldn't print (its table is gone: the pill stands for nothing, or the row is) isn't one the person took
            // out: the line never showed it, so editing the column leaves it, as it leaves the pill.
            if let current, let editor = keys?.editor, ColumnLineGrammar.written(current, editor) == nil { return true }
            if !held.isEmpty { transaction.delete(Set(held)) }
            return true
        case .to(let target):
            if current == target, !held.isEmpty { return true }
            let registry = transaction.shapes.registry
            // The far end on this board: the row, or a pill for its table with the row on the binding.
            guard let end = reach(target, from: table, column: column, keys: keys, in: &transaction) else { return false }
            let own = PartAddress(table, part: column)
            // The arrow's far end as it is bound now (the row, or a pill for its table and the row).
            if let arrow = held.first, let record = transaction.document[arrow],
               let bound = record.boundParts(in: registry).first(where: { $0 != own }),
               let moved = record.movingParts(in: registry, { $0 == bound ? end.address : $0 }) {
                transaction.update(arrow) { $0 = moved }
                return transaction.document[arrow]?.boundParts(in: registry).contains(end.address) == true
            }
            guard let made = registry.drawConnection(from: table, to: end.address.shape, in: transaction.shapes, standingFor: ([], end.standingFor),
                                                     parts: (column, end.address.part)) else { return false }
            transaction.insert(made)
            return transaction.document[made.id] != nil
        }
    }

    /// Where a key to `target` ends on the transaction's board: the row itself, there; else a pill for its table there (reused, or
    /// made and put down in the transaction), with the row on the binding, and the kind the pill is read as. Nil where none can be.
    private static func reach(_ target: PartAddress, from table: ShapeID, column: PartID, keys: KeyIndex?, in transaction: inout Transaction)
        -> (address: PartAddress, standingFor: [ShapeKind])? {
        if transaction.document[target.shape] != nil { return (target, []) }
        // Planned against the board shown as the editor has it, which is the transaction's: a row is written on the board shown.
        guard let editor = keys?.editor, editor.board == transaction.board else { return nil }
        let verdicts = FarVerdicts(editor)
        // What an earlier key of this step put down isn't on the board yet as the editor has it: a pill for the same table is reused,
        // and a new one lands clear of those already put down.
        let document = transaction.document, put = document.shapes.compactMap { editor.document[$0.id] == nil ? $0.box : nil }
        guard verdicts.verdict(of: target.shape) == .reads, let route = verdicts.route, let far = editor.shape(inFile: target.shape),
              let placed = route.placePill(standingFor: target.shape, onBinding: target.part, label: editor.registry.mentionAppearance(of: far)?.label ?? "",
                                           beside: table, from: column, edgeIs: .from, sharing: .any, avoiding: put, reading: document, verdicts: verdicts,
                                           in: editor) else { return nil }
        guard (try? placed.claim(in: &transaction, registry: editor.registry)) != nil, let pill = try? placed.put(in: &transaction) else { return nil }
        return (PartAddress(pill, part: target.part), [placed.farKind])
    }
}

/// What ⌘L's picker means on a table (`ConnectPicks`). Opened on a row being edited (a column), it lists the tables of the file a pill can
/// reach, nearest first, and their columns, never an enum or any other shape: a column picked is the key's far row, a table its primary key's, and the pick
/// draws the key in place of any the column had ("Connect"). Opened on the table, it lists the tables: one picked makes a key column
/// for it, named for it (`customer_id` for customers: the name, singular, and `_id`), typed as its primary key, after the table's own
/// keys, with its key drawn, one step, "Add Key Column".
@MainActor
public enum KeyPicks {
    /// A table of the file (one on another board reached through a pill for it, as `editor.connect` reaches one), and from a row, a
    /// column of one or a table with a primary key; from a table, a table with one.
    static func admits(_ pick: ConnectPick, _ editor: CanvasEditor) -> Bool {
        guard let far = editor.shape(inFile: pick.to.shape)?.typed(as: DatabaseTable.self) else { return false }
        if pick.from.part != nil {
            if pick.to.part != nil { return true }
            // A table as a whole is its primary key's row, which a row of its own (the primary key itself) can't key to.
            guard let key = ColumnLineGrammar.primaryKey(of: far.props) else { return false }
            return PartAddress(far.id, part: key.id) != pick.from.address
        }
        return pick.to.part == nil && ColumnLineGrammar.primaryKey(of: far.props) != nil
    }

    static func plan(_ pick: ConnectPick, _ editor: CanvasEditor) -> ConnectPlan? {
        guard let far = editor.shape(inFile: pick.to.shape)?.typed(as: DatabaseTable.self) else { return nil }
        let table = pick.from.shape, keys = editor.service(KeyIndex.self)
        if let column = pick.from.part {
            guard let row = pick.to.part ?? ColumnLineGrammar.primaryKey(of: far.props)?.id, PartAddress(far.id, part: row) != pick.from.address else { return nil }
            let target = ConnectEnd(far.id, part: row)
            // The column's key is the one it has: one it had goes as the pick draws its new one.
            let held = keys?.arrows(of: column, in: table) ?? []
            return ConnectPlan(from: pick.from, to: target) { transaction in
                let gone = Set(held.filter { transaction.document[$0] != nil })
                if !gone.isEmpty { transaction.delete(gone) }
                return (pick.from, target)
            }
        }
        guard let primary = ColumnLineGrammar.primaryKey(of: far.props), let source = editor.document[table]?.typed(as: DatabaseTable.self) else { return nil }
        let name = keyColumnName(for: editor.registry.title(of: AnyShapeRecord(far)) ?? "", among: source.props.columns.map(\.name))
        let made = Column(name: name, type: TypeRef(keyType(of: primary.type.words), shape: primary.type.shape))
        let target = ConnectEnd(far.id, part: primary.id)
        let keyed = Set(keys?.keys(of: table).keys.map { $0 } ?? [])
        return ConnectPlan(step: TableStyle.addKeyColumnStep, from: pick.from, to: target) { transaction in
            guard let held = transaction.document[table]?.typed(as: DatabaseTable.self) else { throw Transaction.Refused([table]) }
            var columns = held.props.columns
            // After the table's own keys: its primary key's columns and those that have a key already.
            let after = columns.lastIndex { $0.primaryKey || keyed.contains($0.id) }.map { $0 + 1 } ?? 0
            columns.insert(made, at: after)
            transaction.update(table, as: DatabaseTable.self) { $0.props.columns = columns }
            guard transaction.document[table]?.typed(as: DatabaseTable.self)?.props.columns == columns else { throw Transaction.Refused([table]) }
            return (ConnectEnd(table, part: made.id), target)
        }
    }

    /// A key column's name for a table: its name, singular, and `_id` (`customers` → `customer_id`, `categories` → `category_id`,
    /// `addresses` → `address_id`, `statuses` and `status` → `status_id`), its spaces underscores, lowercased; `_2`, `_3` after it where the table has the name already.
    public static func keyColumnName(for table: String, among taken: [String]) -> String {
        var name = table.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "_")
        if name.hasSuffix("ies"), name.count > 3 {
            name = String(name.dropLast(3)) + "y"
        } else if name.hasSuffix("yses"), name.count > 4 {
            name = String(name.dropLast(4)) + "ysis"
        } else if ["sses", "xes", "ches", "shes", "zes", "tuses", "buses", "puses", "ruses", "nuses"].contains(where: name.hasSuffix) {
            // `addresses`, `boxes`, `statuses`: the plural's `es` goes. (`houses` and `databases` lose only their `s`.)
            name = String(name.dropLast(2))
        } else if name.hasSuffix("s"), !["ss", "us", "is"].contains(where: name.hasSuffix), name.count > 1 {
            name = String(name.dropLast())
        }
        let base = (name.isEmpty ? "key" : name) + "_id"
        var candidate = base, number = 2
        while taken.contains(candidate) {
            candidate = "\(base)_\(number)"
            number += 1
        }
        return candidate
    }

    /// The type a key to a column of this type is: its own, but a serial's integer.
    public static func keyType(of type: String) -> String {
        switch type.lowercased() {
        case "serial", "serial4": "int"
        case "bigserial", "serial8": "bigint"
        case "smallserial", "serial2": "smallint"
        default: type
        }
    }
}

// The kit's kinds take what is bound to them along (the core's `TakesBoundShapes`): deleting a table deletes its keys
// ("Delete Table and 3 Arrows"), taking a column out deletes the keys at it ("Delete Column and 1 Arrow"), and copying tables
// copies the keys among them. Any other kind keeps tldraw's rule.
extension TableDefinition: TakesBoundShapes {}
extension EnumDefinition: TakesBoundShapes {}
extension DatabaseDefinition: TakesBoundShapes {}
