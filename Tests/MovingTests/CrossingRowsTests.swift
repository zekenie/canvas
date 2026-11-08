@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import DrawScript
import TestKit
import Topology

// A move keeps the arrows that cross the edge with their ends at rows (K10, T6 panel 2): an arrow goes where its start goes, and
// the end re-pointed to a pill for the shape on the other side keeps its row on the binding (a key to a column, through a pill
// for its table). Fixtures only: rosters as the tables, straps (bound to a shape or a row) as the connector, relays as the pills.

/// Straps as the connector, relays as the pills, as `crossingPlugin` has links.
@MainActor private func rowCrossingPlugin() -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            relay.standsIn(admitting: { _ in { target in target.meta[Closed.self] != true } }, needs: "open", makes: { props, target, label in
                props.stands = [Citation(target)]
                props.says = label
            }) { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
            relay.tool(label: "Relay", systemImage: "arrow.right", placing: relay.placement(size: CGSize(width: 100, height: 40)) { Relay() })
        }
        registrar.drawEdges(kind: { _ in Strap.kind }, sides: { _, _ in [:] }, ends: { record, _ in
            guard let strap = record.typed(as: Strap.self), let from = strap.props.from, let to = strap.props.to else { return nil }
            return (from.shape, to.shape)
        }, make: { request, existing, _ throws(DrawError) in
            existing ?? AnyShapeRecord(ShapeRecord(Strap(from: PartAddress(request.from, part: request.fromPart), to: PartAddress(request.to, part: request.toPart))))
        })
    }
}

/// Root: a pocket P, the rosters L (400, 0) and R (400, 300), three rows each, and a strap from L's first row to R's last.
@MainActor private struct Ledger {
    let p = ShapeID(), l = ShapeID(), r = ShapeID(), s = ShapeID()
    let rows = ["a", "b", "c"].map { RosterRow(name: $0) }
    var pBoard: BoardID { BoardID(owner: p) }

    func file(strap from: PartAddress? = nil, to: PartAddress? = nil, root extra: [AnyShapeRecord] = [], onPocket: [AnyShapeRecord] = [],
              rOnRoot: Bool = true) -> CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [pocket(p, 0, 0), roster(l, 400, 0)] + (rOnRoot ? [roster(r, 400, 300)] : [])
                                        + [AnyShapeRecord(ShapeRecord(id: s, Strap(from: from ?? PartAddress(l, part: rows[0].id),
                                                                                    to: to ?? PartAddress(r, part: rows[2].id))))] + extra),
                   children: [p: CanvasDocument(shapes: onPocket)])
    }

    func roster(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord {
        AnyShapeRecord(ShapeRecord(id: id, Roster(CGRect(x: x, y: y, width: 160, height: 80), rows: rows)))
    }

    func harness(_ file: CanvasFile) throws -> EditorHarness {
        let h = try movingHarness(file, [TopologyPlugin(), DrawPlugin(), RostersPlugin(), StrapsPlugin(), rowCrossingPlugin()])
        h.editor.viewportDidResize(to: crossingView)
        return h
    }

    func strap(_ h: EditorHarness) -> Strap? { h.file.record(s)?.typed(as: Strap.self)?.props }
}

@MainActor let crossingRowsTests = Suite("Moving keeps the arrows at rows that cross", [
    test("the start moves: the strap goes with it, its end a relay for the roster that stays, the row kept on the binding; one Move, undone exactly") {
        let d = Ledger()
        let h = try d.harness(d.file())
        let before = h.file
        expect(h.run("move-to", on: d.l, with: d.p))
        expectEqual(h.file.board(containing: d.s), d.pBoard, "the strap went with its start")
        let relay = try require(h.relays(on: d.pBoard).first)
        expectEqual(h.stands(relay.id), [d.r])
        expectEqual(d.strap(h)?.from, PartAddress(d.l, part: d.rows[0].id), "its start row as it was")
        expectEqual(d.strap(h)?.to, PartAddress(relay.id, part: d.rows[2].id), "its end the relay, the row on the binding")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
        h.editor.redo()
        try expectFile(h, after, "and as the move left them")
    },
    test("the end moves: the strap stays, its end a relay for the roster that moved, the row kept; a staying table's key reaches the moved one") {
        let d = Ledger()
        let h = try d.harness(d.file())
        let before = h.file
        expect(h.run("move-to", on: d.r, with: d.p))
        expectEqual(h.file.board(containing: d.s), .root, "the strap stays with its start")
        let relay = try require(h.relays(on: .root).first)
        expectEqual(h.stands(relay.id), [d.r])
        expectEqual(d.strap(h)?.to, PartAddress(relay.id, part: d.rows[2].id))
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
    },
    test("an end at a relay with a row, moved to the board its roster is on: the strap goes straight to the row, and the relay stays") {
        let d = Ledger(), x = ShapeID()
        let far = AnyShapeRecord(ShapeRecord(id: d.r, Roster(CGRect(x: 100, y: 100, width: 160, height: 80), rows: d.rows)))
        let h = try d.harness(d.file(to: PartAddress(x, part: d.rows[1].id), root: [relay(x, at(700, 0, 100, 40), stands: d.r)], onPocket: [far],
                                     rOnRoot: false))
        expect(h.run("move-to", on: d.l, with: d.p))
        expectEqual(h.file.board(containing: d.s), d.pBoard)
        expectEqual(d.strap(h)?.to, PartAddress(d.r, part: d.rows[1].id), "straight to the roster's row")
        expectEqual(h.relays(on: .root).map(\.id), [x], "the relay stays where it was")
    },
])
