import Canvas

/// The file's edges as a value: what each carrier emitted, by carrier, by each end and by type; and
/// what each stand-in stands for, and who stands for each shape. `TopologyIndex` keeps one and
/// changes it as commits come; a snapshot holds a copy (`TopologySnapshot`), shared until the next
/// change to a table copies that table once. Every query about edges, the index's and a snapshot's,
/// in every view, is one of these, so the two answer alike.
///
/// Forwarded on read: only what carriers emitted is kept, however many shapes the stand-ins at its
/// ends stand for, and every view is read from it as it's asked (`EdgeView`). An edge into a stand-in
/// is read as one copy into each shape it stands for (a read at the far end finds them all, a read at
/// one of those shapes finds its own through `standIns`), and a stand-in's edges to what it stands for
/// are read from `forwards`. So what a stand-in stands for costs what came and went to change, never
/// those shapes times the edges at it, and a read costs what it returns; a file with no stand-ins holds
/// what it did before there were any, and costs what it did.
struct EdgeTables: Sendable {
    /// What each carrier emitted last, in order: a commit says which shapes changed, not what they
    /// carried before.
    private(set) var byCarrier: [ShapeID: [Edge]] = [:]
    /// Each shape's edges as emitted, either way, by carrier, in the order their carriers came: an
    /// edge is filed under its source and its target.
    private var byNode: [ShapeID: EdgeGroup] = [:]
    /// Each type's edges as emitted, by carrier.
    private var byType: [EdgeTypeID: EdgeGroup] = [:]
    /// The stand-ins on a board the editor can show, whatever they stand for now: their own edges are
    /// never forwarded.
    private(set) var standInCarriers: Set<ShapeID> = []
    /// What each stand-in stands for now, in order, for those that stand for something.
    private(set) var forwards: [ShapeID: [ShapeID]] = [:]
    /// The stand-ins that stand for each shape, in the order they came to.
    private(set) var standIns: [ShapeID: [ShapeID]] = [:]
    /// Whether each stand-in in `forwards` stands for what its record names, or what was provided, and
    /// how many stand for what their record names (what the recorded view reads standing edges by).
    private(set) var forwardKind: [ShapeID: ForwardKind] = [:]
    private var recordForwards = 0
    /// The stand-ins in `forwards`, in the order they came to stand for something: the order their
    /// standing edges are read in, among a type's.
    private var standingOrder = ArrivalOrder()
    /// The kind of each shape a stand-in stands for, and how many of each kind each stand-in stands
    /// for: what reads the kinds a stand-in stands for (its ports) reads a few kinds, not its shapes.
    private(set) var forwardedKinds: [ShapeID: ShapeKind] = [:]
    private var kindCounts: [ShapeID: [ShapeKind: Int]] = [:]
    /// The part of its shape each stand-in that stands for one reaches (`Forwarding.row`: a pill for an endpoint), whatever it
    /// stands for now: an edge forwarded through it reaches that part, unless the edge names one there itself.
    private(set) var forwardParts: [ShapeID: PartID] = [:]

    // MARK: Reading them

    /// Every edge touching `id`, as `direction` asks, of the types `filter` admits in the tree
    /// `types`, as `view` reads them: those filed under it, by carrier in the order the carriers came,
    /// each carrier's in the order it emits them (an edge into a stand-in as its copies, source by
    /// source); then, for a stand-in, its own edges to what it stands for; then, through each stand-in
    /// that stands for it, in the order they came to, the copies of the edges at that stand-in that end
    /// here, and its edge to it. An edge from `id` to `id` is there once.
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
        _ = visit(id, direction, filter, types, view) { body($0); return true }
    }

    /// Whether `id` has an edge `edges(of:_:types:in:view:)` would find that `predicate` takes: it
    /// stops at the first, and makes nothing.
    func hasEdges(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                  view: EdgeView = .resolved, where predicate: (Edge) -> Bool) -> Bool {
        !visit(id, direction, filter, types, view) { !predicate($0) }
    }

    /// The shapes at the other end of `id`'s edges, by each edge's type, each once per type, in the
    /// order its first edge comes.
    func neighbors(of id: ShapeID, _ direction: EdgeDirection, types filter: EdgeTypeFilter, in types: EdgeTypeTree,
                   view: EdgeView = .resolved) -> [EdgeTypeID: [ShapeID]] {
        var found: [EdgeTypeID: [ShapeID]] = [:], seen: Set<Neighbor> = []
        forEachEdge(of: id, direction, types: filter, in: types, view: view) { edge in
            let other = edge.otherEnd(from: id, direction)
            if seen.insert(Neighbor(type: edge.type, id: other)).inserted { found[edge.type, default: []].append(other) }
        }
        return found
    }

    /// Every edge of the types `filter` admits, as `view` reads them: type by type (declared ones in
    /// plugin order, then the rest by name), each type's by carrier, in the order they came, each
    /// emitted edge as its copies; standing edges by stand-in, in the order they came to stand for
    /// something.
    func edges(ofType filter: EdgeTypeFilter, in types: EdgeTypeTree, view: EdgeView = .resolved) -> [Edge] {
        var found: [Edge] = []
        var present = Array(byType.keys)
        if hasStanding(view) { present.append(StandingEdge.id) }
        for type in present.filter({ filter.admits($0, in: types) }).sorted(by: types.precedes) {
            if type == StandingEdge.id {
                standingOrder.forEach { standIn in
                    for target in forwarded(standIn, view) ?? [] { found.append(Self.standing(standIn, target)) }
                }
                continue
            }
            byType[type]?.forEach { edge in forEachCopy(of: edge, view) { found.append($0) } }
        }
        return found
    }

    /// What `carrier` carries, as `view` reads it, in the order it emits them: a stand-in's own edges
    /// as emitted, then its edges to what it stands for; any other's each as its copies.
    func edges(carriedBy carrier: ShapeID, view: EdgeView = .resolved) -> [Edge] {
        let emitted = byCarrier[carrier] ?? []
        guard !forwards.isEmpty, view != .literal else { return emitted }
        if standInCarriers.contains(carrier) {
            guard let targets = forwarded(carrier, view) else { return emitted }
            return emitted + targets.map { Self.standing(carrier, $0) }
        }
        var found: [Edge] = []
        for edge in emitted { forEachCopy(of: edge, view) { found.append($0) } }
        return found
    }

    /// The resolved edges forwarded through `standIn` (whose `origin` names it at an end): one for
    /// each shape it stands for, for each edge another shape carries into it or out of it.
    func edges(through standIn: ShapeID) -> [Edge] {
        guard forwards[standIn] != nil, let group = byNode[standIn] else { return [] }
        var found: [Edge] = []
        group.forEach { edge in
            guard !standInCarriers.contains(edge.carrier) else { return }
            forEachCopy(of: edge, .resolved) { found.append($0) }
        }
        return found
    }

    /// The types of the edges there are, declared or not, as `view` reads them. O(types).
    func presentTypes(view: EdgeView = .resolved) -> Set<EdgeTypeID> {
        let present = Set(byType.keys)
        return hasStanding(view) ? present.union([StandingEdge.id]) : present
    }

    /// What `standIn` stands for now, in order: none for a shape that stands for nothing.
    func forwards(of standIn: ShapeID) -> [ShapeID] { forwards[standIn] ?? [] }

    /// The stand-ins that stand for `target` now, in the order they came to.
    func standIns(for target: ShapeID) -> [ShapeID] { standIns[target] ?? [] }

    /// The kinds of what `standIn` stands for now, each once: the first shape's kind first, then the
    /// rest by name. O(those kinds).
    func standingKinds(of standIn: ShapeID) -> [ShapeKind] {
        guard let counts = kindCounts[standIn], let first = forwards[standIn]?.first.flatMap({ forwardedKinds[$0] }) else { return [] }
        return [first] + counts.keys.filter { $0 != first }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Calls `body` with each edge filed under `id` as emitted, by carrier in the order the carriers
    /// came: what's at a stand-in, for the index to say whose edges a change to what it stands for
    /// changes.
    func forEachEmitted(at id: ShapeID, _ body: (Edge) -> Void) { byNode[id]?.forEach(body) }

    // MARK: Reading through the stand-ins

    /// What `id` forwards to in `view`: nil where it forwards nothing (it stands for nothing now; it
    /// stands for what's provided, in the recorded view; any, in the literal view).
    @inline(__always)
    func forwarded(_ id: ShapeID, _ view: EdgeView) -> [ShapeID]? {
        switch view {
        case .literal: return nil
        case .resolved: return forwards.isEmpty ? nil : forwards[id]
        case .recorded:
            guard !forwards.isEmpty, let targets = forwards[id], forwardKind[id] == .record else { return nil }
            return targets
        }
    }

    /// Whether `view` reads standing edges: some stand-in stands for something there.
    private func hasStanding(_ view: EdgeView) -> Bool {
        switch view {
        case .literal: false
        case .resolved: !forwards.isEmpty
        case .recorded: recordForwards > 0
        }
    }

    /// Calls `body` with each copy of an emitted `edge` as `view` reads it: itself when neither end
    /// forwards there, or its carrier is a stand-in (whose own edges are never forwarded); else one
    /// for each pair of what its ends stand for (an end that forwards nothing as itself), source by
    /// source.
    @inline(__always)
    func forEachCopy(of edge: Edge, _ view: EdgeView, _ body: (Edge) -> Void) {
        let sources = forwarded(edge.source, view), targets = forwarded(edge.target, view)
        guard sources != nil || targets != nil, !standInCarriers.contains(edge.carrier) else { return body(edge) }
        let origin = EdgeOrigin.forwarded(source: sources == nil ? nil : edge.source, target: targets == nil ? nil : edge.target)
        if let sources {
            for source in sources {
                if let targets {
                    for target in targets { body(copy(edge, source, target, origin)) }
                } else {
                    body(copy(edge, source, edge.target, origin))
                }
            }
        } else if let targets {
            for target in targets { body(copy(edge, edge.source, target, origin)) }
        }
    }

    /// Calls `body` with each edge of `id`'s the reads above give, in their order, while it returns
    /// true: false once it returned false.
    private func visit(_ id: ShapeID, _ direction: EdgeDirection, _ filter: EdgeTypeFilter, _ types: EdgeTypeTree, _ view: EdgeView,
                       _ body: (Edge) -> Bool) -> Bool {
        let forwarding = view != .literal && !forwards.isEmpty
        // A stand-in that forwards is an end of none of the copies of the edges others carry at it.
        let forwardsAway = forwarding && forwarded(id, view) != nil
        var going = true
        if let group = byNode[id] {
            group.forEachWhile { edge in
                guard filter.isAll || filter.admits(edge.type, in: types) else { return true }
                guard forwarding else {
                    if edge.touches(id, direction) { going = body(edge) }
                    return going
                }
                if forwardsAway, !standInCarriers.contains(edge.carrier) { return true }
                forEachCopy(of: edge, view) { copy in
                    if going, copy.touches(id, direction) { going = body(copy) }
                }
                return going
            }
        }
        guard going, forwarding else { return going }
        let standing = filter.isAll || filter.admits(StandingEdge.id, in: types)
        if standing, direction != .incoming, let targets = forwarded(id, view) {
            for target in targets where !body(Self.standing(id, target)) { return false }
        }
        guard let through = standIns[id] else { return true }
        for (index, standIn) in through.enumerated() where forwarded(standIn, view) != nil {
            byNode[standIn]?.forEachWhile { edge in
                // One filed under `id` too was read there, and one between two stand-ins for it is read
                // through the first of them.
                guard edge.source != id, edge.target != id, !standInCarriers.contains(edge.carrier),
                      filter.isAll || filter.admits(edge.type, in: types) else { return true }
                let other = edge.source == standIn ? edge.target : edge.source
                if other != standIn, through[..<index].contains(other), forwarded(other, view) != nil { return true }
                forEachCopy(of: edge, ending: id, through: standIn, among: through, view, direction) { copy in
                    if going { going = body(copy) }
                }
                return going
            }
            guard going else { return false }
            if standing, direction != .outgoing, !body(Self.standing(standIn, id)) { return false }
        }
        return true
    }

    /// Calls `body` with the copies of an emitted `edge` at `standIn`, which stands for `id`, that
    /// touch `id` as `direction` asks, in the order `forEachCopy` gives them, making only those: an
    /// end that's `standIn`, or another stand-in among `through` (those that stand for `id`), reads as
    /// `id` there.
    private func forEachCopy(of edge: Edge, ending id: ShapeID, through standIn: ShapeID, among through: [ShapeID], _ view: EdgeView,
                             _ direction: EdgeDirection, _ body: (Edge) -> Void) {
        let sources = forwarded(edge.source, view), targets = forwarded(edge.target, view)
        let origin = EdgeOrigin.forwarded(source: sources == nil ? nil : edge.source, target: targets == nil ? nil : edge.target)
        func standsForID(_ end: ShapeID, _ forwards: [ShapeID]?) -> Bool { end == standIn || (forwards != nil && through.contains(end)) }
        let fromID = standsForID(edge.source, sources), toID = standsForID(edge.target, targets)
        if fromID, toID {
            // Both ends read as `id`: source by source, as the copies come.
            for source in sources ?? [edge.source] {
                if source == id {
                    if direction == .incoming {
                        body(copy(edge, id, id, origin))
                    } else {
                        for target in targets ?? [edge.target] { body(copy(edge, id, target, origin)) }
                    }
                } else if direction != .outgoing {
                    body(copy(edge, source, id, origin))
                }
            }
        } else if fromID {
            guard direction != .incoming else { return }
            if let targets {
                for target in targets { body(copy(edge, id, target, origin)) }
            } else {
                body(copy(edge, id, edge.target, origin))
            }
        } else if toID {
            guard direction != .outgoing else { return }
            if let sources {
                for source in sources { body(copy(edge, source, id, origin)) }
            } else {
                body(copy(edge, edge.source, id, origin))
            }
        }
    }

    /// A copy of `edge` with these ends, forwarded as `origin` says: an end forwarded through a stand-in that stands for a part
    /// of its shape (`Forwarding.row`) reaches that part, unless the edge names one there itself (a binding's part, the column
    /// of a table a pill stands for, wins).
    @inline(__always)
    private func copy(_ edge: Edge, _ source: ShapeID, _ target: ShapeID, _ origin: EdgeOrigin) -> Edge {
        guard !forwardParts.isEmpty, case .forwarded(let from, let to) = origin else { return edge.copy(source, target, origin) }
        let parts = EdgeParts(source: edge.parts.source ?? from.flatMap { forwardParts[$0] },
                              target: edge.parts.target ?? to.flatMap { forwardParts[$0] })
        return Edge(type: edge.type, source: source, target: target, carrier: edge.carrier, slot: edge.slot, count: edge.count, origin: origin,
                    parts: parts)
    }

    /// A stand-in's edge to a shape it stands for.
    static func standing(_ standIn: ShapeID, _ target: ShapeID) -> Edge {
        Edge(type: StandingEdge.id, source: standIn, target: target, carrier: standIn, slot: StandingEdge.slot, origin: .standing)
    }

    // MARK: Changing them

    /// Makes `emitted` what `carrier` emitted, keeping each end's and each type's in step. Returns the
    /// edges that came or went, or every one of the carrier's when only their order changed; none
    /// when nothing did.
    mutating func set(_ carrier: ShapeID, emitted edges: [Edge]) -> [Edge] {
        let old = byCarrier[carrier] ?? []
        guard old != edges else { return [] }
        byCarrier[carrier] = edges.isEmpty ? nil : edges

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

    /// Says which part of its shape a stand-in reaches (nil: the shape as a whole); whether that changed.
    mutating func setForwardPart(_ standIn: ShapeID, _ part: PartID?) -> Bool {
        guard forwardParts[standIn] != part else { return false }
        forwardParts[standIn] = part
        return true
    }

    /// Says whether `id` is a stand-in (of a stand-in kind, on a board the editor can show), whose own
    /// edges are never forwarded.
    mutating func setStandIn(_ id: ShapeID, _ isStandIn: Bool) {
        if isStandIn { standInCarriers.insert(id) } else { standInCarriers.remove(id) }
    }

    /// Makes `targets` what `standIn` stands for (none: nothing), as `kind` has it, by `change`, what
    /// came (each with its kind) and went since what it stood for (`ForwardsChange.between`): who stands
    /// for each shape, and the kinds each stands for, are kept in step with it alone.
    mutating func setForwards(_ standIn: ShapeID, _ targets: [ShapeID], kind: ForwardKind, change: ForwardsChange) {
        let newKind: ForwardKind? = targets.isEmpty ? nil : kind
        if change.moved {
            if targets.isEmpty {
                forwards.removeValue(forKey: standIn)
                standingOrder.remove(standIn)
            } else {
                if forwards[standIn] == nil { standingOrder.insert(standIn) }
                forwards[standIn] = targets
            }
            for target in change.went { stopStanding(standIn, for: target) }
            for (target, kind) in change.came { startStanding(standIn, for: target, kind) }
        }
        setForwardKind(standIn, newKind)
    }

    /// Keeps `forwardKind`, and how many of it are `.record`, in step.
    private mutating func setForwardKind(_ standIn: ShapeID, _ kind: ForwardKind?) {
        let old = forwardKind[standIn]
        guard old != kind else { return }
        if old == .record { recordForwards -= 1 }
        if kind == .record { recordForwards += 1 }
        forwardKind[standIn] = kind
    }

    /// Puts `target` into what `standIn` stands for at `index`, of `kind`: one shape come, as a commit
    /// to it has it come.
    mutating func insertForward(_ standIn: ShapeID, _ target: ShapeID, at index: Int, _ kind: ShapeKind, as forwardKind: ForwardKind) {
        if forwards[standIn] == nil { standingOrder.insert(standIn) }
        forwards[standIn, default: []].insert(target, at: index)
        setForwardKind(standIn, forwardKind)
        startStanding(standIn, for: target, kind)
    }

    /// Takes `target` out of what `standIn` stands for: one shape gone, as a commit to it has it go.
    mutating func removeForward(_ standIn: ShapeID, _ target: ShapeID) {
        guard let index = forwards.index(forKey: standIn), let at = forwards.values[index].firstIndex(of: target) else { return }
        forwards.values[index].remove(at: at)
        if forwards.values[index].isEmpty {
            forwards.remove(at: index)
            setForwardKind(standIn, nil)
            standingOrder.remove(standIn)
        }
        stopStanding(standIn, for: target)
    }

    /// A shape stood for whose kind changed (it was turned into another): each stand-in's count of
    /// kinds follows. The stand-ins whose kinds changed: what reads a stand-in's kinds (its ports) is
    /// to hear of it, though no edge changed.
    mutating func setKind(_ kind: ShapeKind, of target: ShapeID) -> [ShapeID] {
        guard let old = forwardedKinds[target], old != kind else { return [] }
        forwardedKinds[target] = kind
        let standing = standIns[target] ?? []
        for standIn in standing {
            count(old, of: standIn, by: -1)
            count(kind, of: standIn, by: 1)
        }
        return standing
    }

    private mutating func startStanding(_ standIn: ShapeID, for target: ShapeID, _ kind: ShapeKind) {
        standIns[target, default: []].append(standIn)
        if forwardedKinds[target] == nil { forwardedKinds[target] = kind }
        count(forwardedKinds[target] ?? kind, of: standIn, by: 1)
    }

    private mutating func stopStanding(_ standIn: ShapeID, for target: ShapeID) {
        if let index = standIns.index(forKey: target) {
            standIns.values[index].removeAll { $0 == standIn }
            if standIns.values[index].isEmpty { standIns.remove(at: index) }
        }
        guard let kind = forwardedKinds[target] else { return }
        count(kind, of: standIn, by: -1)
        if standIns[target] == nil { forwardedKinds.removeValue(forKey: target) }
    }

    private mutating func count(_ kind: ShapeKind, of standIn: ShapeID, by delta: Int) {
        let now = (kindCounts[standIn]?[kind] ?? 0) + delta
        if now > 0 {
            kindCounts[standIn, default: [:]][kind] = now
        } else if let index = kindCounts.index(forKey: standIn) {
            kindCounts.values[index].removeValue(forKey: kind)
            if kindCounts.values[index].isEmpty { kindCounts.remove(at: index) }
        }
    }

    /// Each end's edges among `edges`, in order: an edge under each of its ends, once.
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

/// What changed of what a stand-in stands for: the shapes that came (each with its kind) and went,
/// and whether what it stands for changed at all (`moved`: those, or only their order).
struct ForwardsChange: Sendable {
    var came: [(id: ShapeID, kind: ShapeKind)] = []
    var went: [ShapeID] = []
    var moved = false

    static let none = ForwardsChange()

    /// From `old` to `new` (each once), whose kinds are `kinds`, in step with it. O(both).
    static func between(_ old: [ShapeID], _ new: [ShapeID], kinds: [ShapeKind]) -> ForwardsChange {
        guard old != new else { return .none }
        var change = ForwardsChange(moved: true)
        let before = Set(old), now = Set(new)
        for (index, target) in new.enumerated() where !before.contains(target) { change.came.append((target, kinds[index])) }
        for target in old where !now.contains(target) { change.went.append(target) }
        return change
    }
}

extension Edge {
    /// Calls `body` with each shape the edge is filed under: its source, and its target where it's
    /// another, as emitted.
    @inline(__always)
    func forEachNode(_ body: (ShapeID) -> Void) {
        body(source)
        if target != source { body(target) }
    }

    /// The edge with these ends, forwarded as `origin` says: one of its copies.
    @inline(__always)
    func copy(_ source: ShapeID, _ target: ShapeID, _ origin: EdgeOrigin) -> Edge {
        Edge(type: type, source: source, target: target, carrier: carrier, slot: slot, count: count, origin: origin, parts: parts)
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

    func forEach(_ body: (Edge) -> Void) {
        forEachWhile { body($0); return true }
    }

    /// Calls `body` with each edge in order while it returns true.
    func forEachWhile(_ body: (Edge) -> Bool) {
        for (index, carrier) in order.enumerated() {
            guard let entry = entries[carrier], entry.position == index else { continue }
            for edge in entry.edges where !body(edge) { return }
        }
    }
}

/// Shapes in the order they came, each once: one that comes back comes last. Adding or removing one
/// costs O(1): a removed one leaves a gap, and the gaps go once they're half the order.
struct ArrivalOrder: Sendable {
    private var order: [ShapeID] = []
    /// Where each held one is in `order`: one in `order` at another position is a gap.
    private var positions: [ShapeID: Int] = [:]

    mutating func insert(_ id: ShapeID) {
        guard positions[id] == nil else { return }
        positions[id] = order.count
        order.append(id)
    }

    mutating func remove(_ id: ShapeID) {
        guard positions.removeValue(forKey: id) != nil else { return }
        if positions.isEmpty {
            order = []
        } else if order.count > 16, positions.count * 2 < order.count {
            order = order.enumerated().filter { positions[$0.element] == $0.offset }.map(\.element)
            for (index, id) in order.enumerated() { positions[id] = index }
        }
    }

    func forEach(_ body: (ShapeID) -> Void) {
        for (index, id) in order.enumerated() where positions[id] == index { body(id) }
    }
}
