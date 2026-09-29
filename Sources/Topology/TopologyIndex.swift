import Canvas
import Observation

/// The file's edges, one per editor (`editor.topology`): every edge the shapes on the boards the
/// editor can show carry, by carrier, by each end and by type, derived from the records and never
/// saved. It never transacts: it follows the file.
///
/// It's read whole as the editor opens (every board it can show: the root, then down through each
/// owner of a board it can show, as `canShow` has it), and again for a board or file put in place.
/// Each commit then costs what it changed: the records it added or changed (not those it only moved:
/// `ChangeSet.moved`), removed, or touched on other boards (`elsewhere`: the boards a deletion took
/// or a paste brought, a write to a board that isn't shown) are read again, a kind with no source
/// costing a lookup. Undo and redo are commits like any other. Showing another board reads nothing:
/// the index is the file's. A carrier on a board the editor can't show carries nothing.
///
/// Queries cost what they return: a shape's edges read its own, a type's its own, never a board's.
/// Services that read it as they hear a commit may hear it first: `catchUp` brings it up to date.
/// What's asked of it is asked of its tables (`EdgeTables`) and of the file's containment
/// (`Containment`), which a snapshot for another thread holds as they are (`snapshot()`), so the
/// two answer alike.
@MainActor
@Observable
public final class TopologyIndex {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The edge types, as a tree: worked out once, as the registry never changes.
    public let types: EdgeTypeTree

    /// Each kind's sources, for the kinds that have any.
    @ObservationIgnored private var emitters: [ShapeKind: [EdgeEmitter]] = [:]
    /// The file's edges: by carrier, by each end and by type.
    @ObservationIgnored private(set) var tables = EdgeTables()
    /// +1 for a shape each time its edges change, observed a shape at a time: only the shapes whose
    /// revision has been read (`watched`), so a commit that changes many shapes' edges (a board
    /// deleted) tells only the shapes someone may be watching.
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    @ObservationIgnored private var watched: Set<ShapeID> = []
    /// The revision the index is up to date with.
    @ObservationIgnored private var heardRevision: Int

    /// The shapes whose edges (at either end) the last commit changed; none after a switch of board.
    /// `touched(types:)` is those whose edges of some types it changed.
    @ObservationIgnored public private(set) var touched: Set<ShapeID> = []
    /// `touched`, by the type of each edge that changed.
    @ObservationIgnored private var touchedByType: [EdgeTypeID: Set<ShapeID>] = [:]

    #if DEBUG
    /// How many records sources have read (debug builds), so tests can hold a commit to what it
    /// changed.
    @ObservationIgnored public private(set) var recordsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        types = editor.registry.edgeTypes
        heardRevision = editor.revision
        for kind in editor.registry.kinds {
            let found = editor.registry.edgeEmitters(for: kind)
            if !found.isEmpty { emitters[kind] = found }
        }
        rebuild()
        clearTouched()
    }

    // MARK: Edges

    /// Every edge touching `id`, anywhere in the file, as `direction` asks, of the types `types`
    /// admits: by carrier, in the order the carriers came to it (those read as the editor opened in
    /// the file's order, root first; those one commit brings, in no order among themselves), each
    /// carrier's in the order it emits them. An edge from `id` to `id` is there once.
    public func edges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [Edge] {
        tables.edges(of: id, direction, types: filter, in: types)
    }

    /// Whether `id` has any edge `edges(of:_:types:)` would find that `predicate` takes (any, by
    /// default): it stops at the first, and makes nothing, so it's cheap enough for what's asked on
    /// every commit.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        tables.hasEdges(of: id, direction, types: filter, in: types, where: predicate)
    }

    /// The shapes at the other end of `id`'s edges (as `edges(of:_:types:)` finds them), by each
    /// edge's type, each once per type, in the order its first edge comes: what's connected to it,
    /// and how. `id` itself, for an edge from `id` to `id`.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [EdgeTypeID: [ShapeID]] {
        tables.neighbors(of: id, direction, types: filter, in: types)
    }

    /// Every edge in the file of the types `filter` admits: type by type (declared ones in plugin
    /// order, then the rest by name), each type's by carrier, in the order they came.
    public func edges(ofType filter: EdgeTypeFilter) -> [Edge] { tables.edges(ofType: filter, in: types) }

    /// What `carrier` carries, in the order it emits them; none for a shape on a board the editor
    /// can't show, or in no board of the file.
    public func edges(carriedBy carrier: ShapeID) -> [Edge] { tables.edges(carriedBy: carrier) }

    /// How a shape at an end of an edge is now: live on a board the editor can show, unavailable on
    /// one it can't, missing from the file.
    public func end(_ id: ShapeID) -> EdgeEnd { containment().end(id) }

    /// A shape's revision: +1 each time its edges (at either end) change, from the first time it's
    /// read. Reading it observes only that shape, so a SwiftUI view of one shape's connections
    /// redraws when they change.
    public func revision(of id: ShapeID) -> Int {
        access(keyPath: \.[revision: id])
        watched.insert(id)
        return revisions[id] ?? 0
    }

    /// Only a key: one key path per shape, under which Observation keeps each shape's observers.
    private subscript(revision id: ShapeID) -> Int { revisions[id] ?? 0 }

    /// The shapes whose edges of the types `filter` admits (at either end) the last commit changed:
    /// `touched`, for a service that reads one type (Mentions: an arrow bound to a mentioned shape
    /// changes none of what mentions it). O(the types the commit changed edges of).
    public func touched(types filter: EdgeTypeFilter) -> Set<ShapeID> {
        guard !filter.isAll else { return touched }
        var found: Set<ShapeID> = []
        for (type, ends) in touchedByType where filter.admits(type, in: types) { found.formUnion(ends) }
        return found
    }

    /// Brings the index up to date with a commit it hasn't heard yet, which `changes` must be (the
    /// one a service is hearing): for a service that reads the index as it hears a commit, and may
    /// hear it before this one does. Nothing if it has heard it already.
    public func catchUp(_ changes: ChangeSet) {
        guard heardRevision != editor.revision else { return }
        hear(changes)
    }

    // MARK: Containment

    /// The kinds whose shapes can contain others (`registry.containerKinds`): today the kinds that
    /// own boards.
    public var containerKinds: Set<ShapeKind> { editor.registry.containerKinds }

    /// The shape whose board `id` is on: nil on the root, and for a shape on a board the editor
    /// can't show (or in no board of the file).
    public func parent(of id: ShapeID) -> ShapeID? { containment().parent(of: id) }

    /// The shapes on the board `id` owns, in document order: none for a shape that owns no board the
    /// editor can show.
    public func children(of id: ShapeID) -> [ShapeID] { containment().children(of: id) }

    /// The shapes `id` is inside, the nearest first (its parent, its parent's, up to one on the
    /// root): none on the root, and for a shape on a board the editor can't show.
    public func ancestors(of id: ShapeID) -> [ShapeID] { containment().ancestors(of: id) }

    /// Whether `a` is inside `b`, at any depth (on its board, or on a board under it); never inside
    /// itself. O(`a`'s depth).
    public func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool { containment().isInside(a, b) }

    /// The file's containment as it is now, observed through `document` as the file is (unless
    /// `observing` is false): made for the one question, never kept, since a copy of the file kept
    /// past a commit would make that commit copy the file's tables.
    func containment(observing: Bool = true) -> Containment {
        let file = observing ? editor.file : editor.withoutObservingDocument { editor.file }
        return Containment(file: file, boardOwningKinds: editor.registry.boardOwningKinds)
    }

    // MARK: Following the file

    /// What a commit changed, applied: the records it touched read again, then the revisions of the
    /// shapes whose edges changed bumped.
    private func hear(_ changes: ChangeSet) {
        heardRevision = editor.revision
        clearTouched()
        if changes.replacedDocument {
            rebuild()
        } else {
            var lookup = Lookup(editor)
            // Removed first: one commit can take a shape off one board and put it on another.
            for id in changes.removed { refresh(id, in: &lookup) }
            for id in changes.elsewhere { refresh(id, in: &lookup) }
            for id in changes.added { refresh(id, in: &lookup) }
            for id in changes.changed where !changes.moved.contains(id) { refresh(id, in: &lookup) }
        }
        bump(touched)
    }

    /// Reads a shape's edges again, wherever it is now: none if it's on no board the editor can show.
    private func refresh(_ id: ShapeID, in lookup: inout Lookup) {
        if let record = lookup.shape(id) {
            set(id, derive(record))
        } else {
            set(id, [])
        }
    }

    /// Reads every board the editor can show afresh, and lets go of carriers it no longer finds.
    /// Carriers whose edges didn't change touch nothing.
    private func rebuild() {
        var seen: Set<ShapeID> = []
        let children = editor.file.children, registry = editor.registry
        var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0
        while next < boards.count {
            let board = boards[next]
            next += 1
            for record in editor.contents(of: board).shapes {
                if emitters[record.kind] != nil {
                    seen.insert(record.id)
                    set(record.id, derive(record))
                }
                let owned = BoardID(owner: record.id)
                if children[record.id] != nil, registry.ownsShowableBoard(record), met.insert(owned).inserted { boards.append(owned) }
            }
        }
        for carrier in Array(tables.byCarrier.keys) where !seen.contains(carrier) { set(carrier, []) }
    }

    /// What a record carries, as its kind's sources say.
    private func derive(_ record: AnyShapeRecord) -> [Edge] {
        guard !record.isOpaque, let emitters = emitters[record.kind] else { return [] }
        #if DEBUG
        recordsRead += 1
        #endif
        return Registry.edges(of: record, emitters: emitters, in: editor.registry)
    }

    /// Makes `edges` what `carrier` carries, and notes the ends of the edges that changed in
    /// `touched`.
    private func set(_ carrier: ShapeID, _ edges: [Edge]) {
        for edge in tables.set(carrier, edges) { touch(edge) }
    }

    /// Notes an edge's ends in `touched`, under its type.
    private func touch(_ edge: Edge) {
        touched.insert(edge.source)
        touched.insert(edge.target)
        touchedByType[edge.type, default: []].insert(edge.source)
        touchedByType[edge.type, default: []].insert(edge.target)
    }

    private func clearTouched() {
        touched = []
        touchedByType = [:]
    }

    /// Bumps the revisions of those of these shapes whose revision has been read, telling their
    /// observers.
    private func bump(_ ids: Set<ShapeID>) {
        let (fewer, more) = ids.count < watched.count ? (ids, watched) : (watched, ids)
        for id in fewer where more.contains(id) {
            withMutation(keyPath: \.[revision: id]) { revisions[id, default: 0] += 1 }
        }
    }
}

extension TopologyIndex: EditorService {
    /// Follows the commit, unless a service that reads the index brought it up to date first
    /// (`catchUp`).
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard heardRevision != editor.revision else { return }
        hear(changes)
    }

    /// Nothing: the index is the file's, and showing another board changes no record. A file put in
    /// place with the switch is read afresh.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        clearTouched()
        guard change.isFileReplaced else { return }
        rebuild()
        bump(touched)
    }
}

extension CanvasEditor {
    /// Topology's index of the file's edges; nil without TopologyPlugin.
    public var topology: TopologyIndex? { service(TopologyIndex.self) }
}

/// `editor.shape(inFile:)` for many shapes at once (a board deleted or pasted, thousands of them):
/// the file read once, and whether each board can be shown asked once.
@MainActor
private struct Lookup {
    let editor: CanvasEditor
    let shown: BoardID
    let document: CanvasDocument
    let file: CanvasFile
    var showable: [BoardID: Bool] = [:]

    init(_ editor: CanvasEditor) {
        self.editor = editor
        shown = editor.board
        document = editor.document
        file = editor.file
    }

    mutating func shape(_ id: ShapeID) -> AnyShapeRecord? {
        guard let board = file.board(containing: id) else { return nil }
        if board == shown { return document[id] }
        let canShow = showable[board] ?? editor.canShow(board)
        showable[board] = canShow
        return canShow ? file[board][id] : nil
    }
}
