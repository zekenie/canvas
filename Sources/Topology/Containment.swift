import Canvas

/// What contains what in a file, as a value: which shape each shape is inside, read from the board
/// tree (a shape is inside the owner of the board it's on) on the boards the app can show, the rule
/// `canShow` has. The index makes one over the file as it is for each question it's asked, and a
/// snapshot keeps one over the file as it was (`TopologySnapshot`), so the two answer alike. Nothing
/// is kept but the file: each question costs its shape's depth, or what it lists.
///
/// Only boards contain today (`containerKinds`, the kinds that own boards); frames or groups would
/// be containers here, and every reader, live or not, would follow.
struct Containment: Sendable {
    let file: CanvasFile
    /// The kinds that own boards (`registry.boardOwningKinds`).
    let boardOwningKinds: Set<ShapeKind>

    // MARK: Shapes

    /// A shape on a board the app can show, kept aside or not; nil for one on a board it can't show,
    /// or in no board of the file. O(its depth).
    func shape(_ id: ShapeID) -> AnyShapeRecord? {
        guard let board = file.board(containing: id), file.canShow(board, boardOwningKinds: boardOwningKinds) else { return nil }
        return file[board][id]
    }

    /// How a shape at an end of an edge is: live on a board the app can show, unavailable on one it
    /// can't, missing from the file.
    func end(_ id: ShapeID) -> EdgeEnd {
        guard let board = file.board(containing: id) else { return .missing }
        return file.canShow(board, boardOwningKinds: boardOwningKinds) ? .live(board) : .unavailable
    }

    // MARK: Up and down the tree

    /// The shape whose board `id` is on: nil on the root, and for a shape on a board the app can't
    /// show (or in no board of the file).
    func parent(of id: ShapeID) -> ShapeID? {
        guard shape(id) != nil else { return nil }
        return file.board(containing: id)?.owner
    }

    /// The shapes on the board `id` owns, in document order: none for a shape that owns no board the
    /// app can show.
    func children(of id: ShapeID) -> [ShapeID] {
        guard let owner = shape(id), ownsShowableBoard(owner) else { return [] }
        return file[BoardID(owner: id)].shapes.map(\.id)
    }

    /// The shapes `id` is inside, the nearest first: none on the root, and for a shape on a board the
    /// app can't show.
    func ancestors(of id: ShapeID) -> [ShapeID] {
        guard shape(id) != nil else { return [] }
        var found: [ShapeID] = [], met: Set<ShapeID> = [id], current = id
        while let owner = file.board(containing: current)?.owner, met.insert(owner).inserted {
            found.append(owner)
            current = owner
        }
        return found
    }

    /// Whether `a` is inside `b`, at any depth; never inside itself. O(`a`'s depth).
    func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool {
        a != b && ancestors(of: a).contains(b)
    }

    /// The shapes on the root, inside nothing, in document order.
    var topLevel: [ShapeID] { file.root.shapes.map(\.id) }

    /// Every shape inside `id`, at any depth, in file order (`forEachShape(inFileOrder:)`): its
    /// board's shapes back to front, each owner followed at once by what's inside it. None for a
    /// shape that owns no board the app can show. O(what's inside it).
    func descendants(of id: ShapeID) -> [ShapeID] {
        guard let owner = shape(id), ownsShowableBoard(owner) else { return [] }
        var found: [ShapeID] = []
        walk(from: BoardID(owner: id)) { record, _ in found.append(record.id) }
        return found
    }

    // MARK: File order

    /// Every shape on a board the app can show, kept aside ones too, with its board, in file order:
    /// the root's shapes back to front, each shape that owns a board followed at once by that board's
    /// shapes, and theirs, before the next. O(those shapes); no board is walked twice. An error
    /// `body` throws stops it, and comes out as `body`'s own type.
    func forEachShape<E: Error>(inFileOrder body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        try walk(from: .root, body)
    }

    /// Where a shape comes in file order, as a key that sorts as `forEachShape(inFileOrder:)` visits:
    /// the index of each owner above it on its board, from the root's down, then its own. Nil for a
    /// shape on a board the app can't show, or in no board of the file. O(its depth).
    func fileOrderKey(of id: ShapeID) -> [Int]? {
        var key: [Int] = [], current = id
        // A walk that goes up more boards than the file has has met one twice: owners that hold
        // each other's boards.
        var steps = file.children.count + 1
        while let board = file.board(containing: current) {
            let document = file[board]
            guard let index = document.index(of: current), current == id || ownsShowableBoard(document.shapes[index]) else { return nil }
            key.append(index)
            guard let owner = board.owner else { return key.reversed() }
            steps -= 1
            guard steps > 0 else { return nil }
            current = owner
        }
        return nil
    }

    // MARK: Walking

    /// The shapes on `board` and on every board under it, in file order. Ids are unique across the
    /// file, so going down from a board the app can show meets each board below it once, and each
    /// of those can be shown too: no loop needs guarding, and no call recurses, so a chain of boards
    /// of any depth is walked.
    private func walk<E: Error>(from board: BoardID, _ body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        var stack: [(board: BoardID, shapes: [AnyShapeRecord], next: Int)] = [(board, file[board].shapes, 0)]
        while let top = stack.indices.last {
            let (board, shapes, next) = stack[top]
            guard next < shapes.count else {
                stack.removeLast()
                continue
            }
            stack[top].next = next + 1
            let record = shapes[next]
            try body(record, board)
            if file.children[record.id] != nil, ownsShowableBoard(record) {
                let owned = BoardID(owner: record.id)
                stack.append((owned, file[owned].shapes, 0))
            }
        }
    }

    /// Whether a shape's board can be shown wherever the shape's own board can: `registry.ownsShowableBoard`'s rule.
    private func ownsShowableBoard(_ record: AnyShapeRecord) -> Bool {
        !record.isOpaque && boardOwningKinds.contains(record.kind)
    }
}

extension Registry {
    /// The kinds whose shapes can contain others, as Topology has containment: today the kinds that
    /// own boards (`boardOwningKinds`). A shape of any other kind has nothing inside it.
    public var containerKinds: Set<ShapeKind> { boardOwningKinds }
}
