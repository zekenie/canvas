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
