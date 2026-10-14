import Canvas
import DrawScript
import Foundation

// Ids as names. A title is how a script names a shape; a shape with none is named by its id, in the query language's
// spelling (`#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`, what a query's row gives), wherever a statement names a shape the file
// already has: an edge's end, a delete, a placement's target, `in`, a shape statement that restates one, `share:`'s host.
// An id never makes a shape (one that names none is `unknown_id`), and names only a shape a title could (an arrow's or a
// reference's is `invalid_value`). It is found wherever the app can show the shape, as a title is: on the board the run
// draws on, or, for an edge's end, on another, through a stand-in. `FileNames.place(ofID:)` is the index by id, beside the one
// by title: the file's own, so it costs a lookup, never a pass over the file.

/// How a message and a row call an end of an edge: the title the shape has, and, for an end the statement wrote as an id, that
/// id as written. The same shape named either way is called by its title where it has one.
struct EndName {
    /// The shape's title, folded; nil when it has none.
    let title: String?
    /// The id, when the statement named the end by one.
    var id: ShapeID?
    /// That id as written (`#7C1E…`), for a message about a shape with no title.
    var idWritten: String?

    init(title: String?, id: ShapeID? = nil, idWritten: String? = nil) {
        self.title = title
        self.id = id
        self.idWritten = idWritten
    }

    /// For a message: the title in quotes, else the id as written.
    var said: String { title.map(quoted) ?? idWritten ?? "" }
    /// For a row: the title, else the id as written.
    var plain: String { title ?? idWritten ?? "" }
}

/// The boards the shapes a run deletes own, kept for as long as the set of deleted shapes is the same size: a run only adds to it, so
/// a name on a board off the root asks the file's subtrees once, never once a name.
@MainActor final class TakenBoards {
    private var count = -1
    private var boards: Set<BoardID> = []

    func boards(owned deleted: Set<ShapeID>, in file: CanvasFile) -> Set<BoardID> {
        if deleted.count != count {
            boards = deleted.isEmpty ? [] : Set(file.subtree(ownedBy: deleted))
            count = deleted.count
        }
        return boards
    }
}

extension Drawing {
    /// The id a script wrote, as the file keeps it. Naming a shape by id needs what names shapes, as a title does.
    func shapeID(_ text: String, _ statement: Statement) throws(DrawError) -> ShapeID {
        guard naming != nil else {
            throw DrawError(statement, .noNames, "ids name shapes, and nothing here gives shapes names",
                            hint: "leave ids out: without a plugin that names shapes, no shape can be named or found by name")
        }
        guard let uuid = UUID(uuidString: text) else {
            throw DrawError(statement, .notAnID, "\(ShapeName.idMark) takes a shape's id, and \(ShapeName.id(text).written) isn't one",
                            hint: "an id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a query's row gives it")
        }
        return ShapeID(uuid)
    }

    /// The shape an id names, among the file's, and the board it is on: the board the run draws on first, else any board the app
    /// can show. Why it names none: no shape has it, it is on a board the app can't show, it is kept aside, or it is a kind a
    /// title couldn't name (an arrow, a reference).
    func fileShape(withID id: ShapeID, written: String, _ statement: Statement) throws(DrawError) -> (record: AnyShapeRecord, board: BoardID) {
        let found: (record: AnyShapeRecord, board: BoardID)
        if let record = target.document[id] {
            found = (record, target.board)
        } else if let board = editor.file.board(containing: id), let record = editor.file.record(id) {
            guard editor.canShow(board) else {
                throw DrawError(statement, .unknownID, "\(written) is on a board the app can't show",
                                hint: "an id names a shape on a board the app can show")
            }
            found = (record, board)
        } else {
            throw DrawError(statement, .unknownID, "there's no shape with the id \(written)",
                            hint: "it may have been deleted: run the query that gave it again")
        }
        guard !found.record.isOpaque else {
            throw DrawError(statement, .unknownID, "\(written) is kept aside: the app can't read it")
        }
        guard registry.drawCanName(found.record.kind) else { throw Drawing.unnameable(written, found.record.kind, statement) }
        return found
    }

    /// The refusal of an id whose shape is a kind a title couldn't name, the same at every site that takes an id.
    static func unnameable(_ written: String, _ kind: ShapeKind, _ statement: Statement) -> DrawError {
        DrawError(statement, .invalidValue, "\(written) is \(indefinite(kind)), which a script can't name",
                  hint: "an id names a shape a title could name, a note say: name an arrow by its two ends, and a reference by the shape it stands for")
    }

    /// Whether this run deletes the shape, or the board it is on.
    func isDeleted(_ id: ShapeID, on board: BoardID) -> Bool {
        if deletedShapes.contains(id) { return true }
        guard !deletedShapes.isEmpty, !board.isRoot else { return false }
        return takenBoards.boards(owned: deletedShapes, in: editor.file).contains(board)
    }

    /// An id whose shape this script deletes: no shape to name once it has.
    func deletedID(_ written: String, _ statement: Statement, for what: String) -> DrawError {
        DrawError(statement, .unknownID, "\(what) \(written), which this script deletes",
                  hint: "leave it out, or leave the delete out: deletes are done before the statements that name shapes")
    }

    /// What a shape is called where a message names it: its title in quotes, else the id as written.
    func said(_ record: AnyShapeRecord, written: String) -> String {
        Drawing.title(of: record, names: names, naming: naming, registry: registry).map(quoted) ?? written
    }

    /// The shape a placement target, `in` or `share:` names by id: one the script restates (its item), else one on the board the run
    /// draws on; nil if one a statement that couldn't be resolved restates.
    func find(id: ShapeID, written: String, _ statement: Statement, for what: String) throws(DrawError) -> ShapeItem.Found? {
        if let index = itemByID[id] { return .item(index) }
        if unresolvedIDs.contains(id) { return nil }
        let shape = try fileShape(withID: id, written: written, statement)
        if isDeleted(id, on: shape.board) { throw deletedID(written, statement, for: what) }
        guard shape.board == target.board else { throw severalBoards(said: written, on: shape.board, statement, for: what) }
        return .shape(shape.record)
    }

    /// What an edge's end names by id: the item of the shape the script restates, a shape of the board, or one elsewhere in the
    /// file (the edge then goes through a stand-in beside the other end); a measure reads the open file's shape on any board.
    func endFound(id: ShapeID, written: String, _ statement: Statement) throws(DrawError) -> (found: EdgeEndFound, name: EndName) {
        if let index = itemByID[id] {
            return (.here(items[index].record.id, item: index), EndName(title: items[index].title, id: id, idWritten: written))
        }
        if unresolvedIDs.contains(id) { throw skip() }
        if measuring {
            let record = try measuredEnd(id: id, written: written, statement)
            return (.here(record.id, item: nil), EndName(title: Drawing.title(of: record, names: names, naming: naming, registry: registry),
                                                         id: id, idWritten: written))
        }
        let shape = try fileShape(withID: id, written: written, statement)
        if isDeleted(id, on: shape.board) { throw deletedID(written, statement, for: "an edge is drawn to") }
        let name = EndName(title: Drawing.title(of: shape.record, names: names, naming: naming, registry: registry), id: id, idWritten: written)
        if shape.board == target.board { return (.here(id, item: nil), name) }
        return (.away(FarShape(record: shape.record, board: shape.board)), name)
    }

    /// The shape an edge's end names by id in a measure: one the open file has, on any board (a measure draws no pill, so the
    /// ends are laid straight whatever boards they are on). With no board open, a name it can't find: a warning, and the shape
    /// is measured without the edge.
    func measuredEnd(id: ShapeID, written: String, _ statement: Statement) throws(DrawError) -> AnyShapeRecord {
        guard let record = namesBeyond?.shape(inFile: id), !record.isOpaque else {
            var missing = DrawError(statement, .unknownID, "there's no shape with the id \(written)")
            missing.fromNameLookup = true
            throw missing
        }
        guard registry.drawCanName(record.kind) else {
            var refused = DrawError(statement, .invalidValue, "\(written) is \(indefinite(record.kind)), which a script can't name")
            refused.fromNameLookup = true
            throw refused
        }
        return record
    }

    /// What a pill for the shape an id names is called in a measure: the open file's shape, if it has one.
    func measuredLabel(ofID text: String) -> String? {
        guard let uuid = UUID(uuidString: text), let record = namesBeyond?.shape(inFile: ShapeID(uuid)), !record.isOpaque else { return nil }
        return farLabel(of: record)
    }

    /// What a pill for a far shape is called: its title; failing that what Mentions would call it (a note with no title is
    /// called by its words or its values), else its kind's name.
    func farLabel(of record: AnyShapeRecord) -> String {
        Drawing.title(of: record, names: names, naming: naming, registry: registry)
            ?? registry.drawLabel(of: record) ?? "Untitled " + registry.label(of: record.kind).name
    }
}

extension FileNames {
    /// The shape with this id and the board it is on, when the app can show that board and the shape isn't kept aside: the index by
    /// id, beside the one by title (`places`), the file's own.
    func place(ofID id: ShapeID) -> Place? {
        guard let board = editor.file.board(containing: id), board == editor.board || editor.canShow(board),
              let record = editor.file.record(id), !record.isOpaque else { return nil }
        return (id, board)
    }

    /// What an id names as a shape that holds others, as `container(called:)` says it of a title.
    public func container(withID id: ShapeID) -> Container {
        guard let place = place(ofID: id), let record = editor.file.record(id) else { return .none }
        let registry = editor.registry
        if registry.boardOwningKinds.contains(record.kind) { return .board(BoardID(owner: id)) }
        if registry.isContainer(record) { return .shape(id, on: place.board) }
        return .holdsNone(record)
    }
}
