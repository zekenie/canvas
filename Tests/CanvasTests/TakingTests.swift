@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Shapes that take the shapes bound to them along (`TakesBoundShapes`): CanvasTesting's ledgers take their links,
// boxes keep tldraw's rule. Deleting one deletes what is bound to it, but a read-only link, which lets go where it is
// drawn; the transaction says what went along (`deletedAlong`) and a body names its step (`stepName`); a copy takes
// along what is bound only to shapes copied (`ShapeContext.takenAlong(by:)`).

private func ledger(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Ledger(CGRect(x: x, y: 0, width: 40, height: 30))))
}
private func box(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: 0, width: 40, height: 30))))
}
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))) }
private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding ledgers L and M, box B, and links K1 (L to B), K2 (M to L), K3 (B to M), K4 (B to nothing) and K5 (nothing to
/// nothing); pocket P, whose board holds ledger N, box C and links J1 (N to C) and J2 (C to nothing).
private struct Yard {
    let l = ShapeID(), m = ShapeID(), b = ShapeID(), k1 = ShapeID(), k2 = ShapeID(), k3 = ShapeID(), k4 = ShapeID(), k5 = ShapeID()
    let p = ShapeID(), n = ShapeID(), c = ShapeID(), j1 = ShapeID(), j2 = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }

    func file(frozen: Set<ShapeID> = []) -> CanvasFile {
        func shape(_ record: AnyShapeRecord) -> AnyShapeRecord {
            var record = record
            if frozen.contains(record.id) { record[Frozen.self] = true }
            return record
        }
        return CanvasFile(root: board(shape(ledger(l)), shape(ledger(m, x: 100)), shape(box(b, x: 200)), shape(link(k1, l, b)), shape(link(k2, m, l)),
                                      shape(link(k3, b, m)), shape(link(k4, b, nil)), shape(link(k5, nil, nil)), shape(pocket(p))),
                          children: [p: board(shape(ledger(n)), shape(box(c, x: 100)), shape(link(j1, n, c)), shape(link(j2, c, nil)))])
    }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = [], refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin(), LedgersPlugin(), FreezingPlugin(log: refusals)] + more, file: file)
}

@MainActor private func ids(_ h: EditorHarness) -> [ShapeID] { h.editor.document.shapes.map(\.id) }
@MainActor private func linkProps(_ h: EditorHarness, _ id: ShapeID) -> Link? { h.file.record(id)?.typed(as: Link.self)?.props }

@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

private let linkKind: ShapeKind = Link.kind

@MainActor let takingTests = Suite("Shapes that take what is bound to them", [
    test("deleting a ledger deletes the links bound to either end; links bound to a box, or to nothing, stay as before") {
        let y = Yard()
        let h = try harness(y.file())
        h.editor.transact("Delete") { $0.delete([y.l]) }
        expectEqual(ids(h), [y.m, y.b, y.k3, y.k4, y.k5, y.p], "K1 (L to B) and K2 (M to L) went with L")
        expectEqual(linkProps(h, y.k3), Link(from: y.b, to: y.m), "a link bound elsewhere is as it was")
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        h.editor.undo()
        let again = try harness(y.file())
        again.editor.transact("Delete") { $0.delete([y.b]) }
        expectEqual(ids(again), [y.l, y.m, y.k1, y.k2, y.k3, y.k4, y.k5, y.p], "a box takes nothing: tldraw's rule, links stay")
        expectEqual(linkProps(again, y.k1), Link(from: y.l, to: nil), "K1 lets go of B where it is drawn")
        expectEqual(linkProps(again, y.k3), Link(from: nil, to: y.m))
        expectEqual(linkProps(again, y.k4), Link(from: nil, to: nil))
        expectEqual(again.editor.document[y.k5]?.typed(as: Link.self)?.props, Link(from: nil, to: nil), "a link bound to nothing is no one's")
    },
    test("two ledgers deleted together take every link bound to them, once; a link asked for as well is not along") {
        let y = Yard()
        let h = try harness(y.file())
        var along: [KindCount] = []
        h.editor.transact("Delete") { tx in
            tx.delete([y.l, y.m, y.k3])
            along = tx.deletedAlong
        }
        expectEqual(ids(h), [y.b, y.k4, y.k5, y.p])
        expectEqual(along, [KindCount(kind: linkKind, count: 2)], "K1 and K2; K3 was asked for")
    },
    test("a read-only link lets go where it is drawn and stays, shaking nothing, and the ledger is deleted") {
        let y = Yard(), refusals = RefusalLog()
        let h = try harness(y.file(frozen: [y.k1]), refusals: refusals)
        var along: [KindCount] = []
        h.editor.transact("Delete") { tx in
            tx.delete([y.l])
            along = tx.deletedAlong
        }
        expectEqual(ids(h), [y.m, y.b, y.k1, y.k3, y.k4, y.k5, y.p], "K2 went; K1 is locked")
        expectEqual(linkProps(h, y.k1), Link(from: nil, to: y.b), "it let go of the ledger, as it lets go of any shape that goes")
        expect(refusals.refusals.isEmpty, "the cascade refuses nothing, so nothing shakes")
        expectEqual(along, [KindCount(kind: linkKind, count: 1)])
    },
    test("a ledger that is locked is not deleted, and takes nothing") {
        let y = Yard(), refusals = RefusalLog()
        let h = try harness(y.file(frozen: [y.l]), refusals: refusals)
        let before = h.file
        h.editor.transact("Delete") { $0.delete([y.l]) }
        try expectFile(h, before, "nothing changed")
        expectEqual(refusals.refusals, [[y.l]], "the ledger shook")
        expect(!h.editor.canUndo, "no step")
    },
    test("undo and redo put the ledger and its links back, and take them again, exactly, in one step") {
        let y = Yard()
        let h = try harness(y.file(frozen: [y.k1]))
        let before = h.file
        h.editor.transact("Delete") { $0.delete([y.l, y.m]) }
        let after = h.file
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        h.editor.undo()
        try expectFile(h, before, "undo")
        expect(!h.editor.canUndo, "one step")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "undo again")
    },
    test("a ledger deleted on a board that isn't shown takes the links there, in the step of the board that is; undo and redo exact") {
        let y = Yard()
        let h = try harness(y.file())
        let before = h.file
        var along: [KindCount] = []
        h.editor.transact("Delete") { tx in
            tx.delete([y.n], on: y.pBoard)
            along = tx.deletedAlong
        }
        expectEqual(h.file[y.pBoard].shapes.map(\.id), [y.c, y.j2], "J1 went with N")
        expectEqual(along, [KindCount(kind: linkKind, count: 1)])
        expectEqual(h.editor.document, board(ledger(y.l), ledger(y.m, x: 100), box(y.b, x: 200), link(y.k1, y.l, y.b), link(y.k2, y.m, y.l),
                                             link(y.k3, y.b, y.m), link(y.k4, y.b, nil), link(y.k5, nil, nil), pocket(y.p)), "the board shown as it was")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        // delete(inFile:) reaches it from the root the same way.
        let again = try harness(y.file())
        again.editor.transact("Delete") { $0.delete(inFile: [y.n]) }
        expectEqual(again.file[y.pBoard].shapes.map(\.id), [y.c, y.j2])
    },
    test("deletedAlong counts what a willDelete handler deleted, on any board, and what a taking kind took, by kind, once each; none for what a board's owner takes with it") {
        let y = Yard()
        // A handler that deletes the box on the pocket's board and the one here when B goes.
        let tidy = Contributor(id: "tidy") { r in
            r.willDelete { ids, tx in
                if ids.contains(y.b) { tx.delete([y.c], on: y.pBoard) }
            }
        }
        let h = try harness(y.file(), [tidy])
        var along: [KindCount] = []
        h.editor.transact("Delete") { tx in
            tx.delete([y.b, y.l])
            along = tx.deletedAlong
        }
        expectEqual(Set(along.map(\.kind)), [linkKind, Box.kind], "links (K2 here; K1 was bound to L and B) and the box the handler took")
        expectEqual(along.first { $0.kind == linkKind }?.count, 2, "K1 and K2")
        expectEqual(along.first { $0.kind == Box.kind }?.count, 1)
        expectEqual(h.file[y.pBoard].shapes.map(\.id), [y.n, y.j1, y.j2])
        // A pocket deleted takes its board's shapes, which nobody counts.
        let owner = try harness(y.file())
        var none: [KindCount] = [KindCount(kind: linkKind, count: 9)]
        owner.editor.transact("Delete") { tx in
            tx.delete([y.p])
            none = tx.deletedAlong
        }
        expectEqual(none, [], "the ledger and links on a deleted pocket's board went with it, not along")
        expectEqual(owner.file.children, [:])
    },
    test("a delete that takes nothing along says so: deletedAlong is empty") {
        let y = Yard()
        let h = try harness(y.file())
        var along: [KindCount] = [KindCount(kind: linkKind, count: 9)]
        h.editor.transact("Delete") { tx in
            tx.delete([y.b, y.k5])
            along = tx.deletedAlong
        }
        expectEqual(along, [])
    },
    test("a body's stepName names the step in place of the transaction's name; a group's name still wins; none leaves it") {
        let y = Yard()
        let h = try harness(y.file())
        h.editor.transact("Delete") { tx in
            tx.delete([y.l])
            tx.stepName = "Delete Ledger and 2 Links"
        }
        expectEqual(h.editor.undoHistory.undoName, "Delete Ledger and 2 Links")
        h.editor.undo()
        h.editor.undoHistory.group("Tidy") {
            h.editor.transact("Delete") { tx in
                tx.delete([y.l])
                tx.stepName = "Delete Ledger and 2 Links"
            }
        }
        expectEqual(h.editor.undoHistory.undoName, "Tidy", "the group's")
        h.editor.undo()
        h.editor.transact("Delete") { tx in
            tx.delete([y.l])
            expectEqual(tx.stepName, nil)
        }
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        // On a board that isn't shown it names its step too.
        h.editor.undo()
        h.editor.transact(on: y.pBoard, "Delete") { tx in
            tx.delete([y.n])
            tx.stepName = "Delete Ledger and Link"
        }
        expectEqual(h.editor.undoHistory.undoName, "Delete Ledger and Link")
    },
    test("takenAlong: the shapes bound only to shapes copied, when one of those takes bound shapes") {
        let y = Yard()
        let h = try harness(y.file())
        let context = h.editor.shapeContext
        expectEqual(context.takenAlong(by: [y.l, y.m]), [y.k2], "K2 (M to L) is bound only to the two")
        expectEqual(context.takenAlong(by: [y.l, y.b]), [y.k1], "K1 (L to B), and L takes")
        expectEqual(Set(context.takenAlong(by: [y.l, y.m, y.b])), [y.k1, y.k2, y.k3], "every link among the three")
        expectEqual(context.takenAlong(by: [y.l]), [], "K1 and K2 are bound to shapes not copied")
        expectEqual(context.takenAlong(by: [y.b]), [], "a box takes nothing: K4 (B to nothing) is left to copy as a link does")
        expectEqual(context.takenAlong(by: [y.b, y.m, y.l, y.k1]), [y.k2, y.k3], "one already among them isn't named again")
        let boxes = try harness(CanvasFile(root: board(box(y.b), box(y.c, x: 100), link(y.k1, y.b, y.c))), [])
        expectEqual(boxes.editor.shapeContext.takenAlong(by: [y.b, y.c]), [], "no taking kind among them, no change to a copy")
    },
])
