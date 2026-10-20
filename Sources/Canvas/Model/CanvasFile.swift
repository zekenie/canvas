import CanvasRPC
/// Every board of one file: the root, and a board for each shape that owns one (a shape of a
/// `BoardOwning` kind), kept under the owner's id. A value, like `CanvasDocument`.
///
/// Keying a board by its owner makes the tree a function: a board's parent is whichever board holds
/// its owner. So a board can't have two owners, deleting a shape can take its board with it, and a
/// copy of a shape (a new id) has a board of its own. Shape ids are unique across every board, so an
/// id alone finds a shape (`board(containing:)`, `record(_:)`). A board with no shapes isn't kept: a
/// board that isn't here is empty, so a shape's board exists as soon as the shape does.
///
/// It also holds what plugins keep on the file as a whole (`FileProperty`: `file[P.self]`), which is
/// no board's.
///
/// Every walk up or down the tree is a loop that stops at a board it has already met, so a file of
/// any depth, or one whose boards hold each other's owners (only a hand-edited file can), is safe.
public struct CanvasFile: Equatable, Sendable {
    public private(set) var root: CanvasDocument
    /// The boards with shapes, by owner id. It can hold boards the app keeps without showing them:
    /// boards whose owner isn't in the file, owners that hold each other's boards, and boards of
    /// shapes kept aside or of kinds that own none.
    public private(set) var children: [ShapeID: CanvasDocument]
    /// Entries of a board file's `boards` that didn't read as a board (not an object with a list of
    /// shapes, or under a key that isn't a shape's id), by key: written back as they were, never
    /// shown. A board a shape comes to own under the same key takes its place.
    public internal(set) var unreadableBoards: [String: JSONValue] = [:]
    /// The values plugins keep on the file as a whole (`FileProperty`): those that differ from their
    /// defaults, and those the app can't use, kept as they were.
    var fileValues = FileValues()
    /// Which board each shape is on.
    private var locations: [ShapeID: BoardID] = [:]
    /// Each board's revision: the stamp it got when its shapes last changed.
    private var revisions: [BoardID: Int] = [:]
    /// The next stamp, for whichever board changes next: one counter for the whole file, so a
    /// board's revision never comes back.
    private var nextRevision = 1

    /// Empty boards in `children` are left out. Every shape id must be unique across the boards.
    public init(root: CanvasDocument = CanvasDocument(), children: [ShapeID: CanvasDocument] = [:]) {
        self.root = root
        self.children = children.filter { !$0.value.shapes.isEmpty }
        for board in boards {
            for record in self[board].shapes {
                precondition(locations.updateValue(board, forKey: record.id) == nil, "two shapes in the file share the id \(record.id)")
            }
            stamp(board)
        }
    }

    /// The board's shapes: empty for a board the file doesn't have.
    public subscript(board: BoardID) -> CanvasDocument {
        guard let owner = board.owner else { return root }
        return children[owner] ?? CanvasDocument()
    }

    /// A value a plugin keeps on the file as a whole (`FileProperty`): what the file holds, else the
    /// property's default (also for one kept aside, `keptFileValues`). An editor's file is read here
    /// (`editor.file[P.self]`) and changed only in a transaction (`transaction.setFileValue`);
    /// setting it here is for a file of one's own (one being made, or read). Setting the default
    /// takes the value off the file, and setting one that's kept aside does nothing.
    public subscript<P: FileProperty>(_ property: P.Type) -> P.Value {
        get { fileValues[P.self] }
        set { fileValues[P.self] = newValue }
    }

    /// The file properties the file holds a value for (one that differs from its default), by key.
    public var fileValueKeys: [PropertyKey] { fileValues.keys.sorted { $0.rawValue < $1.rawValue } }

    /// The file properties the file holds a value for that the app can't use, kept as it was read
    /// and written back so (`LoadReport.keptFileValues`), by key.
    public var keptFileValues: [PropertyKey] { fileValues.kept.keys.sorted { $0.rawValue < $1.rawValue } }

    /// The board a shape is on, whichever it is; nil for a shape that isn't in the file.
    public func board(containing id: ShapeID) -> BoardID? { locations[id] }

    /// A shape, wherever it is in the file.
    public func record(_ id: ShapeID) -> AnyShapeRecord? {
        locations[id].flatMap { self[$0][id] }
    }

    /// Whether nothing in the file goes by the id: no shape has it, and nothing is kept under it (a
    /// board whose owner isn't here, or an entry that didn't read as a board under the key the id's
    /// board is written under), which a shape given the id would take for its own. What gives a
    /// shape back an id it had (a paste of what a cut took) asks first.
    public func isUnused(_ id: ShapeID) -> Bool {
        locations[id] == nil && children[id] == nil && (unreadableBoards.isEmpty || unreadableBoards[id.description] == nil)
    }

    /// The board holding the board's owner; nil for the root, and for a board whose owner isn't in
    /// the file.
    public func parent(of board: BoardID) -> BoardID? {
        board.owner.flatMap { locations[$0] }
    }

    /// The boards from the root down to `board`: the root first, `board` last (the root alone for
    /// the root). Nil when going up from `board` never reaches the root: an owner that isn't in the
    /// file, or owners that hold each other's boards.
    public func path(to board: BoardID) -> [BoardID]? {
        var path = [board], met: Set<BoardID> = [board]
        var current = board
        while let owner = current.owner {
            guard let parent = locations[owner], met.insert(parent).inserted else { return nil }
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }

    /// The shape on `board` that holds `id`: `id` itself if it's on `board`, else the owner, on
    /// `board`, of the board `id` is on or of one above it (a subboard's card, for what's on its
    /// board at any depth). Nil for a shape on a board above or beside `board`, and for one that
    /// isn't in the file. A container is on its contents' board, so the boards' owners are the
    /// whole answer. O(the depth of `id`'s board): a loop of owners, which only a file edited by hand
    /// has, ends the walk at a board it has met.
    public func shape(on board: BoardID, holding id: ShapeID) -> ShapeID? {
        guard var current = locations[id] else { return nil }
        guard current != board else { return id }
        var met: Set<BoardID> = [current]
        while let owner = current.owner, let parent = locations[owner], met.insert(parent).inserted {
            if parent == board { return owner }
            current = parent
        }
        return nil
    }

    /// Whether the app can show a board: the root, or a board whose owners, from the root down, are
    /// all in the file, none kept aside, each of one of `boardOwningKinds` (the registry's, the kinds
    /// that are `BoardOwning`). The board itself may have no shapes (yet). O(the board's depth).
    /// `editor.canShow`'s rule, for code that holds a file off the main actor (Topology's snapshot).
    public func canShow(_ board: BoardID, boardOwningKinds: Set<ShapeKind>) -> Bool {
        guard !board.isRoot else { return true }
        guard let path = path(to: board) else { return false }
        return path.dropFirst().allSatisfy { step in
            step.owner.flatMap(record).map { !$0.isOpaque && boardOwningKinds.contains($0.kind) } ?? false
        }
    }

    /// The boards the app can show (`canShow`): the root first, then, breadth first down the tree, the
    /// boards each one's shapes own, in the order their owners are on it (back to front), each once. Only
    /// boards with shapes. What reads every board the editor can show walks this, each board's shapes
    /// `self[board]`; `everyBoard` is every board the file has, shown or not. O(the boards): it reads
    /// no shape but their owners.
    public func showableBoards(boardOwningKinds: Set<ShapeKind>) -> [BoardID] {
        // The boards each board's shapes own, with each owner's place on it: an owner kept aside, or of a
        // kind that owns none, owns no board the app can show.
        var owned: [BoardID: [(place: Int, board: BoardID)]] = [:]
        for owner in children.keys {
            guard let on = locations[owner] else { continue }
            let holder = self[on]
            guard let record = holder[owner], !record.isOpaque, boardOwningKinds.contains(record.kind),
                  let place = holder.index(of: owner) else { continue }
            owned[on, default: []].append((place, BoardID(owner: owner)))
        }
        var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0
        while next < boards.count {
            let board = boards[next]
            next += 1
            for (_, child) in (owned[board] ?? []).sorted(by: { $0.place < $1.place }) where met.insert(child).inserted {
                boards.append(child)
            }
        }
        return boards
    }

    /// Every board the file has, the root first, then the others in no order, whether the app can
    /// show them or not: what reads the file whole walks this (`showableBoards` is what the app can
    /// show).
    public var everyBoard: [BoardID] { boards }

    /// The boards these shapes own, then the boards those boards' shapes own, and so on, breadth
    /// first: everything deleting the shapes takes with it. Only boards the file has (with shapes).
    public func subtree(ownedBy ids: some Sequence<ShapeID>) -> [BoardID] {
        var owners = ids.filter { children[$0] != nil }, met: Set<ShapeID> = []
        var found: [BoardID] = [], next = 0
        while next < owners.count {
            let owner = owners[next]
            next += 1
            guard met.insert(owner).inserted, let document = children[owner] else { continue }
            found.append(BoardID(owner: owner))
            owners += document.shapes.lazy.map(\.id).filter { children[$0] != nil }
        }
        return found
    }

    /// A stamp that changes each time the board's shapes change, and never comes back in this file
    /// (nor in one restamped after it, `restamp(after:)`, but for a board that one didn't change):
    /// what something kept about a board checks before it's used again. 0 for a board that has never
    /// had shapes.
    public func revision(of board: BoardID) -> Int { revisions[board] ?? 0 }

    /// Every shape on these boards.
    func shapeIDs(on boards: some Sequence<BoardID>) -> Set<ShapeID> {
        var ids: Set<ShapeID> = []
        for board in boards { ids.formUnion(self[board].shapes.lazy.map(\.id)) }
        return ids
    }

    /// The shapes on any board but `board` whose records differ from `earlier`'s: those on one file
    /// and not the other (or on another board), and those changed. Costs both files' shapes, but a
    /// board's that's equal in both at once.
    func shapesChanged(from earlier: CanvasFile, except board: BoardID) -> Set<ShapeID> {
        var ids: Set<ShapeID> = []
        for other in Set(boards).union(earlier.boards) where other != board {
            let now = self[other], then = earlier[other]
            guard now != then else { continue }
            for record in now.shapes where then[record.id] != record { ids.insert(record.id) }
            for record in then.shapes where now[record.id] == nil { ids.insert(record.id) }
        }
        return ids
    }

    /// How many shapes there are, on every board.
    public var shapeCount: Int { locations.count }

    public static func == (a: Self, b: Self) -> Bool {
        a.root == b.root && a.children == b.children && a.unreadableBoards == b.unreadableBoards && a.fileValues == b.fileValues
    }

    /// The root, then each board in `children`.
    private var boards: [BoardID] { [.root] + children.keys.map { BoardID(owner: $0) } }

    private mutating func stamp(_ board: BoardID) {
        revisions[board] = nextRevision
        nextRevision += 1
    }

    // MARK: Changing it

    /// Makes `document` the board's shapes. A shape it adds must be on no other board. What the
    /// editor does with each commit to the board it shows.
    @_spi(Host) public mutating func set(_ document: CanvasDocument, for board: BoardID) {
        set(document, for: board, changes: ChangeSet(from: self[board], to: document))
    }

    /// Several boards at once, each as `set(_:for:changes:)` sets it: a commit that moved shapes from
    /// one to another, either way round. Every board lets go of what leaves it before any takes in
    /// what comes, so a shape is on one board at a time whichever is first.
    mutating func set(_ boards: [(board: BoardID, document: CanvasDocument, changes: ChangeSet)]) {
        for (board, _, changes) in boards {
            for id in changes.removed where locations[id] == board { locations[id] = nil }
        }
        for (board, document, changes) in boards { set(document, for: board, changes: changes) }
    }

    /// `changes` must be what changed from `self[board]` to `document` (a commit's), so the shapes'
    /// locations follow in the time the changes take, not the board's.
    mutating func set(_ document: CanvasDocument, for board: BoardID, changes: ChangeSet) {
        for id in changes.removed where locations[id] == board { locations[id] = nil }
        for id in changes.added {
            let before = locations.updateValue(board, forKey: id)
            precondition(before == nil || before == board, "a shape with id \(id) is already on another board")
        }
        if let owner = board.owner {
            children[owner] = document.shapes.isEmpty ? nil : document
            if !document.shapes.isEmpty { dropUnreadable(ownedBy: owner) }
        } else {
            root = document
        }
        stamp(board)
    }

    /// Adds boards under their owners' ids (what pasting a shape that owns one brings): each one the file
    /// doesn't have, with shapes new to the file. Empty ones are left out.
    @_spi(Host) public mutating func insertBoards(_ boards: [ShapeID: CanvasDocument]) {
        for (owner, document) in boards where !document.shapes.isEmpty {
            precondition(children[owner] == nil, "the file already has the board \(owner) owns")
            let board = BoardID(owner: owner)
            for record in document.shapes {
                precondition(locations.updateValue(board, forKey: record.id) == nil, "a shape with id \(record.id) is already in the file")
            }
            children[owner] = document
            dropUnreadable(ownedBy: owner)
            stamp(board)
        }
    }

    /// An unreadable entry under the key a board of `owner`'s is written under, which that board
    /// replaces.
    private mutating func dropUnreadable(ownedBy owner: ShapeID) {
        if !unreadableBoards.isEmpty { unreadableBoards[owner.description] = nil }
    }

    /// Removes boards, and their shapes (the boards under a deleted shape). Never the root.
    @_spi(Host) public mutating func removeBoards(_ boards: some Sequence<BoardID>) {
        for board in boards {
            guard let owner = board.owner else { preconditionFailure("the root board can't be removed") }
            guard let document = children.removeValue(forKey: owner) else { continue }
            for record in document.shapes { locations[record.id] = nil }
            stamp(board)
        }
    }

    /// Puts a step's change in place, as undo and redo do: its board's shapes (`CanvasDocument.apply`),
    /// every board it names whole, the entries that didn't read as boards, and the file's values
    /// (`FileProperty`). The file must be as the delta's `before` side has it. Every board it changes
    /// gets a new revision.
    public mutating func apply(_ delta: DocumentDelta) {
        var document = self[delta.board]
        document.apply(delta)
        apply(delta, document: document, changes: ChangeSet(delta))
    }

    /// As `apply(_:)`, the delta's board already applied (`document`, which `changes` names).
    mutating func apply(_ delta: DocumentDelta, document: CanvasDocument, changes: ChangeSet) {
        #if DEBUG
        for (board, change) in delta.boards { assert(self[board] == change.before, "applying a delta to a file that doesn't hold \(board) as it was") }
        #endif
        // Boards that go, or change, first: a shape one transaction took off the board and put in
        // with another's contents is on one board at a time, either way.
        for (board, change) in delta.boards where !change.before.shapes.isEmpty { clear(board) }
        if !delta.changes.isEmpty { set(document, for: delta.board, changes: changes) }
        for (board, change) in delta.boards where !change.after.shapes.isEmpty { fill(board, with: change.after) }
        for (key, entry) in delta.unreadableBoards { unreadableBoards[key] = entry.after }
        for (key, value) in delta.fileValues { fileValues[key] = value.after }
    }

    /// Takes every shape off a board, the root too.
    private mutating func clear(_ board: BoardID) {
        for record in self[board].shapes { locations[record.id] = nil }
        if let owner = board.owner { children[owner] = nil } else { root = CanvasDocument() }
        stamp(board)
    }

    /// Makes an empty board's shapes `document`'s, each new to the file.
    private mutating func fill(_ board: BoardID, with document: CanvasDocument) {
        for record in document.shapes {
            precondition(locations.updateValue(board, forKey: record.id) == nil, "a shape with id \(record.id) is already in the file")
        }
        if let owner = board.owner { children[owner] = document } else { root = document }
        stamp(board)
    }

    /// Gives every board of this file, and every board `earlier` has stamped, a revision above all
    /// of `earlier`'s, but a board with shapes, as `earlier` has them, which keeps its revision
    /// there: what a file that takes another's place (opening, reverting, reading it again after a
    /// change on disk) needs, so that nothing kept about a board of the old file is taken for the new
    /// one's, while what's kept about a board that didn't change (its preview) stays.
    @_spi(Host) public mutating func restamp(after earlier: CanvasFile) {
        let stamped = Set(revisions.keys).union(earlier.revisions.keys)
        nextRevision = max(nextRevision, earlier.nextRevision)
        for board in stamped {
            let document = self[board]
            if !document.shapes.isEmpty, document == earlier[board] {
                revisions[board] = earlier.revisions[board]
            } else {
                stamp(board)
            }
        }
    }

    /// Each board through `transform`, which must keep every shape's id (filling in defaults).
    mutating func transformBoards(_ transform: (CanvasDocument) -> CanvasDocument) {
        for board in boards {
            let document = transform(self[board])
            guard document != self[board] else { continue }
            if let owner = board.owner { children[owner] = document } else { root = document }
            stamp(board)
        }
    }
}
