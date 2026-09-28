import Canvas

/// What the table of contents lists for one scope: the rows, nested, as `entries` hands them to
/// the list, and where each one is. Kept from one read to the next and brought up to date by
/// placing again only the rows of the shapes that changed, with the rows named under a shape that
/// came or went, so a commit costs what it changed rather than what's on the board.
@MainActor
struct ContentsListing {
    /// The shapes it may list; nil for every shape.
    let scope: Set<ShapeID>?
    /// The top-level rows, back to front, each with the rows nested under it. The rows at every
    /// level are in their shapes' stacking-key order, which is how a row is found again.
    private(set) var entries: [ContentsEntry] = []
    /// Each listed shape's row as listed, and the shape it's nested under (nil at the top).
    private var nodes: [ShapeID: Node] = [:]
    /// For each shape, listed or not, the listed shapes whose kinds name it to nest under: they
    /// move when it comes or goes.
    private var namers: [ShapeID: Set<ShapeID>] = [:]
    /// The shapes changed since it was last brought up to date.
    var pending: Set<ShapeID> = []
    /// Whether the last update brought rows in at more than one place: under two rows (or a row
    /// and the top level), or at two places among one row's rows. A row that comes in under one
    /// that comes in with it comes in with it. The list replaces its rows then, as for a new scope.
    private(set) var isScattered = false
    /// Whether a loop keeps a row at the top though the shape it names is listed. Which row of a
    /// loop stays at the top follows from the order of the whole loop, so while there's one, any
    /// row that comes, goes or moves lists every row again. (No shipped kind makes a loop.)
    private var hasLoop = false

    private struct Node {
        var row: ShapeRow
        var parent: ShapeID?
    }

    /// What bringing it up to date takes.
    private struct Plan {
        /// Rows made again that stay where they are.
        var replacing: [ShapeRow] = []
        /// Rows that leave their place, deepest first, so a row's nested rows that move are out
        /// of it before it moves.
        var detaching: [ShapeID] = []
        /// Rows placed (again), each under its parent (nil at the top), shallowest first, so a
        /// row's parent is in place before it.
        var attaching: [(row: ShapeRow, parent: ShapeID?)] = []
    }

    /// Past this many rows to take out and put back, listing every row again is quicker: each
    /// shifts the rows after it along, and listing again costs about as much as a few hundred of
    /// those, however many rows there are.
    private static let mostMoves = 256

    /// Lists the rows of `shapes` (back to front, each in `scope`) whose kinds list them.
    init(scope: Set<ShapeID>?, shapes: [ShapeID], row: (ShapeID) -> ShapeRow?) {
        self.scope = scope
        // By position in `order` from here on, which is quicker than by id.
        var order: [ShapeRow] = []
        var position: [ShapeID: Int] = [:]
        order.reserveCapacity(shapes.count)
        position.reserveCapacity(shapes.count)
        for id in shapes {
            guard let made = row(id), made.isListed else { continue }
            position[id] = order.count
            order.append(made)
        }
        // A row nests under the shape its kind names when that's listed too, unless that would
        // make a loop: then the later shape stays at the top.
        var parent = [Int](repeating: -1, count: order.count)
        for (i, made) in order.enumerated() {
            guard let named = made.parent, named != made.id, let candidate = position[named] else { continue }
            var ancestor = candidate
            while ancestor != -1, ancestor != i { ancestor = parent[ancestor] }
            if ancestor == -1 { parent[i] = candidate } else { hasLoop = true }
        }
        var children = [[Int]](repeating: [], count: order.count)
        for i in order.indices where parent[i] != -1 { children[parent[i]].append(i) }
        func entry(_ i: Int) -> ContentsEntry {
            ContentsEntry(row: order[i], children: children[i].isEmpty ? nil : children[i].map(entry))
        }
        entries = order.indices.filter { parent[$0] == -1 }.map(entry)
        nodes.reserveCapacity(order.count)
        for (i, made) in order.enumerated() {
            nodes[made.id] = Node(row: made, parent: parent[i] == -1 ? nil : order[parent[i]].id)
            if let named = made.parent { namers[named, default: []].insert(made.id) }
        }
    }

    // MARK: Keeping up

    /// Brings it up to date with the shapes changed since (`pending`): their rows are made again,
    /// and a row whose place changed (it came, went, moved in the stack, or nests elsewhere) is
    /// placed again with the rows under it. False when listing every row again is the better way:
    /// the caller does that instead.
    mutating func update(row: (ShapeID) -> ShapeRow?) -> Bool {
        isScattered = false
        guard !pending.isEmpty else { return true }
        let changed = pending
        pending = []
        guard let plan = plan(for: changed, row: row) else { return false }
        var moving: [ShapeID: ContentsEntry] = [:]
        for id in plan.detaching {
            let keys = path(to: id)
            Self.modify(&entries, under: keys.dropLast()) { rows in
                moving[id] = rows.remove(at: rows.slot(for: keys[keys.count - 1]))
            }
            let node = nodes.removeValue(forKey: id)!
            forget(id, namedUnder: node.row.parent)
        }
        for (made, parent) in plan.attaching {
            var entry = moving.removeValue(forKey: made.id) ?? ContentsEntry(row: made, children: nil)
            entry.row = made
            nodes[made.id] = Node(row: made, parent: parent)
            if let named = made.parent { namers[named, default: []].insert(made.id) }
            let keys = parent.map { path(to: $0) } ?? []
            Self.modify(&entries, under: keys[...]) { rows in rows.insert(entry, at: rows.slot(for: made.key)) }
        }
        // Where they came in, by the row they came in under (nil: the top level).
        let attached = Set(plan.attaching.map(\.row.id))
        var places: [ShapeID?: [Int]] = [:]
        for (made, parent) in plan.attaching where !(parent.map(attached.contains) ?? false) {
            let keys = parent.map { path(to: $0) } ?? []
            places[parent, default: []].append(Self.rows(entries, under: keys[...]).slot(for: made.key))
        }
        isScattered = places.count > 1 || places.values.contains { slots in slots.max()! - slots.min()! + 1 != slots.count }
        for made in plan.replacing {
            let id = made.id
            let old = nodes[id]!.row
            nodes[id]!.row = made
            if old.parent != made.parent {
                forget(id, namedUnder: old.parent)
                if let named = made.parent { namers[named, default: []].insert(id) }
            }
            let keys = path(to: id)
            Self.modify(&entries, under: keys.dropLast()) { rows in rows[rows.slot(for: made.key)].row = made }
        }
        return true
    }

    /// Where the changed shapes' rows, and the rows named under a shape that joined the list or
    /// left it, go now. Nil when listing every row again is the better way.
    private func plan(for changed: Set<ShapeID>, row: (ShapeID) -> ShapeRow?) -> Plan? {
        // The changed shapes listed now, with their rows.
        var fresh: [ShapeID: ShapeRow] = [:]
        for id in changed where scope?.contains(id) ?? true {
            if let made = row(id), made.isListed { fresh[id] = made }
        }
        func isListed(_ id: ShapeID) -> Bool { changed.contains(id) ? fresh[id] != nil : nodes[id] != nil }
        var affected: Set<ShapeID> = []
        for id in changed {
            let was = nodes[id] != nil, now = fresh[id] != nil
            if was || now { affected.insert(id) }
            if was != now { affected.formUnion(namers[id] ?? []) }
        }
        var plan = Plan()
        var parents: [ShapeID: ShapeID?] = [:]
        for id in affected {
            let old = nodes[id]
            guard let made = changed.contains(id) ? fresh[id] : old?.row else {
                plan.detaching.append(id)
                continue
            }
            let parent = made.parent.flatMap { $0 != id && isListed($0) ? $0 : nil }
            if let old, old.parent == parent, old.row.key == made.key {
                if old.row !== made { plan.replacing.append(made) }
                continue
            }
            if old != nil { plan.detaching.append(id) }
            plan.attaching.append((made, parent))
            parents[id] = parent
        }
        guard !plan.detaching.isEmpty || !plan.attaching.isEmpty else { return plan }
        guard !hasLoop, plan.detaching.count + plan.attaching.count <= Self.mostMoves else { return nil }

        func depth(_ id: ShapeID, parent: (ShapeID) -> ShapeID?) -> Int? {
            var depth = 0
            var next = parent(id)
            while let current = next {
                depth += 1
                if depth > nodes.count + parents.count { return nil }         // a loop
                next = parent(current)
            }
            return depth
        }
        let before = plan.detaching.map { ($0, depth($0) { nodes[$0]?.parent } ?? 0) }
        plan.detaching = before.sorted { $0.1 > $1.1 }.map(\.0)
        var after: [ShapeID: Int] = [:]
        for (made, _) in plan.attaching {
            guard let depth = depth(made.id, parent: { parents[$0] ?? nodes[$0]?.parent }) else { return nil }
            after[made.id] = depth
        }
        plan.attaching.sort { after[$0.row.id]! < after[$1.row.id]! }
        return plan
    }

    private mutating func forget(_ id: ShapeID, namedUnder named: ShapeID?) {
        guard let named else { return }
        namers[named]?.remove(id)
        if namers[named]?.isEmpty == true { namers[named] = nil }
    }

    /// The keys of the rows from the top level down to `id`'s, as listed.
    private func path(to id: ShapeID) -> [StackingKey] {
        var keys: [StackingKey] = []
        var next: ShapeID? = id
        while let current = next, let node = nodes[current] {
            keys.append(node.row.key)
            next = node.parent
        }
        return keys.reversed()
    }

    /// The rows nested under the row `path` leads to (keys from the top level down), or the
    /// top-level rows when it's empty.
    private static func rows(_ rows: [ContentsEntry], under path: ArraySlice<StackingKey>) -> [ContentsEntry] {
        guard let key = path.first else { return rows }
        return Self.rows(rows[rows.slot(for: key)].children ?? [], under: path.dropFirst())
    }

    /// Runs `body` on the rows nested under the row `path` leads to (keys from the top level
    /// down), or on the top-level rows when it's empty.
    private static func modify(_ rows: inout [ContentsEntry], under path: ArraySlice<StackingKey>, _ body: (inout [ContentsEntry]) -> Void) {
        guard let key = path.first else { return body(&rows) }
        let i = rows.slot(for: key)
        var children = rows[i].children ?? []
        rows[i].children = nil          // so changing them doesn't copy them
        modify(&children, under: path.dropFirst(), body)
        rows[i].children = children.isEmpty ? nil : children
    }
}

extension [ContentsEntry] {
    /// Where the row with this key is, or would go: rows are in key order.
    @MainActor
    fileprivate func slot(for key: StackingKey) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].row.key < key { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
