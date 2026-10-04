@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import TestKit
import Topology

// Arrows as Topology's edges: an arrow bound at both ends is an edge of the `arrow` family, or of
// its channel's type under it; drawn from a port, it's the channel it was drawn on.

private func type(_ channel: ChannelID) -> EdgeTypeID { EdgeTypeID(rawValue: channel.rawValue) }

@MainActor let arrowEdgeTests = Suite("Arrows as edges", [
    test("the arrow family is named after the arrow kind, and every channel is under it") {
        let types = try PortBoard().h.editor.registry.edgeTypes
        expectEqual(ArrowEdge.id.rawValue, Arrow.kind.rawValue)
        expectEqual(types.parent(of: type(Wire.id)), ArrowEdge.id)
        expectEqual(types.parent(of: type(Pipe.id)), ArrowEdge.id)
        expectEqual(types.plugin(declaring: ArrowEdge.id), .arrowPorts)
    },

    test("an arrow drawn from a port is an edge of the channel it's drawn on; one on none, of the family; a free end, none") {
        let board = try PortBoard()
        let topology = try require(board.h.editor.topology)
        board.connect(to: CGPoint(x: 560, y: 180))
        let drawn = try require(board.arrows.last)
        expectEqual(topology.edges(carriedBy: drawn.id), [Edge(type: type(Wire.id), source: board.a, target: board.b, carrier: drawn.id)])

        let plain = board.addArrow(channel: nil)
        expectEqual(topology.edges(carriedBy: plain), [Edge(type: ArrowEdge.id, source: board.a, target: board.b, carrier: plain)])
        expectEqual(topology.neighbors(of: board.a, .outgoing), [type(Wire.id): [board.b], ArrowEdge.id: [board.b]])
        expectEqual(topology.edges(ofType: .within(ArrowEdge.id)).map(\.carrier), [plain, drawn.id], "type by type, as their plugins declare them: the family (the bridge), then the wire")
        expectEqual(topology.edges(ofType: .only(ArrowEdge.id)).map(\.carrier), [plain])

        // Its end let go: no longer an edge; bound again: one.
        board.h.editor.transact { $0.update(plain, as: Arrow.self) { $0.props.end = .free(CGPoint(x: 900, y: 900)) } }
        expectEqual(topology.edges(carriedBy: plain), [])
        board.h.editor.transact { $0.update(plain, as: Arrow.self) { $0.props.end = binding(board.c) } }
        expectEqual(topology.edges(carriedBy: plain), [Edge(type: ArrowEdge.id, source: board.a, target: board.c, carrier: plain)])

        // Deleting the shape an arrow is bound to lets the arrow go there (Arrows' `willDelete`): no edge.
        board.h.editor.transact { $0.delete([board.c]) }
        expectEqual(topology.edges(carriedBy: plain), [])
        board.h.editor.undo()
        expectEqual(topology.edges(carriedBy: plain), [Edge(type: ArrowEdge.id, source: board.a, target: board.c, carrier: plain)])
    },
])
