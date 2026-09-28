import CoreGraphics
import Geometry

/// The only way to change a document: `editor.transact { tx in ... }`. Everything in one
/// transaction commits together, into the undo step it's part of (`UndoHistory`: every commit from
/// a press to its release is one step, and so is every commit while a shape is being edited).
///
/// A board must always save, so a shape's frame stays finite: a shape inserted with a frame that
/// isn't (a NaN, an infinity) isn't inserted, and a change that would make one so is dropped.
///
/// A read-only shape (`registrar.readOnlyShapes`: a locked one) that was in the document before the
/// transaction isn't changed, restacked, moved or deleted by it, unless the change leaves it no
/// longer read-only (unlocking it). Whatever the transaction was asked to do to it is dropped, the
/// rest of the transaction stands, and once it's done services hear which shapes it refused
/// (`EditorService.didRefuseChanges`). What a deletion does to keep the board whole goes through,
/// read-only or not: its `willDelete` handlers' changes (a shape's dependents going with it), and
/// shapes letting go of what's deleted (`ShapeReferencing`).
///
/// A transaction is on one board of the file, the one the editor shows (`board`), and changes that
/// board's shapes. Two things reach the boards under them: deleting a shape takes the board it owns
/// with it, and every board under that (`ChangeSet.boardsRemoved`); and a shape can go in with its
/// board and the boards under it (`insert(_:contents:)`, a paste; `ChangeSet.boardsAdded`). A shape
/// whose board, or a board under it, holds a read-only shape isn't deleted, as the Finder won't trash
/// a folder holding a locked file. Shape ids are unique across the file: a shape inserted can't have
/// the id of one on any board.
@MainActor
public struct Transaction {
    public private(set) var document: CanvasDocument
    /// The board `document` is: the one the editor shows.
    public let board: BoardID
    let registry: Registry
    let camera: Camera
    let keys: StackingKeyGenerator
    /// The rest of the file, read from the editor as it is.
    let file: FileAccess
    /// Boards going in with the shapes inserted here that own them, and the boards under those, by
    /// owner: what the commit adds to the file.
    private(set) var stagedBoards: [ShapeID: CanvasDocument] = [:]
    /// The shapes on `stagedBoards`.
    private var stagedIDs: Set<ShapeID> = []
    private(set) var didChange = false
    /// What it did so far, record by record: what the commit hands services.
    private(set) var changes = ChangeSet()
    /// Read-only shapes it was asked to change, restack or delete, and didn't.
    private(set) var refused: Set<ShapeID> = []
    /// Shapes whose willDelete handlers have run in this transaction; removed together at the end
    /// of the outermost `delete`.
    private var deleting: Set<ShapeID> = []
    /// A deletion is keeping the board whole (its handlers, and letting go): nothing is refused.
    private var isCascading = false

    init(document: CanvasDocument, board: BoardID, registry: Registry, camera: Camera, keys: StackingKeyGenerator, file: FileAccess) {
        self.document = document
        self.board = board
        self.registry = registry
        self.camera = camera
        self.keys = keys
        self.file = file
    }

    /// Geometry lookups against the document as it is mid-transaction.
    public var shapes: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera) }

    public mutating func insert<P: ShapeProps>(_ shape: ShapeRecord<P>) { insert(AnyShapeRecord(shape)) }

    /// Adds on top. The shape's kind must be installed, and its id new to the file: on no board,
    /// unless this transaction deleted it from this one.
    public mutating func insert(_ record: AnyShapeRecord) { add(record) }

    /// Adds `record` on top, with the board it owns and the boards under that: `contents` holds its
    /// board under its id, and the boards below by their owners' ids (as a copied owner's are).
    /// Every shape in it must be new to the file, of an installed kind. A board in `contents` that
    /// `record` doesn't reach is left out, as is a shape whose frame isn't finite, with its board. If
    /// the insert itself is dropped (its frame isn't finite), or `record` is deleted later in the
    /// transaction, its boards go too.
    public mutating func insert(_ record: AnyShapeRecord, contents: [ShapeID: CanvasDocument]) {
        guard add(record) else { return }
        var owners = [record.id], next = 0, ids: Set<ShapeID> = [record.id]
        var fragment: [ShapeID: CanvasDocument] = [:]
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard let board = contents[owner] else { continue }
            var records: [AnyShapeRecord] = []
            for shape in board.shapes {
                precondition(ids.insert(shape.id).inserted && document[shape.id] == nil && isNewToFile(shape.id),
                             "a shape with id \(shape.id) is already in the file")
                precondition(registry.definition(for: shape.kind)?.erasedAccepts(shape) == true,
                             "no installed plugin defines \(shape.kind) shapes with these props")
                guard shape.box?.isFinite ?? true else { continue }
                records.append(registry.propertyTable.normalized(shape))
                owners.append(shape.id)
            }
            guard !records.isEmpty else { continue }
            fragment[owner] = CanvasDocument(shapes: records)
            stagedIDs.formUnion(records.map(\.id))
            changes.boardsAdded.insert(BoardID(owner: owner))
        }
        stagedBoards.merge(fragment) { _, new in new }
    }

    /// What the board `owner` owns holds, as this transaction leaves it: the boards going in with an
    /// insert, none for a board going with its owner, else the file's.
    public func contents(ofBoardOwnedBy owner: ShapeID) -> CanvasDocument {
        let board = BoardID(owner: owner)
        if let staged = stagedBoards[owner] { return staged }
        return changes.boardsRemoved.contains(board) ? CanvasDocument() : file.contents(board)
    }

    /// Returns whether it went in.
    @discardableResult
    private mutating func add(_ record: AnyShapeRecord) -> Bool {
        precondition(document[record.id] == nil && isNewToFile(record.id), "a shape with id \(record.id) already exists")
        precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                     "no installed plugin defines \(record.kind) shapes with these props")
        guard record.box?.isFinite ?? true else { return false }
        var record = registry.propertyTable.normalized(record)
        record.stackingKey = keys.key(between: document.shapes.last?.stackingKey, and: nil)
        document.append(record)
        changes.added.insert(record.id)
        changes.reordered = true
        didChange = true
        return true
    }

    /// On no board of the file, nor going in with one, unless this transaction deleted it from this
    /// board (it may go back in).
    private func isNewToFile(_ id: ShapeID) -> Bool {
        guard !stagedIDs.contains(id) else { return false }
        guard let board = file.locate(id) else { return true }
        return board == self.board && changes.removed.contains(id)
    }

    /// Changes one shape. Its id and stacking key stay as they were, whatever `body` does. A
    /// read-only shape keeps the change only if it leaves the shape no longer read-only.
    public mutating func update(_ id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let index = document.index(of: id) else { return }
        let old = document.shapes[index]
        var record = old
        body(&record)
        precondition(record.id == id, "a shape's id can't change")
        record.stackingKey = old.stackingKey
        // Values only for what its kind opts into.
        if record.added != old.added { record = registry.propertyTable.normalized(record) }
        guard record != old, record.box?.isFinite ?? true, !refuses(old, becoming: record) else { return }
        document.replace(at: index, with: record)
        noteChanged(id)
    }

    public mutating func update<P: ShapeProps>(_ id: ShapeID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id) { $0.modify(as: P.self, body) }
    }

    /// Whether this transaction keeps `old` as it is, and notes that it did: the shape was in the
    /// document before the transaction, is read-only, and would still be as `new` (nil: deleted,
    /// or moved in the stack, which leaves it as read-only as it was), and no deletion is keeping
    /// the board whole.
    private mutating func refuses(_ old: AnyShapeRecord, becoming new: AnyShapeRecord? = nil) -> Bool {
        guard !isCascading, registry.hasReadOnlyRules, !changes.added.contains(old.id), registry.isReadOnly(old),
              new.map(registry.isReadOnly) ?? true else { return false }
        refused.insert(old.id)
        return true
    }

    /// Moves shapes by `delta`, in world units, as dragging them that far would: a box by its
    /// frame, a `CustomTranslation` kind by its own rules (every `beginTranslation` first, then the
    /// boxes, then the rest, as a drag event does), anything else not at all. Read-only shapes
    /// stay, and the others move without them.
    public mutating func translate(_ ids: Set<ShapeID>, by delta: CGPoint) {
        var records = ids.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }
        records.removeAll { refuses($0) }
        let ids = Set(records.map(\.id))
        var boxes: [ShapeID] = []
        var moves: [@MainActor (CGPoint, inout Transaction) -> Void] = []
        for record in records {
            if let custom = registry.definition(for: record.kind) as? any CustomTranslation {
                if let move = custom.erasedBeginTranslation(of: record, movingWith: ids, in: &self) { moves.append(move) }
            } else if record.box != nil {
                boxes.append(record.id)
            }
        }
        for id in boxes {
            if let box = document[id]?.box { moveBox(id, to: box.origin + delta) }
        }
        for move in moves { move(delta, &self) }
    }

    /// Puts a box shape's frame at `origin`, its size as it was: a move, as `translate` and a drag
    /// make, which the commit's `ChangeSet` names in `moved` unless something else in the
    /// transaction changes the shape too. A shape without a box stays as it is, and so does a
    /// read-only one, as with `update`.
    public mutating func moveBox(_ id: ShapeID, to origin: CGPoint) {
        // Only moved, if nothing but moves changed it before in this transaction.
        let unchanged = !changes.added.contains(id) && (!changes.changed.contains(id) || changes.moved.contains(id))
        update(id) { $0.box?.origin = origin }
        if unchanged, changes.changed.contains(id) { changes.moved.insert(id) }
    }

    /// Paints the shape above every other. Does nothing if it's already on top, or read-only.
    public mutating func bringToFront(_ id: ShapeID) {
        guard let index = document.index(of: id), index != document.shapes.count - 1, !refuses(document.shapes[index]) else { return }
        document.moveToEnd(from: index, key: keys.key(between: document.shapes.last?.stackingKey, and: nil))
        noteChanged(id, reordering: true)
    }

    /// Paints the shape below every other. Does nothing if it's already at the bottom, or read-only.
    public mutating func sendToBack(_ id: ShapeID) {
        guard let index = document.index(of: id), index != 0, !refuses(document.shapes[index]) else { return }
        document.moveToStart(from: index, key: keys.key(between: nil, and: document.shapes.first?.stackingKey))
        noteChanged(id, reordering: true)
    }

    /// Puts a shape just above another in document order (a step forward, past `other`): a key
    /// between `other`'s and the next shape's. Does nothing if it's there already, or read-only.
    public mutating func move(_ id: ShapeID, above other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target + 1,
              !refuses(document.shapes[from]) else { return }
        let shapes = document.shapes
        let next = target + 1 < shapes.count ? shapes[target + 1].stackingKey : nil
        move(id, from: from, to: from < target ? target : target + 1, key: keys.key(between: shapes[target].stackingKey, and: next))
    }

    /// Puts a shape just below another in document order (a step back, past `other`): a key
    /// between the previous shape's and `other`'s. Does nothing if it's there already, or read-only.
    public mutating func move(_ id: ShapeID, below other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target - 1,
              !refuses(document.shapes[from]) else { return }
        let shapes = document.shapes
        let previous = target > 0 ? shapes[target - 1].stackingKey : nil
        move(id, from: from, to: from < target ? target - 1 : target, key: keys.key(between: previous, and: shapes[target].stackingKey))
    }

    private mutating func move(_ id: ShapeID, from: Int, to: Int, key: StackingKey) {
        document.move(from: from, to: to, key: key)
        noteChanged(id, reordering: true)
    }

    /// A shape added in this transaction stays added, however it changes after.
    private mutating func noteChanged(_ id: ShapeID, reordering: Bool = false) {
        if !changes.added.contains(id) { changes.changed.insert(id) }
        changes.moved.remove(id)
        if reordering { changes.reordered = true }
        didChange = true
    }

    /// First, while the shapes still exist, every plugin's `willDelete` handlers run, in this
    /// transaction, seeing every shape as it was; then every shape bound to one of them, and
    /// stays, lets go of it, as its kind says (`ShapeReferencing`: an arrow's end stays where it's
    /// drawn). Names of them (`ShapeNaming`, a mention) are never looked at: they stay as they
    /// were. Handlers may delete more shapes (a shape's dependents): each shape's handlers run and
    /// it's let go of once, and everything is removed together when the outermost `delete` returns.
    /// Read-only shapes asked for stay, and the others go without them; but what the handlers and
    /// letting go do, to keep the board whole, goes through, read-only or not: a read-only dependent
    /// goes with the shape it depends on, as a locked shape in tldraw goes with its deleted parent.
    ///
    /// Each shape deleted takes its board with it, and every board under that (whatever its kind:
    /// the file keeps a board by its owner's id), with no handlers run on them: nothing outside a
    /// board names a shape inside it. A shape asked for whose board, or a board under it, holds a
    /// read-only shape stays, refused, like a read-only shape.
    public mutating func delete(_ ids: Set<ShapeID>) {
        let ids = ids.filter { id in document[id].map { !refuses($0) && !refusesForContents($0) } ?? false }.subtracting(deleting)
        guard !ids.isEmpty else { return }
        let isOutermost = deleting.isEmpty
        deleting.formUnion(ids)
        let wasCascading = isCascading
        isCascading = true
        for handler in registry.willDeleteHandlers { handler(ids, &self) }
        letGo(of: ids)
        isCascading = wasCascading
        guard isOutermost else { return }
        document.remove(deleting)
        var owners: [ShapeID] = []
        for id in deleting {
            if changes.added.remove(id) == nil {                          // added and removed here: never seen
                changes.changed.remove(id)
                changes.moved.remove(id)
                changes.removed.insert(id)
                owners.append(id)
            } else {
                dropStagedBoards(ownedBy: id)
            }
        }
        changes.boardsRemoved.formUnion(file.subtree(Set(owners)))
        changes.reordered = true
        deleting = []
        didChange = true
    }

    /// Whether this transaction keeps a shape because of what its board holds, and notes that it
    /// did: it was in the file before the transaction, and its board, or a board under it, holds a
    /// read-only shape. As `refuses`, not while a deletion is keeping the board whole.
    private mutating func refusesForContents(_ record: AnyShapeRecord) -> Bool {
        guard !isCascading, registry.hasReadOnlyRules, !changes.added.contains(record.id) else { return false }
        let boards = file.subtree([record.id])
        guard boards.contains(where: { file.contents($0).shapes.contains(where: registry.isReadOnly) }) else { return false }
        refused.insert(record.id)
        return true
    }

    /// The boards an insert brought with `owner`, and those under them, no longer go in.
    private mutating func dropStagedBoards(ownedBy owner: ShapeID) {
        var owners = [owner], next = 0
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard let board = stagedBoards.removeValue(forKey: owner) else { continue }
            changes.boardsAdded.remove(BoardID(owner: owner))
            for record in board.shapes {
                stagedIDs.remove(record.id)
                owners.append(record.id)
            }
        }
    }

    /// Deletes these shapes as `delete` does, refusing none: what discarding shapes the app keeps
    /// aside does, on each board they're on.
    mutating func discard(_ ids: Set<ShapeID>) {
        let wasCascading = isCascading
        isCascading = true
        delete(ids)
        isCascading = wasCascading
    }

    /// Every shape bound to one of `ids`, and isn't being deleted too, lets go of it, read-only or
    /// not (`delete` runs this cascading): letting go keeps it as it's drawn, and a shape can't stay
    /// bound to one that's gone. One whose kind can't (it's bound to a shape it can't find) is left as
    /// it was. Only the kinds that bind are asked (`referencingKinds`); names (`ShapeNaming`) are
    /// never looked at.
    private mutating func letGo(of ids: Set<ShapeID>) {
        let kinds = registry.referencingKinds
        guard !kinds.isEmpty else { return }
        let context = shapes
        for record in document.shapes where kinds.contains(record.kind) && !deleting.contains(record.id) {
            guard let released = record.remappingReferences({ ids.contains($0) ? nil : $0 }, in: context), released != record else { continue }
            update(record.id) { $0 = released }
        }
    }
}

/// What a transaction reads of the file beyond its own board: closures over the editor's file as it
/// is, never a copy of it, so a commit (a drag's every event) doesn't copy the whole file's upkeep.
@MainActor
struct FileAccess {
    /// The board a shape is on (`CanvasFile.board(containing:)`).
    let locate: (ShapeID) -> BoardID?
    /// The boards these shapes own, and those under them (`CanvasFile.subtree(ownedBy:)`).
    let subtree: (Set<ShapeID>) -> [BoardID]
    /// A board's shapes (`CanvasFile[board]`).
    let contents: (BoardID) -> CanvasDocument

    /// Over a file of one's own.
    init(_ file: CanvasFile) {
        locate = { file.board(containing: $0) }
        subtree = { file.subtree(ownedBy: $0) }
        contents = { file[$0] }
    }

    init(locate: @escaping (ShapeID) -> BoardID?, subtree: @escaping (Set<ShapeID>) -> [BoardID],
         contents: @escaping (BoardID) -> CanvasDocument) {
        self.locate = locate
        self.subtree = subtree
        self.contents = contents
    }
}
