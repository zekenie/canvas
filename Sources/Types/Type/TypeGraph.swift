import Canvas

/// What the file's types lead to, as a value: each shape's types in the order of its list (`is`)
/// and the types' names. A `Sendable` copy on write that `TypeIndex` keeps by each commit's
/// `ChangeSet`, so a query takes it up in O(1) and answers off the main actor (`:is-a`,
/// `[is~="Person"]`). The chain rows are read in and the reach a query follows come from the one
/// list, `parents(of:)`.
public struct TypeGraph: Sendable {
    /// Each shape's types, in the order of its list: only the shapes that are some.
    public internal(set) var links: [ShapeID: [TypeLink]] = [:]
    /// The title of each type (an untitled one has none).
    public internal(set) var names: [ShapeID: String] = [:]
    /// Every shape that holds `schema`, titled or not (`names` leaves an untitled one out).
    public internal(set) var types: Set<ShapeID> = []
    /// Those of them that hold the mark too: the relationship types.
    public internal(set) var relationshipTypes: Set<ShapeID> = []

    public init() {}

    /// Every shape that leads anywhere: the only ones a shape can be related to by `:is-a`.
    public var sources: Set<ShapeID> { Set(links.keys) }

    /// The shapes a shape leads to one step up, in the order a chain reads them: its own types,
    /// later first (a later one wins). The one place the rule lives.
    public func parents(of shape: ShapeID) -> [ShapeID] {
        (links[shape] ?? []).reversed().map(\.shape)
    }

    /// The shapes a shape leads to in the one order they are read in (`TypeOrder.linearized`): a type
    /// before every type it builds on, each once and never the shape itself, so the chain of a shape
    /// that is its own ancestor stops where it comes back. A name that is gone is in it, ending its
    /// branch.
    public func lineage(of id: ShapeID) -> [ShapeID] {
        TypeOrder.linearized(parents(of: id), excluding: id, parents: parents(of:))
    }

    /// Everything `shape`'s lists lead to, however far, never the shape itself; no order, cycle-safe. A
    /// name that is gone is in it, ending its branch. What `reaches(_:from:)` asks of one type, as a set.
    public func ancestors(of shape: ShapeID) -> Set<ShapeID> {
        var seen: Set<ShapeID> = [shape], level = [shape]
        while !level.isEmpty {
            var next: [ShapeID] = []
            for current in level {
                for parent in parents(of: current) where seen.insert(parent).inserted { next.append(parent) }
            }
            level = next
        }
        seen.remove(shape)
        return seen
    }

    /// What `heads` are, as a chain reads them: each head, and what each that is a type builds on however far,
    /// through types alone (a shape that is no type now ends its branch). What a shape is already (its own list
    /// as `heads`), for the lists that offer it types and its Types tab; cycle-safe.
    public func chained(_ heads: [ShapeID]) -> Set<ShapeID> {
        var seen = Set(heads), level = heads
        while !level.isEmpty {
            var next: [ShapeID] = []
            for shape in level where types.contains(shape) {
                for parent in parents(of: shape) where seen.insert(parent).inserted { next.append(parent) }
            }
            level = next
        }
        return seen
    }

    /// Whether `owner` is in what `target` leads to, however far; no order, cycle-safe. What `lineage`
    /// would answer to `contains`, without making the order.
    public func reaches(_ owner: ShapeID, from target: ShapeID) -> Bool {
        var seen: Set<ShapeID> = [target], level = [target]
        while !level.isEmpty {
            var next: [ShapeID] = []
            for shape in level {
                for parent in parents(of: shape) where seen.insert(parent).inserted {
                    if parent == owner { return true }
                    next.append(parent)
                }
            }
            level = next
        }
        return false
    }
}

/// The order shapes are read in when each lists the shapes it builds on: a type before every type it
/// builds on, so a general type never beats a more specific one that is built on it.
public enum TypeOrder {
    /// A shape's own list as a chain reads it: each type once, the first (as the index and `canvas draw` read a
    /// list that names one twice), latest first. What `linearized` is handed for a list.
    public static func heads(of list: [ShapeID]) -> [ShapeID] {
        var seen: Set<ShapeID> = []
        return Array(list.filter { seen.insert($0).inserted }.reversed())
    }

    /// The shapes `heads` lead to in one order: a shape before every shape it builds on, and where that
    /// leaves a choice, the one a list names first (a list is read latest first). Each once. `heads` is
    /// an instance's own list already reversed (latest first); `parents(x)` is `x`'s own list likewise.
    /// `excluding` is a shape that is never listed (the shape asked about, so a cycle through it ends
    /// there). A name `parents` knows nothing of is listed, with no parents.
    ///
    /// It is C3 (Python's method resolution order) where C3 has an order, else a fallback that keeps
    /// the one rule and never fails: a depth-first walk breaks the ties.
    public static func linearized(_ heads: [ShapeID], excluding: ShapeID? = nil,
                                  parents: (ShapeID) -> [ShapeID]) -> [ShapeID] {
        c3(heads, excluding: excluding, parents: parents) ?? fallback(heads, excluding: excluding, parents: parents)
    }

    /// C3 alone: `L(x) = [x] + merge(L(p1), …, L(pn), [p1…pn])`, and for the heads the same with no head
    /// of its own. Nil where it has no order: a conflict between two lists, a cycle, or `excluding`
    /// reached.
    public static func c3(_ heads: [ShapeID], excluding: ShapeID? = nil,
                          parents: (ShapeID) -> [ShapeID]) -> [ShapeID]? {
        var memo: [ShapeID: [ShapeID]] = [:], active: Set<ShapeID> = []
        func linear(_ shape: ShapeID) -> [ShapeID]? {
            if shape == excluding { return nil }
            if let done = memo[shape] { return done }
            guard active.insert(shape).inserted else { return nil }
            defer { active.remove(shape) }
            guard let rest = merged(unique(parents(shape))) else { return nil }
            memo[shape] = [shape] + rest
            return memo[shape]
        }
        func merged(_ own: [ShapeID]) -> [ShapeID]? {
            var lists: [[ShapeID]] = []
            for parent in own {
                guard let list = linear(parent) else { return nil }
                lists.append(list)
            }
            return merge(lists + [own])
        }
        return merged(unique(heads))
    }

    /// The first head that is in no other list's tail, taken out of every list, until none is left.
    private static func merge(_ lists: [[ShapeID]]) -> [ShapeID]? {
        var lists = lists.filter { !$0.isEmpty }, result: [ShapeID] = []
        while !lists.isEmpty {
            guard let head = lists.lazy.map(\.[0]).first(where: { head in !lists.contains { $0.dropFirst().contains(head) } }) else { return nil }
            result.append(head)
            lists = lists.map { $0.first == head ? Array($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        }
        return result
    }

    /// Where C3 has no order: walk depth first from `heads`, each shape's parents in order, and call a
    /// shape's place in the walk its rank; an edge back to a shape on the walk's current path is a
    /// cycle and is dropped. Then repeatedly list, of the shapes not yet listed that no unlisted shape
    /// builds on, the one of lowest rank. The edges left form no cycle, so there is always one.
    private static func fallback(_ heads: [ShapeID], excluding: ShapeID?, parents: (ShapeID) -> [ShapeID]) -> [ShapeID] {
        var walked: [ShapeID] = [], seen: Set<ShapeID> = [], path: Set<ShapeID> = []
        var edges: [ShapeID: [ShapeID]] = [:]
        func walk(_ shape: ShapeID) {
            seen.insert(shape)
            walked.append(shape)
            path.insert(shape)
            var kept: [ShapeID] = []
            for parent in unique(parents(shape)) where parent != excluding && !path.contains(parent) {
                kept.append(parent)
                if !seen.contains(parent) { walk(parent) }
            }
            edges[shape] = kept
            path.remove(shape)
        }
        for head in unique(heads) where head != excluding && !seen.contains(head) { walk(head) }
        var blockers: [ShapeID: Int] = [:]
        for parent in edges.values.joined() { blockers[parent, default: 0] += 1 }
        var listed: [ShapeID] = [], done: Set<ShapeID> = []
        while let next = walked.first(where: { !done.contains($0) && blockers[$0, default: 0] == 0 }) {
            listed.append(next)
            done.insert(next)
            for parent in edges[next] ?? [] { blockers[parent, default: 0] -= 1 }
        }
        return listed
    }

    private static func unique(_ shapes: [ShapeID]) -> [ShapeID] {
        var seen: Set<ShapeID> = []
        return shapes.filter { seen.insert($0).inserted }
    }
}
