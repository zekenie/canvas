import Canvas
import CoreGraphics

// Stand-ins: shapes that stand for other shapes, so that an edge into one is an edge into what it
// stands for. A kind says its shapes stand in (`x.standsIn { … }`) and what each stands for, as its
// record names it or as is provided later; Topology forwards every edge another shape carries
// through them (`EdgeView.resolved`, what every read gives by default) and knows nothing more of
// why: no kind, no publicness, no query. A kind may also say how one of its shapes is made to stand
// for a given shape (`makes:`), so a plugin that makes shapes by name rather than by a gesture (the
// command line's `draw`) can put one beside what points at it (`registry.standIns`).

/// What a stand-in stands for, as its record says.
public enum Forwarding: Hashable, Sendable {
    /// The shapes its record names, in order: on any board, or gone.
    case shapes([ShapeID])
    /// Whatever was last provided for it under this key, which its record holds (a question it
    /// asks): nothing until an answer for that key comes.
    case provided(ForwardingKey)
}

extension Forwarding {
    /// The one shape a record that names shapes names (once, or several times over): what a reader that
    /// treats a direct stand-in as the shape it names reads it as, whether or not it may stand for it now.
    /// Nil for one that stands for what's provided, and one that names none, or several.
    public var onlyShape: ShapeID? {
        guard case .shapes(let named) = self, let first = named.first, named.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// What a stand-in that stands for what's provided asks, as its record says: an answer counts only
/// for the key the record holds now.
public struct ForwardingKey: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Whether a stand-in may stand for a shape: pure, of that shape's record (never another shape,
/// geometry, a service or the time, and never where a box is), and safe on any thread, so what a
/// stand-in stands for can be worked out off the main actor (`TopologyIndex.preparer()`).
public typealias ForwardAdmission = @Sendable (_ target: AnyShapeRecord) -> Bool

/// Makes a kind's admission from the registry, once for an index (the registry never changes): what
/// it needs of the registry (the kinds whose every shape is public) is read here, so the admission
/// reads only the record.
public typealias ForwardAdmissionMaker = @MainActor (_ registry: Registry) -> ForwardAdmission

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

/// How a stand-in kind makes one of its shapes stand for a given shape: from the shape its tool
/// places (`blank`, in no document), the shape it's made to stand for and what to call it there (what
/// a person picking it would have been shown, the shape's name). Nil: it can't.
public typealias ForwardingMaker = @MainActor (_ blank: AnyShapeRecord, _ target: ShapeID, _ label: String) -> AnyShapeRecord?

/// A kind's stand-in rule, as `standsIn` says it. Only the sugar makes one.
@MainActor
public struct StandIn {
    let admitting: ForwardAdmissionMaker
    let forward: ForwardingRule
    /// What a shape must be for this kind to stand for it, in a word (`public`): said for a person
    /// (`only a public shape`, `make it public`), never read.
    let needs: String?
    /// How one is made to stand for a shape, if the kind says.
    let make: ForwardingMaker?
    /// How a shape is made something the kind may stand for, if the kind says (opaque to Topology).
    let fulfil: (@MainActor (_ record: inout AnyShapeRecord, _ registry: Registry) -> Bool)?
    /// What one calls what it stands for, if the kind says.
    let calls: (@MainActor (_ record: AnyShapeRecord, _ registry: Registry) -> String?)?
}

/// The kinds whose shapes stand in for others: at most one rule per kind.
public enum EdgeForwarding {}

extension EdgeForwarding: KeyedExtensionPoint {
    public typealias Contribution = StandIn
    public static var owner: PluginID { .topology }
    public static func uniqueKeys(of _: StandIn, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: StandIn, for target: ShapeTarget) -> String { "stands in → \(target)" }
}

extension Registry {
    /// Each kind's stand-in rule, for the kinds that have one. Worked out on each call: keep it (the
    /// index does).
    func standInRules() -> [ShapeKind: StandIn] { contributionByKind(to: EdgeForwarding.self) }

    /// Each stand-in kind's admission, made from its rule once for the registry (`memo`): what a reader
    /// of many shapes asks again and again, and what reads a shape on any thread.
    var standInAdmissions: [ShapeKind: ForwardAdmission] {
        memo(StandInAdmissionsKey()) { standInRules().mapValues { $0.admitting(self) } }
    }
}

/// The key `standInAdmissions` is kept under.
private struct StandInAdmissionsKey: Hashable {}

extension ShapeRegistrar {
    /// This kind's shapes stand in for other shapes: an edge another shape carries that ends at one
    /// ends instead at each shape it stands for (`EdgeView.resolved`; the copies name it in their
    /// `origin`), and a `stands-for` edge goes from it to each (`StandingEdge`): as many as it stands
    /// for, read as they're asked for, never kept. `forward` says what one stands for, from its
    /// record, pure; it stands for those of them, in order and each once, that are on a board the
    /// editor can show, aren't kept aside, aren't stand-ins themselves (one hop), and the admission
    /// `admitting` makes takes (made once from the registry, and read on any thread). While it stands
    /// for nothing, an edge into it stays an edge into it.
    ///
    /// `makes` says how a shape of the kind is made to stand for a given shape, which a plugin that
    /// puts shapes down by name (the command line's `draw`) asks of it: it's given the props the
    /// kind's tool places, the shape to stand for and the name to show for it, and leaves them as the
    /// kind's own writers would (fitted too, as a pick is), so that `forward` then says what it
    /// stands for. A kind with it is made by `registry.standIns` (it needs a tool that places it),
    /// and only for a shape `admitting` takes; `needs` says in a word what a shape must be for that
    /// (`public`), for a message to a person that a shape can't be stood for.
    ///
    /// `fulfilling` makes a shape something the kind may stand for, if the kind says how
    /// (References': make it public): it changes the record it's given and says whether it did what
    /// `admitting` then needs; `StandIns.fulfil` runs it on a copy and keeps it only if `admitting`
    /// then takes the shape. Topology learns nothing of what it does.
    ///
    /// `calls` says what a shape of the kind calls what it stands for (the label a direct one keeps,
    /// the words of a query one), which outlives the shape: a pill whose shape is gone keeps its name.
    public mutating func standsIn(admitting: @escaping ForwardAdmissionMaker = { _ in { _ in true } },
                                  needs: String? = nil,
                                  fulfilling: (@MainActor (_ record: inout AnyShapeRecord, _ registry: Registry) -> Bool)? = nil,
                                  calls: (@MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry) -> String?)? = nil,
                                  makes: (@MainActor (_ props: inout Definition.Props, _ target: ShapeID, _ label: String) -> Void)? = nil,
                                  _ forward: @escaping @MainActor (_ shape: ShapeRecord<Definition.Props>, _ registry: Registry) -> Forwarding?) {
        var make: ForwardingMaker?
        if let makes {
            make = { blank, target, label in
                guard var shape = blank.typed(as: Definition.Props.self) else { return nil }
                makes(&shape.props, target, label)
                return AnyShapeRecord(shape)
            }
        }
        var erasedCalls: (@MainActor (AnyShapeRecord, Registry) -> String?)?
        if let calls {
            erasedCalls = { record, registry in record.typed(as: Definition.Props.self).flatMap { calls($0, registry) } }
        }
        contribute(StandIn(admitting: admitting, forward: { record, registry in
            record.typed(as: Definition.Props.self).flatMap { forward($0, registry) }
        }, needs: needs, make: make, fulfil: fulfilling, calls: erasedCalls), to: EdgeForwarding.self)
    }
}

// MARK: Reading the rules

/// The registry's stand-ins, read by whatever puts shapes down by name rather than by a gesture:
/// which kinds stand in, what a record says one stands for, and which of them can be made to stand
/// for a given shape, and how. Made once (`registry.standIns`, worked out on each call): the
/// registry never changes.
@MainActor
public struct StandIns {
    private let rules: [ShapeKind: StandIn]
    private let registry: Registry

    init(_ registry: Registry) {
        self.registry = registry
        rules = registry.standInRules()
    }

    /// Each kind's admission, made once a registry (`Registry.standInAdmissions`), and only once one is asked.
    private var admissions: [ShapeKind: ForwardAdmission] { registry.standInAdmissions }

    /// The kinds whose shapes stand in for others.
    public var kinds: Set<ShapeKind> { Set(rules.keys) }

    /// Whether any kind stands in.
    public var isEmpty: Bool { rules.isEmpty }

    /// What a record says it stands for (the kind's rule, which is pure: no other shape is read); nil
    /// for a shape of a kind that doesn't stand in, or one standing for nothing.
    public func forwarding(of record: AnyShapeRecord) -> Forwarding? {
        guard !record.isOpaque, let rule = rules[record.kind] else { return nil }
        return rule.forward(record, registry)
    }

    /// The one shape a direct stand-in's record names (`Forwarding.onlyShape`), whether or not it may
    /// stand for it now: nil for a shape of a kind that doesn't stand in, one that stands for what's
    /// provided, and one that names none or several. Of a record, so a run's own shapes, which no index
    /// holds yet, read as the file's do.
    public func directTarget(of record: AnyShapeRecord) -> ShapeID? { forwarding(of: record)?.onlyShape }

    /// The kinds that can be made to stand for a given shape (`standsIn(makes:)`), in plugin order:
    /// those a tool places, since it's from what the tool places that one is made.
    public var makers: [ShapeKind] {
        registry.contributions(to: EdgeForwarding.self).compactMap { rule in
            guard rule.value.make != nil, case .kind(let kind) = rule.target, registry.placement(for: kind) != nil else { return nil }
            return kind
        }
    }

    /// Whether a stand-in of `kind` may stand for `target`: the kind's admission, and what stands for
    /// no shape whatever (one kept aside, or a stand-in: one hop).
    public func admits(_ kind: ShapeKind, _ target: AnyShapeRecord) -> Bool {
        guard let admits = admissions[kind], !target.isOpaque, rules[target.kind] == nil else { return false }
        return admits(target)
    }

    /// What a shape must be for a stand-in of `kind` to stand for it, in a word (`public`), for a
    /// message; nil if the kind doesn't say.
    public func needs(_ kind: ShapeKind) -> String? { rules[kind]?.needs }

    /// Makes `target` something a stand-in of `kind` may stand for, if the kind says how
    /// (`standsIn(fulfilling:)`): true when `admits(kind, target)` holds afterward. `target` is changed
    /// only when this returns true, and only by the kind's `fulfilling`. A shape already admitted is
    /// left as it is (true). It doesn't ask leave to write: its caller does, with the transaction.
    public func fulfil(_ kind: ShapeKind, _ target: inout AnyShapeRecord) -> Bool {
        guard rules[kind] != nil else { return false }
        if admits(kind, target) { return true }
        guard let fulfil = rules[kind]?.fulfil else { return false }
        var made = target
        guard fulfil(&made, registry), admits(kind, made) else { return false }
        target = made
        return true
    }

    /// What a stand-in calls what it stands for: the label a direct one keeps, the words of a query
    /// one; nil for a shape of a kind that doesn't stand in or doesn't say, or one calling it nothing.
    public func calls(_ standIn: AnyShapeRecord) -> String? {
        guard !standIn.isOpaque, let rule = rules[standIn.kind] else { return nil }
        return rule.calls?(standIn, registry)
    }

    /// A new shape of `kind` that stands for `target`, called `label` there, in no document: what the
    /// kind's tool places (at the origin), made to stand for it by the kind (`makes`), then put in step
    /// as writing its properties would (`DerivedProps`, so a pill's width fits its label). Nil for a
    /// kind that can't be made to (`makers`). It doesn't ask `admits`: whoever puts it down does.
    public func make(_ kind: ShapeKind, standingFor target: ShapeID, label: String) -> AnyShapeRecord? {
        guard let make = rules[kind]?.make, let placement = registry.placement(for: kind),
              var made = make(placement.shape(at: .zero), target, label) else { return nil }
        if let properties = made.propertiesJSON, let derived = try? registry.shape(made, setting: properties) { made = derived }
        return made
    }
}

extension Registry {
    /// The stand-ins, read: worked out on each call, so keep it.
    @MainActor public var standIns: StandIns { StandIns(self) }
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
