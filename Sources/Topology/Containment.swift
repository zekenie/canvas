import Canvas

/// What contains what in a file, as a value: one tree, of two kinds of link, read from where the
/// shapes are, on the boards the app can show (the rule `canShow` has). A shape in a container on
/// its board (a shape of a `ShapeContaining` kind, a frame, as the core goes by it:
/// `CanvasDocument.container(of:containingKinds:)`) is inside that container; any other shape is
/// inside the owner of the board it's on, and on the root inside nothing. So a container's parent is
/// its own container, else its board's owner; an owner's children are its board's shapes in no
/// container, and a container's are what it holds. The index makes one over the file as it is for
/// each question it's asked, and a snapshot keeps one over the file as it was (`TopologySnapshot`),
/// so the two answer alike. Nothing is kept but the file, whose boards keep who's in which container
/// (the document's index of who names whom): each question costs its shape's depth, or what it
/// lists, and a board without containers costs what it did before there were any.
///
/// File order is the tree's, depth first: a board's shapes in no container, back to front, each
/// followed at once by what's inside it, what it holds (back to front) and, for a shape that owns a
/// board, that board's, before the next shape. A shape of a kind that both owns a board and holds
/// shapes on its own lists what it holds before its board.
struct Containment: Sendable {
    let file: CanvasFile
    /// The kinds that own boards (`registry.boardOwningKinds`).
    let boardOwningKinds: Set<ShapeKind>
    /// The kinds whose shapes hold shapes on the board they're on (`registry.containingKinds`).
    let containingKinds: Set<ShapeKind>

    // MARK: Shapes

    /// A shape on a board the app can show, kept aside or not; nil for one on a board it can't show,
    /// or in no board of the file. O(its board's depth).
    func shape(_ id: ShapeID) -> AnyShapeRecord? { located(id)?.record }

    /// How a shape at an end of an edge is: live on a board the app can show, unavailable on one it
    /// can't, missing from the file.
    func end(_ id: ShapeID) -> EdgeEnd {
        guard let board = file.board(containing: id) else { return .missing }
        return file.canShow(board, boardOwningKinds: boardOwningKinds) ? .live(board) : .unavailable
    }

    /// A shape on a board the app can show, and that board.
    private func located(_ id: ShapeID) -> (record: AnyShapeRecord, board: BoardID)? {
        guard let board = file.board(containing: id), file.canShow(board, boardOwningKinds: boardOwningKinds),
              let record = file[board][id] else { return nil }
        return (record, board)
    }

    // MARK: Up and down the tree

    /// The shape `id` is directly inside: the container it's in on its board, else the owner of its
    /// board; nil on the root in no container, and for a shape on a board the app can't show (or in
    /// no board of the file).
    func parent(of id: ShapeID) -> ShapeID? {
        guard let (record, board) = located(id) else { return nil }
        return container(of: record, on: board) ?? board.owner
    }

    /// The shapes directly inside `id`: what it holds, back to front, then, for a shape that owns a
    /// board the app can show, that board's shapes in no container, back to front. None for any
    /// other shape.
    func children(of id: ShapeID) -> [ShapeID] {
        guard let (record, board) = located(id) else { return [] }
        var found = holds(record) ? file[board].contents(of: id, containingKinds: containingKinds) : []
        if ownsShowableBoard(record) { found += topLevel(of: BoardID(owner: id)) }
        return found
    }

    /// The shapes `id` is inside, the nearest first: the containers it's in on its board, then its
    /// board's owner, the containers that one is in, and so on up; none on the root in no container,
    /// and for a shape on a board the app can't show.
    func ancestors(of id: ShapeID) -> [ShapeID] {
        guard let (record, board) = located(id) else { return [] }
        var found = containers(of: record, on: board), met: Set<ShapeID> = [id], current = board
        while let owner = current.owner, met.insert(owner).inserted, let above = file.board(containing: owner), let held = file[above][owner] {
            found.append(owner)
            found += containers(of: held, on: above)
            current = above
        }
        return found
    }

    /// The container a shape is directly in on `board`, the board it's on, as the core goes by it;
    /// nil for one on its board directly, which costs no lookup. O(1).
    func container(of record: AnyShapeRecord, on board: BoardID) -> ShapeID? {
        guard !containingKinds.isEmpty, record.container != nil else { return nil }
        return file[board].container(of: record, containingKinds: containingKinds)
    }

    /// The containers a shape is in on `board`, the board it's on, the nearest first: what comes
    /// before its board's owner in `ancestors`.
    private func containers(of record: AnyShapeRecord, on board: BoardID) -> [ShapeID] {
        guard !containingKinds.isEmpty, record.container != nil else { return [] }
        return file[board].containers(of: record.id, containingKinds: containingKinds)
    }

    /// Whether `a` is inside `b`, at any depth; never inside itself. O(`a`'s depth).
    func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool {
        a != b && ancestors(of: a).contains(b)
    }

    /// The shapes inside nothing: the root's in no container, in document order.
    var topLevel: [ShapeID] { topLevel(of: .root) }

    /// Whether a shape is inside nothing: on the root, in no container. O(1).
    func isTopLevel(_ id: ShapeID) -> Bool {
        guard file.board(containing: id) == .root else { return false }
        let root = file.root
        guard isContaining(root), let record = root[id] else { return true }
        return root.container(of: record, containingKinds: containingKinds) == nil
    }

    /// Every shape inside `id`, at any depth, in file order: what it holds and its board's shapes,
    /// each followed at once by what's inside it. None for a shape that holds nothing and owns no
    /// board the app can show. O(what's inside it).
    func descendants(of id: ShapeID) -> [ShapeID] {
        guard let (record, board) = located(id) else { return [] }
        let document = file[board]
        var runs: [Run] = [], entered: Set<ShapeID> = []
        guard enter(record, from: Run(board: board, document: document, contained: isContaining(document)), into: &runs, entered: &entered) else {
            return []
        }
        var found: [ShapeID] = []
        walk(runs, entered: entered) { record, _ in found.append(record.id) }
        return found
    }

    // MARK: File order

    /// Every shape on a board the app can show, kept aside ones too, with its board, in file order:
    /// the root's shapes in no container, back to front, each followed at once by what's inside it
    /// (what it holds, then its board's shapes), and theirs, before the next. O(those shapes); no
    /// board or container is walked twice. An error `body` throws stops it, and comes out as `body`'s
    /// own type.
    func forEachShape<E: Error>(inFileOrder body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        try walk([run(of: .root)], entered: [], body)
    }

    /// Where a shape comes in file order, as a key that sorts as `forEachShape(inFileOrder:)` visits:
    /// for each shape it's inside, from the outermost down, then for itself, its place among what's
    /// directly inside the same shape (its index on its board; a board's shapes in no container come
    /// after what the board's owner holds, if it holds any). Nil for a shape on a board the app can't
    /// show, or in no board of the file. O(its depth).
    func fileOrderKey(of id: ShapeID) -> [Int]? {
        guard var board = file.board(containing: id) else { return nil }
        var document = file[board]
        guard var index = document.index(of: id) else { return nil }
        var key: [Int] = []
        // A walk up through more boards than the file has, or more containers than a board has
        // shapes, has met one twice: owners that hold each other's boards (a hand-edited file's),
        // or a loop of containers (which reading breaks).
        var boards = file.children.count + 1, containers = document.shapes.count
        while true {
            if isContaining(document), let holder = document.container(of: document.shapes[index], containingKinds: containingKinds),
               let at = document.index(of: holder) {
                key.append(index)
                containers -= 1
                guard containers >= 0 else { return nil }
                index = at
                continue
            }
            guard let owner = board.owner else {
                key.append(index)
                return key.reversed()
            }
            boards -= 1
            guard boards > 0, let above = file.board(containing: owner) else { return nil }
            let upper = file[above]
            guard let at = upper.index(of: owner) else { return nil }
            let ownerRecord = upper.shapes[at]
            guard ownsShowableBoard(ownerRecord) else { return nil }
            key.append(holds(ownerRecord) ? upper.shapes.count + index : index)
            board = above
            document = upper
            index = at
            containers = document.shapes.count
        }
    }

    // MARK: Walking

    /// Where a walk is: a board's shapes in no container, or a container's contents (`contents`, its
    /// ids back to front), from `next`.
    private struct Run {
        let board: BoardID
        let document: CanvasDocument
        /// Whether a shape on the board names a container: else none is skipped as walked with its
        /// container, and none is asked what it holds.
        let contained: Bool
        var contents: [ShapeID]?
        var next = 0

        init(board: BoardID, document: CanvasDocument, contained: Bool, contents: [ShapeID]? = nil) {
            self.board = board
            self.document = document
            self.contained = contained
            self.contents = contents
        }

        /// The run's next shape; nil once it's done.
        mutating func advance(_ kinds: Set<ShapeKind>) -> AnyShapeRecord? {
            if let contents {
                while next < contents.count {
                    let id = contents[next]
                    next += 1
                    if let record = document[id] { return record }
                }
                return nil
            }
            while next < document.shapes.count {
                let record = document.shapes[next]
                next += 1
                // Walked with its container.
                if contained, document.container(of: record, containingKinds: kinds) != nil { continue }
                return record
            }
            return nil
        }
    }

    /// A board's shapes in no container, as a walk's run.
    private func run(of board: BoardID) -> Run {
        let document = file[board]
        return Run(board: board, document: document, contained: isContaining(document))
    }

    /// Adds what's inside `record` (a shape of `run`'s) to `runs`, as runs to walk next: its board's
    /// shapes, then, above them so they're walked first, what it holds. Whether it added any. A
    /// container is entered once (a loop of containers never comes from a board, which reading
    /// breaks, but a walk never goes round one).
    private func enter(_ record: AnyShapeRecord, from run: Run, into runs: inout [Run], entered: inout Set<ShapeID>) -> Bool {
        let owns = file.children[record.id] != nil && ownsShowableBoard(record)
        var held: [ShapeID] = []
        if run.contained, holds(record), entered.insert(record.id).inserted {
            held = run.document.contents(of: record.id, containingKinds: containingKinds)
        }
        if owns { runs.append(self.run(of: BoardID(owner: record.id))) }
        if !held.isEmpty { runs.append(Run(board: run.board, document: run.document, contained: true, contents: held)) }
        return owns || !held.isEmpty
    }

    /// The shapes of `runs`, the last first, each followed at once by what's inside it. Ids are
    /// unique across the file, so going down from a board the app can show meets each board below it
    /// once, and each of those can be shown too; a container is entered once. No call recurses, so a
    /// chain of boards or containers of any depth is walked.
    private func walk<E: Error>(_ runs: [Run], entered: Set<ShapeID>, _ body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        var stack = runs, entered = entered
        while var run = stack.popLast() {
            while let record = run.advance(containingKinds) {
                try body(record, run.board)
                var inside: [Run] = []
                guard enter(record, from: run, into: &inside, entered: &entered) else { continue }
                stack.append(run)
                stack += inside
                break
            }
        }
    }

    /// A board's shapes in no container, in document order.
    private func topLevel(of board: BoardID) -> [ShapeID] {
        let document = file[board]
        guard isContaining(document) else { return document.shapes.map(\.id) }
        return document.shapes.compactMap { document.container(of: $0, containingKinds: containingKinds) == nil ? $0.id : nil }
    }

    /// Whether some shape on the board may be in a container: a containing kind is installed, and a
    /// shape on it names a container (O(1)).
    private func isContaining(_ document: CanvasDocument) -> Bool {
        !containingKinds.isEmpty && document.namesContainers
    }

    /// Whether a shape holds shapes on its board, as the core goes by it: of a containing kind, not
    /// kept aside.
    private func holds(_ record: AnyShapeRecord) -> Bool {
        !record.isOpaque && containingKinds.contains(record.kind)
    }

    /// Whether a shape's board can be shown wherever the shape's own board can: `registry.ownsShowableBoard`'s rule.
    private func ownsShowableBoard(_ record: AnyShapeRecord) -> Bool {
        !record.isOpaque && boardOwningKinds.contains(record.kind)
    }
}

extension Registry {
    /// The kinds whose shapes can contain others, as Topology has containment: those that own boards
    /// (`boardOwningKinds`: a subboard) and those that hold shapes on the board they're on
    /// (`containingKinds`: a frame). A shape of any other kind has nothing inside it.
    public var containerKinds: Set<ShapeKind> { boardOwningKinds.union(containingKinds) }
}
