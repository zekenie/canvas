import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Neighbors
import TestKit
import Topology

// A row as the lists' subject (`watch(PartAddress)`): only the lights that serve rows are asked, given `#S::part(R)`, and no Inside
// or Contains; a shape's lists ask only the lights that serve shapes; hovering asks none of a row's. Rosters (CanvasTesting's) and
// straps, each a wire from its start's row to its end's.

/// Straps as wires, bound at rows.
@MainActor private func strapWires() -> Contributor {
    Contributor(id: "strap-wires") { registrar in
        registrar.edges(Strap.self) { record, _, sink in
            guard let strap = record.typed(as: Strap.self)?.props, let from = strap.from, let to = strap.to else { return }
            sink.emit(WireEdge.id, from: from.shape, to: to.shape, fromPart: from.part, toPart: to.part)
        }
    }
}

/// The test lights, and two of a row's own: what a row is wired to and from, at the row.
@MainActor private func rowLights() -> [NeighborLight] {
    let wire = WireEdge.id.rawValue
    return testLights() + [
        NeighborLight("Row Wired To", color: .systemTeal, serves: .rows, query: { ":edge-from(\($0), \(wire))" }),
        NeighborLight("Row Wired From", color: .systemTeal, serves: .both, query: { ":edge-to(\($0), \(wire))" }),
    ]
}

/// Where each list is with `rowLights()`: the four test lights', the two of rows, then Inside and Contains.
private enum RowLists {
    static let wiredTo = 0, rowWiredTo = 4, rowWiredFrom = 5, inside = 6, contains = 7
}

@MainActor let rowSubjectTests = Suite("Neighbors: a row as the subject", [
    test("a row's lists ask only the lights that serve rows, given the row; a shape's only those that serve shapes") {
        let a = RosterRow(name: "a"), b = RosterRow(name: "b")
        let left = ShapeID(), right = ShapeID(), other = ShapeID()
        let shapes: [AnyShapeRecord] = [
            AnyShapeRecord(ShapeRecord(id: left, Roster(CGRect(x: 0, y: 0, width: 100, height: 60), rows: [a, b]))),
            AnyShapeRecord(ShapeRecord(id: right, Roster(CGRect(x: 300, y: 0, width: 100, height: 60), rows: [a]))),
            AnyShapeRecord(ShapeRecord(id: other, Roster(CGRect(x: 600, y: 0, width: 100, height: 60), rows: [a]))),
            AnyShapeRecord(ShapeRecord(Strap(from: PartAddress(left, part: a.id), to: PartAddress(right, part: a.id)))),
            AnyShapeRecord(ShapeRecord(Strap(from: PartAddress(left, part: b.id), to: PartAddress(other)))),
            AnyShapeRecord(ShapeRecord(Strap(from: PartAddress(other), to: PartAddress(left, part: a.id)))),
        ]
        let h = try listHarness(CanvasFile(root: CanvasDocument(shapes: shapes)), lights: rowLights(),
                                more: [RostersPlugin(), StrapsPlugin(), strapWires()])
        h.list.watch(PartAddress(left, part: a.id))
        h.settleList()
        expectEqual(h.list.subject, PartAddress(left, part: a.id))
        expectEqual(h.rows(RowLists.rowWiredTo), [right], "what the row is wired to, at the row")
        expectEqual(h.rows(RowLists.rowWiredFrom), [other], "and from: a light that serves both")
        expectEqual(h.rows(RowLists.wiredTo), [], "a shape's light isn't asked")
        expectEqual(h.count(RowLists.inside) + h.count(RowLists.contains), 0, "nor Inside, nor Contains")
        h.list.watch(PartAddress(left, part: b.id))
        h.settleList()
        expectEqual(h.rows(RowLists.rowWiredTo), [other])
        expectEqual(h.rows(RowLists.rowWiredFrom), [])
        h.list.watch(left)
        h.settleList()
        expectEqual(h.rows(RowLists.rowWiredTo), [], "a light for rows alone isn't asked of the shape")
        expectEqual(h.rows(RowLists.rowWiredFrom), [other], "one for both is")
        expectEqual(Set(h.rows(RowLists.wiredTo)), [right, other], "the shape's own lights are")
        expectEqual(NeighborLight.selector(of: PartAddress(left, part: a.id)), "#\(left)::part(\(a.id))")
    },
    test("a row's tab is Connections on the kinds with parts: its lists are the row's") {
        let a = RosterRow(name: "a")
        let roster = ShapeID()
        let h = try listHarness(CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: roster, Roster(CGRect(x: 0, y: 0, width: 100, height: 60), rows: [a])))])),
                                lights: rowLights(), more: [RostersPlugin()])
        let record = try require(h.editor.document[roster])
        let layout = try require(h.editor.detailPanel?.rowLayout(for: record, part: a.id))
        expectEqual(layout.tabs.map(\.title), ["Connections"])
        expectEqual(layout.header(as: DetailRowHeader.self)?.part.name, "a")
    },
])
