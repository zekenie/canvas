import Canvas

/// What a record carries, as a source says it (`EdgeSink.emit`): each edge once, in the order it was
/// first emitted (a text's order), with how often it was.
public struct EdgeSink {
    let carrier: ShapeID
    private var keys: [EdgeKey] = []
    private var counts: [EdgeKey: Int] = [:]
    /// How many edges it dropped for being Topology's own (`StandingEdge`).
    private(set) var reserved = 0

    init(carrier: ShapeID) { self.carrier = carrier }

    /// An edge of `type` from one shape to another, carried in `slot` ("" for the carrier itself, as
    /// an arrow is; else the name of the property it's in). Emitting one again, with the same type,
    /// ends and slot, counts it again (a text that mentions a shape twice). The slot `stands-for` and
    /// the type of that name are Topology's own (a stand-in's edges to what it stands for,
    /// `StandingEdge`): an edge in either is dropped.
    /// `fromPart` and `toPart` are the parts of its ends it reaches (an arrow bound to a row), part of its identity.
    public mutating func emit(_ type: EdgeTypeID, from source: ShapeID, to target: ShapeID, slot: String = "",
                              fromPart: PartID? = nil, toPart: PartID? = nil) {
        guard slot != StandingEdge.slot, type != StandingEdge.id else {
            reserved += 1
            return
        }
        let key = EdgeKey(type: type, source: source, target: target, slot: slot, parts: EdgeParts(source: fromPart, target: toPart))
        if let count = counts[key] {
            counts[key] = count + 1
        } else {
            counts[key] = 1
            keys.append(key)
        }
    }

    /// Everything emitted, in the order each was first.
    var edges: [Edge] {
        keys.map { Edge(type: $0.type, source: $0.source, target: $0.target, carrier: carrier, slot: $0.slot, count: counts[$0]!, parts: $0.parts) }
    }
}

struct EdgeKey: Hashable {
    let type: EdgeTypeID
    let source: ShapeID
    let target: ShapeID
    let slot: String
    let parts: EdgeParts
}

/// Says what edges a record carries. A pure function of the record and the registry: it must never
/// read other shapes, geometry, services, the camera or the time, and never depend on where a box is
/// (a commit that only moves shapes, `ChangeSet.moved`, isn't read again). That's what lets the index
/// follow each commit by reading only the records it changed, and undo put edges back exactly. A
/// record's edges may name shapes that aren't there: which ends are live is worked out when read.
public typealias EdgeEmitter = @MainActor (_ record: AnyShapeRecord, _ registry: Registry, _ sink: inout EdgeSink) -> Void

/// A source of edges, for one kind or for the kinds a scope reaches. Only the sugar makes one.
@MainActor
public struct EdgeSource {
    let emit: EdgeEmitter
}

/// What records carry edges: sources for a kind, or for the kinds a scope reaches (those that hold a
/// property, or have a capability). They add up: a kind's shapes carry what each of its sources emits.
public enum EdgeSources {}

extension EdgeSources: ExtensionPoint {
    public typealias Contribution = EdgeSource
    public static var owner: PluginID { .topology }
    /// Edges on other kinds' shapes say which: the kinds that hold a property, or have a capability.
    public static var scope: PointScope { .scoped }
    public static func summary(of source: EdgeSource, for target: ShapeTarget) -> String {
        "edges → \(target)"
    }
}

extension Registry {
    /// What each source for `kind` emits, in plugin order: its own, then those whose scope reaches it.
    /// Worked out on each call: keep it per kind.
    func edgeEmitters(for kind: ShapeKind) -> [EdgeEmitter] {
        contributions(to: EdgeSources.self, for: kind).map(\.emit)
    }

    /// The edges a record carries, as its kind's sources emit them, in order: none for a shape kept
    /// aside. Pure, for code that holds a record the index doesn't (a transaction's) and for tests.
    public func edges(of record: AnyShapeRecord) -> [Edge] {
        guard !record.isOpaque else { return [] }
        let emitters = edgeEmitters(for: record.kind)
        guard !emitters.isEmpty else { return [] }
        var reserved = 0
        return Self.edges(of: record, emitters: emitters, in: self, reserved: &reserved)
    }

    /// What the emitters say `record` carries; `reserved` counts the edges dropped for being
    /// Topology's own.
    static func edges(of record: AnyShapeRecord, emitters: [EdgeEmitter], in registry: Registry, reserved: inout Int) -> [Edge] {
        var sink = EdgeSink(carrier: record.id)
        for emit in emitters { emit(record, registry, &sink) }
        reserved += sink.reserved
        return sink.edges
    }
}

// MARK: Sugar

extension PluginRegistrar {
    /// The edges `K`'s shapes carry, for a kind another plugin registers (a horizontal's
    /// over a kind it's given): `emit` gets each record of the kind (`record.typed(as: K.self)` for
    /// its props) and says what it carries. Pure: see `EdgeEmitter`.
    public mutating func edges<K: ShapeProps>(_ kind: K.Type, _ emit: @escaping EdgeEmitter) {
        contribute(EdgeSource(emit: emit), to: EdgeSources.self, for: .kind(K.kind))
    }

    /// Every shape a value of the added property `P` names is an edge of type `T` from the shape that
    /// holds it, in the slot `P`'s key names, on every kind that opts into `P`: a relation nobody
    /// draws or writes in text (what a task is blocked by), kept as shapes' names. Declare `T` too
    /// (`edgeType`).
    public mutating func edges<P: ShapeProperty, T: EdgeType>(in property: P.Type, as type: T.Type) where P.Value: ShapeNaming {
        let slot = P.key.rawValue, id = T.id
        forShapes(holding: P.self) { holders in
            holders.edges { record, _, sink in
                record[P.self]?.forEachNamedShape { sink.emit(id, from: record.id, to: $0, slot: slot) }
            }
        }
    }
}

extension ScopedRegistrar {
    /// The edges the shapes of every kind the scope reaches carry: Mentions' on the kinds that can name
    /// shapes. Pure: see `EdgeEmitter`.
    public mutating func edges(_ emit: @escaping EdgeEmitter) {
        contribute(EdgeSource(emit: emit), to: EdgeSources.self)
    }
}

extension ShapeRegistrar {
    /// The edges this kind's shapes carry: `emit` gets each one, typed, and says what it carries.
    /// Pure: see `EdgeEmitter`.
    public mutating func edges(_ emit: @escaping @MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry, _ sink: inout EdgeSink) -> Void) {
        contribute(EdgeSource(emit: { record, registry, sink in
            guard let shape = record.typed(as: Definition.Props.self) else { return }
            emit(shape, registry, &sink)
        }), to: EdgeSources.self)
    }
}
