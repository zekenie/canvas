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
/// board's shapes. Three things reach the boards under them: deleting a shape takes the board it owns
/// with it, and every board under that (`ChangeSet.boardsRemoved`); a shape can go in with its
/// board and the boards under it (`insert(_:contents:)`, a paste; `ChangeSet.boardsAdded`); and
/// shapes can move onto the board a shape on this board owns (`move(_:toBoardOwnedBy:)`;
/// `boardsAdded`, or `boardsChanged` if the board held shapes already). A shape
/// whose board, or a board under it, holds a read-only shape isn't deleted, as the Finder won't trash
/// a folder holding a locked file. Shape ids are unique across the file: a shape inserted can't have
/// the id of one on any board.
///
/// Containers (`ShapeContaining`: a frame) hold shapes on their board (`AnyShapeRecord.container`):
/// what a container holds moves with it (`translate`) and is restacked with it, read-only or not,
/// paints above it, and is read-only while it is (a shape in a read-only container changes not at
/// all, and nothing joins or leaves one); deleting a container lets go of what it holds into its own
/// container. `setContainer` puts a shape in one, and `settle` keeps what's put down from sitting
/// across a container's edge (Settling.swift).
///
/// A shape can become another kind under its id (`turn`), so whatever binds or names it goes on
/// doing so.
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
    /// owner: what the commit adds to the file. Also the boards shapes were moved onto here
    /// (`move(_:toBoardOwnedBy:)`), whole, with what the file holds there already: what the commit
    /// adds, or, if the file held shapes there (`changes.boardsChanged`), writes over it.
    private(set) var stagedBoards: [ShapeID: CanvasDocument] = [:]
    /// The shapes inserted or moved onto `stagedBoards` here.
    private var stagedIDs: Set<ShapeID> = []
    /// The owners of the boards shapes were moved onto here. None of them is deleted in the same
    /// transaction (`delete` holds to it): what moved there would be dropped with the board, and the
    /// boards it owns left with no owner. No flow deletes a shape it has just moved shapes onto.
    private var movedOnto: Set<ShapeID> = []
    private(set) var didChange = false
    /// What it did so far, record by record: what the commit hands services.
    private(set) var changes = ChangeSet()
    /// Read-only shapes it was asked to change, restack, move or delete, and didn't (and read-only
    /// containers that wouldn't take a shape: `setContainer`, `settle`).
    var refused: Set<ShapeID> = []
    /// The read-only shapes it was asked to change, restack, move or delete so far, and didn't, and
    /// read-only containers that wouldn't take a shape: what a plugin that must change everything or
    /// nothing reads, to throw so nothing commits, then shake them (`editor.refuseChanges(to:)`).
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

    init(document: CanvasDocument, board: BoardID, registry: Registry, camera: Camera, keys: StackingKeyGenerator, file: FileAccess) {
        self.document = document
        self.board = board
        self.registry = registry
        self.camera = camera
        self.keys = keys
        self.file = file
    }

    /// Whether an agent makes the change (the command line's `draw`), not a person at the app: its
    /// commit says so (`ChangeSet.byAgent`), so what acts on a person's edits (a schema card's sync)
    /// takes what it changed as it is. Saying so changes nothing by itself.
    public var byAgent: Bool {
        get { changes.byAgent }
        set { changes.byAgent = newValue }
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
            var records: [AnyShapeRecord] = [], below: [ShapeID: AnyShapeRecord] = [:]
            for shape in board.shapes {
                precondition(ids.insert(shape.id).inserted && document[shape.id] == nil && isNewToFile(shape.id),
                             "a shape with id \(shape.id) is already in the file")
                precondition(registry.definition(for: shape.kind)?.erasedAccepts(shape) == true,
                             "no installed plugin defines \(shape.kind) shapes with these props")
                guard shape.box?.isFinite ?? true else { continue }
                var record = registry.propertyTable.normalized(shape)
                // In a container on its own board below it, as the board it came from had it.
                if let container = record.container, record.box == nil || !(below[container].map(registry.isContainer) ?? false) {
                    record.container = nil
                }
                records.append(record)
                below[record.id] = record
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
    /// insert, or that shapes were moved onto (`move(_:toBoardOwnedBy:)`), none for a board going
    /// with its owner, else the file's.
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
        // A container it comes with (a paste's copy, `copy(as:container:)`) it's in if that's a
        // container on the board by now that takes it; else it's on the board directly.
        if let container = record.container, !takes(container, record) { record.container = nil }
        tops = [:]
        document.append(record)
        changes.added.insert(record.id)
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

    /// On no board of the file, nor going in with one, unless this transaction deleted it from this
    /// board (it may go back in).
    private func isNewToFile(_ id: ShapeID) -> Bool {
        guard !stagedIDs.contains(id) else { return false }
        guard let board = file.locate(id) else { return true }
        return board == self.board && changes.removed.contains(id)
    }

    /// Changes one shape. Its id, stacking key and container stay as they were, whatever `body`
    /// does (`setContainer` changes a container). A read-only shape keeps the change only if it
    /// leaves the shape no longer read-only, and a shape in a read-only container keeps none.
    public mutating func update(_ id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let index = document.index(of: id) else { return }
        let old = document.shapes[index]
        var record = old
        body(&record)
        precondition(record.id == id, "a shape's id can't change")
        record.stackingKey = old.stackingKey
        record.containerBits = old.containerBits
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
    /// document before the transaction, no deletion is keeping the board whole, a container that
    /// moves isn't carrying it, and it's read-only: by a rule, and would still be as `new` (nil:
    /// deleted, or moved in the stack, which leaves it as read-only as it was), or in a read-only
    /// container, which holds it whatever the change.
    private mutating func refuses(_ old: AnyShapeRecord, becoming new: AnyShapeRecord? = nil) -> Bool {
        guard !isCascading, registry.hasReadOnlyRules, !changes.added.contains(old.id), carrying.isEmpty || !carrying.contains(old.id),
              registry.isReadOnly(old) && (new.map(registry.isReadOnly) ?? true) || registry.isInsideReadOnlyContainer(old, in: document)
        else { return false }
        refused.insert(old.id)
        return true
    }

    /// Whether this transaction holds a shape as it is, as `refuses` would, noting nothing: it was in
    /// the document before the transaction, and it, or a container it's in, is read-only.
    func holds(_ record: AnyShapeRecord) -> Bool {
        !isCascading && registry.hasReadOnlyRules && !changes.added.contains(record.id) && (carrying.isEmpty || !carrying.contains(record.id))
            && (registry.isReadOnly(record) || registry.isInsideReadOnlyContainer(record, in: document))
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
        update(id) { $0.box?.origin = origin }
        if unchanged, changes.changed.contains(id) { changes.moved.insert(id) }
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
    /// read-only shape stays, refused, like a read-only shape. A container deleted lets go of what
    /// it holds, which stays where it is, now in the container's own container (the nearest one up
    /// that isn't deleted too), read-only or not; a shape in a read-only container is read-only, so
    /// it stays, as the container does. A shape can't be deleted in the transaction that moved shapes
    /// onto its board (`move(_:toBoardOwnedBy:)`).
    public mutating func delete(_ ids: Set<ShapeID>) {
        let ids = ids.filter { id in document[id].map { !refuses($0) && !refusesForContents($0) } ?? false }.subtracting(deleting)
        guard !ids.isEmpty else { return }
        precondition(movedOnto.isDisjoint(with: ids), "a shape can't be deleted in the transaction that moved shapes onto its board")
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

    // MARK: Turning, and moving to the board below

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
    /// shape (or one in a read-only container), refused as `update` refuses it, which services hear.
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
        guard new.box?.isFinite ?? true else { return false }
        precondition(!registry.ownsShowableBoard(old) || registry.boardOwningKinds.contains(new.kind) || contents(ofBoardOwnedBy: id).shapes.isEmpty,
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
    /// owns boards, not among them), under their ids: on top of what that board holds, in their order,
    /// each with its props, added values and metadata, and with what it owns (a board goes with its
    /// owner wherever that is). What a container among them holds goes with it, at any depth. A shape
    /// stays in a container that moves with it, and is in none there otherwise. Ids not on this board
    /// are passed over. The commit says the board is new to the file (`boardsAdded`), or changed if it
    /// held shapes already (`boardsChanged`), and what moved removed from this one; undoing it puts
    /// every shape back, in its place in the stack.
    ///
    /// Bindings (`ShapeReferencing`: an arrow's ends) are to shapes on the same board, so those across
    /// the edge are let go of, as deleting the shape would: a shape that stays lets go of what moves
    /// (an arrow's end stays where it's drawn), and one that moves of what stays, read-only or not.
    /// Names (`ShapeNaming`: a mention) may be of a shape on any board, and stay as they are.
    ///
    /// All or nothing for read-only shapes: if `owner`, or a shape that would move, is read-only (or in
    /// a read-only container), nothing moves, services hear which were refused (`refusedShapes`), and
    /// this returns false. It's false too, nothing moving and nothing refused, for an `owner` that isn't
    /// on this board or owns no board (a shape whose turn into a kind that owns one was refused).
    /// Nothing else is asked of a shape that moves (no handlers run), and `owner` can't be deleted in
    /// this transaction.
    @discardableResult
    public mutating func move(_ ids: Set<ShapeID>, toBoardOwnedBy owner: ShapeID) -> Bool {
        // An owner that isn't here, or owns no board (a turn into a kind that owns one was refused):
        // nothing to move onto, so nothing moves.
        guard let holder = document[owner], registry.ownsShowableBoard(holder) else { return false }
        let kinds = registry.containingKinds
        var moving: Set<ShapeID> = []
        for id in ids where document[id] != nil {
            moving.insert(id)
            moving.formUnion(document.descendants(of: id, containingKinds: kinds))
        }
        precondition(!moving.contains(owner), "a shape can't move onto its own board, nor onto that of a shape a container that moves holds")
        guard !moving.isEmpty else { return true }
        // Every shape refused is noted, so each is heard refused.
        var isRefused = holds(holder)
        if isRefused { refused.insert(owner) }
        for index in moving.compactMap({ document.index(of: $0) }).sorted() where refuses(document.shapes[index]) { isRefused = true }
        guard !isRefused else { return false }
        // Bindings, both ways, while every shape is still here: an arrow lets go of an end where it's
        // drawn.
        let referencing = registry.referencingKinds
        if !referencing.isEmpty {
            let context = shapes
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
            if changes.added.remove(id) == nil {                          // added and moved here: never on this board
                changes.changed.remove(id)
                changes.moved.remove(id)
                changes.removed.insert(id)
            }
        }
        // On the other, above what it holds.
        var target = contents(ofBoardOwnedBy: owner)
        for var record in leaving {
            record.stackingKey = keys.key(between: target.shapes.last?.stackingKey, and: nil)
            target.append(record)
        }
        let owned = BoardID(owner: owner)
        if stagedBoards[owner] == nil {
            if !changes.boardsRemoved.contains(owned), !file.contents(owned).shapes.isEmpty {
                changes.boardsChanged.insert(owned)
            } else {
                changes.boardsAdded.insert(owned)
            }
        }
        stagedBoards[owner] = target
        stagedIDs.formUnion(moving)
        movedOnto.insert(owner)
        changes.reordered = true
        didChange = true
        return true
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
