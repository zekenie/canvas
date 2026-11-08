import AppKit
import Canvas
import Connections
import Palette
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
    /// A table's keys: the far row of each column that starts one (the first, should a column start several).
    private var kept: [ShapeID: [PartID: PartAddress]] = [:]
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

    /// The columns of `table` that start a key, each with the row it goes to.
    func keys(of table: ShapeID) -> [PartID: PartAddress] {
        if let keys = kept[table] { return keys }
        var keys: [PartID: PartAddress] = [:]
        editor.topology?.forEachEdge(of: table, .outgoing, types: .only(type), view: .literal) { edge in
            guard edge.isConnection, let part = edge.sourcePart, keys[part] == nil else { return }
            keys[part] = PartAddress(edge.target, part: edge.targetPart)
        }
        kept[table] = keys
        return keys
    }

    /// The row `column` of `table`'s key goes to, by address, so its name is read live where it's said
    /// (`editor.accessibleName(of:)`: "id in customers"); nil for a column with no key.
    func target(of column: PartID, in table: ShapeID) -> PartAddress? { keys(of: table)[column] }
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

// The kit's kinds take what is bound to them along (the core's `TakesBoundShapes`): deleting a table deletes its keys
// ("Delete Table and 3 Arrows"), taking a column out deletes the keys at it ("Delete Column and 1 Arrow"), and copying tables
// copies the keys among them. Any other kind keeps tldraw's rule.
extension TableDefinition: TakesBoundShapes {}
extension EnumDefinition: TakesBoundShapes {}
extension DatabaseDefinition: TakesBoundShapes {}
