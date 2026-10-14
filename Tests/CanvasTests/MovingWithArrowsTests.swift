@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A shape that binds (a link, as an arrow does) only to shapes that move, moves with them
// (`Transaction.move(_:to:)`), named or not; one bound to anything that stays lets go, as it always did,
// and a locked one stays and lets go with no refusal. CanvasTesting's pockets and links stand in for
// subboards and arrows.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: 0, width: 40, height: 30))))
}
private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?, frozen: Bool = false) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
    if frozen { record[Frozen.self] = true }
    return record
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

@MainActor private func harness(_ file: CanvasFile, _ refusals: RefusalLog = RefusalLog(), _ log: ChangeLog = ChangeLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin(), FreezingPlugin(log: refusals), recordingChanges(log)], file: file)
}

@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

@MainActor private func ends(_ h: EditorHarness, _ id: ShapeID) -> Link? { h.file.record(id)?.typed(as: Link.self)?.props }

/// A root holding boxes M, N and Z, pocket P, and links: L between M and N, LZ between M and Z, LF from M
/// to nothing, and a frozen LK between M and N. P's board holds box B.
private struct Island {
    let m = ShapeID(), n = ShapeID(), z = ShapeID(), p = ShapeID(), b = ShapeID()
    let l = ShapeID(), lz = ShapeID(), lf = ShapeID(), lk = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var file: CanvasFile {
        CanvasFile(root: board(box(m), box(n, x: 100), box(z, x: 200), AnyShapeRecord(ShapeRecord(id: p, Pocket(unit))),
                               link(l, m, n), link(lz, m, z), link(lf, m, nil), link(lk, m, n, frozen: true)),
                   children: [p: board(box(b))])
    }
}

@MainActor let movingWithArrowsTests = Suite("Moving with its arrows", [
    test("a link between two shapes that move rides along, bound, though it isn't named; one bound to one that moves and one that stays lets go; one free at its other end rides along") {
        let isle = Island(), log = ChangeLog()
        let h = try harness(isle.file, RefusalLog(), log)
        let before = h.file
        let moved = h.editor.transact("Move") { $0.move([isle.m, isle.n], to: isle.pBoard) }
        expect(moved)
        expectEqual(h.file.board(containing: isle.l), isle.pBoard, "the link between them went")
        expectEqual(ends(h, isle.l), Link(from: isle.m, to: isle.n), "bound as it was")
        expectEqual(h.file.board(containing: isle.lf), isle.pBoard, "so did the one free at its other end")
        expectEqual(ends(h, isle.lf), Link(from: isle.m, to: nil))
        expectEqual(h.file.board(containing: isle.lz), .root, "the one bound to a shape that stays stays")
        expectEqual(ends(h, isle.lz), Link(from: nil, to: isle.z), "and lets go of the one that moved")
        let change = try require(log.changes.last)
        expect(change.removed.isSuperset(of: [isle.l, isle.lf]), "gone from the board shown")
        expect(change.elsewhere.isSuperset(of: [isle.l, isle.lf]), "and on the other")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo puts all of it back, every end as it was")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")
    },
    test("a locked link bound only to shapes that move stays, and lets go: no refusal") {
        let isle = Island(), refusals = RefusalLog()
        let h = try harness(isle.file, refusals)
        let before = h.file
        let moved = h.editor.transact("Move") { tx -> Bool in
            let moved = tx.move([isle.m, isle.n], to: isle.pBoard)
            expectEqual(tx.refusedShapes, [], "never a refusal for a link")
            return moved
        }
        expect(moved)
        expectEqual(h.file.board(containing: isle.lk), .root, "it stays")
        expectEqual(ends(h, isle.lk), Link(from: nil, to: nil), "and lets go through its lock, as before")
        expect(refusals.refusals.isEmpty)
        h.editor.undo()
        try expectFile(h, before, "undo")
    },
    test("move(_:from:to:) from a board that isn't shown takes the link along too") {
        let m = ShapeID(), n = ShapeID(), z = ShapeID(), l = ShapeID(), lz = ShapeID(), p = ShapeID()
        let file = CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: p, Pocket(unit)))),
                              children: [p: board(box(m), box(n, x: 100), box(z, x: 200), link(l, m, n), link(lz, n, z))])
        let h = try harness(file)
        let before = h.file
        let moved = h.editor.transact("Move") { $0.move([m, n], from: BoardID(owner: p), to: .root) }
        expect(moved)
        expectEqual(h.file.board(containing: l), .root, "the link came onto the board shown")
        expectEqual(ends(h, l), Link(from: m, to: n))
        expectEqual(h.file.board(containing: lz), BoardID(owner: p))
        expectEqual(ends(h, lz), Link(from: nil, to: z))
        h.editor.undo()
        try expectFile(h, before, "undo")
        expect(!h.editor.canUndo)
    },
    test("a link named with its shapes moves once; one bound to a single shape that moves goes with it, the others let go") {
        let isle = Island()
        let h = try harness(isle.file)
        let before = h.file
        h.editor.transact("Move") { $0.move([isle.m, isle.n, isle.l], to: isle.pBoard) }
        expectEqual(h.file.board(containing: isle.l), isle.pBoard)
        expectEqual(ends(h, isle.l), Link(from: isle.m, to: isle.n))
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.transact("Move") { $0.move([isle.m], to: isle.pBoard) }
        expectEqual(h.file.board(containing: isle.lf), isle.pBoard, "bound to the one that moved, and only to it")
        expectEqual(ends(h, isle.lf), Link(from: isle.m, to: nil))
        expectEqual(ends(h, isle.l), Link(from: nil, to: isle.n), "bound to one that stays: let go")
        expectEqual(ends(h, isle.lz), Link(from: nil, to: isle.z))
    },
    test("what a move took along without being asked is named (rodeAlong): the link between the shapes and the one free at its other end, not the one bound to what stays, nor the locked one; the same off a board that isn't shown") {
        let isle = Island()
        let h = try harness(isle.file)
        h.editor.transact("Move") { tx in
            expectEqual(tx.rodeAlong, [], "before anything moves")
            _ = tx.move([isle.m, isle.n], to: isle.pBoard)
            expectEqual(tx.rodeAlong, [isle.l, isle.lf])
        }
        let m = ShapeID(), n = ShapeID(), l = ShapeID(), p = ShapeID()
        let file = CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: p, Pocket(unit)))), children: [p: board(box(m), box(n, x: 100), link(l, m, n))])
        let g = try harness(file)
        g.editor.transact("Move") { tx in
            _ = tx.move([m, n], from: BoardID(owner: p), to: .root)
            expectEqual(tx.rodeAlong, [l])
        }
    },
    test("a link bound only to a link that rides along stays and lets go of it, whichever is lower in the stack") {
        @MainActor func run(linkFirst: Bool) throws -> (BoardID?, Link?) {
            let m = ShapeID(), n = ShapeID(), l1 = ShapeID(), l2 = ShapeID(), p = ShapeID()
            let first = link(l1, m, n), second = link(l2, l1, nil)
            let pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(unit)))
            let root = linkFirst ? board(box(m), box(n, x: 100), first, second, pocket) : board(box(m), box(n, x: 100), second, first, pocket)
            let h = try harness(CanvasFile(root: root))
            let before = h.file
            h.editor.transact("Move") { _ = $0.move([m, n], to: BoardID(owner: p)) }
            expectEqual(h.file.board(containing: l1), BoardID(owner: p), "the link between the two went")
            let after = h.file
            h.editor.undo()
            try expectFile(h, before, "undo")
            h.editor.redo()
            try expectFile(h, after, "redo")
            return (h.file.board(containing: l2), ends(h, l2))
        }
        for linkFirst in [true, false] {
            let result = try run(linkFirst: linkFirst)
            expectEqual(result.0, .root, "it stays (the link it is bound to is \(linkFirst ? "below" : "above") it)")
            expectEqual(result.1, Link(from: nil, to: nil), "and lets go of the link that moved")
        }
    },
    test("onto the board shown from another, with a link that rides along and a locked one that stays: the commit names what came, the paint order follows, a locked link named in the move refuses it whole; undo and redo exact") {
        let m = ShapeID(), n = ShapeID(), l = ShapeID(), p = ShapeID(), k = ShapeID()
        let log = ChangeLog(), refusals = RefusalLog()
        let file = CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: p, Pocket(unit)))),
                              children: [p: board(box(m), box(n, x: 100), link(l, m, n), link(k, m, n, frozen: true))])
        let h = try harness(file, refusals, log)
        let before = h.file
        _ = h.editor.paintOrder()
        let moved = h.editor.transact("Move") { $0.move([m, n], from: BoardID(owner: p), to: .root) }
        expect(moved)
        let change = try require(log.changes.last)
        expectEqual(change.added, [m, n, l])
        expect(change.reordered)
        expectEqual(h.file.board(containing: k), BoardID(owner: p), "the locked link stays")
        expectEqual(ends(h, k), Link(from: nil, to: nil), "and lets go")
        expectEqual(h.editor.paintOrder().map(\.id), h.editor.document.shapes.map(\.id), "painted is what is on the board")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        let named = h.editor.transact("Move") { $0.move([m, n, k], from: BoardID(owner: p), to: .root) }
        expect(!named, "a locked link named in the move refuses it")
        try expectFile(h, before, "nothing moved")
    },
])
