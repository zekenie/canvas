@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Geometry
import TestKit
import Topology

// Stand-ins over fixtures, never the shipped Reference: a relay stands for the shapes it cites (its
// record names them) and has ports on every channel (`portsOnEveryChannel`, left and right), so what
// it takes follows what it stands for. A hub is a kind with ports on both channels whose wire only
// starts connections, so a relay for a hub and another kind has fewer channels or roles than either.

/// A box that stands for the shapes it cites.
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

/// A box whose ports on the wire only start connections, and on the pipe do both.
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

/// Relays, with ports on every channel on the sides given; and hubs.
@MainActor func relaysPlugin(sides: [PortSide] = [.left, .right], role: PortRole = .both) -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            relay.portsOnEveryChannel(sides: sides, role: role)
            relay.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(HubDefinition()) { hub in
            hub.ports(Wire.self, role: .source)
            hub.ports(Pipe.self)
        }
    }
}

/// An editor like `portsHarness`'s, with relays and hubs.
@MainActor func relayHarness(_ connections: ConnectionLog = ConnectionLog(), sides: [PortSide] = [.left, .right], role: PortRole = .both) throws -> EditorHarness {
    try portsHarness(connections, more: [relaysPlugin(sides: sides, role: role)])
}

/// Where most tests put what a relay stands for: clear of the relay at `boxFrame`.
let farBox = CGRect(x: 400, y: 250, width: 100, height: 100)

extension EditorHarness {
    /// Makes the relay stand for `shapes` (a transaction).
    func repoint(_ relay: ShapeID, to shapes: [ShapeID]) {
        editor.transact { $0.update(relay, as: Relay.self) { $0.props.stands = shapes.map(Citation.init) } }
    }

    /// The connection a drag from `box`'s right dot begins: what a connection from a box on the wire is.
    func beginConnection(_ connections: ConnectionLog, from dot: CGPoint, via body: CGPoint) throws -> Connection {
        let before = connections.begun.count
        connect(from: dot, to: dot + CGPoint(x: 30, y: 0), via: body)
        expectEqual(connections.begun.count, before + 1)
        return try require(connections.begun.last)
    }
}
