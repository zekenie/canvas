import AppKit
import Canvas
import Connections
import Draw
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
    private unowned let editor: CanvasEditor
    private var following: TopologyFollowing?
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
        following = editor.topology?.follow { [weak self] change in self?.heard(change) }
    }

    private func heard(_ change: TopologyChange) {
        guard !kept.isEmpty else { return }
        if change.cause == .rebuild { return kept.removeAll() }
        guard let topology = editor.topology else { return }
        for id in change.touched(types: .only(type), in: topology.types) { kept[id] = nil }
    }

    /// The columns of `table` that start a key, each with the row it goes to and its arrows.
    private func held(_ table: ShapeID) -> [PartID: Key] {
        if let keys = kept[table] { return keys }
        var keys: [PartID: Key] = [:]
        editor.topology?.forEachEdge(of: table, .outgoing, types: .only(type), view: .literal) { edge in
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

/// A line's key, written with its column in the row's transaction (`TableLines.apply`): the arrow made, its far end moved to the
/// row the line names (a re-aim keeps the arrow, its bend and its id), or the column's arrows deleted where the line names none.
@MainActor
enum KeyArrows {
    /// Writes `key` for `column` of `table`, as the board has it now (`keys`); false where the arrow can't be made (the connector
    /// refuses the pair), so the row's commit writes nothing and the table shakes. A column as stored writes nothing.
    static func write(_ key: ColumnKey, from column: PartID, of table: ShapeID, keys: KeyIndex?, in transaction: inout Transaction) -> Bool {
        let held = keys?.arrows(of: column, in: table).filter { transaction.document[$0] != nil } ?? []
        let current = keys?.target(of: column, in: table)
        switch key {
        case .stored:
            return true
        case .none:
            if !held.isEmpty { transaction.delete(Set(held)) }
            return true
        case .to(let target):
            if current == target, !held.isEmpty { return true }
            let registry = transaction.shapes.registry
            if let arrow = held.first, let current, let record = transaction.document[arrow],
               let moved = record.movingParts(in: registry, { $0 == current ? target : $0 }) {
                transaction.update(arrow) { $0 = moved }
                return transaction.document[arrow]?.boundParts(in: registry).contains(target) == true
            }
            guard let made = registry.drawConnection(from: table, to: target.shape, in: transaction.shapes, parts: (column, target.part)) else { return false }
            transaction.insert(made)
            return transaction.document[made.id] != nil
        }
    }
}

/// What ⌘L's picker means on a table (`ConnectPicks`). Opened on a row being edited (a column), it lists the tables on the board and
/// their columns, never an enum or any other shape: a column picked is the key's far row, a table its primary key's, and the pick
/// draws the key in place of any the column had ("Connect"). Opened on the table, it lists the tables: one picked makes a key column
/// for it, named for it (`customer_id` for customers: the name, singular, and `_id`), typed as its primary key, after the table's own
/// keys, with its key drawn, one step, "Add Key Column".
@MainActor
enum KeyPicks {
    static func admits(_ pick: ConnectPick, _ editor: CanvasEditor) -> Bool {
        guard let far = editor.document[pick.to.shape]?.typed(as: DatabaseTable.self) else { return false }
        if pick.from.part != nil { return pick.to.part != nil || ColumnLineGrammar.primaryKey(of: far.props) != nil }
        return pick.to.part == nil && ColumnLineGrammar.primaryKey(of: far.props) != nil
    }

    static func plan(_ pick: ConnectPick, _ editor: CanvasEditor) -> ConnectPlan? {
        guard let far = editor.document[pick.to.shape]?.typed(as: DatabaseTable.self) else { return nil }
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
    /// `addresses` → `address_id`), its spaces underscores, lowercased; `_2`, `_3` after it where the table has the name already.
    static func keyColumnName(for table: String, among taken: [String]) -> String {
        var name = table.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "_")
        if name.hasSuffix("ies"), name.count > 3 {
            name = String(name.dropLast(3)) + "y"
        } else if ["sses", "xes", "ches", "shes", "zes"].contains(where: name.hasSuffix) {
            name = String(name.dropLast(2))
        } else if name.hasSuffix("s"), !name.hasSuffix("ss"), name.count > 1 {
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
    static func keyType(of type: String) -> String {
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
