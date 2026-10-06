@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Shapes moving off a board that isn't the transaction's (`Transaction.move(_:from:to:)`), onto the board
// shown, across the tree or up it, and shapes restacked on a board that isn't shown
// (`move(_:above:on:)`, `move(_:below:on:)`): what the commit says, what a lock refuses, and that undo
// and redo bring the whole file back exactly. CanvasTesting's pockets and corrals stand in for subboards
// and frames.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID, x: CGFloat = 0, y: CGFloat = 0, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: 40, height: 30)))).copy(as: id, container: container)
}
private func corral(_ id: ShapeID, _ frame: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame))).copy(as: id, container: container)
}
private func pocket(_ id: ShapeID, _ frame: CGRect = unit, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))).copy(as: id, container: container)
}
private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

@MainActor private func harness(_ file: CanvasFile, _ log: ChangeLog = ChangeLog(), _ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), LinksPlugin(), NamingPlugin(), FreezingPlugin(log: refusals),
                                recordingChanges(log)], file: file)
}

@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

@MainActor private func props<P: ShapeProps>(_ h: EditorHarness, _ id: ShapeID, as _: P.Type) -> P? {
    h.file.record(id)?.typed(as: P.self)?.props
}

/// Freezes shapes on a board, shown or not (or thaws them, with `false`), in one step.
@MainActor private func freeze(_ h: EditorHarness, _ shapes: [ShapeID], on board: BoardID, _ frozen: Bool = true) {
    h.editor.transact(on: board, "Freeze") { transaction in
        for id in shapes { transaction.update(id) { $0[Frozen.self] = frozen ? true : nil } }
    }
}

@MainActor let movingOffBoardsTests = Suite("Moving shapes off a board that isn't shown", [
    test("from a pocket's board onto the root, shown: on top of what it holds, added there; the pocket's board changed; undo and redo") {
        let p = ShapeID(), r = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(r, x: 300)), children: [p: board(box(a), box(b, x: 100), box(c, x: 200))]), log)
        let before = h.file, pRevision = h.file.revision(of: pBoard)
        let moved = h.editor.transact("Move") { transaction -> Bool in
            let moved = transaction.move([c, a], from: pBoard, to: .root)
            expectEqual(ids(transaction.document), [p, r, a, c], "the transaction's own document has them on top")
            expectEqual(ids(transaction.contents(of: pBoard)), [b])
            return moved
        }
        expect(moved)
        expectEqual(ids(h.editor.document), [p, r, a, c], "on top, in the order they were")
        expectEqual(ids(h.file[pBoard]), [b])
        expectEqual(h.file.board(containing: a), .root)
        expectEqual(h.file.board(containing: c), .root)
        expectEqual(h.file.record(a)?.box, before.record(a)?.box, "where they were")
        expect(h.file.revision(of: pBoard) > pRevision, "the board they left changed")
        let keys = h.editor.document.shapes.compactMap(\.stackingKey)
        expectEqual(keys, keys.sorted(), "on keys rising above what was there")
        let change = try require(log.changes.last)
        expectEqual(change.added, [a, c], "come to the board shown")
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.elsewhere, [a, c], "gone from the other")
        expect(change.removed.isEmpty && change.changed.isEmpty && change.boardsAdded.isEmpty && change.reordered)
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "every shape where it was")
        expectEqual(log.changes.last?.removed, [a, c])
        h.editor.redo()
        try expectFile(h, after, "and on the root again")
    },
    test("across the tree, from one pocket's board onto another's, neither shown: one commit, each shape on one board; undo and redo") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), b = ShapeID(), y = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100))),
                                       children: [p: board(box(a), box(b, x: 100)), q: board(box(y))]), log)
        let before = h.file, commits = log.changes.count
        expect(h.editor.transact("Move") { $0.move([a], from: pBoard, to: qBoard) })
        expectEqual(ids(h.file[pBoard]), [b])
        expectEqual(ids(h.file[qBoard]), [y, a], "above what it holds")
        expectEqual(h.file.board(containing: a), qBoard)
        expectEqual(log.changes.count, commits + 1)
        let change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [pBoard, qBoard])
        expectEqual(change.elsewhere, [a])
        expect(change.added.isEmpty && change.removed.isEmpty, "the board shown is as it was")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "back on the board it was on")
        h.editor.redo()
        try expectFile(h, after, "and across again")
    },
    test("up the tree, from a pocket's pocket's board onto a new board, the root shown: the board it empties goes, and undo brings it back") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(pocket(q)), q: board(box(a))]), log)
        let before = h.file
        expect(h.editor.transact("Move") { $0.move([a], from: qBoard, to: pBoard) })
        expectEqual(ids(h.file[pBoard]), [q, a])
        expect(h.file.children[q] == nil, "a board with no shapes isn't kept")
        expectEqual(h.file.board(containing: a), pBoard)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "the board back, with its shape")
        h.editor.redo()
        try expectFile(h, after, "and gone again")
    },
    test("a corral moves with what it holds and a pocket with its board; a shape whose corral stays is in none where it lands") {
        let p = ShapeID(), k = ShapeID(), i = ShapeID(), j = ShapeID(), s = ShapeID(), t = ShapeID()
        let pBoard = BoardID(owner: p), sBoard = BoardID(owner: s)
        let h = try harness(CanvasFile(root: board(pocket(p)),
                                       children: [p: board(corral(k, CGRect(x: 0, y: 0, width: 400, height: 300)), box(i, x: 20, y: 20, in: k),
                                                           box(j, x: 100, y: 20, in: k), pocket(s, CGRect(x: 500, y: 0, width: 100, height: 100))),
                                                  s: board(box(t))]))
        let before = h.file
        expect(h.editor.transact("Move") { $0.move([k, j, s], from: pBoard, to: .root) })
        expectEqual(ids(h.editor.document), [p, k, i, j, s], "what the corral holds goes with it, asked for or not")
        expectEqual(h.editor.holder(of: i), k)
        expectEqual(h.editor.holder(of: j), k)
        expectEqual(ids(h.file[sBoard]), [t], "the pocket's board went with it")
        expectEqual(h.file.path(to: sBoard), [.root, sBoard])
        h.editor.undo()
        try expectFile(h, before, "every shape where it was")

        expect(h.editor.transact("Move") { $0.move([j], from: pBoard, to: .root) })
        expectEqual(h.editor.holder(of: j), nil, "its corral stayed")
        expectEqual(h.file[pBoard].container(of: i, containingKinds: h.editor.registry.containingKinds), k)
    },
    test("bindings across the edge let go both ways, locked or not; a binding between shapes that move is kept, and so is a name") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), l1 = ShapeID(), l2 = ShapeID(), l3 = ShapeID(), m = ShapeID()
        let refusals = RefusalLog(), pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p)),
                                       children: [p: board(box(a), box(b, x: 100), box(c, x: 200), link(l1, a, b), link(l2, a, c), link(l3, c, b),
                                                           AnyShapeRecord(ShapeRecord(id: m, Memo(lead: Citation(a)))))]), ChangeLog(), refusals)
        freeze(h, [l2], on: pBoard)
        let before = h.file
        h.editor.transact("Move") { $0.move([a, b, l1, l3], from: pBoard, to: .root) }
        expectEqual(h.file.board(containing: l1), .root)
        expectEqual(h.file.board(containing: l2), pBoard)
        expectEqual(props(h, l1, as: Link.self), Link(from: a, to: b), "between two that move")
        expectEqual(props(h, l3, as: Link.self), Link(from: nil, to: b), "a link that moves lets go of what stays")
        expectEqual(props(h, l2, as: Link.self), Link(from: nil, to: c), "and one that stays of what moves, though it's locked")
        expectEqual(props(h, m, as: Memo.self)?.lead, Citation(a), "a name of a shape on another board is kept")
        expectEqual(refusals.refusals, [], "which is no refusal")
        h.editor.undo()
        try expectFile(h, before, "every end as it was")
    },
    test("a read-only shape among those that move, or the locked owner of the board they'd go onto, refuses all: nothing commits, and it says false") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), f = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100))),
                                       children: [p: board(box(a), box(f, x: 100))]), log, refusals)
        freeze(h, [f], on: pBoard)
        var held = h.file, commits = log.changes.count
        var refused: Set<ShapeID> = []
        let moved = h.editor.transact("Move") { transaction -> Bool in
            let moved = transaction.move([a, f], from: pBoard, to: .root)
            refused = transaction.refusedShapes
            return moved
        }
        expect(!moved)
        expectEqual(refused, [f], "the locked shape among them")
        expectEqual(refusals.refusals.last, [f], "heard")
        expectEqual(h.file, held)
        expectEqual(log.changes.count, commits, "nothing committed")

        freeze(h, [f], on: pBoard, false)
        h.editor.freeze([q])
        held = h.file
        commits = log.changes.count
        expect(!h.editor.transact("Move") { $0.move([a], from: pBoard, to: qBoard) }, "a locked owner takes nothing")
        expectEqual(refusals.refusals.last, [q])
        expectEqual(h.file, held)
        expectEqual(log.changes.count, commits)
    },
    test("off a board, or onto one, the editor couldn't show: false, nothing refused; with nothing of the ids there, true and nothing done") {
        let p = ShapeID(), x = ShapeID(), y = ShapeID(), a = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(x, x: 300)), children: [p: board(box(a)), x: board(box(y))]), log, refusals)
        let before = h.file
        expect(!h.editor.transact { $0.move([y], from: BoardID(owner: x), to: .root) }, "a box owns no board, though the file holds one under it")
        expect(!h.editor.transact { $0.move([a], from: pBoard, to: BoardID(owner: ShapeID())) }, "an owner not in the file")
        expect(h.editor.transact { $0.move([x], from: pBoard, to: .root) }, "a shape that isn't there")
        try expectFile(h, before, "nothing moved")
        expectEqual(log.changes.count, 0)
        expectEqual(refusals.refusals, [])
    },
    test("moved off the board shown and back in one transaction: changed there, not added; the board it passed through as it was") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(b, x: 100)), children: [p: board(box(ShapeID()))]), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            expect(transaction.move([a], to: pBoard))
            expect(transaction.move([a], from: pBoard, to: .root))
        }
        expectEqual(ids(h.editor.document), [p, b, a], "back, on top")
        expectEqual(h.file[pBoard], before[pBoard])
        let change = try require(log.changes.last)
        expectEqual(change.changed, [a])
        expect(change.added.isEmpty && change.removed.isEmpty)
        h.editor.undo()
        try expectFile(h, before, "where it was in the stack")
    },
    test("moved off a board, then moved and put down where it lands, in one step: into a corral it lands mostly inside") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), corral(k, CGRect(x: 400, y: 0, width: 300, height: 200))),
                                       children: [p: board(box(a))]), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            expect(transaction.move([a], from: pBoard, to: .root))
            transaction.translate([a], by: CGPoint(x: 420, y: 20))
            _ = transaction.settle([a])
        }
        expectEqual(h.file.record(a)?.box?.origin, CGPoint(x: 420, y: 20))
        expectEqual(h.editor.holder(of: a), k, "in the corral it landed in")
        expectEqual(log.changes.count, 1, "one commit")
        h.editor.undo()
        try expectFile(h, before, "back on its board")
    },
])

@MainActor let restackingOnBoardsTests = Suite("Restacking shapes on a board that isn't shown", [
    test("above and below another shape there, a corral with what it holds; one step, whose undo puts the file back") {
        let p = ShapeID(), a = ShapeID(), k = ShapeID(), i = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p)),
                                       children: [p: board(box(a), corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(i, x: 20, y: 20, in: k),
                                                           box(b, x: 400), box(c, x: 500))]), log)
        let before = h.file
        h.editor.transact("Reorder") { transaction in
            transaction.move(a, above: c, on: pBoard)
            expectEqual(ids(transaction.contents(of: pBoard)), [k, i, b, c, a])
            transaction.move(k, below: b, on: pBoard)
        }
        expectEqual(ids(h.file[pBoard]), [k, i, b, c, a], "the corral and what it holds already just below b")
        h.editor.transact("Reorder") { $0.move(k, above: c, on: pBoard) }
        expectEqual(ids(h.file[pBoard]), [b, c, k, i, a], "the corral takes what it holds along")
        let change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.elsewhere, [k, i])
        h.editor.undo()
        h.editor.undo()
        try expectFile(h, before, "as it was")
    },
    test("a read-only shape there isn't restacked, and is heard refused; on the board shown it's move(_:above:)") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), x = ShapeID(), y = ShapeID(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(x), box(y, x: 100)), children: [p: board(box(a), box(b, x: 100))]), ChangeLog(), refusals)
        freeze(h, [a], on: pBoard)
        let held = h.file
        h.editor.transact("Reorder") { $0.move(a, above: b, on: pBoard) }
        expectEqual(h.file, held)
        expectEqual(refusals.refusals.last, [a])
        h.editor.transact("Reorder") { $0.move(x, above: y, on: .root) }
        expectEqual(ids(h.editor.document), [p, y, x])
    },
])
