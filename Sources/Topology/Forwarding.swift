import Canvas

// Stand-ins: shapes that stand for other shapes, so that an edge into one is an edge into what it
// stands for. A kind says its shapes stand in (`x.standsIn { … }`) and what each stands for, as its
// record names it or as is provided later; Topology forwards every edge another shape carries
// through them (`EdgeView.resolved`, what every read gives by default) and knows nothing more of
// why: no kind, no publicness, no query.

/// What a stand-in stands for, as its record says.
public enum Forwarding: Hashable, Sendable {
    /// The shapes its record names, in order: on any board, or gone.
    case shapes([ShapeID])
    /// Whatever was last provided for it under this key, which its record holds (a question it
    /// asks): nothing until an answer for that key comes.
    case provided(ForwardingKey)
}

/// What a stand-in that stands for what's provided asks, as its record says: an answer counts only
/// for the key the record holds now.
public struct ForwardingKey: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Whether a stand-in may stand for a shape: pure, of that shape's record and the registry (never
/// another shape, geometry, a service or the time, and never where a box is).
public typealias ForwardAdmission = @MainActor (_ target: AnyShapeRecord, _ registry: Registry) -> Bool

/// What a stand-in stands for, from its record: pure, as an `EdgeEmitter` is of its carrier's (never
/// another shape, geometry, a service or the time, and never where a box is). Nil: nothing.
public typealias ForwardingRule = @MainActor (_ record: AnyShapeRecord, _ registry: Registry) -> Forwarding?

/// How a stand-in stands for its shapes now (`TopologyIndex.forwarding(of:)`).
public enum ForwardingState: Hashable, Sendable {
    /// It isn't a stand-in (or not on a board the editor can show), or its record names nothing.
    case none
    /// Its record names what it stands for: these, those of them it may stand for, in order.
    case record([ShapeID])
    /// It stands for what was provided for the key its record holds: these.
    case provided([ShapeID])
    /// It stands for what's provided, and nothing has been for the key its record holds now.
    case pending
}

/// A kind's stand-in rule, as `standsIn` says it. Only the sugar makes one.
@MainActor
public struct StandIn {
    /// The most shapes one stands for: those past it are left out, in order.
    public let maxTargets: Int
    let admitting: ForwardAdmission
    let forward: ForwardingRule
}

/// The kinds whose shapes stand in for others: at most one rule per kind.
public enum EdgeForwarding {}

extension EdgeForwarding: KeyedExtensionPoint {
    public typealias Contribution = StandIn
    public static var owner: PluginID { .topology }
    public static func uniqueKeys(of _: StandIn, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: StandIn, for target: ShapeTarget) -> String { "stands in → \(target)" }

    /// No stand-in stands for fewer than one shape at most.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for rule in registry.contributions(to: EdgeForwarding.self) where rule.value.maxTargets < 1 {
            throw .invalid(point: "EdgeForwarding", reason: "\(rule.pluginID) lets \(rule.target) stand for at most \(rule.value.maxTargets) shapes; at least 1")
        }
    }

    /// The most edges one carrier's edges are forwarded into (an arrow between two stand-ins for 50
    /// shapes each would be 2,500): copies past it are left out, though every edge a carrier emits
    /// keeps one, so its ends as emitted are always read.
    public static let maxPairsPerCarrier = 256
}

extension Registry {
    /// Each kind's stand-in rule, for the kinds that have one. Worked out on each call: keep it (the
    /// index does).
    func standInRules() -> [ShapeKind: StandIn] { contributionByKind(to: EdgeForwarding.self) }
}

extension ShapeRegistrar {
    /// This kind's shapes stand in for other shapes: an edge another shape carries that ends at one
    /// ends instead at each shape it stands for (`EdgeView.resolved`; the copies name it in their
    /// `origin`), and a `stands-for` edge goes from it to each (`StandingEdge`). `forward` says what
    /// one stands for, from its record, pure; it stands for those of them, in order and each once,
    /// that are on a board the editor can show, aren't kept aside, aren't stand-ins themselves (one
    /// hop), and `admitting` takes, up to `maxTargets`. While it stands for nothing, an edge into it
    /// stays an edge into it.
    public mutating func standsIn(maxTargets: Int = 50,
                                  admitting: @escaping ForwardAdmission = { _, _ in true },
                                  _ forward: @escaping @MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry) -> Forwarding?) {
        contribute(StandIn(maxTargets: maxTargets, admitting: admitting, forward: { record, registry in
            record.typed(as: Definition.Props.self).flatMap { forward($0, registry) }
        }), to: EdgeForwarding.self)
    }
}

/// The edge from a stand-in to each shape it stands for: Topology's own, so no plugin writes
/// another's id. In the resolved view only, carried by the stand-in in the slot of the same name,
/// which no source may emit into.
public enum StandingEdge {}

extension StandingEdge: EdgeType {
    public static let id: EdgeTypeID = "stands-for"
    public static let summary: String? = "from a shape to each shape it stands for"
    /// The slot standing edges are in, named as the type is: an edge a source emits in it, or of
    /// this type, is dropped (`EdgeSink.emit`).
    public static var slot: String { id.rawValue }
}
