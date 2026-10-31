import Canvas

/// What the table of contents lists of a board: the rows, nested, as `entries` hands them to the
/// list, and where each one is. Kept from one read to the next and brought up to date by
/// placing again only the rows of the shapes that changed, with the rows named under a shape that
/// came or went, so a commit costs what it changed rather than what's on the board. What each update
/// changed is noted for the list that shows it (`changes`), which follows it row by row.
@MainActor
struct ContentsListing {
    /// Which listing this is: each one listed from scratch is a new one, which a list shows whole.
    let serial: Int
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
    /// What the updates since the list showing it last took them changed (`takeChanges(by:)`), noted
    /// only once a list follows it (headless, or with no list shown, nothing is).
    private(set) var changes = ContentsListingChanges()
    /// How many updates have changed it: a list that shows it reads again when this does.
    private(set) var version = 0
    /// The list that took its changes last: another that takes them can't follow from there, and
    /// shows it whole.
    private var taker: ObjectIdentifier?
    /// How many listings have been made, for each one's `serial`.
    private static var made = 0
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

    /// Lists the rows of `shapes` (back to front) whose kinds list them.
    init(shapes: [ShapeID], row: (ShapeID) -> ShapeRow?) {
        Self.made += 1
        serial = Self.made
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

    /// Whether the shape has a row here.
    func lists(_ id: ShapeID) -> Bool { nodes[id] != nil }

    /// The shape whose row the shape's row is nested under here; nil at the top, or not listed.
    func parent(of id: ShapeID) -> ShapeID? { nodes[id]?.parent }

    /// The shape's row as listed; nil for a shape not listed.
    func row(of id: ShapeID) -> ShapeRow? { nodes[id]?.row }

    /// The shape's row as listed, with the rows nested under it; nil for a shape not listed. O(its
    /// depth) searches of the rows at each level.
    func entry(of id: ShapeID) -> ContentsEntry? {
        guard nodes[id] != nil else { return nil }
        let keys = path(to: id)
        let level = Self.rows(entries, under: keys.dropLast())
        return level[level.slot(for: keys[keys.count - 1])]
    }

    /// The rows nested under the shape's row (nil: the top-level rows), back to front; none for a
    /// shape not listed.
    func children(of parent: ShapeID?) -> [ContentsEntry] {
        guard let parent else { return entries }
        guard nodes[parent] != nil else { return [] }
        return Self.rows(entries, under: path(to: parent)[...])
    }

    /// What the updates since `taker` last took them changed, for it to follow, and nothing kept for
    /// the next; nil when another list took them since (or none ever did), which shows it whole.
    mutating func takeChanges(by taker: ObjectIdentifier) -> ContentsListingChanges? {
        defer {
            changes = ContentsListingChanges()
            self.taker = taker
        }
        return self.taker == taker ? changes : nil
    }

    // MARK: Keeping up

    /// Brings it up to date with the shapes changed since (`pending`): their rows are made again,
    /// and a row whose place changed (it came, went, moved in the stack, or nests elsewhere) is
    /// placed again with the rows under it. False when listing every row again is the better way:
    /// the caller does that instead.
    mutating func update(row: (ShapeID) -> ShapeRow?) -> Bool {
        guard !pending.isEmpty else { return true }
        let changed = pending
        pending = []
        guard let plan = plan(for: changed, row: row) else { return false }
        if !plan.detaching.isEmpty || !plan.attaching.isEmpty || !plan.replacing.isEmpty { version += 1 }
        let noting = taker != nil
        var moving: [ShapeID: ContentsEntry] = [:]
        for id in plan.detaching {
            let keys = path(to: id)
            Self.modify(&entries, under: keys.dropLast()) { rows in
                moving[id] = rows.remove(at: rows.slot(for: keys[keys.count - 1]))
            }
            let node = nodes.removeValue(forKey: id)!
            forget(id, namedUnder: node.row.parent)
            if noting {
                changes.moved.insert(id)
                if let parent = node.parent { changes.parents.insert(parent) }
            }
        }
        for (made, parent) in plan.attaching {
            var entry = moving.removeValue(forKey: made.id) ?? ContentsEntry(row: made, children: nil)
            entry.row = made
            nodes[made.id] = Node(row: made, parent: parent)
            if let named = made.parent { namers[named, default: []].insert(made.id) }
            let keys = parent.map { path(to: $0) } ?? []
            Self.modify(&entries, under: keys[...]) { rows in rows.insert(entry, at: rows.slot(for: made.key)) }
            if noting {
                changes.moved.insert(made.id)
                if let parent { changes.parents.insert(parent) }
            }
        }
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
            if noting { changes.replaced.insert(id) }
        }
        return true
    }

    /// Where the changed shapes' rows, and the rows named under a shape that joined the list or
    /// left it, go now. Nil when listing every row again is the better way.
    private func plan(for changed: Set<ShapeID>, row: (ShapeID) -> ShapeRow?) -> Plan? {
        // The changed shapes listed now, with their rows.
        var fresh: [ShapeID: ShapeRow] = [:]
        for id in changed {
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

/// What a listing's updates changed, for the list that shows it to follow (`ContentsListing.takeChanges`):
/// the rows that came, went or moved (each read again where it is now), the rows whose nested rows
/// changed, and the rows made again where they are. Gathered over updates until the list takes them.
struct ContentsListingChanges {
    var moved: Set<ShapeID> = []
    var parents: Set<ShapeID> = []
    var replaced: Set<ShapeID> = []

    var isEmpty: Bool { moved.isEmpty && parents.isEmpty && replaced.isEmpty }
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
