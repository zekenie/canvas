import Canvas

/// The file's edges as a value: what each carrier emitted, and the edges as stand-ins forward them
/// (`EdgeView.resolved`), by carrier, by each end and by type; and what each stand-in stands for.
/// `TopologyIndex` keeps one and changes it as commits come; a snapshot holds a copy
/// (`TopologySnapshot`), shared until the next change to a table copies that table once. Every
/// query about edges, the index's and a snapshot's, in every view, is one of these, so the two
/// answer alike.
///
/// Sparse: the resolved edges are kept whole (by each end and type, as every reader reads them by
/// default), and by carrier only for a carrier whose edges forwarding changed (an arrow into a
/// stand-in; a stand-in with standing edges). The other views are read from them by mapping each
/// forwarded edge back (`Edge.origin` keeps the stand-in at each end), so a file with no stand-ins
/// holds what it did before there were any, and costs what it did.
struct EdgeTables: Sendable {
    /// What each carrier emitted last, in order: a commit says which shapes changed, not what they
    /// carried before.
    private(set) var byCarrier: [ShapeID: [Edge]] = [:]
    /// What a carrier carries in the resolved view, only where that isn't what it emitted.
    private(set) var resolvedByCarrier: [ShapeID: [Edge]] = [:]
    /// Each shape's resolved edges, either way, by carrier, in the order their carriers came: an
    /// edge is filed under its ends and its literal ends (`Edge.literalSource`, `literalTarget`), so
    /// an edge forwarded through a stand-in is found from the stand-in too.
    private var byNode: [ShapeID: EdgeGroup] = [:]
    /// Each type's resolved edges, by carrier.
    private var byType: [EdgeTypeID: EdgeGroup] = [:]
    /// What each stand-in stands for now, in order, for those that stand for something.
    private(set) var forwards: [ShapeID: [ShapeID]] = [:]
    /// The stand-ins that stand for each shape, in the order they came to.
    private(set) var standIns: [ShapeID: [ShapeID]] = [:]
    /// Whether each stand-in in `forwards` stands for what its record names, or what was provided.
    private(set) var forwardKind: [ShapeID: ForwardKind] = [:]

    // MARK: Reading them

    /// Every edge touching `id`, as `direction` asks, of the types `filter` admits in the tree
    /// `types`, as `view` reads them: by carrier, in the order the carriers came, each carrier's in
    /// the order it emits them. An edge from `id` to `id` is there once, and the copies of an edge
    /// forwarded into several shapes that `view` reads back as one are one.
    func edges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
               view: EdgeView = .resolved) -> [Edge] {
        var found: [Edge] = []
        forEachEdge(of: id, direction, types: filter, in: types, view: view) { found.append($0) }
        return found
    }

    /// Calls `body` with each edge `edges(of:_:types:in:view:)` returns, in its order, making no array: what a walk
    /// over many shapes' edges (each one's instances, and theirs) reads them by.
    func forEachEdge(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                     view: EdgeView = .resolved, _ body: (Edge) -> Void) {
        guard let group = byNode[id] else { return }
        if view == .resolved {
            group.forEach { edge in
                if edge.touches(id, direction), filter.isAll || filter.admits(edge.type, in: types) { body(edge) }
            }
            return
        }
        var mapped: Set<Edge> = []
        group.forEach { edge in
            // An edge as emitted is itself in every view, and no forwarded copy reads back as it.
            if case .emitted = edge.origin {
                if edge.touches(id, direction), filter.isAll || filter.admits(edge.type, in: types) { body(edge) }
                return
            }
            guard let seen = viewed(edge, view), seen.touches(id, direction), filter.isAll || filter.admits(seen.type, in: types),
                  seen == edge || mapped.insert(seen).inserted else { return }
            body(seen)
        }
    }

    /// Whether `id` has an edge `edges(of:_:types:in:view:)` would find that `predicate` takes: it
    /// stops at the first, and makes nothing.
    func hasEdges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                  view: EdgeView = .resolved, where predicate: (Edge) -> Bool) -> Bool {
        guard let group = byNode[id] else { return false }
        if view == .resolved {
            return group.contains { $0.touches(id, direction) && (filter.isAll || filter.admits($0.type, in: types)) && predicate($0) }
        }
        return group.contains { edge in
            // An edge as emitted is itself in every view.
            guard let seen = edge.origin == .emitted ? edge : viewed(edge, view) else { return false }
            return seen.touches(id, direction) && (filter.isAll || filter.admits(seen.type, in: types)) && predicate(seen)
        }
    }

    /// The shapes at the other end of `id`'s edges, by each edge's type, each once per type, in the
    /// order its first edge comes.
    func neighbors(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                   view: EdgeView = .resolved) -> [EdgeTypeID: [ShapeID]] {
        var found: [EdgeTypeID: [ShapeID]] = [:], seen: Set<Neighbor> = []
        for edge in edges(of: id, direction, types: filter, in: types, view: view) {
            let other = edge.otherEnd(from: id, direction)
            if seen.insert(Neighbor(type: edge.type, id: other)).inserted { found[edge.type, default: []].append(other) }
        }
        return found
    }

    /// Every edge of the types `filter` admits, as `view` reads them: type by type (declared ones in
    /// plugin order, then the rest by name), each type's by carrier, in the order they came.
    func edges(ofType filter: EdgeTypeFilter, in types: EdgeTypeTree, view: EdgeView = .resolved) -> [Edge] {
        var found: [Edge] = [], mapped: Set<Edge> = []
        for type in byType.keys.filter({ filter.admits($0, in: types) }).sorted(by: types.precedes) {
            byType[type]?.forEach { edge in
                if view == .resolved {
                    found.append(edge)
                } else if let seen = viewed(edge, view), seen == edge || mapped.insert(seen).inserted {
                    found.append(seen)
                }
            }
        }
        return found
    }

    /// What `carrier` carries, as `view` reads it, in the order it emits them.
    func edges(carriedBy carrier: ShapeID, view: EdgeView = .resolved) -> [Edge] {
        switch view {
        case .resolved: return resolvedByCarrier[carrier] ?? byCarrier[carrier] ?? []
        case .literal: return byCarrier[carrier] ?? []
        case .recorded:
            guard let resolved = resolvedByCarrier[carrier] else { return byCarrier[carrier] ?? [] }
            var found: [Edge] = [], mapped: Set<Edge> = []
            for edge in resolved {
                if let seen = viewed(edge, .recorded), seen == edge || mapped.insert(seen).inserted { found.append(seen) }
            }
            return found
        }
    }

    /// The resolved edges forwarded through `standIn` (whose `origin` names it at an end): one for
    /// each shape it stands for, for each edge another shape carries into it or out of it.
    func edges(through standIn: ShapeID) -> [Edge] {
        guard forwards[standIn] != nil, let group = byNode[standIn] else { return [] }
        var found: [Edge] = []
        group.forEach { edge in
            if case .forwarded(let source, let target) = edge.origin, source == standIn || target == standIn { found.append(edge) }
        }
        return found
    }

    /// The types of the edges there are, declared or not, as `view` reads them. O(types).
    func presentTypes(view: EdgeView = .resolved) -> Set<EdgeTypeID> {
        let present = Set(byType.keys)
        switch view {
        case .resolved: return present
        case .literal: return present.subtracting([StandingEdge.id])
        case .recorded: return forwardKind.values.contains(.record) ? present : present.subtracting([StandingEdge.id])
        }
    }

    /// An edge as `view` reads it: nil for one it doesn't hold (a standing edge, in the literal
    /// view; one of a stand-in for what's provided, in the recorded view); a forwarded one with each
    /// end the view doesn't forward put back at its stand-in.
    func viewed(_ edge: Edge, _ view: EdgeView) -> Edge? {
        switch (edge.origin, view) {
        case (.emitted, _), (_, .resolved):
            return edge
        case (.standing, .literal):
            return nil
        case (.standing, .recorded):
            return forwardKind[edge.carrier] == .provided ? nil : edge
        case (.forwarded, .literal):
            return edge.literal
        case (.forwarded(let source, let target), .recorded):
            let backSource = source.map { forwardKind[$0] == .provided } ?? false
            let backTarget = target.map { forwardKind[$0] == .provided } ?? false
            guard backSource || backTarget else { return edge }
            let stillSource = backSource ? nil : source, stillTarget = backTarget ? nil : target
            return Edge(type: edge.type, source: backSource ? edge.literalSource : edge.source,
                        target: backTarget ? edge.literalTarget : edge.target, carrier: edge.carrier, slot: edge.slot, count: edge.count,
                        origin: stillSource == nil && stillTarget == nil ? .emitted : .forwarded(source: stillSource, target: stillTarget))
        }
    }

    /// What `standIn` stands for now, in order: none for a shape that stands for nothing.
    func forwards(of standIn: ShapeID) -> [ShapeID] { forwards[standIn] ?? [] }

    /// The stand-ins that stand for `target` now, in the order they came to.
    func standIns(for target: ShapeID) -> [ShapeID] { standIns[target] ?? [] }

    /// The carriers of the edges filed under `id`, in the order they came: those with an edge at
    /// it, resolved or as emitted.
    func carriers(at id: ShapeID) -> [ShapeID] { byNode[id]?.carriers ?? [] }

    // MARK: Changing them

    /// Makes `emitted` what `carrier` emitted, and `resolved` what it carries as stand-ins forward
    /// it (nil: what it emitted, nothing forwarded), keeping each end's and each type's in step.
    /// Returns the resolved edges whose ends it changed the edges of: those that came or went, or
    /// every one of the carrier's when only their order changed; none when nothing did.
    mutating func set(_ carrier: ShapeID, emitted: [Edge], resolved: [Edge]?) -> [Edge] {
        // Nothing forwarded anywhere (no stand-in stands for anything): no lookup there.
        let oldEmitted = byCarrier[carrier] ?? [], oldResolved = resolvedByCarrier.isEmpty ? nil : resolvedByCarrier[carrier]
        let emittedChanged = oldEmitted != emitted
        if emittedChanged { byCarrier[carrier] = emitted.isEmpty ? nil : emitted }
        let old = oldResolved ?? oldEmitted, edges = resolved ?? emitted
        if oldResolved == nil, resolved == nil {
            guard emittedChanged else { return [] }
        } else {
            if oldResolved != resolved { resolvedByCarrier[carrier] = resolved }
            guard old != edges else { return [] }
        }

        // A carrier's edges come or go whole (opening a file, a shape added or deleted): each end
        // and type holds only these of its, so they're added or taken edge by edge.
        if old.isEmpty {
            for edge in edges {
                edge.forEachNode { byNode[$0, default: EdgeGroup()].append(edge, for: carrier) }
                byType[edge.type, default: EdgeGroup()].append(edge, for: carrier)
            }
            return edges
        }
        if edges.isEmpty {
            // An end or type the edge before had too (a text's edges all start at its shape) is
            // done: taking a carrier out of a group takes all of its edges there. By index: no edge
            // is kept from one to the next.
            for index in old.indices {
                let edge = old[index], first = index == old.startIndex
                let sameSource = !first && old[index - 1].source == edge.source
                edge.forEachNode { node in if !sameSource || node != edge.source { Self.remove(carrier, from: node, in: &byNode) } }
                if first || old[index - 1].type != edge.type { Self.remove(carrier, from: edge.type, in: &byType) }
            }
            return old
        }

        // What the edges before were filed under is only let go of where the new ones aren't.
        let newNodes = Self.byNode(edges)
        var oldNodes: Set<ShapeID> = []
        for edge in old { edge.forEachNode { if newNodes[$0] == nil { oldNodes.insert($0) } } }
        for node in oldNodes { Self.remove(carrier, from: node, in: &byNode) }
        for (node, touching) in newNodes { byNode[node, default: EdgeGroup()].set(touching, for: carrier) }

        let newTypes = Dictionary(grouping: edges, by: \.type)
        for type in Set(old.lazy.map(\.type)) where newTypes[type] == nil { Self.remove(carrier, from: type, in: &byType) }
        for (type, ofType) in newTypes { byType[type, default: EdgeGroup()].set(ofType, for: carrier) }

        let changed = Set(old).symmetricDifference(edges)
        // Only their order changed: every end's edges read in another order.
        return changed.isEmpty ? old : Array(changed)
    }

    /// Makes `targets` what `standIn` stands for (none: nothing), as `kind` has it, keeping who
    /// stands for each shape in step. Whether that changed anything.
    mutating func setForwards(_ standIn: ShapeID, _ targets: [ShapeID], kind: ForwardKind) -> Bool {
        let old = forwards[standIn] ?? []
        let newKind: ForwardKind? = targets.isEmpty ? nil : kind
        guard old != targets || forwardKind[standIn] != newKind else { return false }
        if old != targets {
            forwards[standIn] = targets.isEmpty ? nil : targets
            let now = Set(targets), before = Set(old)
            for target in old where !now.contains(target) {
                guard let index = standIns.index(forKey: target) else { continue }
                standIns.values[index].removeAll { $0 == standIn }
                if standIns.values[index].isEmpty { standIns.remove(at: index) }
            }
            for target in targets where !before.contains(target) { standIns[target, default: []].append(standIn) }
        }
        if forwardKind[standIn] != newKind { forwardKind[standIn] = newKind }
        return true
    }

    /// Each end's edges among `edges`, in order: an edge under each of its ends and literal ends,
    /// once.
    private static func byNode(_ edges: [Edge]) -> [ShapeID: [Edge]] {
        var found: [ShapeID: [Edge]] = [:]
        for edge in edges { edge.forEachNode { found[$0, default: []].append(edge) } }
        return found
    }

    private static func remove<Key: Hashable>(_ carrier: ShapeID, from key: Key, in groups: inout [Key: EdgeGroup]) {
        guard let index = groups.index(forKey: key) else { return }
        groups.values[index].remove(carrier)
        if groups.values[index].isEmpty { groups.remove(at: index) }
    }
}

/// How a stand-in stands for its shapes: as its record names them, or as provided.
enum ForwardKind: Hashable, Sendable {
    case record
    case provided
}

extension Edge {
    /// Calls `body` with each shape the edge is filed under: its source, its target, and its literal
    /// ends where they differ, each once.
    @inline(__always)
    func forEachNode(_ body: (ShapeID) -> Void) {
        body(source)
        if target != source { body(target) }
        guard case .forwarded(let s, let t) = origin else { return }
        if let s, s != source, s != target { body(s) }
        if let t, t != source, t != target, t != s { body(t) }
    }

    /// Whether it's filed under `node`: one of the shapes `forEachNode` calls with.
    @inline(__always)
    func isFiled(under node: ShapeID) -> Bool {
        if source == node || target == node { return true }
        guard case .forwarded(let s, let t) = origin else { return false }
        return s == node || t == node
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

    /// The carriers it holds, in the order they came.
    var carriers: [ShapeID] {
        order.enumerated().compactMap { entries[$0.element]?.position == $0.offset ? $0.element : nil }
    }

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
