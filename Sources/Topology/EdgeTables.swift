import Canvas

/// The file's edges as a value: by carrier, by each end and by type. `TopologyIndex` keeps one and
/// changes it as commits come; a snapshot holds a copy (`TopologySnapshot`), shared until the next
/// change to a table copies that table once. Every query about edges, the index's and a snapshot's,
/// is one of these, so the two answer alike.
struct EdgeTables: Sendable {
    /// What each carrier emitted last, in order: a commit says which shapes changed, not what they
    /// carried before.
    private(set) var byCarrier: [ShapeID: [Edge]] = [:]
    /// Each shape's edges, either way, by carrier, in the order their carriers came.
    private var byNode: [ShapeID: EdgeGroup] = [:]
    /// Each type's edges, by carrier.
    private var byType: [EdgeTypeID: EdgeGroup] = [:]

    // MARK: Reading them

    /// Every edge touching `id`, as `direction` asks, of the types `filter` admits in the tree
    /// `types`: by carrier, in the order the carriers came, each carrier's in the order it emits them.
    /// An edge from `id` to `id` is there once.
    func edges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree) -> [Edge] {
        guard let group = byNode[id] else { return [] }
        var found: [Edge] = []
        group.forEach { edge in
            if edge.touches(id, direction), filter.isAll || filter.admits(edge.type, in: types) { found.append(edge) }
        }
        return found
    }

    /// Whether `id` has an edge `edges(of:_:types:in:)` would find that `predicate` takes: it stops
    /// at the first, and makes nothing.
    func hasEdges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                  where predicate: (Edge) -> Bool) -> Bool {
        byNode[id]?.contains { $0.touches(id, direction) && (filter.isAll || filter.admits($0.type, in: types)) && predicate($0) } ?? false
    }

    /// The shapes at the other end of `id`'s edges, by each edge's type, each once per type, in the
    /// order its first edge comes.
    func neighbors(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree) -> [EdgeTypeID: [ShapeID]] {
        var found: [EdgeTypeID: [ShapeID]] = [:], seen: Set<Neighbor> = []
        for edge in edges(of: id, direction, types: filter, in: types) {
            let other = edge.otherEnd(from: id, direction)
            if seen.insert(Neighbor(type: edge.type, id: other)).inserted { found[edge.type, default: []].append(other) }
        }
        return found
    }

    /// Every edge of the types `filter` admits: type by type (declared ones in plugin order, then the
    /// rest by name), each type's by carrier, in the order they came.
    func edges(ofType filter: EdgeTypeFilter, in types: EdgeTypeTree) -> [Edge] {
        var found: [Edge] = []
        for type in byType.keys.filter({ filter.admits($0, in: types) }).sorted(by: types.precedes) {
            byType[type]?.forEach { found.append($0) }
        }
        return found
    }

    /// What `carrier` carries, in the order it emits them.
    func edges(carriedBy carrier: ShapeID) -> [Edge] { byCarrier[carrier] ?? [] }

    /// The types of the edges there are, declared or not. O(types).
    var presentTypes: Set<EdgeTypeID> { Set(byType.keys) }

    // MARK: Changing them

    /// Makes `edges` what `carrier` carries, keeping each end's and each type's in step. Returns the
    /// edges whose ends it changed the edges of: those that came or went, or every one of the
    /// carrier's when only their order changed; none when nothing did.
    mutating func set(_ carrier: ShapeID, _ edges: [Edge]) -> [Edge] {
        let old = byCarrier[carrier] ?? []
        guard old != edges else { return [] }
        byCarrier[carrier] = edges.isEmpty ? nil : edges

        // A carrier's edges come or go whole (opening a file, a shape added or deleted): each end
        // and type holds only these of its, so they're added or taken edge by edge.
        if old.isEmpty || edges.isEmpty {
            // An end or type the edge before had too (a text's edges all start at its shape) is
            // done: taking a carrier out of a group takes all of its edges there.
            var previous: Edge?
            for edge in old.isEmpty ? edges : old {
                if old.isEmpty {
                    byNode[edge.source, default: EdgeGroup()].append(edge, for: carrier)
                    if edge.target != edge.source { byNode[edge.target, default: EdgeGroup()].append(edge, for: carrier) }
                    byType[edge.type, default: EdgeGroup()].append(edge, for: carrier)
                } else {
                    if edge.source != previous?.source { Self.remove(carrier, from: edge.source, in: &byNode) }
                    Self.remove(carrier, from: edge.target, in: &byNode)
                    if edge.type != previous?.type { Self.remove(carrier, from: edge.type, in: &byType) }
                }
                previous = edge
            }
            return old.isEmpty ? edges : old
        }

        let oldNodes = Self.byNode(old), newNodes = Self.byNode(edges)
        for node in oldNodes.keys where newNodes[node] == nil { Self.remove(carrier, from: node, in: &byNode) }
        for (node, touching) in newNodes { byNode[node, default: EdgeGroup()].set(touching, for: carrier) }

        let oldTypes = Dictionary(grouping: old, by: \.type), newTypes = Dictionary(grouping: edges, by: \.type)
        for type in oldTypes.keys where newTypes[type] == nil { Self.remove(carrier, from: type, in: &byType) }
        for (type, ofType) in newTypes { byType[type, default: EdgeGroup()].set(ofType, for: carrier) }

        let changed = Set(old).symmetricDifference(edges)
        // Only their order changed: every end's edges read in another order.
        return changed.isEmpty ? old : Array(changed)
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

    private static func remove<Key: Hashable>(_ carrier: ShapeID, from key: Key, in groups: inout [Key: EdgeGroup]) {
        guard let index = groups.index(forKey: key) else { return }
        groups.values[index].remove(carrier)
        if groups.values[index].isEmpty { groups.remove(at: index) }
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
struct EdgeGroup: Sendable {
    /// A carrier's edges, and where it is in `order`.
    private struct Entry: Sendable {
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
