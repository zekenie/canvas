import Canvas

/// Topology as it was at one instant, for any thread: the file's edges and containment when the
/// snapshot was taken (`topology.snapshot()`, O(1)), answering every question about them the index
/// answers, as it would have then (not what changed: `revision(of:)`, `touched`), and a few more that
/// read the whole file (its shapes in file order). A query
/// that walks a whole component, or every mention, runs on it off the main actor, uninterrupted,
/// whatever commits land meanwhile.
///
/// It shares the index's tables and the editor's file until the next commit changes them, which then
/// copies each table it changes, once (a move changes none of the index's). So hold one for a task,
/// never past it: kept, it makes every later commit's first change to a table copy it.
public struct TopologySnapshot: Sendable {
    /// The edge types, as a tree.
    public let types: EdgeTypeTree
    /// The kinds whose shapes can contain others (`registry.containerKinds`): today the kinds that
    /// own boards.
    public let containerKinds: Set<ShapeKind>
    private let tables: EdgeTables
    private let containment: Containment

    init(types: EdgeTypeTree, containerKinds: Set<ShapeKind>, tables: EdgeTables, containment: Containment) {
        self.types = types
        self.containerKinds = containerKinds
        self.tables = tables
        self.containment = containment
    }

    // MARK: Edges

    /// Every edge touching `id`, as `direction` asks, of the types `types` admits: as
    /// `TopologyIndex.edges(of:_:types:)`.
    public func edges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [Edge] {
        tables.edges(of: id, direction, types: filter, in: types)
    }

    /// Whether `id` has an edge `edges(of:_:types:)` would find that `predicate` takes: it stops at
    /// the first, and makes nothing.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        tables.hasEdges(of: id, direction, types: filter, in: types, where: predicate)
    }

    /// The shapes at the other end of `id`'s edges, by type: as `TopologyIndex.neighbors(of:_:types:)`.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [EdgeTypeID: [ShapeID]] {
        tables.neighbors(of: id, direction, types: filter, in: types)
    }

    /// Every edge in the file of the types `filter` admits: as `TopologyIndex.edges(ofType:)`.
    public func edges(ofType filter: EdgeTypeFilter) -> [Edge] { tables.edges(ofType: filter, in: types) }

    /// What `carrier` carries, in the order it emits them.
    public func edges(carriedBy carrier: ShapeID) -> [Edge] { tables.edges(carriedBy: carrier) }

    /// The types of the edges in the file: declared ones, and any nobody declares that a shape
    /// carries (a newer app's channel, kept as written). O(types).
    public var presentTypes: Set<EdgeTypeID> { tables.presentTypes }

    /// How a shape at an end of an edge was: live on a board the app can show, unavailable on one it
    /// can't, missing from the file. A shape kept aside on a board it can show is live: `shape(_:)`
    /// says whether it's kept aside.
    public func end(_ id: ShapeID) -> EdgeEnd { containment.end(id) }

    // MARK: Shapes and containment

    /// A shape on a board the app can show, kept aside or not (`isOpaque`); nil for one on a board it
    /// can't show, or in no board of the file. O(its depth).
    public func shape(_ id: ShapeID) -> AnyShapeRecord? { containment.shape(id) }

    /// The shape whose board `id` is on: nil on the root, and for a shape on a board the app can't
    /// show.
    public func parent(of id: ShapeID) -> ShapeID? { containment.parent(of: id) }

    /// The shapes on the board `id` owns, in document order: none for a shape that owns no board the
    /// app can show.
    public func children(of id: ShapeID) -> [ShapeID] { containment.children(of: id) }

    /// The shapes `id` is inside, the nearest first: none on the root, and for a shape on a board the
    /// app can't show.
    public func ancestors(of id: ShapeID) -> [ShapeID] { containment.ancestors(of: id) }

    /// Whether `a` is inside `b`, at any depth; never inside itself. O(`a`'s depth).
    public func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool { containment.isInside(a, b) }

    /// The shapes on the root, inside nothing, in document order.
    public var topLevel: [ShapeID] { containment.topLevel }

    /// Every shape inside `id`, at any depth, in file order: none for a shape that owns no board the
    /// app can show. O(what's inside it).
    public func descendants(of id: ShapeID) -> [ShapeID] { containment.descendants(of: id) }

    /// Every shape on a board the app can show, kept aside ones too, with its board, in file order:
    /// the root's shapes back to front, each shape that owns a board followed at once by that board's
    /// shapes, and theirs, before the next. O(those shapes). An error `body` throws stops it, and
    /// comes out as `body`'s own type (a query's, when it's cancelled).
    public func forEachShape<E: Error>(inFileOrder body: (AnyShapeRecord, BoardID) throws(E) -> Void) throws(E) {
        try containment.forEachShape(inFileOrder: body)
    }

    /// Where a shape comes in file order, as a key that sorts (lexicographically) as
    /// `forEachShape(inFileOrder:)` visits: the index of each owner above it on its board, from the
    /// root's down, then its own. Nil for a shape on a board the app can't show, or in no board of
    /// the file. O(its depth): for putting a few shapes in order without walking the file.
    public func fileOrderKey(of id: ShapeID) -> [Int]? { containment.fileOrderKey(of: id) }
}

extension TopologyIndex {
    /// Topology as it is now, for another thread: the index's tables, the editor's file and the edge
    /// types, shared, not copied (O(1)). It reads no record, and observes nothing. Taken by a service
    /// hearing a commit the index may not have heard yet, its edges are the commit before's while its
    /// file is the commit's, as the index's own answers are then: `catchUp` first.
    public func snapshot() -> TopologySnapshot {
        TopologySnapshot(types: types, containerKinds: containerKinds, tables: tables, containment: containment(observing: false))
    }
}
