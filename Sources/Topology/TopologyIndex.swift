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
@MainActor
@Observable
public final class TopologyIndex {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The edge types, as a tree: worked out once, as the registry never changes.
    public let types: EdgeTypeTree

    /// Each kind's sources, for the kinds that have any.
    @ObservationIgnored private var emitters: [ShapeKind: [EdgeEmitter]] = [:]
    /// What each carrier emitted last, in order: a commit says which shapes changed, not what they
    /// carried before.
    @ObservationIgnored private var byCarrier: [ShapeID: [Edge]] = [:]
    /// Each shape's edges, either way, by carrier, in the order their carriers came.
    @ObservationIgnored private var byNode: [ShapeID: EdgeGroup] = [:]
    /// Each type's edges, by carrier.
    @ObservationIgnored private var byType: [EdgeTypeID: EdgeGroup] = [:]
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
        guard let group = byNode[id] else { return [] }
        var found: [Edge] = []
        group.forEach { edge in
            if edge.touches(id, direction), filter.isAll || filter.admits(edge.type, in: types) { found.append(edge) }
        }
        return found
    }

    /// Whether `id` has any edge `edges(of:_:types:)` would find that `predicate` takes (any, by
    /// default): it stops at the first, and makes nothing, so it's cheap enough for what's asked on
    /// every commit.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        byNode[id]?.contains { $0.touches(id, direction) && (filter.isAll || filter.admits($0.type, in: types)) && predicate($0) } ?? false
    }

    /// The shapes at the other end of `id`'s edges (as `edges(of:_:types:)` finds them), by each
    /// edge's type, each once per type, in the order its first edge comes: what's connected to it,
    /// and how. `id` itself, for an edge from `id` to `id`.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [EdgeTypeID: [ShapeID]] {
        var found: [EdgeTypeID: [ShapeID]] = [:], seen: Set<Neighbor> = []
        for edge in edges(of: id, direction, types: filter) {
            let other = edge.otherEnd(from: id, direction)
            if seen.insert(Neighbor(type: edge.type, id: other)).inserted { found[edge.type, default: []].append(other) }
        }
        return found
    }

    /// Every edge in the file of the types `filter` admits: type by type (declared ones in plugin
    /// order, then the rest by name), each type's by carrier, in the order they came.
    public func edges(ofType filter: EdgeTypeFilter) -> [Edge] {
        var found: [Edge] = []
        for type in byType.keys.filter({ filter.admits($0, in: types) }).sorted(by: types.precedes) {
            byType[type]?.forEach { found.append($0) }
        }
        return found
    }

    /// What `carrier` carries, in the order it emits them; none for a shape on a board the editor
    /// can't show, or in no board of the file.
    public func edges(carriedBy carrier: ShapeID) -> [Edge] { byCarrier[carrier] ?? [] }

    /// How a shape at an end of an edge is now: live on a board the editor can show, unavailable on
    /// one it can't, missing from the file.
    public func end(_ id: ShapeID) -> EdgeEnd {
        if editor.document[id] != nil { return .live(editor.board) }
        guard let board = editor.file.board(containing: id) else { return .missing }
        return editor.canShow(board) ? .live(board) : .unavailable
    }

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

    /// The shape whose board `id` is on: nil on the root, and for a shape on a board the editor
    /// can't show (or in no board of the file).
    public func parent(of id: ShapeID) -> ShapeID? {
        guard editor.shape(inFile: id) != nil else { return nil }
        return editor.file.board(containing: id)?.owner
    }

    /// The shapes on the board `id` owns, in document order: none for a shape that owns no board the
    /// editor can show.
    public func children(of id: ShapeID) -> [ShapeID] {
        guard let owner = editor.shape(inFile: id), editor.registry.ownsShowableBoard(owner) else { return [] }
        return editor.contents(of: BoardID(owner: id)).shapes.map(\.id)
    }

    /// The shapes `id` is inside, the nearest first (its parent, its parent's, up to one on the
    /// root): none on the root, and for a shape on a board the editor can't show.
    public func ancestors(of id: ShapeID) -> [ShapeID] {
        guard editor.shape(inFile: id) != nil else { return [] }
        let file = editor.file
        var found: [ShapeID] = [], met: Set<ShapeID> = [id], current = id
        while let owner = file.board(containing: current)?.owner, met.insert(owner).inserted {
            found.append(owner)
            current = owner
        }
        return found
    }

    /// Whether `a` is inside `b`, at any depth (on its board, or on a board under it); never inside
    /// itself. O(`a`'s depth).
    public func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool {
        a != b && ancestors(of: a).contains(b)
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
        for carrier in Array(byCarrier.keys) where !seen.contains(carrier) { set(carrier, []) }
    }

    /// What a record carries, as its kind's sources say.
    private func derive(_ record: AnyShapeRecord) -> [Edge] {
        guard !record.isOpaque, let emitters = emitters[record.kind] else { return [] }
        #if DEBUG
        recordsRead += 1
        #endif
        return Registry.edges(of: record, emitters: emitters, in: editor.registry)
    }

    /// Makes `edges` what `carrier` carries, keeping each end's and each type's in step, and notes
    /// the ends of the edges that changed in `touched`.
    private func set(_ carrier: ShapeID, _ edges: [Edge]) {
        let old = byCarrier[carrier] ?? []
        guard old != edges else { return }
        byCarrier[carrier] = edges.isEmpty ? nil : edges

        // A carrier's edges come or go whole (opening a file, a shape added or deleted): each end
        // and type holds only these of its, so they're added or taken edge by edge.
        if old.isEmpty || edges.isEmpty {
            // An end or type the edge before had too (a text's edges all start at its shape) is
            // done: taking a carrier out of a group takes all of its edges there.
            var previous: Edge?
            for edge in old.isEmpty ? edges : old {
                touch(edge)
                if old.isEmpty {
                    byNode[edge.source, default: EdgeGroup()].append(edge, for: carrier)
                    if edge.target != edge.source { byNode[edge.target, default: EdgeGroup()].append(edge, for: carrier) }
                    byType[edge.type, default: EdgeGroup()].append(edge, for: carrier)
                } else {
                    if edge.source != previous?.source { remove(carrier, from: edge.source, in: &byNode) }
                    remove(carrier, from: edge.target, in: &byNode)
                    if edge.type != previous?.type { remove(carrier, from: edge.type, in: &byType) }
                }
                previous = edge
            }
            return
        }

        let changed = Set(old).symmetricDifference(edges)
        // Only their order changed: every end's edges read in another order.
        for edge in changed.isEmpty ? old : Array(changed) { touch(edge) }

        let oldNodes = Self.byNode(old), newNodes = Self.byNode(edges)
        for node in oldNodes.keys where newNodes[node] == nil { remove(carrier, from: node, in: &byNode) }
        for (node, touching) in newNodes { byNode[node, default: EdgeGroup()].set(touching, for: carrier) }

        let oldTypes = Dictionary(grouping: old, by: \.type), newTypes = Dictionary(grouping: edges, by: \.type)
        for type in oldTypes.keys where newTypes[type] == nil { remove(carrier, from: type, in: &byType) }
        for (type, ofType) in newTypes { byType[type, default: EdgeGroup()].set(ofType, for: carrier) }
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

    /// Each end's edges among `edges`, in order: an edge from a shape to itself once.
    private static func byNode(_ edges: [Edge]) -> [ShapeID: [Edge]] {
        var found: [ShapeID: [Edge]] = [:]
        for edge in edges {
            found[edge.source, default: []].append(edge)
            if edge.target != edge.source { found[edge.target, default: []].append(edge) }
        }
        return found
    }

    private func remove<Key: Hashable>(_ carrier: ShapeID, from key: Key, in groups: inout [Key: EdgeGroup]) {
        guard let index = groups.index(forKey: key) else { return }
        groups.values[index].remove(carrier)
        if groups.values[index].isEmpty { groups.remove(at: index) }
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

/// A shape at the other end of an edge, of its type: what `neighbors` lists once.
private struct Neighbor: Hashable {
    let type: EdgeTypeID
    let id: ShapeID
}

/// Edges grouped by carrier (a shape's, a type's), in the order the carriers came: a carrier that
/// comes back comes last. Setting or removing a carrier's costs O(its edges), whatever the group
/// holds: a removed carrier leaves a gap, and the gaps go once they're half the order.
struct EdgeGroup {
    /// A carrier's edges, and where it is in `order`.
    private struct Entry {
        var position: Int
        var edges: [Edge]
    }

    private var order: [ShapeID] = []
    /// Each carrier held: a carrier in `order` at another position than its entry's is a gap.
    private var entries: [ShapeID: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func set(_ carried: [Edge], for carrier: ShapeID) {
        if let index = entries.index(forKey: carrier) {
            entries.values[index].edges = carried
        } else {
            entries[carrier] = Entry(position: order.count, edges: carried)
            order.append(carrier)
        }
    }

    /// Adds one edge to `carrier`'s, after those it holds: a carrier new to the group comes last.
    mutating func append(_ edge: Edge, for carrier: ShapeID) {
        if let index = entries.index(forKey: carrier) {
            entries.values[index].edges.append(edge)
        } else {
            entries[carrier] = Entry(position: order.count, edges: [edge])
            order.append(carrier)
        }
    }

    mutating func remove(_ carrier: ShapeID) {
        guard entries.removeValue(forKey: carrier) != nil else { return }
        if entries.isEmpty {
            order = []
        } else if order.count > 16, entries.count * 2 < order.count {
            order = order.enumerated().filter { entries[$0.element]?.position == $0.offset }.map(\.element)
            for (index, carrier) in order.enumerated() { entries[carrier]?.position = index }
        }
    }

    /// Whether an edge it holds satisfies `predicate`: it stops at the first.
    func contains(where predicate: (Edge) -> Bool) -> Bool {
        entries.values.contains { $0.edges.contains(where: predicate) }
    }

    func forEach(_ body: (Edge) -> Void) {
        for (index, carrier) in order.enumerated() {
            guard let entry = entries[carrier], entry.position == index else { continue }
            for edge in entry.edges { body(edge) }
        }
    }
}
