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
    public mutating func emit(_ type: EdgeTypeID, from source: ShapeID, to target: ShapeID, slot: String = "") {
        guard slot != StandingEdge.slot, type != StandingEdge.id else {
            reserved += 1
            return
        }
        let key = EdgeKey(type: type, source: source, target: target, slot: slot)
        if let count = counts[key] {
            counts[key] = count + 1
        } else {
            counts[key] = 1
            keys.append(key)
        }
    }

    /// Everything emitted, in the order each was first.
    var edges: [Edge] {
        keys.map { Edge(type: $0.type, source: $0.source, target: $0.target, carrier: carrier, slot: $0.slot, count: counts[$0]!) }
    }
}

struct EdgeKey: Hashable {
    let type: EdgeTypeID
    let source: ShapeID
    let target: ShapeID
    let slot: String
}

/// Says what edges a record carries. A pure function of the record and the registry: it must never
/// read other shapes, geometry, services, the camera or the time, and never depend on where a box is
/// (a commit that only moves shapes, `ChangeSet.moved`, isn't read again). That's what lets the index
/// follow each commit by reading only the records it changed, and undo put edges back exactly. A
/// record's edges may name shapes that aren't there: which ends are live is worked out when read.
public typealias EdgeEmitter = @MainActor (_ record: AnyShapeRecord, _ registry: Registry, _ sink: inout EdgeSink) -> Void

/// A source of edges, for one kind or for the kinds `appliesTo` picks. Only the sugar makes one.
@MainActor
public struct EdgeSource {
    let appliesTo: (@MainActor (ShapeKind, Registry) -> Bool)?
    let emit: EdgeEmitter
}

/// What records carry edges: sources for a kind, or for every kind a `where` picks. They add up: a
/// kind's shapes carry what each of its sources emits.
public enum EdgeSources {}

extension EdgeSources: ExtensionPoint {
    public typealias Contribution = EdgeSource
    public static var owner: PluginID { .topology }
    public static func summary(of source: EdgeSource, for target: ShapeTarget) -> String {
        "edges → " + (target == .any ? "every shape" : "\(target)")
    }
}

extension Registry {
    /// What each source for `kind` emits, in plugin order: its own, then every kind's that picks it
    /// (`where`, asked here). Worked out on each call: keep it per kind.
    func edgeEmitters(for kind: ShapeKind) -> [EdgeEmitter] {
        contributions(to: EdgeSources.self, for: kind).compactMap { source in
            (source.appliesTo.map { $0(kind, self) } ?? true) ? source.emit : nil
        }
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
        contribute(EdgeSource(appliesTo: nil, emit: emit), to: EdgeSources.self, for: .kind(K.kind))
    }

    /// The edges the shapes of every kind `appliesTo` picks carry (every kind by default), asked once
    /// per kind: by the registry (`registry.namingKinds.contains(kind)`), or by what the kind opts
    /// into. Pure: see `EdgeEmitter`.
    public mutating func edgesForEveryShape(where appliesTo: @escaping @MainActor (ShapeKind, Registry) -> Bool = { _, _ in true },
                                            _ emit: @escaping EdgeEmitter) {
        contribute(EdgeSource(appliesTo: appliesTo, emit: emit), to: EdgeSources.self)
    }

    /// Every shape a value of the added property `P` names is an edge of type `T` from the shape that
    /// holds it, in the slot `P`'s key names, on every kind that opts into `P`: a relation nobody
    /// draws or writes in text (what a task is blocked by), kept as shapes' names. Declare `T` too
    /// (`edgeType`).
    public mutating func edges<P: ShapeProperty, T: EdgeType>(in property: P.Type, as type: T.Type) where P.Value: ShapeNaming {
        let slot = P.key.rawValue, id = T.id
        edgesForEveryShape(where: { kind, registry in registry.properties(for: kind).contains(P.key) }) { record, _, sink in
            record[P.self]?.forEachNamedShape { sink.emit(id, from: record.id, to: $0, slot: slot) }
        }
    }
}

extension ShapeRegistrar {
    /// The edges this kind's shapes carry: `emit` gets each one, typed, and says what it carries.
    /// Pure: see `EdgeEmitter`.
    public mutating func edges(_ emit: @escaping @MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry, _ sink: inout EdgeSink) -> Void) {
        contribute(EdgeSource(appliesTo: nil, emit: { record, registry, sink in
            guard let shape = record.typed(as: Definition.Props.self) else { return }
            emit(shape, registry, &sink)
        }), to: EdgeSources.self)
    }
}
