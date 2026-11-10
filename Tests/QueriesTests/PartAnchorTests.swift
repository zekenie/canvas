import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// An edge word's anchor at a row (`#S::part(R)`): only the edges whose end at the anchor is that row count, which way each word
// reads them; the anchor as a whole counts every edge. Rosters (CanvasTesting's) 1 and 2, three rows each; straps bound at rows,
// each a wire (a connection) from its start's row to its end's: 11 from row a of 1 to row c of 2, 12 from row b of 1 to row c of
// 2, 13 from 2 as a whole to row a of 1, and 14 from row a of 1 to 2 as a whole.

/// Straps emit a wire from what their start is bound to, to what their end is, with each end's part.
@MainActor private func strapWires() -> Contributor {
    Contributor(id: "strap-wires") { registrar in
        registrar.edges(Strap.self) { record, _, sink in
            guard let strap = record.typed(as: Strap.self)?.props, let from = strap.from, let to = strap.to else { return }
            sink.emit(WireEdge.id, from: from.shape, to: to.shape, fromPart: from.part, toPart: to.part)
        }
    }
}

private let a = RosterRow(name: "a"), b = RosterRow(name: "b"), c = RosterRow(name: "c")

@MainActor private func rowsHarness() throws -> EditorHarness {
    let rosters = [1, 2].map { n in AnyShapeRecord(ShapeRecord(id: id(n), Roster(unit, rows: [a, b, c]))) }
    func strap(_ n: Int, _ from: PartAddress, _ to: PartAddress) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id(n), Strap(from: from, to: to))) }
    let straps = [strap(11, PartAddress(id(1), part: a.id), PartAddress(id(2), part: c.id)),
                  strap(12, PartAddress(id(1), part: b.id), PartAddress(id(2), part: c.id)),
                  strap(13, PartAddress(id(2)), PartAddress(id(1), part: a.id)),
                  strap(14, PartAddress(id(1), part: a.id), PartAddress(id(2)))]
    return try EditorHarness(plugins: queryPlugins(more: [RostersPlugin(), StrapsPlugin(), strapWires()]),
                             file: CanvasFile(root: CanvasDocument(shapes: rosters + straps)))
}

@MainActor let partAnchorTests = Suite("An anchor at a row", [
    test("each edge word counts the edges whose end at the anchor is the row, which way it reads them; the shape as a whole, all") {
        let h = try rowsHarness()
        let one = "#\(uuid(1))", two = "#\(uuid(2))"
        func row(_ shape: String, _ part: RosterRow) -> String { shape + "::part(\(part.id))" }
        expectMatches([
            ":edge-from(\(row(one, a)), wire)": [2],
            ":edge-from(\(row(one, b)), wire)": [2],
            ":edge-from(\(row(one, c)), wire)": [],
            ":edge-from(\(one), wire)": [2],
            ":edge-to(\(row(one, a)), wire)": [2],
            ":edge-to(\(row(one, b)), wire)": [],
            ":edge-to(\(row(two, c)), wire)": [1],
            ":edge-to(\(row(two, a)), wire)": [],
            ":starts-at(\(row(one, a)), wire)": [11, 14],
            ":starts-at(\(row(one, b)), wire)": [12],
            ":ends-at(\(row(two, c)), wire)": [11, 12],
            ":ends-at(\(row(one, a)), wire)": [13],
            ":ends-at(\(one), wire)": [13],
        ], on: h)
        // A connection's ends, read at the row: where the strap starts, when it starts at that row.
        expectMatches([
            ":start-of(#\(uuid(11))::part(\(a.id)))": [1],
            ":start-of(#\(uuid(11))::part(\(b.id)))": [],
            ":end-of(#\(uuid(12))::part(\(c.id)))": [2],
        ], on: h)
    },
    test("a row's anchor among few candidates reads the candidates' own edges, and answers the same") {
        let h = try rowsHarness()
        let one = "#\(uuid(1))::part(\(b.id))"
        expectMatches([
            "#\(uuid(2)):edge-from(\(one), wire)": [2],
            "#\(uuid(2)):edge-to(\(one), wire)": [],
            "#\(uuid(12)):starts-at(\(one), wire)": [12],
            "#\(uuid(11)):starts-at(\(one), wire)": [],
        ], on: h)
    },
])
