import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit
import Topology

// A stand-in that stands for what's provided for what it asks (a reference drawn by its query) has no title, and its record
// names no shape it could be named by, so a script names it by its id: an edge into it, a restatement, a placement against it,
// a delete. Over fixtures: a beacon stands for what's provided for what it asks, and a relay (a stand-in for the shapes its
// record names) is still named by the shape it stands for.

/// A box that stands for what's provided for what it asks, as a reference drawn by its query does: one that asks nothing
/// stands for nothing. Nothing here answers it, which is nothing to Draw: what it stands for is never read.
struct Beacon: BoxShapeProps {
    static let kind: ShapeKind = "beacon"
    static let properties = Properties<Beacon> {
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

extension Beacon {
    init() { self.init(.zero) }
}

struct BeaconDefinition {}

extension BeaconDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Beacon>, in context: RenderContext) {}
}

/// Beacons: placed by a tool, standing for what's provided for what they ask, and made by no one to stand for a given shape.
@MainActor func beaconsPlugin() -> Contributor {
    Contributor(id: "beacons") { registrar in
        registrar.shape(BeaconDefinition()) { beacon in
            beacon.standsIn { shape, _ in shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks)) }
            beacon.tool(label: "Beacon", systemImage: "light.beacon.max", placing: beacon.placement(size: CGSize(width: 100, height: 40)) { Beacon() })
        }
    }
}

/// A coast: on the root, the tiles Hub and Dock (open), the beacons Lit (asking "tiles") and Dark (asking nothing), a relay
/// for Dock, and the pocket P; on P's board, the beacon Far (asking "tiles").
@MainActor struct Coast {
    let p = ShapeID(), hub = ShapeID(), dock = ShapeID(), lit = ShapeID(), dark = ShapeID(), relay = ShapeID(), far = ShapeID()
    /// Whether Hub may be stood for.
    var openHub = false

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat, open: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: 150, width: 120, height: 80), label: label)))
            if open { record.meta[Open.self] = true }
            return record
        }
        func beacon(_ id: ShapeID, asks: String, x: CGFloat, y: CGFloat) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Beacon(CGRect(x: x, y: y, width: 100, height: 40), asks: asks)))
        }
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 400, y: 500, width: 100, height: 100))))
        pocket[Nickname.self] = "P"
        let relayRecord = AnyShapeRecord(ShapeRecord(id: relay, Relay(CGRect(x: 1000, y: 170, width: Relay.width(saying: "Dock"), height: 40),
                                                                      stands: [dock], says: "Dock")))
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 100, open: openHub), tile(dock, "Dock", x: 800, open: true),
                                                        beacon(lit, asks: "tiles", x: 400, y: 170), beacon(dark, asks: "", x: 400, y: 350),
                                                        relayRecord, pocket]),
                          children: [p: CanvasDocument(shapes: [beacon(far, asks: "tiles", x: 400, y: 150)])])
    }

    func editor(log: EdgeLog = EdgeLog()) throws -> CanvasEditor {
        let editor = try drawEditor([TopologyPlugin(), PocketsPlugin(), namedPockets, relaysPlugin(), beaconsPlugin()], log: log)
        editor.replaceFile(with: file)
        return editor
    }
}

/// An id as a script writes it.
private func mark(_ id: ShapeID) -> String { "#\(id)" }

@MainActor let drawAskingStandInTests = Suite("draw: a stand-in for what it asks is named by its id", [
    test("an edge into a beacon by its id is drawn straight into it, judged by its own kind; its row calls it by the id; a run again is unchanged") {
        let c = Coast(), log = EdgeLog()
        let editor = try c.editor(log: log)
        let result = try drawn("edge \"Hub\" -> \(mark(c.lit))", on: editor)
        expectEqual(rows(result), [["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": .string(mark(c.lit)),
                                    "toId": .string(c.lit.description)]])
        expectEqual(messages(result), [])
        let link = try require(editor.document.shapes.compactMap { $0.typed(as: Link.self) }.last)
        expectEqual(link.props.from, c.hub)
        expectEqual(link.props.to, c.lit, "into the beacon: no relay is made for one, on one board or two")
        expectEqual(editor.relays().count, 1, "Dock's, as it was")
        // Asked of the beacon as itself: it stands for no shape its record names.
        expectEqual(log.requests.last?.to, c.lit)
        expectEqual(log.requests.last?.toStandsFor, [])
        let again = try drawn("edge \"Hub\" -> \(mark(c.lit))", on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        // Out of one, too.
        let out = try drawn("edge \(mark(c.lit)) -> \"Dock\"", on: editor)
        expectEqual(rows(out), [["line": 1, "did": "connected", "kind": "link", "from": .string(mark(c.lit)), "to": "Dock",
                                 "fromId": .string(c.lit.description)]])
    },
    test("a beacon named by its id is restated, placed against and deleted with its arrows; deleting the shape at an arrow's other end leaves it") {
        let c = Coast()
        let editor = try c.editor()
        let restated = try drawn("beacon \(mark(c.lit)) asks: \"cards\"", on: editor)
        expectEqual(rows(restated).first?["did"], "updated")
        expectEqual(rows(restated).first?["id"], .string(c.lit.description))
        expectEqual(rows(restated).first?["title"], nil, "it has none")
        expectEqual(editor.document[c.lit]?.typed(as: Beacon.self)?.props.asks, "cards")
        expectEqual(rows(try drawn("beacon \(mark(c.lit)) asks: \"cards\"", on: editor)).first?["did"], "unchanged")
        let placed = try drawn("tile \"Near\" right of \(mark(c.lit))", on: editor)
        expectEqual(rows(placed).first?["did"], "created")
        let near = try require(shape("Near", in: editor)?.box)
        expect(near.minX >= (try require(editor.document[c.lit]?.box)).maxX, "right of the beacon")
        expectEqual(try refused("tile \"New\" in \(mark(c.lit))", on: editor).reason, "cannot_contain", "it holds no shapes")
        // A delete of the tile an arrow runs from takes the arrow and leaves the beacon: it stands for what it asks, not for one shape.
        _ = try drawn("edge \"Near\" -> \(mark(c.lit))", on: editor)
        _ = try drawn("delete \"Near\"", on: editor)
        expect(editor.document[c.lit] != nil, "the beacon stays")
        // Its own delete takes it and the arrows on it.
        _ = try drawn("edge \"Hub\" -> \(mark(c.lit))", on: editor)
        let deleted = try drawn("delete \(mark(c.lit))", on: editor)
        let beaconRow: JSON = ["line": 1, "did": "deleted", "kind": "beacon", "id": .string(c.lit.description)]
        expect(rows(deleted).contains(beaconRow), "\(rows(deleted))")
        expectEqual(rows(deleted).count, 2, "the beacon and the arrow into it")
        expectEqual(editor.document[c.lit], nil)
        expect(!editor.document.shapes.contains { $0.typed(as: Link.self)?.props.to == c.lit }, "no arrow left on it")
    },
    test("only a stand-in for what it asks is named by its id: a relay for the shape its record names, and a beacon that asks nothing, are invalid_value") {
        let c = Coast()
        let editor = try c.editor()
        for id in [c.relay, c.dark] {
            for script in ["edge \"Hub\" -> \(mark(id))", "delete \(mark(id))", "tile \"New\" right of \(mark(id))"] {
                expectEqual(try refused(script, on: editor).reason, "invalid_value", script)
            }
        }
        let relay = try refused("edge \"Hub\" -> \(mark(c.relay))", on: editor)
        expectEqual(relay.message, "\(mark(c.relay)) is a relay, which a script can't name")
        expectEqual(relay.hint, "an id names a shape a title could name (a note, say) or a reference drawn by its query: name an arrow by its two ends, and a reference that stands for a shape by that shape")
        expectEqual(try refused("beacon \(mark(c.dark)) asks: \"tiles\"", on: editor).reason, "invalid_value", "nor restated, till it asks")
    },
    test("via: into a beacon is refused, since it stands for others itself; an arrow into it is read as into what it stands for already") {
        let c = Coast()
        let editor = try c.editor()
        let via = try refused("edge \"Hub\" -> \(mark(c.lit)) via: relay", on: editor)
        expectEqual(via.reason, "invalid_value")
        expectEqual(via.message, "edge \"Hub\" -> \(mark(c.lit)): via: relay can't stand for \(mark(c.lit)), a beacon that stands for others itself")
        expectEqual(via.hint, "leave via: out: an arrow into \(mark(c.lit)) is read as an arrow into what it stands for")
        expectEqual(editor.relays().count, 1, "nothing drawn")
    },
    test("a beacon on another board: an end that can be stood for is reached through a relay beside it; one that can't is several_boards, and the hint asks nothing of the beacon") {
        var c = Coast()
        let closed = try refused("edge \"Hub\" -> \(mark(c.far))", on: try c.editor())
        expectEqual(closed.reason, "several_boards")
        let hint = try require(closed.hint)
        expect(hint.contains("make \"Hub\" open"), hint)
        expect(!hint.contains(mark(c.far)), "nothing makes a beacon something a relay stands for: \(hint)")
        c.openHub = true
        let editor = try c.editor()
        let result = try drawn("edge \"Hub\" -> \(mark(c.far))", on: editor)
        expectEqual(result["on"]?["board"], .string(c.p.description), "drawn where the beacon is")
        let board = BoardID(owner: c.p)
        let relay = try require(editor.relays(on: board).first)
        expectEqual(relay.props.stands.map(\.shape), [c.hub], "a relay for Hub, beside the beacon")
        expectEqual(editor.linkEnds(on: board).first?.from, relay.id)
        expectEqual(editor.linkEnds(on: board).first?.to, c.far)
        expectEqual(rows(result).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(result).last, ["line": 1, "did": "connected", "kind": "link", "from": "Hub", "to": .string(mark(c.far)), "via": "relay",
                                        "toId": .string(c.far.description)])
        expectEqual(rows(try drawn("edge \"Hub\" -> \(mark(c.far))", on: editor)).map { $0["did"] }, ["unchanged"], "found where the relay is")
    },
])
