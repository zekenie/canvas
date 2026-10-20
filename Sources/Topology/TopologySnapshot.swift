import Canvas

/// Topology as it was at one instant, for any thread: the file's edges and containment when the
/// snapshot was taken (`topology.snapshot()`, O(1)), answering every question about them the index
/// answers, as it would have then (not what changed: `revision(of:)`, `touched`), and a few more that
/// read the whole file (its shapes in file order). A query
/// that walks a whole component, or every mention, runs on it off the main actor, uninterrupted,
/// whatever commits land meanwhile.
///
/// It reads the edges in one view (`view`, taken with it: `snapshot(.recorded)`), as the index would
/// have read them asked for that view; its shapes and containment are the same in every view
/// (containment is never forwarded).
///
/// It shares the index's tables and the editor's file until the next commit changes them, which then
/// copies each table it changes, once (a move changes none of the index's). So hold one for a task,
/// never past it: kept, it makes every later commit's first change to a table copy it.
public struct TopologySnapshot: Sendable {
    /// The edge types, as a tree.
    public let types: EdgeTypeTree
    /// The kinds whose shapes can contain others (`registry.containerKinds`): those that own boards
    /// (a subboard) and those that hold shapes on the board they're on (a frame).
    public let containerKinds: Set<ShapeKind>
    /// The kinds whose shapes stand in for others (`EdgeForwarding`).
    public let standInKinds: Set<ShapeKind>
    /// How it reads the edges: resolved through every stand-in (the default), through those whose
    /// record names what they stand for, or as carriers emitted them.
    public let view: EdgeView
    private let tables: EdgeTables
    private let containment: Containment

    init(types: EdgeTypeTree, containerKinds: Set<ShapeKind>, standInKinds: Set<ShapeKind>, view: EdgeView, tables: EdgeTables,
         containment: Containment) {
        self.types = types
        self.containerKinds = containerKinds
        self.standInKinds = standInKinds
        self.view = view
        self.tables = tables
        self.containment = containment
    }

    // MARK: Edges

    /// Every edge touching `id`, as `direction` asks, of the types `types` admits: as
    /// `TopologyIndex.edges(of:_:types:)`.
    public func edges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [Edge] {
        tables.edges(of: id, direction, types: filter, in: types, view: view)
    }

    /// Whether `id` has an edge `edges(of:_:types:)` would find that `predicate` takes: it stops at
    /// the first, and makes nothing.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        tables.hasEdges(of: id, direction, types: filter, in: types, view: view, where: predicate)
    }

    /// The shapes at the other end of `id`'s edges, by type: as `TopologyIndex.neighbors(of:_:types:)`.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [EdgeTypeID: [ShapeID]] {
        tables.neighbors(of: id, direction, types: filter, in: types, view: view)
    }

    /// Every edge in the file of the types `filter` admits: as `TopologyIndex.edges(ofType:)`.
    public func edges(ofType filter: EdgeTypeFilter) -> [Edge] { tables.edges(ofType: filter, in: types, view: view) }

    /// What `carrier` carries, in the order it emits them (in the literal view, what it emitted).
    public func edges(carriedBy carrier: ShapeID) -> [Edge] { tables.edges(carriedBy: carrier, view: view) }

    /// The types of the edges in the file: declared ones, and any nobody declares that a shape
    /// carries (a newer app's channel, kept as written). O(types).
    public var presentTypes: Set<EdgeTypeID> { tables.presentTypes(view: view) }

    /// The shapes `standIn` stood for, in order: as `TopologyIndex.forwards(of:)`, whatever the view.
    public func forwards(of standIn: ShapeID) -> [ShapeID] { tables.forwards(of: standIn) }

    /// The stand-ins that stood for `target`: as `TopologyIndex.standIns(for:)`, whatever the view.
    public func standIns(for target: ShapeID) -> [ShapeID] { tables.standIns(for: target) }

    /// How a shape at an end of an edge was: live on a board the app can show, unavailable on one it
    /// can't, missing from the file. A shape kept aside on a board it can show is live: `shape(_:)`
    /// says whether it's kept aside.
    public func end(_ id: ShapeID) -> EdgeEnd { containment.end(id) }

    // MARK: Shapes and containment

    /// A shape on a board the app can show, kept aside or not (`isOpaque`); nil for one on a board it
    /// can't show, or in no board of the file. O(its depth).
    public func shape(_ id: ShapeID) -> AnyShapeRecord? { containment.shape(id) }

    /// The shape `id` is directly inside: the container it's in on its board (a frame), else the
    /// owner of its board; nil on the root in no container, and for a shape on a board the app can't
    /// show.
    public func parent(of id: ShapeID) -> ShapeID? { containment.parent(of: id) }

    /// The shapes directly inside `id`: what it holds (a frame's shapes), back to front, then, for a
    /// shape that owns a board the app can show, that board's shapes in no container, back to front.
    /// None for any other shape.
    public func children(of id: ShapeID) -> [ShapeID] { containment.children(of: id) }

    /// The shapes `id` is inside, the nearest first: none on the root in no container, and for a
    /// shape on a board the app can't show.
    public func ancestors(of id: ShapeID) -> [ShapeID] { containment.ancestors(of: id) }

    /// Whether `a` is inside `b`, at any depth; never inside itself. O(`a`'s depth).
    public func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool { containment.isInside(a, b) }

    /// The shapes inside nothing: the root's in no container, in document order.
    public var topLevel: [ShapeID] { containment.topLevel }

    /// Whether a shape is inside nothing: on the root, in no container. O(1).
    public func isTopLevel(_ id: ShapeID) -> Bool { containment.isTopLevel(id) }

    /// The container a shape on `board` is directly in there (a frame), as the core goes by it: its
    /// `parent(of:)` when it's in one; nil for a shape on its board directly, which costs no lookup.
    /// O(1), for a reader that holds the record and knows its board (a query's walk, which
    /// `forEachShape(inFileOrder:)` hands both) and works out what's above each container and each
    /// board once.
    public func container(of record: AnyShapeRecord, on board: BoardID) -> ShapeID? { containment.container(of: record, on: board) }

    /// Every shape inside `id`, at any depth, in file order: none for a shape that holds nothing and
    /// owns no board the app can show. O(what's inside it).
    public func descendants(of id: ShapeID) -> [ShapeID] { containment.descendants(of: id) }

    /// Every shape on a board the app can show, kept aside ones too, with its board, in file order:
    /// the root's shapes in no container, back to front, each followed at once by what's inside it
    /// (what it holds, then, for a shape that owns a board, that board's shapes), and theirs, before
    /// the next. O(those shapes). An error `body` throws stops it, and comes out as `body`'s own type
    /// (a query's, when it's cancelled).
    public func forEachShape<E: Error>(inFileOrder body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        try containment.forEachShape(inFileOrder: body)
    }

    /// Where a shape comes in file order, as a key that sorts (lexicographically) as
    /// `forEachShape(inFileOrder:)` visits: for each shape it's inside, from the outermost down, then
    /// for itself, its place among what's directly inside the same shape (its index on its board).
    /// Nil for a shape on a board the app can't show, or in no board of the file. O(its depth): for
    /// putting a few shapes in order without walking the file.
    public func fileOrderKey(of id: ShapeID) -> [Int]? { containment.fileOrderKey(of: id) }
}

extension TopologyIndex {
    /// Topology as it is now, for another thread, its edges read in `view` (resolved through every
    /// stand-in by default): the index's tables, the editor's file and the edge types, shared, not
    /// copied (O(1)). It reads no record, and observes nothing. Taken as services take a commit in,
    /// look the index up first (`editor.topology`), so it has taken the commit in: a snapshot of an
    /// index that hasn't would hold the commit's file with the commit before's edges.
    public func snapshot(_ view: EdgeView = .resolved) -> TopologySnapshot {
        TopologySnapshot(types: types, containerKinds: containerKinds, standInKinds: standInKinds, view: view, tables: tables,
                         containment: containment(observing: false))
    }
}
