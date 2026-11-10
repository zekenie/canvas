@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import DrawScript
import TestKit
import Topology

// What a move that keeps arrows needs over fixtures: links as the connector (Draw's `drawEdges`, with the ends a link has), and
// relays as the pills, which stand for the shapes they cite (their record names them) unless a shape is closed, as a private
// shape isn't stood for. Moving knows no kind: it asks Draw, which asks the registry.

/// Whether a relay may not stand for a shape: metadata a test writes on a shape, as a person makes one private.
enum Closed: ShapeMetaKey {
    static let owner: PluginID = "relays"
    static let name = "closed"
    typealias Value = Bool
}

/// A box that stands for the shapes it cites.
struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("says", \.says)
    }
    var frame: CGRect
    var stands: [Citation]
    var says: String
    init(_ frame: CGRect, stands: [ShapeID] = [], says: String = "") {
        self.frame = frame
        self.stands = stands.map(Citation.init)
        self.says = says
    }
}

extension Relay {
    init() { self.init(CGRect(x: 0, y: 0, width: 100, height: 40)) }
}

struct RelayDefinition {}

extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}

/// Links as the connector, relays as the pills. The relays are made by a tool, 100 × 40, for any shape not closed.
@MainActor func crossingPlugin() -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            relay.standsIn(admitting: { _ in { target in target.meta[Closed.self] != true } }, needs: "open", makes: { props, target, label in
                props.stands = [Citation(target)]
                props.says = label
            }) { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
            relay.tool(label: "Relay", systemImage: "arrow.right", placing: relay.placement(size: CGSize(width: 100, height: 40)) { Relay() })
        }
        registrar.drawEdges(kind: { _ in Link.kind }, sides: { _, _ in [:] }, ends: { record, _ in
            guard let link = record.typed(as: Link.self), let from = link.props.from, let to = link.props.to else { return nil }
            return (from, to)
        }, make: { request, existing, _ throws(DrawError) in
            existing ?? AnyShapeRecord(ShapeRecord(Link(from: request.from, to: request.to)))
        })
    }
}

/// The plugins a move that keeps arrows is tried with (Topology and Draw come before what contributes to them).
@MainActor func crossingPlugins() -> [any CanvasPlugin] { [TopologyPlugin(), DrawPlugin(), crossingPlugin()] }

/// The view the editor is given where a pocket's board is landed on.
let crossingView = CGSize(width: 1000, height: 700)

func relay(_ id: ShapeID, _ frame: CGRect, stands: ShapeID, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Relay(frame, stands: [stands]))).copy(as: id, container: container)
}

/// A shape closed to relays: a private one.
func closed(_ record: AnyShapeRecord) -> AnyShapeRecord {
    var record = record
    record.meta[Closed.self] = true
    return record
}

extension EditorHarness {
    /// The relays on a board, in order.
    func relays(on board: BoardID) -> [AnyShapeRecord] { file[board].shapes.filter { $0.kind == Relay.kind } }

    /// What a record cites, if it is a relay.
    func stands(_ id: ShapeID) -> [ShapeID] { file.record(id)?.typed(as: Relay.self)?.props.stands.map(\.shape) ?? [] }

    /// A link's ends.
    func ends(of link: ShapeID) -> (from: ShapeID?, to: ShapeID?) {
        let props = file.record(link)?.typed(as: Link.self)?.props
        return (props?.from, props?.to)
    }
}
