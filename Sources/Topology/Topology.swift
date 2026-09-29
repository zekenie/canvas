import Canvas

/// Topology, as a plugin: what connects and contains what, whatever is where. Edges are a typed
/// graph (an arrow bound at both ends, a mention in text); containment is a tree (which board a
/// shape is on, and so which shape it's inside). Spatial relations (a note that happens to sit within
/// a rectangle's bounds) aren't part of it: they're geometry.
///
/// The shapes are the system of record: an arrow's record (its bound ends, its channel) is its edge,
/// a note's text is its mentions. Plugins say what a record carries (`EdgeSources`: a pure function
/// of one record), and `TopologyIndex` (`editor.topology`) keeps the file's edges, both ways and by
/// type, derived from the records and never saved: nothing goes in props, metadata or the file, so
/// nothing can disagree with the shapes. Types are a tree any plugin adds to (`EdgeTypes`).
extension PluginID {
    public static let topology: PluginID = "topology"
}

// MARK: Edge types

/// An edge type's id: what a query filters by (`EdgeTypeFilter`). Only its type writes it
/// (`static let id: EdgeTypeID = "mention"`); the build's id audit refuses another module that
/// writes it without depending on the type's. A channel's type has the channel's id (Ports).
public struct EdgeTypeID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A kind of edge, declared by the plugin that owns what it means (`registrar.edgeType(T.self)`),
/// under at most one parent: a tree, so a query for a family (`.within(parent)`) finds every kind of
/// it. An edge reports its most specific type.
///
///     public enum MentionEdge {}
///     extension MentionEdge: EdgeType {
///         public static let id: EdgeTypeID = "mention"
///         public static let summary: String? = "a mention in a shape's text, from that shape to the shape it names"
///     }
public protocol EdgeType {
    static var id: EdgeTypeID { get }
    /// The type it's a kind of; nil (the default) for a root.
    static var parent: EdgeTypeID? { get }
    /// What an edge of the type is, in one line for people and models (what `canvas
    /// query-vocabulary` lists): what it joins, and which way it runs, lowercase, no period. Nil (the
    /// default): nothing said.
    static var summary: String? { get }
}

extension EdgeType {
    public static var parent: EdgeTypeID? { nil }
    public static var summary: String? { nil }
}

// MARK: Edges

/// One edge: from `source` to `target`, of `type` (its most specific), carried by `carrier` (the
/// shape whose record holds it: the arrow; the note whose text mentions), in `slot` (where in the
/// carrier: "" for the carrier itself, as an arrow is; else the name of the property that holds it,
/// a kind's own or an added property's key), `count` times there (a note mentioning a shape twice in
/// its text: 2). Its identity is its carrier, slot, type, source and target; `count` is a value.
public struct Edge: Hashable, Sendable, Codable {
    public let type: EdgeTypeID
    public let source: ShapeID
    public let target: ShapeID
    public let carrier: ShapeID
    public let slot: String
    public let count: Int

    public init(type: EdgeTypeID, source: ShapeID, target: ShapeID, carrier: ShapeID, slot: String = "", count: Int = 1) {
        self.type = type
        self.source = source
        self.target = target
        self.carrier = carrier
        self.slot = slot
        self.count = count
    }

    /// The end that isn't `id`, as `direction` reads it: the target of an edge going out of `id`,
    /// the source of one coming in; `id` itself for an edge from `id` to `id`.
    func otherEnd(from id: ShapeID, _ direction: EdgeDirection) -> ShapeID {
        switch direction {
        case .outgoing: target
        case .incoming: source
        case .either: source == id ? target : source
        }
    }

    /// Whether it touches `id` as `direction` asks.
    func touches(_ id: ShapeID, _ direction: EdgeDirection) -> Bool {
        switch direction {
        case .outgoing: source == id
        case .incoming: target == id
        case .either: source == id || target == id
        }
    }
}

/// Which of a shape's edges: those that start at it, those that end at it, or both.
public enum EdgeDirection: Hashable, Sendable {
    case outgoing, incoming, either
}

/// Which types of edges a query wants: all of them; some types and every type under them
/// (`.within("arrow")`: plain arrows and every channel's); or exactly some types (`.only("arrow")`:
/// plain arrows alone). A type no plugin declares (a channel from a newer app, kept as written) has
/// no parent, so only `.all`, and `.within` or `.only` naming it, match it.
public struct EdgeTypeFilter: Hashable, Sendable {
    enum Match: Hashable, Sendable {
        case all
        case within(Set<EdgeTypeID>)
        case only(Set<EdgeTypeID>)
    }

    let match: Match

    public static let all = EdgeTypeFilter(match: .all)

    /// These types and every type under them.
    public static func within(_ types: EdgeTypeID...) -> EdgeTypeFilter { within(types) }

    /// These types and every type under them, from a list worked out elsewhere (a query's): none,
    /// for an empty one.
    public static func within(_ types: some Sequence<EdgeTypeID>) -> EdgeTypeFilter { EdgeTypeFilter(match: .within(Set(types))) }

    /// Exactly these types.
    public static func only(_ types: EdgeTypeID...) -> EdgeTypeFilter { only(types) }

    /// Exactly these types, from a list worked out elsewhere (a query's, each type and those under
    /// it already taken in): none, for an empty one.
    public static func only(_ types: some Sequence<EdgeTypeID>) -> EdgeTypeFilter { EdgeTypeFilter(match: .only(Set(types))) }

    /// Whether an edge of `type` passes, in the tree `types`. O(the type's depth).
    public func admits(_ type: EdgeTypeID, in types: EdgeTypeTree) -> Bool {
        switch match {
        case .all: true
        case .only(let wanted): wanted.contains(type)
        case .within(let wanted): wanted.contains(type) || types.ancestors(of: type).contains(where: wanted.contains)
        }
    }

    var isAll: Bool { match == .all }
}

/// How an end of an edge is now: a shape on a board the editor can show (which); a shape the file
/// keeps on a board the editor can't show (under an owner kept aside, say), which nothing follows;
/// or a shape in no board of the file (deleted, or never there: an edge may outlive its target, as a
/// mention does). Worked out when read (`TopologyIndex.end(_:)`).
public enum EdgeEnd: Hashable, Sendable, Codable {
    case live(BoardID)
    case missing
    case unavailable
}

// MARK: The plugin

/// A horizontal on the core alone: edge types and what records carry edges are its points
/// (`EdgeTypes`, `EdgeSources`), and its service keeps the file's edges (`editor.topology`). Every
/// plugin list with a plugin that contributes to them (Ports, Mentions) needs it. Put it early (in
/// the shipped list, right after Selection), so its service hears each commit before those that
/// read it; one that hears a commit first brings it up to date (`catchUp`).
public struct TopologyPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .topology }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { TopologyIndex(editor: $0) }
    }
}
