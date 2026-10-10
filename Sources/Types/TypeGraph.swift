import Canvas

/// What the file's types lead to, as a value: each shape's types in the order of its list (`is`)
/// and the types' names. A `Sendable` copy on write that `TypeIndex` keeps by each commit's
/// `ChangeSet`, so a query takes it up in O(1) and answers off the main actor (`:is-a`,
/// `[is~="Person"]`), and so the chain that settling reads and the one the query follows are the one
/// function, `lineage(of:)`.
public struct TypeGraph: Sendable {
    /// Each shape's types, in the order of its list: only the shapes that are some.
    public internal(set) var links: [ShapeID: [TypeLink]] = [:]
    /// The title of each type (an untitled one has none).
    public internal(set) var names: [ShapeID: String] = [:]

    public init() {}

    /// Every shape that leads anywhere: the only ones a shape can be related to by `:is-a`.
    public var sources: Set<ShapeID> { Set(links.keys) }

    /// The shapes a shape leads to one step up, in the order a chain reads them: its own types,
    /// later first (a later one wins). The one place the rule lives.
    public func parents(of shape: ShapeID) -> [ShapeID] {
        (links[shape] ?? []).reversed().map(\.shape)
    }

    /// The shapes a shape leads to, level by level, nearest first, each once and never the shape
    /// itself, so the chain of a shape that is its own ancestor stops where it comes back.
    public func lineage(of id: ShapeID) -> [ShapeID] {
        var seen: Set<ShapeID> = [id], chain: [ShapeID] = [], level = [id]
        while !level.isEmpty {
            var next: [ShapeID] = []
            for shape in level {
                for parent in parents(of: shape) where seen.insert(parent).inserted {
                    chain.append(parent)
                    next.append(parent)
                }
            }
            level = next
        }
        return chain
    }
}
