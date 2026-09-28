import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Ports
import Selection
import TestKit
import Topology

// Connections as Topology's edges: the connector names the family (`Hookup` here), each channel is
// an edge type under it, and a connection bound at both ends is one edge, of its channel's type.

private func type(_ channel: ChannelID) -> EdgeTypeID { EdgeTypeID(rawValue: channel.rawValue) }

/// An edge type that isn't a channel, declared by a plugin of its own, as Mentions' `mention` is.
enum Remark {}
extension Remark: EdgeType {
    static let id: EdgeTypeID = "remark"
}

/// Links, drawn by a connector that says no connection's ends (no `ends`), and so carries no edges.
@MainActor func endlessLinksHarness() throws -> EditorHarness {
    let connector = Contributor(id: "link-connector") { registrar in
        registrar.connects(Link.self, edgeType: Hookup.self, canConnect: { _, _ in true }) { _, _ in nil }
    }
    return try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), LinksPlugin(), PortsPlugin(),
                                       channelsPlugin(), connector])
}

/// Inserts a link from `from` to `to`, drawn on `channel`.
@MainActor func insertLink(_ h: EditorHarness, _ from: ShapeID?, _ to: ShapeID?, on channel: ChannelID?) -> ShapeID {
    var link = ShapeRecord(Link(from: from, to: to))
    link[ChannelProperty.self] = channel
    h.editor.transact { $0.insert(link) }
    return link.id
}

@MainActor let edgeTests = Suite("Connections as edges", [
    test("each channel is an edge type of its declarer's, under the connector's family; without a connector, a root") {
        let types = try linksHarness().editor.registry.edgeTypes
        expectEqual(types.declared, [type(Wire.id), type(Pipe.id), Hookup.id])
        expectEqual(types.parent(of: type(Wire.id)), Hookup.id)
        expectEqual(types.parent(of: type(Pipe.id)), Hookup.id)
        expectEqual(types.plugin(declaring: type(Wire.id)), "channels")
        expectEqual(types.plugin(declaring: Hookup.id), "link-connector")
        expectEqual(types.descendants(of: Hookup.id), [type(Wire.id), type(Pipe.id)])

        let alone = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin()])
        expectEqual(alone.edgeTypes.parent(of: type(Wire.id)), nil, "no connector, no family")
    },

    test("a connection bound at both ends is one edge of its channel's type; a plain one is the family's; one bound at one end is none; a channel nobody declares is kept as written") {
        let h = try linksHarness()
        let topology = try require(h.editor.topology)
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        @MainActor func link(_ from: ShapeID?, _ to: ShapeID?, on channel: ChannelID?) -> ShapeID {
            var link = ShapeRecord(Link(from: from, to: to))
            link[ChannelProperty.self] = channel
            h.editor.transact { $0.insert(link) }
            return link.id
        }
        let wired = link(a, b, on: Wire.id), plain = link(b, a, on: nil), half = link(a, nil, on: Wire.id), roped = link(a, b, on: Rope.id)
        expectEqual(topology.edges(carriedBy: wired), [Edge(type: type(Wire.id), source: a, target: b, carrier: wired)])
        expectEqual(topology.edges(carriedBy: plain), [Edge(type: Hookup.id, source: b, target: a, carrier: plain)])
        expectEqual(topology.edges(carriedBy: half), [], "bound at one end only: no edge")
        expectEqual(topology.edges(carriedBy: roped), [Edge(type: type(Rope.id), source: a, target: b, carrier: roped)])
        expect(!topology.types.isDeclared(type(Rope.id)))
        expectEqual(topology.edges(of: a).map(\.carrier), [wired, plain, roped])

        expectEqual(topology.edges(ofType: .within(Hookup.id)).map(\.carrier), [wired, plain], "the family and its channels")
        expectEqual(topology.edges(ofType: .only(Hookup.id)).map(\.carrier), [plain], "the family alone: plain connections")
        expectEqual(topology.edges(ofType: .only(type(Rope.id))).map(\.carrier), [roped])
        expectEqual(topology.neighbors(of: a, .outgoing), [type(Wire.id): [b], type(Rope.id): [b]])
        expectEqual(topology.neighbors(of: a, .incoming), [Hookup.id: [b]])

        // Bound at its other end too: now an edge. Moving the boxes reads nothing.
        h.editor.transact { $0.update(half, as: Link.self) { $0.props.to = b } }
        expectEqual(topology.edges(carriedBy: half), [Edge(type: type(Wire.id), source: a, target: b, carrier: half)])
        #if DEBUG
        let read = topology.recordsRead
        h.editor.transact { $0.translate([a, b], by: CGPoint(x: 10, y: 10)) }
        expectEqual(topology.recordsRead, read, "a move reads no connection")
        #endif
    },

    test("a connector without `ends` carries no edges, though its connections are bound at both ends: they're only ever drawn from a port") {
        let h = try endlessLinksHarness()
        let topology = try require(h.editor.topology)
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        let wired = insertLink(h, a, b, on: Wire.id), plain = insertLink(h, b, a, on: nil)
        for link in [wired, plain] {
            expectEqual(topology.edges(carriedBy: link), [])
            expect(h.editor.registry.connectionEnds(of: try require(h.editor.document[link])) == nil)
        }
        expectEqual(topology.edges(of: a), [])
        expectEqual(topology.edges(of: b), [])
        expectEqual(h.editor.registry.edgeTypes.parent(of: type(Wire.id)), Hookup.id, "its family is declared all the same")
    },

    test("a channel that's another edge type's id, not a channel's, is the family's: a connection is never an edge of a type that isn't a channel's") {
        let remarks = Contributor(id: "remarks") { $0.edgeType(Remark.self) }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), LinksPlugin(), PortsPlugin(),
                                            channelsPlugin(), linkConnectorPlugin(), remarks])
        let topology = try require(h.editor.topology)
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        let posing = insertLink(h, a, b, on: ChannelID(rawValue: Remark.id.rawValue)), roped = insertLink(h, a, b, on: Rope.id)
        expectEqual(topology.edges(carriedBy: posing), [Edge(type: Hookup.id, source: a, target: b, carrier: posing)])
        expectEqual(topology.edges(ofType: .only(Remark.id)), [], "no connection is a remark")
        expectEqual(topology.edges(carriedBy: roped), [Edge(type: type(Rope.id), source: a, target: b, carrier: roped)],
                    "one nobody declares at all is kept as written")
    },
])
