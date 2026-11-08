import Canvas

/// Topology, as a plugin: what connects and contains what, whatever is where. Edges are a typed
/// graph (an arrow bound at both ends, a mention in text); containment is a tree (the container a
/// shape is in on its board, a frame, else the owner of the board it's on, and so on up). Spatial
/// relations (a note that happens to sit within a rectangle's bounds) aren't part of it: they're
/// geometry.
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
/// writes it without depending on the type's. A channel's type has the channel's id (Connections).
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
/// its text: 2), and how it came to be (`origin`): as its carrier emitted it, forwarded through a
/// stand-in at either end (`EdgeForwarding`), or a stand-in's own edge to a shape it stands for. Its
/// identity is its carrier, slot, type, source, target, origin and the parts of its ends (`parts`: an
/// arrow bound to a row); `count` is a value. So the copies of one arrow into a stand-in for several
/// shapes are each an edge, and a key moved from one row of a table to another is another edge.
public struct Edge: Hashable, Sendable, Codable {
    public let type: EdgeTypeID
    public let source: ShapeID
    public let target: ShapeID
    public let carrier: ShapeID
    public let slot: String
    public let count: Int
    /// How it came to be: `.emitted` for every edge a source emits, as the index has it where no
    /// end is a stand-in.
    public let origin: EdgeOrigin
    /// The part of each end it reaches, when it reaches one (`PartedShape`'s rows: an arrow bound to a column): `.none`
    /// for an edge between whole shapes, every edge but those, which costs one word.
    public let parts: EdgeParts

    public init(type: EdgeTypeID, source: ShapeID, target: ShapeID, carrier: ShapeID, slot: String = "", count: Int = 1,
                origin: EdgeOrigin = .emitted, parts: EdgeParts = .none) {
        self.type = type
        self.source = source
        self.target = target
        self.carrier = carrier
        self.slot = slot
        self.count = count
        self.origin = origin
        self.parts = parts
    }

    /// The part of its source it starts at; nil for the shape as a whole.
    public var sourcePart: PartID? { parts.source }

    /// The part of its target it ends at; nil for the shape as a whole.
    public var targetPart: PartID? { parts.target }

    /// The part at `id`'s end, as `direction` reads it: its source's going out of `id`, its target's coming in (either:
    /// the source's when `id` is its source). Nil for a whole shape.
    public func part(at id: ShapeID, _ direction: EdgeDirection) -> PartID? {
        switch direction {
        case .outgoing: parts.source
        case .incoming: parts.target
        case .either: source == id ? parts.source : parts.target
        }
    }

    /// Whether it touches `part` of `id` (nil: `id` as a whole) as `direction` asks: an end at `id` that reaches that part.
    public func touches(_ id: ShapeID, part: PartID?, _ direction: EdgeDirection) -> Bool {
        switch direction {
        case .outgoing: source == id && parts.source == part
        case .incoming: target == id && parts.target == part
        case .either: (source == id && parts.source == part) || (target == id && parts.target == part)
        }
    }

    /// The part at the other end from `id`, as `direction` reads it (`otherEnd(from:_:)`'s part).
    public func otherPart(from id: ShapeID, _ direction: EdgeDirection) -> PartID? {
        switch direction {
        case .outgoing: parts.target
        case .incoming: parts.source
        case .either: source == id ? parts.target : parts.source
        }
    }

    /// Whether this is the connection: the edge in the empty slot, the carrier's own (an arrow bound at
    /// both ends), as against one a property of the carrier holds. The one place the convention is read.
    public var isConnection: Bool { slot.isEmpty }

    /// The source its carrier emitted: the stand-in it was forwarded through, if it was at that end.
    public var literalSource: ShapeID {
        if case .forwarded(let source?, _) = origin { source } else { source }
    }

    /// The target its carrier emitted: the stand-in it was forwarded through, if it was at that end.
    public var literalTarget: ShapeID {
        if case .forwarded(_, let target?) = origin { target } else { target }
    }

    /// Hashes its ends alone (each id two words): equal edges have equal ends, and edges that share
    /// both ends are few (a carrier's are told apart by their ends; copies of one forwarded edge by
    /// where they end), so the sets the tables diff in, and a reader collects edges in, hash a
    /// fraction of what every field would cost.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(target)
    }

    /// The edge as its carrier emitted it: its literal ends, `.emitted`. Itself for one emitted.
    public var literal: Edge {
        guard case .forwarded = origin else { return self }
        return Edge(type: type, source: literalSource, target: literalTarget, carrier: carrier, slot: slot, count: count, parts: parts)
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

/// The parts an edge's ends reach (`PartAddress.part`, a row of each shape), as an arrow bound to rows emits them: an edge
/// between whole shapes is `.none`, and the rest are boxed (`indirect`), so every edge pays one word for them.
public enum EdgeParts: Hashable, Sendable, Codable {
    case none
    indirect case some(source: PartID?, target: PartID?)

    /// The parts of two ends: `.none` when neither names one.
    public init(source: PartID?, target: PartID?) {
        self = source == nil && target == nil ? .none : .some(source: source, target: target)
    }

    public var source: PartID? {
        if case .some(let source, _) = self { source } else { nil }
    }

    public var target: PartID? {
        if case .some(_, let target) = self { target } else { nil }
    }
}

/// How an edge came to be.
public enum EdgeOrigin: Hashable, Sendable, Codable {
    /// As its carrier emitted it.
    case emitted
    /// Emitted with a stand-in at one end or both, and forwarded: each end that was one names it
    /// here (the edge's own end is a shape it stands for); an end that wasn't is nil. Boxed
    /// (`indirect`), so an origin is one word: an edge where nothing stands in, every edge of most
    /// files, is hardly bigger for having one.
    indirect case forwarded(source: ShapeID?, target: ShapeID?)
    /// A stand-in's own edge to a shape it stands for (`StandingEdge`), carried by the stand-in.
    case standing
}

/// Which edges a reader sees, where stand-ins forward (`EdgeForwarding`).
public enum EdgeView: Hashable, Sendable {
    /// Every end that's a stand-in forwarded to each shape it stands for, and stand-ins' edges to
    /// those shapes (`stands-for`): an arrow into a stand-in is an arrow into what it stands for.
    /// What every read gives unless it asks otherwise.
    case resolved
    /// Forwarded only through stand-ins whose own record names what they stand for
    /// (`Forwarding.shapes`): one that stands for whatever was provided (`Forwarding.provided`) is
    /// left at its own end, and has no standing edges. A function of the records alone.
    case recorded
    /// Each end as its carrier emitted it, and no standing edges.
    case literal
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

/// A horizontal on the core alone: edge types, what records carry edges and which kinds' shapes
/// stand in for others are its points (`EdgeTypes`, `EdgeSources`, `EdgeForwarding`), its service
/// keeps the file's edges (`editor.topology`), and it declares the one edge type that's its own,
/// `stands-for` (`StandingEdge`). Every
/// plugin list with a plugin that contributes to them (Ports, Mentions) needs it. Put it early (in
/// the shipped list, right after Selection); a service that reads it as it takes a commit in has it
/// take the commit in first, wherever the two are in the list (looking it up does).
public struct TopologyPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .topology }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { TopologyIndex(editor: $0) }
        // Its own: the edge from a stand-in to each shape it stands for.
        registrar.edgeType(StandingEdge.self)
    }
}
