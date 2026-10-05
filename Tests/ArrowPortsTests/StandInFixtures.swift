@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Topology

// Stand-ins over fixtures: a relay stands for the shapes it cites and has ports on every channel,
// left and right, so what ends on it follows what it stands for. A hub has ports on the wire that
// only start connections.

struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [ShapeID] = []) {
        self.frame = frame
        self.stands = stands.map(Citation.init)
    }
}

extension Relay {
    init() { self.init(.zero) }
}

struct RelayDefinition {}

extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}

struct Hub: BoxShapeProps {
    static let kind: ShapeKind = "hub"
    static let properties = Properties<Hub> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Hub {
    init() { self.init(.zero) }
}

struct HubDefinition {}

extension HubDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Hub>, in context: RenderContext) {}
}

@MainActor func relaysPlugin() -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            relay.portsOnEveryChannel(sides: [.left, .right])
            relay.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(HubDefinition()) { hub in hub.ports(Wire.self, role: .source) }
    }
}

extension PortBoard {
    /// A relay at `frame`, standing for `shapes`.
    @discardableResult
    func addRelay(at frame: CGRect = boxD, for shapes: [ShapeID] = []) -> ShapeID {
        h.add(Relay(frame, stands: shapes))
    }

    /// Makes the relay stand for `shapes`.
    func repoint(_ relay: ShapeID, to shapes: [ShapeID]) {
        h.editor.transact { $0.update(relay, as: Relay.self) { $0.props.stands = shapes.map(Citation.init) } }
    }
}
