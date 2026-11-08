@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology

// Edges that reach a part of their ends (a strap bound to a roster's row, as an arrow is to a table's column): each end's
// part is part of the edge's identity (a strap moved from one row to another is another edge, and touches the roster), the
// edge with none costs nothing more, a row's edges are filtered from its shape's, and a snapshot answers alike.

/// Straps emit a wire from what their start is bound to, to what their end is, with each end's part.
@MainActor private func strapEdges() -> Contributor {
    Contributor(id: "strap-edges") { registrar in
        registrar.edges(Strap.self) { record, _, sink in
            guard let strap = record.typed(as: Strap.self)?.props, let from = strap.from, let to = strap.to else { return }
            sink.emit(WireEdge.id, from: from.shape, to: to.shape, fromPart: from.part, toPart: to.part)
        }
    }
}

@MainActor private func partGraph() throws -> (h: EditorHarness, left: ShapeID, right: ShapeID, rows: [RosterRow]) {
    let h = try graph(more: [RostersPlugin(), StrapsPlugin(), strapEdges()])
    let rows = ["a", "b", "c"].map { RosterRow(name: $0) }
    let left = h.add(Roster(CGRect(x: 0, y: 0, width: 100, height: 80), rows: rows))
    let right = h.add(Roster(CGRect(x: 300, y: 0, width: 100, height: 80), rows: rows))
    return (h, left, right, rows)
}

@MainActor let partEdgeTests = Suite("Edges at parts", [
    test("an edge carries each end's part, and an edge with none has none") {
        let (h, left, right, rows) = try partGraph()
        let strap = h.add(Strap(from: PartAddress(left, part: rows[0].id), to: PartAddress(right, part: rows[2].id)))
        let whole = h.add(Strap(from: PartAddress(left), to: PartAddress(right)))
        let topology = try require(h.editor.topology)
        let edge = try require(topology.edges(carriedBy: strap).first)
        expectEqual(edge.sourcePart, rows[0].id)
        expectEqual(edge.targetPart, rows[2].id)
        expectEqual(edge.part(at: right, .either), rows[2].id)
        expectEqual(edge.otherPart(from: right, .incoming), rows[0].id)
        let plain = try require(topology.edges(carriedBy: whole).first)
        expectEqual(plain.parts, .none)
        expectEqual(EdgeParts(source: nil, target: nil), .none)
        expectEqual(MemoryLayout<EdgeParts>.size, MemoryLayout<Int>.size, "an edge pays one word for its parts, boxed")
    },
    test("a row's edges are filtered from its shape's, either way; the shape as a whole has its own") {
        let (h, left, right, rows) = try partGraph()
        let one = h.add(Strap(from: PartAddress(left, part: rows[0].id), to: PartAddress(right, part: rows[2].id)))
        let two = h.add(Strap(from: PartAddress(left, part: rows[1].id), to: PartAddress(right, part: rows[2].id)))
        let whole = h.add(Strap(from: PartAddress(left), to: PartAddress(right)))
        let topology = try require(h.editor.topology)
        expectEqual(topology.edges(of: right, part: rows[2].id, .incoming).map(\.carrier), [one, two])
        expectEqual(topology.edges(of: left, part: rows[1].id, .outgoing).map(\.carrier), [two])
        expectEqual(topology.edges(of: left, part: rows[1].id, .incoming).count, 0)
        expectEqual(topology.edges(of: right, part: nil).map(\.carrier), [whole])
        let snapshot = topology.snapshot()
        expectEqual(snapshot.edges(of: right, part: rows[2].id, .incoming).map(\.carrier), [one, two])
        expectEqual(snapshot.edges(of: left, part: nil).map(\.carrier), [whole])
    },
    test("a strap moved from one row to another is another edge, and the change touches the roster") {
        let (h, left, right, rows) = try partGraph()
        let strap = h.add(Strap(from: PartAddress(left, part: rows[0].id), to: PartAddress(right, part: rows[2].id)))
        let topology = try require(h.editor.topology)
        let before = try require(topology.edges(carriedBy: strap).first)
        var touched: Set<ShapeID> = []
        let following = topology.follow { touched.formUnion($0.touched) }
        h.editor.transact { $0.moveParts([PartAddress(right, part: rows[2].id): PartAddress(right, part: rows[1].id)]) }
        let after = try require(topology.edges(carriedBy: strap).first)
        expect(before != after, "the edge at another row is another edge")
        expectEqual(after.targetPart, rows[1].id)
        expect(touched.contains(right), "the roster is touched")
        following.cancel()
    },
])

// Forwarding with parts (K10): an edge into a stand-in reaches the part its carrier names there (a key's binding: a pill for a
// table, the column on the binding), else the part the stand-in stands for (`Forwarding.row`: a pill for an endpoint), so what
// reads a row's edges counts those through pills.

/// A box that stands for one row of a roster (its record names the roster and the row), as a pill for an endpoint does.
private struct Badge: BoxShapeProps {
    static let kind: ShapeKind = "badge"
    static let properties = Properties<Badge> {
        Property("frame", \.frame).required()
        Property("roster", \.roster)
        Property("row", \.row)
    }
    var frame: CGRect
    var roster: Citation?
    var row: PartID?
    init(_ frame: CGRect = unit, roster: ShapeID? = nil, row: PartID? = nil) {
        self.frame = frame
        self.roster = roster.map(Citation.init)
        self.row = row
    }
    init() { self.init(unit) }
}

private struct BadgeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Badge>, in context: RenderContext) {}
}

/// Badges, which stand for a row, and proxies, which stand for a shape.
@MainActor private func badgeGraph() throws -> (h: EditorHarness, left: ShapeID, right: ShapeID, rows: [RosterRow]) {
    let badges = Contributor(id: "badges") { registrar in
        registrar.shape(BadgeDefinition()) { badge in
            badge.standsIn { shape, _ in
                guard let roster = shape.props.roster?.shape else { return nil }
                return shape.props.row.map { .row(roster, $0) } ?? .shapes([roster])
            }
        }
    }
    let h = try graph(more: [StandInsPlugin(), RostersPlugin(), StrapsPlugin(), strapEdges(), badges])
    let rows = ["a", "b", "c"].map { RosterRow(name: $0) }
    let left = h.add(Roster(CGRect(x: 0, y: 0, width: 100, height: 80), rows: rows))
    let right = h.add(Roster(CGRect(x: 300, y: 0, width: 100, height: 80), rows: rows))
    return (h, left, right, rows)
}

@MainActor let forwardingPartTests = Suite("Forwarding with parts", [
    test("an edge into a stand-in for a shape reaches the part its carrier names: a key to a column through a pill for its table") {
        let (h, left, right, rows) = try badgeGraph()
        let pill = h.add(Proxy(unit, stands: [Citation(right)]))
        let strap = h.add(Strap(from: PartAddress(left, part: rows[0].id), to: PartAddress(pill, part: rows[2].id)))
        let topology = try require(h.editor.topology)
        let edge = try require(topology.edges(of: right, .incoming, types: .only(WireEdge.id)).first)
        expectEqual(edge.carrier, strap)
        expectEqual(edge.source, left)
        expectEqual(edge.targetPart, rows[2].id, "the part the binding names, of the shape the pill stands for")
        expectEqual(topology.edges(of: right, part: rows[2].id, .incoming).map(\.carrier), [strap], "counted among the row's edges")
        expectEqual(topology.edges(of: right, part: nil, .incoming, types: .only(WireEdge.id)).count, 0, "and not the shape's as a whole")
        expectEqual(topology.snapshot().edges(of: right, part: rows[2].id, .incoming).map(\.carrier), [strap], "a snapshot alike")
    },
    test("an edge into a stand-in for a row, naming no part, reaches that row; one that names a part keeps its own") {
        let (h, left, right, rows) = try badgeGraph()
        let badge = h.add(Badge(roster: right, row: rows[1].id))
        let plain = h.add(Strap(from: PartAddress(left, part: rows[0].id), to: PartAddress(badge)))
        let named = h.add(Strap(from: PartAddress(left), to: PartAddress(badge, part: rows[2].id)))
        let topology = try require(h.editor.topology)
        expectEqual(topology.forwarding(of: badge), .record([right]), "it stands for the roster, as its record names it")
        expectEqual(topology.directTarget(of: badge), right)
        expectEqual(topology.directPart(of: badge), rows[1].id)
        expectEqual(topology.standIns(naming: right), [badge], "named, as a stand-in for a shape is")
        expectEqual(topology.edges(of: right, part: rows[1].id, .incoming).map(\.carrier), [plain], "the badge's row")
        expectEqual(topology.edges(of: right, part: rows[2].id, .incoming).map(\.carrier), [named], "the binding's part wins")
        expectEqual(topology.edges(carriedBy: plain, view: .literal).first?.targetPart, nil, "literally, the edge names no part")
    },
    test("a stand-in re-pointed to another row of the same shape: its edges reach the new row, and the change touches the shape") {
        let (h, left, right, rows) = try badgeGraph()
        let badge = h.add(Badge(roster: right, row: rows[1].id))
        let strap = h.add(Strap(from: PartAddress(left), to: PartAddress(badge)))
        let topology = try require(h.editor.topology)
        var touched: Set<ShapeID> = []
        let following = topology.follow { touched.formUnion($0.touched) }
        h.editor.transact { $0.update(badge, as: Badge.self) { $0.props.row = rows[0].id } }
        expectEqual(topology.edges(of: right, part: rows[0].id, .incoming).map(\.carrier), [strap])
        expectEqual(topology.edges(of: right, part: rows[1].id, .incoming).count, 0)
        expect(touched.contains(right), "the shape it stands for is touched: its row's edges changed")
        following.cancel()
    },
    test("a stand-in for a row stands for nothing once the row is gone from its shape, as it is drawn (missing); the row back, it stands for it again") {
        let (h, left, right, rows) = try badgeGraph()
        let badge = h.add(Badge(roster: right, row: rows[1].id))
        let strap = h.add(Strap(from: PartAddress(left), to: PartAddress(badge)))
        let topology = try require(h.editor.topology)
        expectEqual(topology.forwarding(of: badge), .record([right]))
        expectEqual(topology.edges(of: right, part: rows[1].id, .incoming).map(\.carrier), [strap])
        h.editor.transact { $0.update(right, as: Roster.self) { $0.props.rows = [rows[0], rows[2]] } }
        expectEqual(topology.forwarding(of: badge), .record([]), "it stands for nothing")
        expectEqual(topology.edges(of: right, .incoming, types: .only(WireEdge.id)).count, 0, "no edge into the roster through it")
        expectEqual(topology.edges(of: badge, .incoming, types: .only(WireEdge.id)).map(\.carrier), [strap], "the arrow stays at the pill")
        h.editor.undo()
        expectEqual(topology.forwarding(of: badge), .record([right]))
        expectEqual(topology.edges(of: right, part: rows[1].id, .incoming).map(\.carrier), [strap])
    },
    test("the core's stand-in lookup is Topology's: the stand-ins naming a shape, a row's among them") {
        let (h, _, right, rows) = try badgeGraph()
        let badge = h.add(Badge(roster: right, row: rows[1].id))
        let pill = h.add(Proxy(unit, stands: [Citation(right)]))
        var found: [(id: ShapeID, board: BoardID)] = []
        h.editor.transact { found = $0.standIns(naming: right) }
        expectEqual(Set(found.map(\.id)), [badge, pill])
        expect(found.allSatisfy { $0.board == .root })
    },
])
