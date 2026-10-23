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
/// board's shapes. Five things reach other boards: deleting a shape takes the board it owns with it,
/// and every board under that (`ChangeSet.boardsRemoved`); shapes on any board can be deleted
/// (`delete(_:on:)`), with their handlers and the same cascade; a shape can go in with its board and the
/// boards under it (`insert(_:contents:)`, a paste; `ChangeSet.boardsAdded`); and shapes can move onto
/// any other board of the file (`move(_:to:)`, or `move(_:toBoardOwnedBy:)` onto the board a shape on
/// this one owns; `boardsAdded`, or `boardsChanged` if the board held shapes already, as the root
/// does), to be moved there (`translate(_:by:on:)`) and put down there by the in-or-out rule
/// (`settle(_:on:)`); and a shape on any board can be changed (`update(_:on:_:)`), in the same commit,
/// so the same undo step. `contents(of:)` is any board as the transaction leaves it. A shape whose
/// board, or a board under it, holds a read-only shape isn't deleted, as the Finder won't trash a
/// folder holding a locked file. Shape ids are unique across the file: a shape inserted can't have
/// the id of one on any board.
///
/// Containers (`ShapeContaining`: a frame) hold shapes on their board (`AnyShapeRecord.container`):
/// what a container holds moves with it (`translate`) and is restacked with it, read-only or not,
/// paints above it, and is read-only while it is (a shape in a read-only container changes not at
/// all, and nothing joins or leaves one); deleting a container lets go of what it holds into its own
/// container. `setContainer` puts a shape in one, and `settle` keeps what's put down from sitting
/// across a container's edge (Settling.swift).
///
/// A board is read-only while the shape that owns it is (a locked subboard, one in a locked frame,
/// one on a read-only board: `isBoardReadOnly`, the editor's rule), as a container is: every shape
/// that was on it before the transaction is held as a read-only one is, its own lock included, and
/// nothing goes on it (an insert, a move onto it), which services hear as its owner refused.
///
/// A shape can become another kind under its id (`turn`), so whatever binds or names it goes on
/// doing so.
///
/// The file's own values (`FileProperty`) are read and written here too (`fileValue`,
/// `setFileValue`), whatever board the transaction is on: they are the file's, so no board's lock
/// holds them, and they commit with the rest, in the same undo step.
@MainActor
public struct Transaction {
    public private(set) var document: CanvasDocument
    /// The board `document` is: the one the editor shows.
    public let board: BoardID
    /// Whether the board can't change: the shape that owns it can't (a rule says so of it, or of a
    /// container it's in), or the board that one's on can't, up to the root (`editor.isBoardReadOnly`
    /// on the board shown). Every shape that was on it before the transaction is held as a read-only
    /// one is (`isReadOnly(_:)`), and nothing goes on it: an insert is dropped, and services hear the
    /// board's owner refused, as a read-only container is when a shape would join it.
    public let isBoardReadOnly: Bool
    /// Whether what this transaction writes may reach the board the editor shows: false in a step on a board that
    /// is not shown (`transact(on:)`), and in what it does on other boards, since a commit that reached the board
    /// shown from there is dropped whole (`CanvasEditor.transact(on:)`). A `willDelete` handler that would write
    /// there must leave that part out when this is false (the core does not do it for the handler), or the whole step is lost.
    public internal(set) var mayReachBoardShown = true
    let registry: Registry
    let camera: Camera
    let keys: StackingKeyGenerator
    /// The rest of the file, read from the editor as it is.
    let file: FileAccess
    /// What the editor lays shapes out with, which `shapes` reads this transaction's file through;
    /// nil where there is no editor to ask (`discardKeptAside`).
    private let layout: LayoutSource?
    /// Boards going in with the shapes inserted here that own them, and the boards under those: what
    /// the commit adds to the file. Also the boards shapes were moved onto here (`move(_:to:)`), moved
    /// on (`translate(_:by:on:)`) or settled on (`settle(_:on:)`), whole, with what the file holds
    /// there already: what the commit adds, or, if the file held shapes there
    /// (`changes.boardsChanged`; the root always), writes over.
    private(set) var stagedBoards: [BoardID: CanvasDocument] = [:]
    /// The shapes inserted or moved onto `stagedBoards` here, each with the board it's on.
    private var stagedIDs: [ShapeID: BoardID] = [:]
    /// The boards shapes were moved onto here, moved on or settled on. None of them goes with a shape
    /// deleted in the same transaction, its owner or one above it (`delete` holds to it): what moved
    /// there would be dropped with the board, and the boards it owns left with no owner. No flow
    /// deletes a shape it has just moved shapes under.
    private var movedOnto: Set<BoardID> = []
    /// Every shape this transaction deleted, on whichever board, whether or not it was ever in the file
    /// (`delete`): none is on a board any more (`board(containing:)`), and `transact(on:)` commits nothing
    /// that deleted an owner on the way to the board shown.
    private(set) var deleted: Set<ShapeID> = []
    /// The owner of the board of the transaction that made this one over another board, and of each board
    /// above it (`delete(_:on:)`): this one deletes none of them, whoever asks, a handler included, as it
    /// passes over one it's asked for.
    private var kept: Set<ShapeID> = []
    /// The shapes whose deletion is under way in the transactions that made this one over another board
    /// (`delete(_:on:)`): a deletion of one of them, from here, is passed over, as one on a board is
    /// while it's under way, so each shape's handlers run once however the boards cross.
    private var enclosing: Set<ShapeID> = []
    /// The shapes `move(_:to:)` took along though they weren't asked for: an arrow bound only to shapes
    /// that moved (`rodeAlong`).
    private var rode: Set<ShapeID> = []
    /// What the moves of this transaction took along though nobody asked for it (`move(_:to:)`: an arrow
    /// bound only to shapes that moved): a caller that moves shapes onto a board and puts them where they
    /// land (`translate(_:by:on:)`) translates these with them, so what is drawn against them (a free
    /// end of an arrow) keeps its place against them. The rule for what rides is the core's, here.
    public var rodeAlong: Set<ShapeID> { rode }
    /// Whether it changed a board: its own, or one it staged. (The file's values aside: `hasChanges`.)
    private(set) var didChange = false
    /// The file's values as it leaves them (`FileProperty`), once it has written one; nil while it
    /// hasn't, and they are the file's (`file.values`).
    private(set) var stagedFileValues: FileValues?
    /// Whether there is anything to commit: a board changed, or one of the file's values.
    var hasChanges: Bool { didChange || !changes.fileValues.isEmpty }
    /// Every write that is not a move, in order, one entry for each time a shape was added, changed other than by
    /// moving it, staged or deleted: what `LayoutReading.isChanged` reads as a set, kept as a log so whoever keeps
    /// an answer over the changed shapes applies only the entries since it last asked (`LayoutReading.changes`).
    /// Append-only; a shape appears as often as it was written.
    private var writes: [ShapeID] = []
    /// The shapes written on other boards (a transaction over another board's writes, taken in): changed as `isChanged` says.
    private var writtenElsewhere: Set<ShapeID> = []
    /// Which transaction's log this is: a number no other transaction has (`LayoutReading.runID`).
    private let run = LayoutSource.nextRun()
    /// What it did so far, record by record: what the commit hands services.
    private(set) var changes = ChangeSet()
    /// What it has done so far, as its commit would hand it to services were it to end now: the shapes of its own
    /// board it added, changed (those it only moved in `moved`) and removed, and, in `elsewhere`, those it wrote on
    /// other boards of the file (and the shapes of a board it takes; the shapes a handler it ran on another board wrote back on this one may be among them too, which a commit's own `elsewhere` never holds). For what says, before a commit,
    /// what the commit would touch: a run that may never commit asks a rule which shapes its writes reach
    /// (Validation's `touches`). A value: taken again after the next write.
    public var pending: ChangeSet {
        var pending = changes
        pending.elsewhere = writtenElsewhere
        // As the commit hands it: every shape of a board the transaction takes goes with it.
        for board in changes.boardsRemoved { pending.elsewhere.formUnion(file.contents(board).shapes.lazy.map(\.id)) }
        return pending
    }
    /// Read-only shapes it was asked to change, restack, move or delete, and didn't (and read-only
    /// containers that wouldn't take a shape: `setContainer`, `settle`; and the owners of read-only
    /// boards that wouldn't: `insert`, `move(_:to:)`).
    var refused: Set<ShapeID> = []
    /// The read-only shapes it was asked to change, restack, move or delete so far, and didn't, and
    /// read-only containers that wouldn't take a shape, and the owners of read-only boards that
    /// wouldn't: what `editor.transactWhole` reads, so work that must change everything or nothing
    /// commits nothing and shakes them.
    public var refusedShapes: Set<ShapeID> { refused }
    /// Shapes whose willDelete handlers have run in this transaction; removed together at the end
    /// of the outermost `delete`.
    private var deleting: Set<ShapeID> = []
    /// A deletion is keeping the board whole (its handlers, and letting go): nothing is refused.
    private var isCascading = false
    /// Shapes moved with a container that moves (`translate`, a drag): read-only or not, they go
    /// with it, as letting go goes through a lock.
    var carrying: Set<ShapeID> = []
    /// Where each container worked out so far tops out in the stack, itself and what it holds
    /// (`topIndex(of:)`): kept while nothing moves in the stack (anything restacked, inserted or
    /// deleted forgets them all), so shapes joining a container one at a time look at what it holds
    /// once.
    private var tops: [ShapeID: Int] = [:]

    init(document: CanvasDocument, board: BoardID, isBoardReadOnly: Bool, registry: Registry, camera: Camera, keys: StackingKeyGenerator,
         file: FileAccess, layout: LayoutSource?) {
        self.layout = layout
        self.document = document
        self.board = board
        self.isBoardReadOnly = isBoardReadOnly
        self.registry = registry
        self.camera = camera
        self.keys = keys
        self.file = file
    }

    /// Whether a shape on this board can't change: a plugin's rule says so of it, or of a container it's
    /// in, at any depth (everything in a locked frame is locked too), or the board can't
    /// (`isBoardReadOnly`). What the transaction holds it to, if it was there before the transaction (a
    /// shape it put in isn't held: a paste moves its locked copies into place). O(the shape's depth).
    public func isReadOnly(_ record: AnyShapeRecord) -> Bool {
        isBoardReadOnly || registry.isReadOnly(record, in: document)
    }

    /// Whether an agent makes the change (the command line's `draw`), not a person at the app: its
    /// commit says so (`ChangeSet.byAgent`), so what acts on a person's edits (a type's sync)
    /// takes what it changed as it is. Saying so changes nothing by itself.
    public var byAgent: Bool {
        get { changes.byAgent }
        set { changes.byAgent = newValue }
    }

    /// Geometry lookups against the document as it is mid-transaction. Layout inputs are read through
    /// it as the transaction leaves the file: a provider is handed what it inserted, changed and moved
    /// (and nothing of what it deleted), and a value set for a shape (`editor.setLayoutInput`) is read
    /// for one it hasn't changed. A shape it didn't touch reads the size the editor has kept for it; one
    /// with none kept is laid out against this transaction's file. The context is a snapshot: read it, use it, and let it go before the
    /// next change, or that change copies what it holds.
    public var shapes: ShapeContext {
        guard let layout else { return ShapeContext(document: document, registry: registry, camera: camera) }
        let here = self
        // Only what it reads of the file's values, not another copy of the transaction.
        let staged = stagedFileValues, held = file.values
        let source = LayoutSource(inputs: layout.inputs, sizes: layout.sizes, lend: layout.lend, shape: { here.record(inFile: $0) },
                                  board: { here.board(containing: $0) }, fileValues: { staged ?? held() }, isChanged: { id in
            here.changes.added.contains(id) || (here.changes.changed.contains(id) && !here.changes.moved.contains(id))
                || here.stagedIDs[id] != nil || here.writtenElsewhere.contains(id)
        }, writes: writes, run: run)
        return ShapeContext(document: document, registry: registry, camera: camera, index: nil, layout: source)
    }

    /// A shape on any board of the file as this transaction leaves it (`location(of:)`).
    func record(inFile id: ShapeID) -> AnyShapeRecord? {
        location(of: id).flatMap { contents(of: $0)[id] }
    }

    // MARK: The file's values

    /// The file's values as this transaction leaves them.
    var fileValues: FileValues { stagedFileValues ?? file.values() }

    /// One of the file's own values (`FileProperty`), as this transaction leaves it: what it set,
    /// else what the file holds, else the property's default.
    public func fileValue<P: FileProperty>(_: P.Type) -> P.Value { fileValues[P.self] }

    /// Sets one of the file's own values (`FileProperty`), whatever board the transaction is on. It
    /// commits with the rest of the transaction, as one undo step, and services hear which
    /// (`ChangeSet.fileValues`); a transaction that only does this changes no shape and no board.
    /// Setting the default takes the value off the file. Setting what it already is changes nothing
    /// (alone, it commits nothing and opens no step). Dropped, as a shape's value is for a kind that
    /// doesn't opt in, for a property no installed plugin declares (`registrar.declare(file:)`), and
    /// for one whose value in the file the app can't use and keeps aside (`file.keptFileValues`). No
    /// board's lock holds it: it is the file's.
    public mutating func setFileValue<P: FileProperty>(_: P.Type, to value: P.Value) {
        guard registry.declares(file: P.self) else { return }
        var values = fileValues
        let old = values[P.self]
        values[P.self] = value
        guard values[P.self] != old else { return }
        stagedFileValues = values
        // Set back to what the file holds, it's no change.
        if FileValues.same(values[P.key], file.values()[P.key]) {
            changes.fileValues.remove(P.key)
        } else {
            changes.fileValues.insert(P.key)
        }
    }

    /// Takes in the file's values a transaction over another board wrote (`transaction(on:)`).
    private mutating func takeFileValues(of there: Transaction) {
        guard let values = there.stagedFileValues else { return }
        stagedFileValues = values
        changes.fileValues = values.keysDiffering(from: file.values())
    }

    public mutating func insert<P: ShapeProps>(_ shape: ShapeRecord<P>) { insert(AnyShapeRecord(shape)) }

    /// Adds on top. The shape's kind must be installed, and its id new to the file: on no board,
    /// unless this transaction deleted it, from this board or another. A read-only board (`isBoardReadOnly`) takes
    /// nothing: the shape doesn't go in, and services hear the board's owner refused.
    public mutating func insert(_ record: AnyShapeRecord) { add(record) }

    /// Adds `record` on top, with the board it owns and the boards under that: `contents` holds its
    /// board under its id, and the boards below by their owners' ids (as a copied owner's are).
    /// Every shape in it must be new to the file, of an installed kind. A board in `contents` that
    /// `record` doesn't reach is left out, as is a shape whose frame isn't finite, with its board. If
    /// the insert itself is dropped (its frame isn't finite, or this board is read-only), or `record`
    /// is deleted later in the transaction, its boards go too.
    public mutating func insert(_ record: AnyShapeRecord, contents: [ShapeID: CanvasDocument]) {
        guard add(record) else { return }
        var owners = [record.id], next = 0, ids: Set<ShapeID> = [record.id]
        var fragment: [BoardID: CanvasDocument] = [:]
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard let board = contents[owner] else { continue }
            var records: [AnyShapeRecord] = [], below: [ShapeID: AnyShapeRecord] = [:]
            for shape in board.shapes {
                precondition(ids.insert(shape.id).inserted && document[shape.id] == nil && isNewToFile(shape.id),
                             "a shape with id \(shape.id) is already in the file")
                precondition(registry.definition(for: shape.kind)?.erasedAccepts(shape) == true,
                             "no installed plugin defines \(shape.kind) shapes with these props")
                guard shape.box?.isFinite ?? true else { continue }
                var record = keptInStep(registry.propertyTable.normalized(shape), before: nil)
                // In a container on its own board below it, as the board it came from had it.
                if let container = record.container, record.box == nil || !(below[container].map(registry.isContainer) ?? false) {
                    record.container = nil
                }
                records.append(record)
                below[record.id] = record
                owners.append(shape.id)
            }
            guard !records.isEmpty else { continue }
            let owned = BoardID(owner: owner)
            fragment[owned] = CanvasDocument(shapes: records)
            for record in records {
                stagedIDs[record.id] = owned
                writes.append(record.id)
            }
            changes.boardsAdded.insert(owned)
        }
        stagedBoards.merge(fragment) { _, new in new }
    }

    /// A board of the file as this transaction leaves it: `document` for its own; a board going in with
    /// an insert, or that shapes were moved onto or settled on here (`move(_:to:)`, `settle(_:on:)`);
    /// none for a board going with its owner; else the file's.
    public func contents(of board: BoardID) -> CanvasDocument {
        if board == self.board { return document }
        if let staged = stagedBoards[board] { return staged }
        return changes.boardsRemoved.contains(board) ? CanvasDocument() : file.contents(board)
    }

    /// What the board `owner` owns holds, as this transaction leaves it (`contents(of:)`).
    public func contents(ofBoardOwnedBy owner: ShapeID) -> CanvasDocument { contents(of: BoardID(owner: owner)) }

    /// Returns whether it went in.
    @discardableResult
    private mutating func add(_ record: AnyShapeRecord) -> Bool {
        precondition(document[record.id] == nil && isNewToFile(record.id), "a shape with id \(record.id) already exists")
        precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                     "no installed plugin defines \(record.kind) shapes with these props")
        guard record.box?.isFinite ?? true else { return false }
        // A read-only board takes nothing, as a read-only container doesn't: its owner is heard refused.
        guard !isBoardReadOnly else {
            if let owner = board.owner { refused.insert(owner) }
            return false
        }
        var record = keptInStep(registry.propertyTable.normalized(record), before: nil)
        record.stackingKey = keys.key(between: document.shapes.last?.stackingKey, and: nil)
        // A container it comes with (a paste's copy, `copy(as:container:)`) it's in if that's a
        // container on the board by now that takes it; else it's on the board directly.
        if let container = record.container, !takes(container, record) { record.container = nil }
        tops = [:]
        document.append(record)
        changes.added.insert(record.id)
        writes.append(record.id)
        changes.reordered = true
        didChange = true
        return true
    }

    /// Whether a shape going in can be in `container`: a box, and a container on this board that takes
    /// it; a read-only one doesn't, and services hear it was refused.
    private mutating func takes(_ container: ShapeID, _ record: AnyShapeRecord) -> Bool {
        guard record.box != nil, let holder = document[container], registry.isContainer(holder) else { return false }
        guard !holds(holder) else {
            refused.insert(container)
            return false
        }
        return true
    }

    /// On no board of the file, nor going in with one, unless this transaction deleted it, from this
    /// board or another (it may go back in).
    private func isNewToFile(_ id: ShapeID) -> Bool {
        guard stagedIDs[id] == nil else { return false }
        guard let board = file.locate(id) else { return true }
        return board == self.board && changes.removed.contains(id) || deleted.contains(id)
    }

    /// Changes one shape. Its id, stacking key and container stay as they were, whatever `body`
    /// does (`setContainer` changes a container). A read-only shape keeps the change only if it
    /// leaves the shape no longer read-only, and a shape in a read-only container, or on a read-only
    /// board, keeps none.
    public mutating func update(_ id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let index = document.index(of: id) else { return }
        let old = document.shapes[index]
        var record = old
        body(&record)
        precondition(record.id == id, "a shape's id can't change")
        record.stackingKey = old.stackingKey
        record.containerBits = old.containerBits
        // Values only for what its kind opts into, and what its kind keeps in step with them.
        if record.added != old.added { record = keptInStep(registry.propertyTable.normalized(record), before: old) }
        guard record != old, record.box?.isFinite ?? true, !refuses(old, becoming: record) else { return }
        document.replace(at: index, with: record)
        noteChanged(id)
    }

    public mutating func update<P: ShapeProps>(_ id: ShapeID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id) { $0.modify(as: P.self, body) }
    }

    /// `record` with what its kind keeps in step (`keepsInStep`) as it's written: `before` is the shape
    /// as it was, nil for one going in. Its values as its kind has them after, and its id, place in the
    /// stack and container as they were.
    private func keptInStep(_ record: AnyShapeRecord, before: AnyShapeRecord?) -> AnyShapeRecord {
        guard !record.isOpaque else { return record }
        let rules = registry.stepRules(for: record.kind)
        guard !rules.isEmpty else { return record }
        var kept = record
        for rule in rules { rule(before, &kept) }
        precondition(kept.id == record.id, "a shape's id can't change")
        kept.stackingKey = record.stackingKey
        kept.containerBits = record.containerBits
        return kept.added == record.added ? kept : registry.propertyTable.normalized(kept)
    }

    /// Whether this transaction keeps `old` as it is, and notes that it did: the shape was in the
    /// document before the transaction, no deletion is keeping the board whole, a container that
    /// moves isn't carrying it, and it's read-only: by a rule, and would still be as `new` (nil:
    /// deleted, or moved in the stack, which leaves it as read-only as it was), or in a read-only
    /// container, or on a read-only board, either of which holds it whatever the change.
    private mutating func refuses(_ old: AnyShapeRecord, becoming new: AnyShapeRecord? = nil) -> Bool {
        guard !isCascading, registry.hasReadOnlyRules, !changes.added.contains(old.id), carrying.isEmpty || !carrying.contains(old.id),
              isBoardReadOnly || registry.isReadOnly(old) && (new.map(registry.isReadOnly) ?? true)
                || registry.isInsideReadOnlyContainer(old, in: document)
        else { return false }
        refused.insert(old.id)
        return true
    }

    /// Whether this transaction holds a shape as it is, as `refuses` would, noting nothing: it was in
    /// the document before the transaction, and it, a container it's in, or the board, is read-only.
    func holds(_ record: AnyShapeRecord) -> Bool {
        !isCascading && registry.hasReadOnlyRules && !changes.added.contains(record.id) && (carrying.isEmpty || !carrying.contains(record.id))
            && (isBoardReadOnly || registry.isReadOnly(record) || registry.isInsideReadOnlyContainer(record, in: document))
    }

    /// Moves shapes by `delta`, in world units, as dragging them that far would: a box by its
    /// frame, a `CustomTranslation` kind by its own rules (every `beginTranslation` first, then the
    /// boxes, then the rest, as a drag event does), anything else not at all. What a container holds
    /// moves with it, at any depth, read-only or not, once however it's asked for. Read-only shapes
    /// stay (and what's in them), and the others move without them.
    public mutating func translate(_ ids: Set<ShapeID>, by delta: CGPoint) { _ = translated(ids, by: delta) }

    /// `translate`, saying what moved: the shapes asked for that aren't held, and what they carry.
    mutating func translated(_ ids: Set<ShapeID>, by delta: CGPoint) -> [ShapeID] {
        let asked = ids.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }
        let (records, carried) = moving(asked)
        let wasCarrying = carrying
        carrying.formUnion(carried)
        defer { carrying = wasCarrying }
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
        return records.map(\.id)
    }

    /// Of `asked` (back to front), what moves: those that aren't held, and what the containers among
    /// them hold, at any depth, read-only or not (`carried`), each once, back to front. A shape asked
    /// for inside another asked for is carried by it, or, if that one is held, held with it.
    mutating func moving(_ asked: [AnyShapeRecord]) -> (records: [AnyShapeRecord], carried: Set<ShapeID>) {
        let kinds = registry.containingKinds
        guard !kinds.isEmpty, document.namesContainers else { return (asked.filter { !refuses($0) }, []) }
        let askedIDs = Set(asked.map(\.id)), document = document
        func isInsideAsked(_ record: AnyShapeRecord) -> Bool {
            record.namesContainer && document.containers(of: record.id, containingKinds: kinds).contains(where: askedIDs.contains)
        }
        var roots: [AnyShapeRecord] = []
        for record in asked where !isInsideAsked(record) && !refuses(record) { roots.append(record) }
        var carried: Set<ShapeID> = []
        for root in roots { carried.formUnion(document.descendants(of: root.id, containingKinds: kinds)) }
        // Asked for inside a container that stays: held with it.
        for record in asked where !carried.contains(record.id) && isInsideAsked(record) { _ = refuses(record) }
        guard !carried.isEmpty else { return (roots, []) }
        let ids = Set(roots.map(\.id)).union(carried)
        return (ids.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }, carried)
    }

    /// Puts a box shape's frame at `origin`, its size as it was: a move, as `translate` and a drag
    /// make, which the commit's `ChangeSet` names in `moved` unless something else in the
    /// transaction changes the shape too. A shape without a box stays as it is, and so does a
    /// read-only one, as with `update`.
    public mutating func moveBox(_ id: ShapeID, to origin: CGPoint) {
        // Only moved, if nothing but moves changed it before in this transaction.
        let unchanged = !changes.added.contains(id) && (!changes.changed.contains(id) || changes.moved.contains(id))
        let logged = writes.count
        update(id) { $0.box?.origin = origin }
        if unchanged, changes.changed.contains(id) {
            changes.moved.insert(id)
            // A move is no write: the log has what `isChanged` reads.
            writes.removeSubrange(logged...)
        }
    }

    // Restacking. A container takes what it holds along, at any depth, in its order, just above it
    // (read-only or not, as moving it does), and a shape in a container goes no lower than just
    // above it: a container's contents paint above it.

    /// Paints the shape above every other, what it holds just above it. Does nothing if it's already
    /// on top, or read-only.
    public mutating func bringToFront(_ id: ShapeID) {
        guard let index = document.index(of: id) else { return }
        let block = block(of: id, at: index)
        // The top shape that stays.
        var anchor = document.shapes.count - 1, last = block.count - 1
        while last >= 0, block[last] == anchor {
            anchor -= 1
            last -= 1
        }
        guard last >= 0, !refuses(document.shapes[index]) else { return }
        restack(block, above: anchor)
    }

    /// Paints the shape below every other, what it holds just above it; one in a container, just
    /// above its container. Does nothing if it's there already, or read-only.
    public mutating func sendToBack(_ id: ShapeID) {
        guard let index = document.index(of: id) else { return }
        let block = block(of: id, at: index), floor = floor(of: document.shapes[index])
        guard !Self.isBlock(block, justAbove: floor), !refuses(document.shapes[index]) else { return }
        restack(block, above: floor)
    }

    /// Puts a shape just above another in document order (a step forward, past `other`): a key
    /// between `other`'s and the next shape's; what it holds just above it. One in a container goes
    /// no lower than just above it. Does nothing if it's there already, if `other` is in it, or if
    /// it's read-only.
    public mutating func move(_ id: ShapeID, above other: ShapeID) {
        guard id != other, let from = document.index(of: id), var anchor = document.index(of: other) else { return }
        let block = block(of: id, at: from)
        guard !Self.has(block, anchor) else { return }
        if let floor = floor(of: document.shapes[from]), anchor < floor { anchor = floor }
        guard !Self.isBlock(block, justAbove: anchor), !refuses(document.shapes[from]) else { return }
        restack(block, above: anchor)
    }

    /// Puts a shape just below another in document order (a step back, past `other`): a key
    /// between the previous shape's and `other`'s; what it holds just above it. One in a container
    /// goes no lower than just above it. Does nothing if it's there already, if `other` is in it, or
    /// if it's read-only.
    public mutating func move(_ id: ShapeID, below other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other) else { return }
        let block = block(of: id, at: from)
        guard !Self.has(block, target) else { return }
        // Just above the nearest shape below `other` that stays.
        var anchor: Int? = target - 1
        while let below = anchor, below >= 0, Self.has(block, below) { anchor = below - 1 }
        if anchor == -1 { anchor = nil }
        if let floor = floor(of: document.shapes[from]), (anchor ?? -1) < floor { anchor = floor }
        guard !Self.isBlock(block, justAbove: anchor), !refuses(document.shapes[from]) else { return }
        restack(block, above: anchor)
    }

    /// Paints the shapes above every other, keeping their order among themselves, each with what it
    /// holds just above it. A shape that is on top already, or read-only, stays.
    public mutating func bringToFront(_ ids: [ShapeID]) {
        for id in backToFront(ids) { bringToFront(id) }
    }

    /// Paints the shapes below every other, keeping their order among themselves, each with what it
    /// holds just above it; one in a container, just above its container. A shape that is there
    /// already, or read-only, stays.
    public mutating func sendToBack(_ ids: [ShapeID]) {
        for id in backToFront(ids).reversed() { sendToBack(id) }
    }

    /// tldraw's Bring Forward: each shape moves just past the nearest shape above it that overlaps
    /// it and isn't moving too, nor held in it (a container's contents go with it); past a shape it
    /// doesn't overlap, a move would change nothing to see. The topmost shape moves first, so the
    /// shapes keep their order among themselves. A shape with nothing to pass stays, as does a
    /// read-only one. Shapes painted by anchor (`PaintOrderAnchored`) don't count.
    public mutating func bringForward(_ ids: [ShapeID]) { step(ids, forward: true) }

    /// tldraw's Send Backward: each shape moves just below the nearest shape under it that overlaps
    /// it and isn't moving too, nor held in it (a container's contents go with it). The lowest
    /// shape moves first, so the shapes keep their order among themselves. A shape with nothing to
    /// pass stays, as does a read-only one. Shapes painted by anchor (`PaintOrderAnchored`) don't
    /// count.
    public mutating func sendBackward(_ ids: [ShapeID]) { step(ids, forward: false) }

    /// So the shapes keep their order among themselves.
    private func backToFront(_ ids: [ShapeID]) -> [ShapeID] {
        ids.sorted { (document.index(of: $0) ?? 0) < (document.index(of: $1) ?? 0) }
    }

    private mutating func step(_ ids: [ShapeID], forward: Bool) {
        let moving = Set(ids)
        func bounds(_ id: ShapeID) -> CGRect? { shapes.geometry(of: id)?.bounds }
        let ordered = backToFront(ids)
        for id in forward ? ordered.reversed() : ordered {
            guard let index = document.index(of: id), let mine = bounds(id) else { continue }
            let all = document.shapes
            let passing = forward ? Array(all[(index + 1)...]) : all[..<index].reversed()
            // What a container holds goes with it, so it's never the shape it steps past.
            let held = Set(document.descendants(of: id, containingKinds: registry.containingKinds))
            let next = passing.first { other in
                !moving.contains(other.id) && !held.contains(other.id) && !(registry.definition(for: other.kind) is any PaintOrderAnchored)
                    && bounds(other.id).map { $0.intersects(mine) } == true
            }
            guard let next else { continue }
            if forward { move(id, above: next.id) } else { move(id, below: next.id) }
        }
    }

    /// The shape at `index` and what it holds, at any depth, by their indices, ascending: what
    /// restacking it moves.
    private func block(of id: ShapeID, at index: Int) -> [Int] {
        guard !registry.containingKinds.isEmpty, document.namesContainers, document.shapesNaming(id).isEmpty == false else { return [index] }
        return ([index] + document.descendantIndices(of: id, containingKinds: registry.containingKinds)).sorted()
    }

    /// Where the shape's container is in the stack, which it goes no lower than just above; nil for
    /// a shape on the board directly.
    private func floor(of record: AnyShapeRecord) -> Int? {
        guard record.namesContainer else { return nil }
        return document.container(of: record, containingKinds: registry.containingKinds).flatMap { document.index(of: $0) }
    }

    /// Whether `block` (ascending) has `index`: a binary search, as a container's block may be long.
    private static func has(_ block: [Int], _ index: Int) -> Bool {
        var low = 0, high = block.count
        while low < high {
            let middle = (low + high) / 2
            if block[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low < block.count && block[low] == index
    }

    /// Whether the shapes at `block` are just above `anchor`, one after another (at the bottom, for nil).
    private static func isBlock(_ block: [Int], justAbove anchor: Int?) -> Bool {
        let start = (anchor ?? -1) + 1
        return block.enumerated().allSatisfy { $0.element == start + $0.offset }
    }

    /// Moves the shapes at `block` (ascending indices, none of them `anchor`) to just above the shape
    /// at `anchor`, or to the bottom for nil, in their order, with keys between its key and the
    /// next shape's that stays: a shape alone by one key there, as it always was.
    private mutating func restack(_ block: [Int], above anchor: Int?) {
        tops = [:]
        let shapes = document.shapes
        var next = (anchor ?? -1) + 1
        while next < shapes.count, Self.has(block, next) { next += 1 }
        let low = anchor.map { shapes[$0].stackingKey } ?? nil, high = next < shapes.count ? shapes[next].stackingKey : nil
        let ids = block.map { shapes[$0].id }
        if block.count == 1 {
            let from = block[0]
            document.move(from: from, to: anchor.map { from < $0 ? $0 : $0 + 1 } ?? 0, key: keys.key(between: low, and: high))
        } else {
            document.move(block, above: anchor, keys: stackingKeys(block.count, between: low, and: high))
        }
        for id in ids { noteChanged(id, reordering: true) }
    }

    /// `count` keys rising between `low` and `high`: on top, each above the one before, so they stay
    /// short; between two, by halving, so they grow with the logarithm of how many.
    private func stackingKeys(_ count: Int, between low: StackingKey?, and high: StackingKey?) -> [StackingKey] {
        guard count > 0 else { return [] }
        guard high != nil else {
            var made: [StackingKey] = [], previous = low
            for _ in 0..<count {
                let key = keys.key(between: previous, and: nil)
                made.append(key)
                previous = key
            }
            return made
        }
        let middle = keys.key(between: low, and: high), lower = (count - 1) / 2
        return stackingKeys(lower, between: low, and: middle) + [middle] + stackingKeys(count - 1 - lower, between: middle, and: high)
    }

    // MARK: Containers

    /// Puts a shape in a container on this board (a shape of a `ShapeContaining` kind), or, with nil,
    /// on the board directly: what it holds goes with it. Joining raises it, with what it holds, just
    /// above what the container holds already, if it's below that, so it paints above them; leaving
    /// keeps its place. Only a box shape is put in a container, never in itself or in a shape it
    /// holds, nor in one on another board: those ask for nothing. Read-only, it's refused, and so is
    /// a read-only container it would join (services hear it was the container: nothing joins a
    /// locked frame); a shape in a read-only container is read-only, so nothing leaves one either.
    public mutating func setContainer(_ id: ShapeID, to container: ShapeID?) { setContainer([id], to: container) }

    /// Puts shapes in a container on this board, or on the board directly, as `setContainer(_:to:)`
    /// puts each, in one look at what the container holds: those below it rise together, in their
    /// order. For many shapes at once (a selection grouped), where one at a time would look at what
    /// the container holds for each.
    public mutating func setContainer(_ ids: [ShapeID], to container: ShapeID?) {
        var holder: AnyShapeRecord?
        if let container {
            guard let found = document[container], registry.isContainer(found) else { return }
            holder = found
        }
        var joining: [ShapeID] = [], seen: Set<ShapeID> = []
        for id in ids where seen.insert(id).inserted {
            guard let record = document[id], record.box != nil, record.container != container else { continue }
            if let container, let holder {
                guard !isInside(container, id) else { continue }
                var joined = record
                joined.container = container
                guard !refuses(record, becoming: joined) else { continue }
                guard !holds(holder) else {
                    refused.insert(container)
                    return
                }
            } else {
                guard !refuses(record) else { continue }
            }
            joining.append(id)
        }
        join(joining, container)
    }

    /// Whether `shape` is `ancestor`, or in it at any depth, as the board keeps containers (usable or
    /// not): putting `ancestor` in `shape` would make a loop.
    private func isInside(_ shape: ShapeID, _ ancestor: ShapeID) -> Bool {
        var next: ShapeID? = shape, steps = 0
        while let id = next, steps <= document.shapes.count {
            if id == ancestor { return true }
            next = document[id]?.container
            steps += 1
        }
        return false
    }

    /// `setContainer`, asked nothing, for several shapes at once: what settling does once it's worked
    /// out what goes where. Those that join a container rise as `raise(_:into:)` says, together.
    mutating func join(_ ids: [ShapeID], _ container: ShapeID?) {
        // Where what the container holds tops out before they join it, unless one of them is in it
        // already (then worked out with them left out, as they rise).
        var top: Int?
        if let container, !ids.contains(where: { document.containers(of: $0, containingKinds: registry.containingKinds).contains(container) }) {
            top = topIndex(of: container)
        }
        var joined: [ShapeID] = []
        for id in ids where name(container, for: id) { joined.append(id) }
        if let container, !joined.isEmpty { raise(joined, into: container, above: top) }
    }

    /// Where the topmost of a container and what it holds, at any depth, is in the stack, kept for
    /// the transaction while nothing moves in it (`tops`).
    private mutating func topIndex(of container: ShapeID) -> Int? {
        if let top = tops[container] { return top }
        guard let index = document.index(of: container) else { return nil }
        let top = max(index, document.topIndex(heldBy: container, excluding: [], containingKinds: registry.containingKinds) ?? index)
        tops[container] = top
        return top
    }

    /// Names `container` as the shape's, raising nothing; whether that changed it.
    mutating func name(_ container: ShapeID?, for id: ShapeID) -> Bool {
        guard let index = document.index(of: id), document.shapes[index].container != container else { return false }
        // What the containers it leaves hold may top out lower now.
        if !tops.isEmpty { for left in document.containers(of: id, containingKinds: registry.containingKinds) { tops[left] = nil } }
        var record = document.shapes[index]
        record.container = container
        document.replace(at: index, with: record)
        noteChanged(id)
        return true
    }

    /// Raises shapes that have just joined a container, each with what it holds, to just above what
    /// the container held already (or the container itself; `top`, where that tops out, if it's
    /// known), those that are below that, together, in their order. One look at what the container
    /// holds, however many joined it, and none for one joined after another while the stack stays as
    /// it is.
    mutating func raise(_ ids: [ShapeID], into container: ShapeID, above top: Int? = nil) {
        guard let holder = document.index(of: container) else { return }
        var blocks: [(index: Int, block: [Int])] = []
        for id in ids { if let index = document.index(of: id) { blocks.append((index, block(of: id, at: index))) } }
        let anchor = top ?? max(holder, document.topIndex(heldBy: container, excluding: Set(blocks.lazy.flatMap(\.block)),
                                                          containingKinds: registry.containingKinds) ?? holder)
        let rising = Set(blocks.lazy.filter { $0.index < anchor }.flatMap(\.block)).sorted()
        guard !rising.isEmpty else {
            // Nothing moved in the stack: what the container, and those it's in, hold tops out higher.
            let highest = blocks.lazy.compactMap(\.block.last).max() ?? anchor
            for held in [container] + document.containers(of: container, containingKinds: registry.containingKinds) {
                if let kept = tops[held] { tops[held] = max(kept, highest) }
            }
            return
        }
        restack(rising, above: anchor)
    }

    /// A shape added in this transaction stays added, however it changes after.
    private mutating func noteChanged(_ id: ShapeID, reordering: Bool = false) {
        if !changes.added.contains(id) { changes.changed.insert(id) }
        changes.moved.remove(id)
        writes.append(id)
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
    /// the file keeps a board by its owner's id; but not the board of a shape a handler moved off the
    /// boards it was under, which stays with it), with no handlers run on them: nothing outside a
    /// board names a shape inside it. A shape asked for whose board, or a board under it, holds a
    /// read-only shape stays, refused, like a read-only shape. A container deleted lets go of what
    /// it holds, which stays where it is, now in the container's own container (the nearest one up
    /// that isn't deleted too), read-only or not; a shape in a read-only container is read-only, so
    /// it stays, as the container does. A shape can't be deleted in the transaction that moved shapes
    /// onto its board, or a board under it (`move(_:to:)`), or settled shapes there (`settle(_:on:)`).
    public mutating func delete(_ ids: Set<ShapeID>) {
        let ids = ids.filter { id in document[id].map { !refuses($0) && !refusesForContents($0) } ?? false }
            .subtracting(deleting).subtracting(enclosing).subtracting(kept)
        guard !ids.isEmpty else { return }
        precondition(movedOnto.allSatisfy { climb($0).ownerHere.map { !ids.contains($0) } ?? true },
                     "a shape can't be deleted in the transaction that moved shapes onto its board, or onto a board under it")
        let isOutermost = deleting.isEmpty
        deleting.formUnion(ids)
        let wasCascading = isCascading
        isCascading = true
        for handler in registry.willDeleteHandlers { handler(ids, &self) }
        letGo(of: ids)
        isCascading = wasCascading
        guard isOutermost else { return }
        if document.namesContainers { release(from: deleting) }
        tops = [:]
        document.remove(deleting)
        for id in deleting {
            writes.append(id)
            if changes.added.remove(id) == nil {                          // added and removed here: never seen
                changes.changed.remove(id)
                changes.moved.remove(id)
                changes.removed.insert(id)
            } else {
                dropStagedBoards(ownedBy: id)
            }
        }
        deleted.formUnion(deleting)
        // The boards the file has under them, a shape moved here from another board included: it owns
        // its boards wherever it is.
        // But not the board of a shape that left them by now (a handler moved it onto another board).
        changes.boardsRemoved.formUnion(file.subtree(deleting).filter { board in board.owner.map { isUnder(deleting, $0) } ?? false })
        // What a handler wrote on a board that goes with the deletion goes with it (`update(_:on:)`).
        for board in changes.boardsRemoved where stagedBoards[board] != nil && !movedOnto.contains(board) {
            stagedBoards[board] = nil
            changes.boardsChanged.remove(board)
        }
        changes.reordered = true
        deleting = []
        didChange = true
    }

    /// `delete(_:)` on any board of the file, over that board as this transaction leaves it
    /// (`transaction(on:readingThrough:)`): the handlers run there, with `tx.board` that board and every
    /// shape as it was (bound, in place, in its container), bindings are let go of and containers
    /// released there, and the boards under what is deleted go (`boardsRemoved`), all in this
    /// transaction's commit, so in the same undo step, services hearing the shapes in `elsewhere`. What a
    /// handler wrote on other boards, this one's too, is taken in. A read-only shape there stays, refused
    /// (`refusedShapes`), unless a deletion is keeping the board whole (`isCascading`). The board is
    /// staged but not reserved (`update(_:on:_:)`), so a deletion in the same transaction of its owner,
    /// or above, is allowed and takes what was deleted with the board. Nothing for a board the editor
    /// couldn't show once this transaction commits, or one that goes with a shape deleted earlier. The
    /// owner of this transaction's board, and of each board above it, stays whoever asks for it, a handler
    /// there included (it would take the board this transaction is on; `transact(on:)` commits nothing
    /// then). A shape this transaction brought onto `board` may be deleted there, with the boards it
    /// owns. A shape whose deletion is under way, here or in a transaction that made this one, isn't
    /// deleted again by a handler there: each shape's handlers run once however the boards cross. On
    /// this transaction's own board it's `delete(_:)`.
    public mutating func delete(_ ids: Set<ShapeID>, on board: BoardID) {
        guard board != self.board else { return delete(ids) }
        guard !climb(board).isTaken, var there = transaction(on: board, readingThrough: true) else { return }
        there.kept = kept.union(owners(above: self.board))
        there.enclosing = enclosing.union(deleting)
        there.isCascading = isCascading
        there.movedOnto = movedOnto
        there.delete(ids)
        absorb(there)
    }

    /// `delete(_:on:)` for shapes on whichever boards they are on (`board(containing:)`): one
    /// `delete(_:on:)` a board, the deepest first (ties by the board's name), so the owner of a board
    /// named beside shapes on it goes after them, whose handlers run: the same call on the same file
    /// gives the same file. Nothing for a shape on none.
    public mutating func delete(inFile ids: Set<ShapeID>) {
        var byBoard: [BoardID: Set<ShapeID>] = [:]
        for id in ids { if let board = location(of: id) { byBoard[board, default: []].insert(id) } }
        // The deepest board first, so a board's owner is deleted after the shapes asked for on it, whose handlers run:
        // the same call gives the same file, whatever order a dictionary holds.
        let order = byBoard.keys.map { (board: $0, depth: depth(of: $0)) }
            .sorted { ($0.depth, $0.board.description) > ($1.depth, $1.board.description) }
        for (board, _) in order { delete(byBoard[board] ?? [], on: board) }
    }

    /// How many owners are above a board, each where this transaction leaves it.
    private func depth(of board: BoardID) -> Int {
        var count = 0, current = board, met: Set<BoardID> = []
        while let owner = current.owner, met.insert(current).inserted {
            count += 1
            guard let at = location(of: owner) else { break }
            current = at
        }
        return count
    }

    /// Whether `owner` is one of `ids` or on a board under one of them, each where this transaction leaves it.
    private func isUnder(_ ids: Set<ShapeID>, _ owner: ShapeID) -> Bool {
        var current = owner, met: Set<ShapeID> = []
        while met.insert(current).inserted {
            if ids.contains(current) { return true }
            guard let at = location(of: current), let up = at.owner else { return false }
            current = up
        }
        return false
    }

    /// The owner of `board`, and of each board above it, where this transaction leaves them.
    private func owners(above board: BoardID) -> Set<ShapeID> {
        var owners: Set<ShapeID> = [], current = board, met: Set<BoardID> = []
        while let owner = current.owner, met.insert(current).inserted {
            owners.insert(owner)
            guard let at = location(of: owner) else { break }
            current = at
        }
        return owners
    }

    /// Takes in what a deletion in a transaction over another board did: that board as it leaves it, if
    /// anything went from it; the boards under what went, which go from this one's too, as `delete`
    /// drops them; and what a handler there wrote on other boards (`take` drops these three): the boards
    /// it staged, this one among them (each shape compared with this board as it was: one that differs is
    /// changed, one gone is removed, one that came, moved on or put in, is added, or changed if this
    /// transaction had taken it off, and it is on no other board; the stack changed if the order of its
    /// shapes is not what it was), and the shapes it moved. What this transaction had
    /// brought onto that board and is gone now, named or not, is on no board and brings no boards in.
    private mutating func absorb(_ there: Transaction) {
        refused.formUnion(there.refused)
        takeInWrites(of: there)
        deleted.formUnion(there.deleted)
        rode.formUnion(there.rode)
        for id in there.deleted { stagedIDs[id] = nil }
        changes.boardsRemoved.formUnion(there.changes.boardsRemoved)
        for gone in there.changes.boardsRemoved where stagedBoards[gone] != nil && !movedOnto.contains(gone) {
            for record in stagedBoards.removeValue(forKey: gone)?.shapes ?? [] { stagedIDs[record.id] = nil }
            changes.boardsChanged.remove(gone)
        }
        for id in there.deleted { dropStagedBoards(ownedBy: id) }
        for (staged, document) in there.stagedBoards where !changes.boardsRemoved.contains(staged) {
            guard staged == self.board else {
                stage(document, on: staged, reserving: there.movedOnto.contains(staged))
                continue
            }
            // What a handler wrote on this board: shapes changed, left, or come (moved on, or put in), as
            // the board is by now against what it was before; one that came is no longer on another board.
            for record in self.document.shapes {
                guard let now = document[record.id] else {
                    writes.append(record.id)
                    if changes.added.remove(record.id) == nil {
                        changes.changed.remove(record.id)
                        changes.moved.remove(record.id)
                        changes.removed.insert(record.id)
                    }
                    continue
                }
                if now != record { noteChanged(record.id, reordering: now.stackingKey != record.stackingKey) }
            }
            for record in document.shapes where self.document[record.id] == nil {
                if changes.removed.remove(record.id) != nil { changes.changed.insert(record.id) } else { changes.added.insert(record.id) }
                writes.append(record.id)
                stagedIDs[record.id] = nil
            }
            if !document.shapes.lazy.map(\.id).elementsEqual(self.document.shapes.lazy.map(\.id)) { changes.reordered = true }
            self.document = document
            tops = [:]
            didChange = true
        }
        if there.didChange { stage(there.document, on: there.board, reserving: false) }
        for (id, staged) in there.stagedIDs where staged != self.board {
            stagedIDs[id] = staged
            writes.append(id)
        }
    }

    /// Every shape that names one of `deleted` as its container, and stays, goes into the nearest
    /// container above that one that isn't deleted, or onto the board directly: as the board keeps
    /// containers, usable or not, read-only or not, keeping the board whole as letting go does. It
    /// keeps its place in the stack, which is above that container's.
    private mutating func release(from deleted: Set<ShapeID>) {
        for container in deleted {
            let named = document.shapesNaming(container)
            guard !named.isEmpty else { continue }
            var target = document[container]?.container, steps = 0
            while let id = target, deleted.contains(id), steps <= document.shapes.count {
                target = document[id]?.container
                steps += 1
            }
            for id in named where !deleted.contains(id) {
                guard let index = document.index(of: id) else { continue }
                var record = document.shapes[index]
                record.container = target
                document.replace(at: index, with: record)
                noteChanged(id)
            }
        }
    }

    /// Whether this transaction keeps a shape because of what its board holds, and notes that it
    /// did: the file has a board of its own, or under it, that holds a read-only shape (one brought
    /// from another board has its boards still; one put in with this transaction has none). As
    /// `refuses`, not while a deletion is keeping the board whole.
    private mutating func refusesForContents(_ record: AnyShapeRecord) -> Bool {
        guard !isCascading, registry.hasReadOnlyRules else { return false }
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
            guard let board = stagedBoards.removeValue(forKey: BoardID(owner: owner)) else { continue }
            changes.boardsAdded.remove(BoardID(owner: owner))
            changes.boardsChanged.remove(BoardID(owner: owner))
            for record in board.shapes {
                stagedIDs[record.id] = nil
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

    // MARK: Turning, and moving to another board

    /// Turns a shape into another kind: `record`'s kind and props in place of its own, the same shape
    /// otherwise. It keeps its id, so whatever binds or names it still does (an arrow's end, a
    /// mention), its place in the stack, its container and its metadata, and the values of its added
    /// properties that its new kind holds too (a title); `record`'s added values fill in the rest
    /// (defaults, or what a placement set), and its id, stacking key and container are ignored. Only
    /// a box shape is in a container, so one turned into a kind with no box is on the board directly.
    /// The new kind must be installed, and accept `record`'s props. A container (`ShapeContaining`)
    /// turned into a kind that isn't one lets go of what it holds, as deleting it does: those shapes
    /// stay where they are, in its own container. A shape of a kind that owns boards (`BoardOwning`)
    /// whose board holds shapes can only be turned into a kind that owns boards, so no board is left
    /// without an owner: move its shapes out first.
    ///
    /// Returns whether the shape is now as `record` says. It isn't for a shape that isn't on this
    /// board or is kept aside, one whose new frame isn't finite (as `update` drops it), and a read-only
    /// shape (or one in a read-only container, or on a read-only board), refused as `update` refuses
    /// it, which services hear.
    @discardableResult
    public mutating func turn(_ id: ShapeID, into record: AnyShapeRecord) -> Bool {
        precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                     "no installed plugin defines \(record.kind) shapes with these props")
        guard let index = document.index(of: id), !document.shapes[index].isOpaque else { return false }
        let old = document.shapes[index]
        var new = AnyShapeRecord(id: id, kind: record.kind, props: record.props, stackingKey: old.stackingKey, meta: old.meta)
        new.added = record.added
        new.added.overlay(old.added)
        if new.box != nil { new.containerBits = old.containerBits }
        new = registry.propertyTable.normalized(new)
        if new.added != old.added || new.kind != old.kind { new = keptInStep(new, before: old) }
        guard new.box?.isFinite ?? true else { return false }
        precondition(!registry.ownsShowableBoard(old) || registry.boardOwningKinds.contains(new.kind) || contents(of: BoardID(owner: id)).shapes.isEmpty,
                     "a shape that owns a board with shapes can only be turned into a kind that owns boards: move its shapes out first")
        guard new != old else { return true }
        guard !refuses(old, becoming: new) else { return false }
        if registry.isContainer(old), !registry.isContainer(new) { release(from: [id]) }
        tops = [:]
        document.replace(at: index, with: new)
        noteChanged(id)
        return true
    }

    /// `turn(_:into:)` a shape of `props`' kind, with those props and the defaults of its added
    /// properties.
    @discardableResult
    public mutating func turn<P: ShapeProps>(_ id: ShapeID, into props: P) -> Bool {
        turn(id, into: AnyShapeRecord(ShapeRecord(props)))
    }

    /// Moves shapes on this board onto the board `owner` owns (a shape on this board of a kind that
    /// owns boards, not among them), as `move(_:to:)` moves them. It's false, nothing moving and
    /// nothing refused, for an `owner` that isn't on this board or owns no board (a shape whose turn
    /// into a kind that owns one was refused).
    @discardableResult
    public mutating func move(_ ids: Set<ShapeID>, toBoardOwnedBy owner: ShapeID) -> Bool {
        // An owner that isn't here, or owns no board (a turn into a kind that owns one was refused):
        // nothing to move onto, so nothing moves.
        guard let holder = document[owner], registry.ownsShowableBoard(holder) else { return false }
        return move(ids, to: BoardID(owner: owner))
    }

    /// Moves shapes on this board onto another board of the file, under their ids: on top of what that
    /// board holds as this transaction leaves it (`contents(of:)`), in their order, each with its props,
    /// added values and metadata, and with what it owns (a board goes with its owner wherever that is).
    /// What a container among them holds goes with it, at any depth, and so does a shape that binds
    /// (`ShapeReferencing`: an arrow) to some of what moves and to nothing else, wherever it is on this
    /// board and whether it was named or not, unless it's read-only: a read-only one stays, and lets go
    /// of what moves below. Such a shape is judged against what moves before any of them joined, so one
    /// bound only to another that rides along stays and lets go of it, whatever the order of the stack;
    /// `rodeAlong` names them, for a caller that puts what moved down (`translate(_:by:on:)`) to translate
    /// them too. (tldraw's move between pages takes only the shapes it is given and their
    /// descendants, and an arrow it isn't given stays, unbound.) A shape stays in a container that
    /// moves with it, and is in none there otherwise, until it's put down there (`settle(_:on:)`). Ids
    /// not on this board are passed over. The commit says the board is new to the file (`boardsAdded`),
    /// or changed if it held shapes already (`boardsChanged`; the root always), and what moved removed
    /// from this one; undoing it puts every shape back, in its place in the stack.
    ///
    /// Bindings (`ShapeReferencing`: an arrow's ends) are to shapes on the same board, so those across
    /// the edge are let go of, as deleting the shape would: a shape that stays lets go of what moves
    /// (an arrow's end stays where it's drawn), and one that moves of what stays, read-only or not. An
    /// arrow bound only to shapes that move isn't across the edge: it moves with them.
    /// Names (`ShapeNaming`: a mention) may be of a shape on any board, and stay as they are.
    ///
    /// All or nothing for read-only shapes: if a shape that would move is read-only (or in a read-only
    /// container, or this board is read-only), or the board's owner is (as `setContainer` holds a
    /// container, on its own board as this transaction leaves it, a board up the tree from it being
    /// read-only too: the board itself is), nothing moves, services hear which were refused
    /// (`refusedShapes`), and this returns false. It's false too, nothing moving and nothing refused, for a board the
    /// editor couldn't show once this transaction commits (`canShow`'s rule, each owner on the way up
    /// where this transaction leaves it: one not in the file, kept aside, or of a kind that owns no
    /// board). Nothing else is asked of a shape that moves (no handlers run). `board` can't be this
    /// one, one going with a shape this transaction deleted, or the board of a shape that moves or one
    /// under it (a loop); and a shape that owns a board shapes were moved onto, or is above one, can't
    /// be deleted in the same transaction.
    @discardableResult
    public mutating func move(_ ids: Set<ShapeID>, to board: BoardID) -> Bool {
        precondition(board != self.board, "shapes can't move onto the board they're on")
        let kinds = registry.containingKinds
        var moving: Set<ShapeID> = []
        for id in ids where document[id] != nil {
            moving.insert(id)
            moving.formUnion(document.descendants(of: id, containingKinds: kinds))
        }
        let way = climb(board)
        precondition(!way.isTaken, "shapes can't move onto a board that goes with a shape deleted in the same transaction")
        precondition(way.ownerHere.map { !moving.contains($0) } ?? true,
                     "a shape can't move onto its own board or one under it, nor onto those of a shape a container that moves holds")
        // A board it couldn't show (an owner kept aside, or of a kind that owns none: a turn into one
        // refused): nothing to move onto, so nothing moves.
        guard way.canShow else { return false }
        guard !moving.isEmpty else { return true }
        // Every shape refused is noted, so each is heard refused.
        var isRefused = false
        if let owner = board.owner, holdsOwner(owner) {
            refused.insert(owner)
            isRefused = true
        }
        for index in moving.compactMap({ document.index(of: $0) }).sorted() where refuses(document.shapes[index]) { isRefused = true }
        guard !isRefused else { return false }
        // Bindings, both ways, while every shape is still here: an arrow lets go of an end where it's
        // drawn. One bound only to shapes that move moves with them, unless it's read-only (it stays,
        // and lets go below, as a lock doesn't stand in the way of a move being whole).
        let referencing = registry.referencingKinds
        if !referencing.isEmpty {
            let context = shapes, movers = moving
            for record in document.shapes where referencing.contains(record.kind) && !movers.contains(record.id) {
                if !holds(record), record.isBound(onlyTo: movers, in: context) {
                    moving.insert(record.id)
                    rode.insert(record.id)
                }
            }
            let wasCascading = isCascading
            isCascading = true
            for record in document.shapes where referencing.contains(record.kind) {
                let isMoving = moving.contains(record.id)
                guard let released = record.remappingReferences({ moving.contains($0) == isMoving ? $0 : nil }, in: context),
                      released != record else { continue }
                update(record.id) { $0 = released }
            }
            isCascading = wasCascading
        }
        // Off this board, as they are by now, back to front, each in the container it's in if that
        // moves too.
        var leaving: [AnyShapeRecord] = []
        for index in moving.compactMap({ document.index(of: $0) }).sorted() {
            var record = document.shapes[index]
            if let container = record.container, !moving.contains(container) { record.container = nil }
            leaving.append(record)
        }
        tops = [:]
        document.remove(moving)
        for id in moving {
            writes.append(id)
            if changes.added.remove(id) == nil {                          // added and moved here: never on this board
                changes.changed.remove(id)
                changes.moved.remove(id)
                changes.removed.insert(id)
            }
        }
        // On the other, above what it holds as this transaction leaves it.
        var target = contents(of: board)
        for var record in leaving {
            record.stackingKey = keys.key(between: target.shapes.last?.stackingKey, and: nil)
            target.append(record)
        }
        stage(target, on: board)
        for id in moving { stagedIDs[id] = board }
        changes.reordered = true
        return true
    }

    /// Moves shapes on any board of the file onto another, as `move(_:to:)` moves this board's: from
    /// `source` as this transaction leaves it, onto `destination` (this board too: on top of what it
    /// holds, the shapes `added` here, or `changed` if they were here before this transaction), with
    /// what a container among them holds and the boards they own, their bindings across the edge let
    /// go both ways, names kept, all or nothing for read-only shapes there and for `destination`'s
    /// owner. The commit says `source` changed (`boardsChanged`, what left it `elsewhere`); undoing it
    /// puts every shape back. False, nothing moving and nothing refused, for a `source` or a
    /// `destination` the editor couldn't show once this transaction commits. On this board it's
    /// `move(_:to:)`; `destination` can't be `source`, nor under a shape that moves (a loop).
    @discardableResult
    public mutating func move(_ ids: Set<ShapeID>, from source: BoardID, to destination: BoardID) -> Bool {
        guard source != board else { return move(ids, to: destination) }
        precondition(destination != source, "shapes can't move onto the board they're on")
        guard var there = transaction(on: source, readingThrough: true) else { return false }
        let moved = there.move(ids, to: destination)
        refused.formUnion(there.refused)
        takeFileValues(of: there)
        guard moved else { return false }
        rode.formUnion(there.rode)
        if there.didChange { stage(there.document, on: source) }
        for (staged, document) in there.stagedBoards {
            guard staged == board else {
                stage(document, on: staged)
                continue
            }
            // Onto this board: on top of `document` as it was read, so it's `document` with them on top.
            let arrived = Set(there.stagedIDs.lazy.filter { $0.value == staged }.map(\.key))
            self.document = document
            tops = [:]
            for id in arrived {
                if changes.removed.remove(id) != nil { changes.changed.insert(id) } else { changes.added.insert(id) }
                writes.append(id)
                stagedIDs[id] = nil
            }
            changes.reordered = true
            didChange = true
        }
        for (id, staged) in there.stagedIDs where staged != board {
            stagedIDs[id] = staged
            writes.append(id)
        }
        return true
    }

    /// `move(_:above:)` on another board of the file, over that board as this transaction leaves it,
    /// as `translate(_:by:on:)` moves shapes there: what this transaction brought there isn't held, and
    /// a read-only shape that was there stays, refused. On this transaction's own board it's
    /// `move(_:above:)`; a board the editor couldn't show changes nothing.
    public mutating func move(_ id: ShapeID, above other: ShapeID, on board: BoardID) {
        guard board != self.board else { return move(id, above: other) }
        guard var there = transaction(on: board) else { return }
        there.move(id, above: other)
        take(there)
    }

    /// `move(_:below:)` on another board of the file, as `move(_:above:on:)` restacks there.
    public mutating func move(_ id: ShapeID, below other: ShapeID, on board: BoardID) {
        guard board != self.board else { return move(id, below: other) }
        guard var there = transaction(on: board) else { return }
        there.move(id, below: other)
        take(there)
    }

    /// Moves shapes on another board of the file by `delta` (world units), as `translate` moves them on
    /// this one (what a container holds goes along): over that board as this transaction leaves it
    /// (`contents(of:)`), as `settle(_:on:)` settles there, so what `move(_:to:)` took there goes where
    /// it should there after its bindings across the edge were let go where it was drawn. What this
    /// transaction brought there (moved, or in with its owner) isn't held, as what it adds here isn't;
    /// a read-only shape that was there before stays, refused (`refusedShapes`). On this transaction's
    /// own board it's `translate`; a board the editor couldn't show moves nothing. `board` can't be one
    /// going with a shape this transaction deleted.
    public mutating func translate(_ ids: Set<ShapeID>, by delta: CGPoint, on board: BoardID) {
        guard board != self.board else { return translate(ids, by: delta) }
        guard var there = transaction(on: board) else { return }
        there.translate(ids, by: delta)
        take(there)
    }

    // MARK: Writing to other boards

    /// The board a shape is on, as this transaction leaves the file: this one; the one it moved the
    /// shape onto, or brought it in on; else the file's. Nil for a shape on no board of the file, and
    /// for one this transaction deleted or took the board of.
    public func board(containing id: ShapeID) -> BoardID? { location(of: id) }

    /// Changes one shape on any board of the file, as `update(_:_:)` changes one on this board: its id,
    /// stacking key and container stay as they were, and the change lands in this transaction's commit,
    /// so it is in the same undo step as everything else the transaction does, and undo and redo put
    /// the other board's shape back and again exactly, with this board's. The board is read as this
    /// transaction leaves it (`contents(of:)`), so a shape moved onto it, or inserted with it, can be
    /// written there. Services hear it as a commit that changed that board (`ChangeSet.boardsChanged`,
    /// the shape in `elsewhere`), in the same commit as this board's.
    ///
    /// Nothing happens for a shape that isn't on `board`, for a board the editor couldn't show once this
    /// transaction commits (`canShow`'s rule: an owner kept aside, or of a kind that owns no board), or
    /// for one that goes with a shape this transaction deleted. A shape written to in a `willDelete`
    /// handler on a board that goes with the same deletion leaves no trace: the board is gone, and undo
    /// brings it back as it was.
    ///
    /// Read-only shapes and boards are held as on this board: a shape that was there before the
    /// transaction and is read-only (or in a read-only container, or on a read-only board) keeps its
    /// change only if it leaves the shape no longer read-only, and is noted in `refusedShapes`, which
    /// services hear refused once the transaction is done; what this transaction put on that board
    /// isn't held. Inside a deletion keeping the board whole (a `willDelete` handler) nothing is held,
    /// as nothing is on this board: the handler's writes go through a lock, a read-only shape
    /// depending on what's deleted among them, wherever it is.
    ///
    /// On this transaction's own board it's `update(_:_:)`. It can't reach the board shown from a
    /// transaction on another board (`transact(on:)` commits nothing then, as when it moves shapes onto
    /// it).
    public mutating func update(_ id: ShapeID, on board: BoardID, _ body: (inout AnyShapeRecord) -> Void) {
        guard board != self.board else { return update(id, body) }
        guard !climb(board).isTaken, var there = transaction(on: board), there.document[id] != nil else { return }
        there.isCascading = isCascading
        // `there` reads the board as this transaction leaves it, sharing its storage with the copy this one
        // has staged: a write would copy the board's whole array of shapes, again for every shape written
        // (n shapes on a board of m cost n times m). This transaction lets go of its copy while `there`
        // writes, and takes the result back (or the copy, if nothing changed).
        let wasStaged = stagedBoards.removeValue(forKey: board) != nil
        there.update(id, body)
        if there.didChange {
            take(there, reserving: false)
        } else {
            refused.formUnion(there.refused)
            if wasStaged { stagedBoards[board] = there.document }
        }
    }

    /// `update(_:on:_:)`, with the shape's props typed.
    public mutating func update<P: ShapeProps>(_ id: ShapeID, on board: BoardID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id, on: board) { $0.modify(as: P.self, body) }
    }

    /// `update(_:on:_:)` on whichever board the shape is on (`board(containing:)`); nothing for a shape
    /// on none.
    public mutating func update(inFile id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let board = location(of: id) else { return }
        update(id, on: board, body)
    }

    /// Puts `document` in for another board, as this transaction leaves it: what the commit adds to the
    /// file, or, if the file held shapes there (the root always does), writes over; nothing, if the file
    /// held none and it holds none now. No shape this transaction deletes may take it with it
    /// (`movedOnto`).
    private mutating func stage(_ document: CanvasDocument, on board: BoardID, reserving: Bool = true) {
        if stagedBoards[board] == nil {
            if board.isRoot || (!changes.boardsRemoved.contains(board) && !file.contents(board).shapes.isEmpty) {
                changes.boardsChanged.insert(board)
            } else {
                changes.boardsAdded.insert(board)
            }
        }
        stagedBoards[board] = document
        if reserving { movedOnto.insert(board) }
        // A board the file held none of, and that holds none by now (what moved onto it went again, or was
        // deleted there), was not added.
        if document.shapes.isEmpty, changes.boardsAdded.remove(board) != nil { stagedBoards[board] = nil }
        didChange = true
    }

    /// A board as this transaction leaves the file, climbing its owners, each where this transaction
    /// leaves it (`location(of:)`): whether the editor could show it once this transaction commits
    /// (`canShow`'s rule; above this board the file's path holds, as nothing here moves an owner up
    /// there); whether it goes with a shape this transaction deleted (an owner on the way up was in the
    /// file, and is on no board now); and the owner on the way up that's on this board, if the way
    /// comes through here: no shape moves onto a board under itself, nor is deleted from over one it
    /// moved shapes onto.
    private func climb(_ board: BoardID) -> (canShow: Bool, isTaken: Bool, ownerHere: ShapeID?) {
        var current = board, met: Set<BoardID> = [board], showable = true
        while let owner = current.owner {
            guard let at = location(of: owner) else { return (false, file.locate(owner) != nil, nil) }
            if !(contents(of: at)[owner].map(registry.ownsShowableBoard) ?? false) { showable = false }
            if at == self.board { return (showable && file.canShow(at), false, owner) }
            guard met.insert(at).inserted else { return (false, false, nil) }
            current = at
        }
        return (showable, false, nil)
    }

    /// The board a shape is on as this transaction leaves the file: this one; the one it moved the shape
    /// onto, or brought it in on; else the file's, unless it deleted the shape, on whichever board, or
    /// took its board (nil, as for a shape on no board).
    private func location(of id: ShapeID) -> BoardID? {
        if document[id] != nil { return board }
        if let staged = stagedIDs[id] { return staged }
        guard !deleted.contains(id), let found = file.locate(id), found != board, !changes.boardsRemoved.contains(found) else { return nil }
        return found
    }

    /// Whether this transaction holds the owner of a board shapes would move onto, as `setContainer`
    /// holds a container: whether that board is read-only as this transaction leaves the file
    /// (`isReadOnly(board:)`).
    private func holdsOwner(_ owner: ShapeID) -> Bool { !isCascading && isReadOnly(board: BoardID(owner: owner)) }

    /// Whether a board can't change, as this transaction leaves the file: this one as the transaction
    /// was told (`isBoardReadOnly`); another while the shape that owns it, where this transaction leaves
    /// it (`location(of:)`), is held: on this board, as `holds` says; on another, if it was there before
    /// this transaction (one it brought there isn't held, as one it added here isn't) and it, or a
    /// container it's in there, is read-only; or while the board that shape is on is read-only, up to
    /// the root. The editor's rule (`registry.isReadOnly(board:in:)`), over the file as this transaction
    /// leaves it. O(the board's depth).
    private func isReadOnly(board target: BoardID) -> Bool {
        guard registry.hasReadOnlyRules else { return false }
        var current = target, met: Set<BoardID> = []
        // Every walk up the tree stops at a board it has met: a hand-edited file may hold a loop.
        while let owner = current.owner, met.insert(current).inserted {
            if current == board { return isBoardReadOnly }
            guard let at = location(of: owner) else { return false }
            let there = contents(of: at)
            guard let record = there[owner] else { return false }
            if at == board { return holds(record) }
            if stagedIDs[owner] == nil, registry.isReadOnly(record, in: there) { return true }
            current = at
        }
        return false
    }

    /// A transaction over another board as this one leaves it, to move or settle shapes there
    /// (`translate(_:by:on:)`, `settle(_:on:)`): the same registry, camera, keys and file, read-only
    /// as that board is as this one leaves the file (`isReadOnly(board:)`), and what this one brought
    /// there (moved there, or in with its owner) taken as added there, so it isn't held, as what this
    /// one adds here isn't. Nil for a board the editor couldn't show once this transaction commits.
    /// What it does comes back with `take(_:)`. `readingThrough`: it reads every other board, and
    /// where each shape is, as this one leaves the file too (its own board among them), for a move off
    /// that board (`move(_:from:to:)`), which reads and stages the board it goes onto.
    func transaction(on board: BoardID, readingThrough: Bool = false) -> Transaction? {
        let way = climb(board)
        precondition(!way.isTaken, "shapes can't move or settle on a board that goes with a shape deleted in the same transaction")
        guard way.canShow else { return nil }
        var access = file
        if readingThrough {
            let here = self, file = file
            access = FileAccess(locate: { here.location(of: $0) }, subtree: file.subtree, contents: { here.contents(of: $0) }, canShow: file.canShow,
                                values: file.values)
        }
        var there = Transaction(document: contents(of: board), board: board, isBoardReadOnly: isReadOnly(board: board), registry: registry,
                                camera: camera, keys: keys, file: access, layout: layout)
        for (id, on) in stagedIDs where on == board {
            there.changes.added.insert(id)
            there.writes.append(id)
        }
        there.mayReachBoardShown = mayReachBoardShown
        there.stagedFileValues = stagedFileValues
        return there
    }

    /// The writes a transaction over another board made, in this one's log (`LayoutReading.changes`): its own
    /// writes there (moves are not in it), and the shapes as written elsewhere for `isChanged`.
    private mutating func takeInWrites(of there: Transaction) {
        writes.append(contentsOf: there.writes)
        writtenElsewhere.formUnion(there.writes)
        writtenElsewhere.formUnion(there.writtenElsewhere)
    }

    /// Takes in what a transaction over another board did (`transaction(on:)`): that board as it
    /// leaves it, if it changed anything there, and what it refused.
    mutating func take(_ there: Transaction, reserving: Bool = true) {
        refused.formUnion(there.refused)
        takeInWrites(of: there)
        takeFileValues(of: there)
        if there.didChange { stage(there.document, on: there.board, reserving: reserving) }
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
    /// Whether the editor can show a board (`CanvasEditor.canShow`: the file's rule,
    /// `CanvasFile.canShow(_:boardOwningKinds:)`, with the registry's kinds that own boards).
    let canShow: (BoardID) -> Bool
    /// The file's own values (`FileProperty`), as the file holds them.
    let values: () -> FileValues

    /// Over a file of one's own, whose boards `boardOwningKinds` (the registry's) show.
    init(_ file: CanvasFile, boardOwningKinds: Set<ShapeKind>) {
        locate = { file.board(containing: $0) }
        subtree = { file.subtree(ownedBy: $0) }
        contents = { file[$0] }
        canShow = { file.canShow($0, boardOwningKinds: boardOwningKinds) }
        values = { file.fileValues }
    }

    init(locate: @escaping (ShapeID) -> BoardID?, subtree: @escaping (Set<ShapeID>) -> [BoardID],
         contents: @escaping (BoardID) -> CanvasDocument, canShow: @escaping (BoardID) -> Bool, values: @escaping () -> FileValues) {
        self.locate = locate
        self.subtree = subtree
        self.contents = contents
        self.canShow = canShow
        self.values = values
    }
}
