@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Topology

// Stand-ins over the fixtures, never a real plugin's: a proxy stands for the shapes its citations
// name (its record names them: `Forwarding.shapes`), and a gate likewise, but only for shapes whose
// metadata says they're open (its admission). A proxy may also emit a wire of its own to `next`, an
// edge a stand-in carries, which is never forwarded.

/// A box that stands for the shapes it cites, and carries a wire to `next`.
struct Proxy: BoxShapeProps {
    static let kind: ShapeKind = "proxy"
    static let properties = Properties<Proxy> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("next", \.next)
    }
    var frame: CGRect
    var stands: [Citation]
    var next: ShapeID?
    init(_ frame: CGRect, stands: [Citation] = [], next: ShapeID? = nil) {
        self.frame = frame
        self.stands = stands
        self.next = next
    }
}

extension Proxy {
    init() { self.init(.zero) }
}

/// A box that stands for the shapes it cites that are open (`Open`).
struct Gate: BoxShapeProps {
    static let kind: ShapeKind = "gate"
    static let properties = Properties<Gate> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Gate {
    init() { self.init(.zero) }
}

/// Whether a gate may stand for a shape: metadata a test writes on any shape.
enum Open: ShapeMetaKey {
    static let owner: PluginID = "stand-ins"
    static let name = "open"
    typealias Value = Bool
}

struct ProxyDefinition {}

extension ProxyDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Proxy>, in context: RenderContext) {}
}

struct GateDefinition {}

extension GateDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gate>, in context: RenderContext) {}
}

/// Proxies (each standing for at most `most` shapes, 50 by default; given a second rule, `twice`)
/// and gates.
struct StandInsPlugin: CanvasPlugin {
    var most = 50
    var twice = false
    var id: PluginID { "stand-ins" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ProxyDefinition()) { proxy in
            proxy.standsIn(maxTargets: most) { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
            if twice { proxy.standsIn { _, _ in nil } }
            proxy.edges { shape, _, sink in
                if let next = shape.props.next { sink.emit(WireEdge.id, from: shape.id, to: next) }
            }
        }
        registrar.shape(GateDefinition()) { gate in
            gate.standsIn(admitting: { target, _ in target.meta[Open.self] == true }) { shape, _ in .shapes(shape.props.stands.map(\.shape)) }
        }
    }
}

func proxy(_ id: ShapeID, _ stands: [ShapeID], next: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Proxy(unit, stands: stands.map(Citation.init), next: next)))
}

func gate(_ id: ShapeID, _ stands: [ShapeID]) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Gate(unit, stands: stands.map(Citation.init))))
}

/// A box that's open to gates.
func open(_ id: ShapeID) -> AnyShapeRecord {
    var record = box(id)
    record.meta[Open.self] = true
    return record
}

/// The graph's fixtures with stand-ins: `more` after them.
@MainActor func standing(_ file: CanvasFile = CanvasFile(), most: Int = 50, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try graph(file, more: [StandInsPlugin(most: most)] + more)
}

/// An edge forwarded through stand-ins, as the index resolves it.
func forwarded(_ type: EdgeTypeID, _ source: ShapeID, _ target: ShapeID, by carrier: ShapeID, from literalSource: ShapeID? = nil,
               to literalTarget: ShapeID? = nil, slot: String = "", count: Int = 1) -> Edge {
    Edge(type: type, source: source, target: target, carrier: carrier, slot: slot, count: count,
         origin: .forwarded(source: literalSource, target: literalTarget))
}

/// A stand-in's edge to a shape it stands for.
func stands(_ standIn: ShapeID, for target: ShapeID) -> Edge {
    Edge(type: StandingEdge.id, source: standIn, target: target, carrier: standIn, slot: StandingEdge.slot, origin: .standing)
}

// A lens stands for whatever is provided for the question its record asks (`Forwarding.provided`,
// its key from `asks`): nothing until an answer for that key comes (`provide`).

/// A box that stands for what's provided for what it asks.
struct Lens: BoxShapeProps {
    static let kind: ShapeKind = "lens"
    static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("asks", \.asks)
    }
    var frame: CGRect
    var asks: String
    init(_ frame: CGRect, asks: String = "") {
        self.frame = frame
        self.asks = asks
    }
}

extension Lens {
    init() { self.init(.zero) }
}

struct LensDefinition {}

extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}

/// Lenses, each standing for at most `most` shapes, and only open ones if `gated`; one that asks
/// nothing stands for nothing.
struct LensesPlugin: CanvasPlugin {
    var most = 50
    var gated = false
    var id: PluginID { "lenses" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LensDefinition()) { lens in
            lens.standsIn(maxTargets: most, admitting: { target, _ in !gated || target.meta[Open.self] == true }) { shape, _ in
                shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks))
            }
        }
    }
}

func lens(_ id: ShapeID, asks: String) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Lens(unit, asks: asks)))
}

/// The graph's fixtures with proxies, gates and lenses.
@MainActor func lensing(_ file: CanvasFile = CanvasFile(), most: Int = 50, gated: Bool = false) throws -> EditorHarness {
    try standing(file, more: [LensesPlugin(most: most, gated: gated)])
}

/// An answer for a lens.
func answer(_ asks: String, _ shapes: [ShapeID], _ revision: Int = 1) -> ProvidedForwarding {
    ProvidedForwarding(key: ForwardingKey(asks), shapes: shapes, revision: revision)
}
