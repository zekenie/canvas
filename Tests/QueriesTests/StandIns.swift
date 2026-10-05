import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// Stand-ins for queries' tests, never a real plugin's (Topology's own tests have their own): a
// proxy stands for the shapes its record cites (`Forwarding.shapes`), a lens for whatever answer
// was provided for the question its record asks (`Forwarding.provided`, nothing until one comes).
// Arrows (CanvasTesting's links, which are wires) into either read, in the resolved view, at what
// it stands for. Neither knows a query: the engine learns nothing of why a shape stands in.

/// A box that stands for the shapes it cites.
struct Proxy: BoxShapeProps {
    static let kind: ShapeKind = "proxy"
    static let properties = Properties<Proxy> {
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

extension Proxy {
    init() { self.init(.zero) }
}

/// A box that stands for what's provided for the question it asks.
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

struct ProxyDefinition {}

extension ProxyDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Proxy>, in context: RenderContext) {}
}

struct LensDefinition {}

extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}

/// Proxies and lenses.
struct StandInsPlugin: CanvasPlugin {
    var id: PluginID { "stand-ins" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ProxyDefinition()) { proxy in
            proxy.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(LensDefinition()) { lens in
            lens.standsIn { shape, _ in shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks)) }
        }
    }
}

func proxy(_ id: ShapeID, _ stands: [ShapeID]) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Proxy(unit, stands: stands.map(Citation.init))))
}

func lens(_ id: ShapeID, asks: String) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Lens(unit, asks: asks)))
}

/// An answer for a lens.
func provided(_ asks: String, _ shapes: [ShapeID], _ revision: Int = 1) -> ProvidedForwarding {
    ProvidedForwarding(key: ForwardingKey(asks), shapes: shapes, revision: revision)
}

/// On the top board: chores 1 "Alpha", 2 "Beta" and 3 "Gamma"; proxy 5, standing for 1; lens 6, asking
/// "q"; a wire 7 from 3 to the proxy, a wire 8 from 3 to the lens, a wire 9 from 3 to 1 as drawn, and
/// a wire 10 from the proxy to the lens.
struct Relay {
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                 proxy(id(5), [id(1)]), lens(id(6), asks: "q"), link(id(7), id(3), id(5)),
                                                 link(id(8), id(3), id(6)), link(id(9), id(3), id(1)), link(id(10), id(5), id(6))]))
    }
}

/// The relay, with the stand-ins installed and `more` after them.
@MainActor func relay(file: CanvasFile = Relay().file, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: queryPlugins(more: [StandInsPlugin()] + more), file: file)
}
