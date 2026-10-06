@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Shapes moving from a transaction's board onto any other board of the file (`Transaction.move(_:to:)`),
// and put down there by the in-or-out rule (`Transaction.settle(_:on:)`), with CanvasTesting's pockets
// and corrals standing in for subboards and frames: up, down and across the tree, what the commit
// says, what a lock refuses, and that undo and redo bring the whole file back exactly.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)
/// A corral 400 × 300 at (100, 100): edges x 100…500, y 100…400.
private let pen = CGRect(x: 100, y: 100, width: 400, height: 300)

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

@MainActor private func plugins(_ log: ChangeLog, _ refusals: RefusalLog) -> [any CanvasPlugin] {
    [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), LinksPlugin(), NamingPlugin(), FreezingPlugin(log: refusals), recordingChanges(log)]
}

/// An editor of `file`, with every change set and refusal services hear kept.
@MainActor private func harness(_ file: CanvasFile, _ log: ChangeLog = ChangeLog(), _ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: plugins(log, refusals), file: file)
}

/// The file, and the file as a board file's bytes: what a round trip must come back to.
@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

/// A shape's props, wherever it is in the file.
@MainActor private func props<P: ShapeProps>(_ h: EditorHarness, _ id: ShapeID, as _: P.Type) -> P? {
    h.file.record(id)?.typed(as: P.self)?.props
}

/// Freezes shapes on a board, shown or not (or thaws them, with `false`), in one step.
@MainActor private func freeze(_ h: EditorHarness, _ shapes: [ShapeID], on board: BoardID, _ frozen: Bool = true) {
    h.editor.transact(on: board, "Freeze") { transaction in
        for id in shapes { transaction.update(id) { $0[Frozen.self] = frozen ? true : nil } }
    }
}

/// The container a shape is in on a board of the file, as the core goes by it.
@MainActor private func holder(_ h: EditorHarness, of id: ShapeID, on board: BoardID) -> ShapeID? {
    h.file[board].container(of: id, containingKinds: h.editor.registry.containingKinds)
}

@MainActor let movingAcrossBoardsTests = Suite("Moving shapes onto any board", [
    test("from the root onto a pocket's pocket's board: under their ids, in their order, where they were; the commit says so, and so do undo and redo") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p), box(a), box(b, x: 100), box(c, x: 200)), children: [p: board(pocket(q))]), log)
        let before = h.file, pBoard = BoardID(owner: p), qBoard = BoardID(owner: q), pRevision = h.file.revision(of: pBoard)
        let moved = h.editor.transact("Move") { transaction -> Bool in
            let moved = transaction.move([c, a], to: qBoard)
            expectEqual(ids(transaction.contents(of: qBoard)), [a, c], "the transaction sees them there")
            expectEqual(transaction.contents(of: .root), transaction.document, "and its own board as its document")
            expectEqual(transaction.document[a], nil)
            return moved
        }
        expect(moved)
        expectEqual(ids(h.editor.document), [p, b])
        expectEqual(ids(h.file[qBoard]), [a, c], "in the order they were, not the order asked for")
        expectEqual(h.file.record(a)?.box, before.record(a)?.box, "where they were")
        expectEqual(h.file.board(containing: a), qBoard)
        expectEqual(h.file.board(containing: c), qBoard)
        expectEqual(h.file.path(to: qBoard), [.root, pBoard, qBoard])
        expectEqual(h.file[pBoard], before[pBoard], "the board between is as it was")
        expectEqual(h.file.revision(of: pBoard), pRevision)
        expect(h.file.revision(of: qBoard) > pRevision, "and the board made has a revision of its own")
        let keys = h.file[qBoard].shapes.compactMap(\.stackingKey)
        expect(keys.count == 2 && keys[0] < keys[1], "on keys of their own, rising")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [a, c])
        expectEqual(change.boardsAdded, [qBoard])
        expectEqual(change.boardsChanged, [])
        expectEqual(change.elsewhere, [a, c])
        expect(change.added.isEmpty && change.changed.isEmpty && change.boardsRemoved.isEmpty && change.reordered)
        let after = h.file
        expectEqual(h.editor.undoHistory.undoName, "Move")

        h.editor.undo()
        try expectFile(h, before, "every shape where it was")
        expectEqual(log.changes.last?.added, [a, c])
        expectEqual(log.changes.last?.boardsRemoved, [qBoard], "the board the move made goes")
        h.editor.redo()
        try expectFile(h, after, "and on the board again")
        expect(h.enter(p) && h.enter(q))
        expectEqual(ids(h.editor.document), [a, c])
    },
    test("from a pocket's board onto the root: on top of what the root holds, the root changed; the step is the board shown's") {
        let p = ShapeID(), r = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(r, x: 300)), children: [p: board(box(a), box(b, x: 100), box(c, x: 200))]), log)
        expect(h.enter(p))
        let before = h.file, rootRevision = h.file.revision(of: .root), pRevision = h.file.revision(of: pBoard)
        h.editor.transact("Move") { transaction in
            expect(transaction.move([b], to: .root))
            expectEqual(ids(transaction.contents(of: .root)), [p, r, b])
        }
        expectEqual(ids(h.editor.document), [a, c])
        expectEqual(ids(h.file.root), [p, r, b], "on top")
        expectEqual(h.file.root[p], before.root[p], "what it held is as it was")
        expectEqual(h.file.root[r], before.root[r])
        let keys = h.file.root.shapes.compactMap(\.stackingKey)
        expect(keys.count == 3 && keys == keys.sorted(), "on keys that rise")
        expectEqual(h.file.board(containing: b), .root)
        expect(h.file.revision(of: .root) > rootRevision && h.file.revision(of: pBoard) > pRevision, "both boards have new revisions")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [b])
        expectEqual(change.boardsChanged, [.root], "the root is changed, never added")
        expectEqual(change.boardsAdded, [])
        expectEqual(change.elsewhere, [b], "only what came")
        let after = h.file

        expect(h.editor.showBoard(.root))
        h.editor.undo()
        expectEqual(h.editor.board, pBoard, "undoing it shows the board it was made on")
        try expectFile(h, before, "the root as it was")
        expectEqual(log.changes.last?.boardsChanged, [.root])
        expectEqual(log.changes.last?.added, [b])
        h.editor.redo()
        try expectFile(h, after, "and with it again")
    },
    test("from inside a pocket onto a sibling pocket's board that holds shapes: above them, and the commit says the board changed") {
        let p = ShapeID(), s = ShapeID(), a = ShapeID(), b = ShapeID(), x = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), sBoard = BoardID(owner: s)
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(s, CGRect(x: 200, y: 0, width: 100, height: 100))),
                                       children: [p: board(box(a), box(b, x: 100)), s: board(box(x, x: 300))]), log)
        expect(h.enter(p))
        let before = h.file, revision = h.file.revision(of: sBoard)
        h.editor.transact("Move") { $0.move([b, a], to: sBoard) }
        expectEqual(ids(h.editor.document), [])
        expectEqual(ids(h.file[sBoard]), [x, a, b])
        expectEqual(h.file[sBoard][x], before[sBoard][x], "what it held is as it was")
        let keys = h.file[sBoard].shapes.compactMap(\.stackingKey)
        expect(keys.count == 3 && keys == keys.sorted(), "on keys that rise")
        expect(h.file.revision(of: sBoard) > revision)
        expectEqual(h.file.board(containing: a), sBoard)
        expectEqual(h.file.children[p], nil, "the board left empty isn't kept")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [a, b])
        expectEqual(change.boardsChanged, [sBoard])
        expectEqual(change.boardsAdded, [])
        expectEqual(change.elsewhere, [a, b])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
        expectEqual(h.editor.board, pBoard)
        h.editor.redo()
        try expectFile(h, after, "and moved again")
    },
    test("a corral moves with what it holds, at any depth; a pocket takes its board along, which is under the board it moved onto") {
        let p = ShapeID(), r = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), q = ShapeID(), d = ShapeID(), c = ShapeID()
        let log = ChangeLog(), pBoard = BoardID(owner: p), rBoard = BoardID(owner: r), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p), corral(k, CGRect(x: 0, y: 200, width: 600, height: 400)), box(a, x: 20, y: 220, in: k),
                                                   corral(l, CGRect(x: 100, y: 250, width: 300, height: 200), in: k), box(b, x: 120, y: 270, in: l),
                                                   pocket(q, CGRect(x: 700, y: 0, width: 100, height: 100)), box(c, x: 800)),
                                       children: [p: board(pocket(r)), q: board(box(d))]), log)
        let before = h.file, kinds = h.editor.registry.containingKinds

        h.editor.transact("Move") { $0.move([k], to: rBoard) }
        expectEqual(ids(h.editor.document), [p, q, c])
        expectEqual(ids(h.file[rBoard]), [k, a, l, b], "the corral, and what it holds, at any depth")
        expectEqual(h.file[rBoard].shapes.map(\.container), [nil, k, k, l])
        expectEqual(h.file[rBoard].contents(of: k, containingKinds: kinds), [a, l])
        expectEqual(log.changes.last?.removed, [k, a, l, b])
        expectEqual(log.changes.last?.elsewhere, [k, a, l, b])
        h.editor.undo()
        try expectFile(h, before, "all of it in the corral again")

        h.editor.transact("Move") { $0.move([q], to: rBoard) }
        expectEqual(h.file.board(containing: q), rBoard)
        expectEqual(h.file[qBoard], before[qBoard], "its board is as it was")
        expectEqual(h.file.board(containing: d), qBoard)
        expectEqual(h.file.path(to: qBoard), [.root, pBoard, rBoard, qBoard])
        let change = try require(log.changes.last)
        expectEqual(change.boardsAdded, [rBoard], "the board it owns isn't one the commit reached")
        expectEqual(change.elsewhere, [q])
        expect(h.enter(p) && h.enter(r) && h.enter(q))
        expectEqual(ids(h.editor.document), [d])
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        try expectFile(h, before, "the pocket on the root, with its board")
    },
    test("a binding between shapes that move is kept; one across the edge lets go of that end, whichever way, locked or not; a name is kept") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), l1 = ShapeID(), l2 = ShapeID(), l3 = ShapeID(), m = ShapeID()
        let refusals = RefusalLog(), pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p)),
                                       children: [p: board(box(a), box(b, x: 100), box(c, x: 200), link(l1, a, b), link(l2, a, c), link(l3, c, b),
                                                           AnyShapeRecord(ShapeRecord(id: m, Memo(lead: Citation(a)))))]), ChangeLog(), refusals)
        expect(h.enter(p))
        h.editor.freeze([l2])
        let before = h.file
        h.editor.transact("Move") { $0.move([a, b, l1, l3], to: .root) }
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
    test("a read-only shape among those that move, a locked owner on another board, or an owner in a locked corral there, refuses all") {
        let p = ShapeID(), a = ShapeID(), f = ShapeID(), k = ShapeID(), q = ShapeID(), s = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q), sBoard = BoardID(owner: s)
        let h = try harness(CanvasFile(root: board(pocket(p), box(a, x: 200), box(f, x: 300)),
                                       children: [p: board(corral(k, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                           pocket(q, CGRect(x: 20, y: 20, width: 100, height: 100), in: k),
                                                           pocket(s, CGRect(x: 700, y: 0, width: 100, height: 100)))]), log, refusals)
        @MainActor func attempt(_ ids: Set<ShapeID>, to target: BoardID) -> (moved: Bool, refused: Set<ShapeID>) {
            var result = (moved: true, refused: Set<ShapeID>())
            h.editor.transact("Move") { transaction in
                result.moved = transaction.move(ids, to: target)
                result.refused = transaction.refusedShapes
            }
            return result
        }
        h.editor.freeze([f])
        var held = h.file, commits = log.changes.count
        var result = attempt([a, f], to: sBoard)
        expect(!result.moved)
        expectEqual(result.refused, [f], "a locked shape among them")
        expectEqual(refusals.refusals, [[f]], "heard")
        expectEqual(h.file, held)
        expectEqual(log.changes.count, commits, "nothing committed")

        h.editor.freeze([f], false)
        freeze(h, [s], on: pBoard)
        held = h.file
        commits = log.changes.count
        result = attempt([a], to: sBoard)
        expect(!result.moved)
        expectEqual(result.refused, [s], "a locked owner on another board takes nothing")
        expectEqual(refusals.refusals.last, [s])
        expectEqual(h.file, held)
        expectEqual(log.changes.count, commits)

        freeze(h, [s], on: pBoard, false)
        freeze(h, [k], on: pBoard)
        held = h.file
        result = attempt([a], to: qBoard)
        expect(!result.moved)
        expectEqual(result.refused, [q], "an owner in a locked corral on its board is held as the corral holds it")
        expectEqual(refusals.refusals.last, [q])
        expectEqual(h.file, held)
        expect(h.file.children[q] == nil, "no board was made")

        freeze(h, [k], on: pBoard, false)
        result = attempt([a], to: qBoard)
        expect(result.moved, "and unlocked it takes them")
        expectEqual(result.refused, [])
        expectEqual(ids(h.file[qBoard]), [a])
    },
    test("onto a board the editor couldn't show once the transaction commits, nothing moves, nothing is refused, and it says false") {
        let json = """
        { "format" : 3, "versions" : { "kinds" : { "box" : 0 } }, "shapes" : [
          { "id" : "00000000-0000-0000-0000-000000000001", "kind" : "gadget", "index" : "a0", "props" : { } }
        ] }
        """
        let log = ChangeLog(), refusals = RefusalLog()
        let loaded = try BoardCodec(registry: try Registry(plugins: plugins(log, refusals))).decode(Data(json.utf8))
        let gadget = try require(loaded.document.shapes.first)
        expect(gadget.isOpaque)
        let p = ShapeID(), e = ShapeID(), k = ShapeID(), x = ShapeID(), y = ShapeID(), g = ShapeID(), a = ShapeID()
        let h = try harness(CanvasFile(root: CanvasDocument(shapes: [gadget, pocket(p), pocket(e, CGRect(x: 200, y: 0, width: 100, height: 100)),
                                                                     corral(k, CGRect(x: 400, y: 0, width: 300, height: 200)), box(x, x: 800), box(a, x: 900)]),
                                       children: [gadget.id: board(box(g)), x: board(pocket(y))]), log, refusals)
        let before = h.file
        for (target, why) in [(BoardID(owner: ShapeID()), "an owner not in the file"), (BoardID(owner: gadget.id), "an owner kept aside"),
                              (BoardID(owner: x), "a box owns no board, though the file holds one under it"),
                              (BoardID(owner: y), "under a board it can't show")] {
            let moved = h.editor.transact("Move") { $0.move([a], to: target) }
            expect(!moved, why)
            expect(!h.editor.transact { $0.move([], to: target) }, "\(why), with nothing to move")
        }
        expect(h.editor.transact { $0.move([], to: BoardID(owner: p)) }, "with nothing to move onto a board it can show, nothing to say no to")
        try expectFile(h, before, "nothing moved")
        expectEqual(log.changes.count, 0, "nothing committed")
        expect(!h.editor.canUndo)

        h.editor.transact("Move") { transaction in
            expect(transaction.turn(e, into: Box(CGRect(x: 200, y: 0, width: 100, height: 100))))
            expect(!transaction.move([a], to: BoardID(owner: e)), "a pocket turned into a box in the same transaction owns no board")
        }
        expectEqual(h.file.record(e)?.kind, Box.kind, "the turn stands")
        expectEqual(h.file.board(containing: a), .root)
        expectEqual(h.file.children.count, 2, "no board was made")
        expectEqual(refusals.refusals, [])

        h.editor.transact("Turn into Pocket") { transaction in
            expect(transaction.turn(k, into: Pocket(CGRect(x: 400, y: 0, width: 240, height: 160))))
            expect(transaction.move([a], to: BoardID(owner: k)), "a corral turned into a pocket in the same transaction owns one")
        }
        expectEqual(ids(h.file[BoardID(owner: k)]), [a])
    },
    test("two moves in one transaction onto two boards, one under a pocket the other move took: one commit, one step") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), b = ShapeID(), x = ShapeID(), y = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), qBoard = BoardID(owner: q)
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(q, CGRect(x: 200, y: 0, width: 100, height: 100)), box(a, x: 400), box(b, x: 500)),
                                       children: [p: board(box(x)), q: board(box(y))]), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            expect(transaction.move([q], to: pBoard))
            expect(transaction.move([a], to: qBoard), "Q, under P as the transaction leaves the file")
            expect(transaction.move([b], to: pBoard))
            expectEqual(ids(transaction.contents(of: pBoard)), [x, q, b])
            expectEqual(ids(transaction.contents(of: qBoard)), [y, a])
            transaction.delete([b])
            expectEqual(ids(transaction.contents(of: pBoard)), [x, q, b], "b moved off this board before")
        }
        expectEqual(ids(h.editor.document), [p])
        expectEqual(ids(h.file[pBoard]), [x, q, b])
        expectEqual(ids(h.file[qBoard]), [y, a])
        expectEqual(h.file.path(to: qBoard), [.root, pBoard, qBoard])
        let change = try require(log.changes.last)
        expectEqual(change.removed, [q, a, b])
        expectEqual(change.boardsChanged, [pBoard, qBoard])
        expectEqual(change.elsewhere, [q, a, b])
        expectEqual(log.changes.count, 1, "one commit")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "one step")
        h.editor.redo()
        try expectFile(h, after, "and again")
    },
    test("a shape not over a board it moved shapes onto can still be deleted in the same transaction") {
        let p = ShapeID(), q = ShapeID(), s = ShapeID(), a = ShapeID(), b = ShapeID(), z = ShapeID(), log = ChangeLog()
        let qBoard = BoardID(owner: q), sBoard = BoardID(owner: s)
        let h = try harness(CanvasFile(root: board(pocket(p), pocket(s, CGRect(x: 200, y: 0, width: 100, height: 100)), box(a, x: 400), box(b, x: 500)),
                                       children: [p: board(pocket(q)), s: board(box(z))]), log)
        h.editor.transact("Move") { transaction in
            expect(transaction.move([a], to: qBoard))
            transaction.delete([b, s])
        }
        expectEqual(ids(h.editor.document), [p])
        expectEqual(ids(h.file[qBoard]), [a])
        expectEqual(h.file.record(z), nil, "the deleted pocket's board went with it")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [a, b, s])
        expectEqual(change.boardsAdded, [qBoard])
        expectEqual(change.boardsRemoved, [sBoard])
        expectEqual(change.elsewhere, [a, z])
    },
    test("a transaction on a board that isn't shown moves shapes onto any board but the one shown") {
        let p = ShapeID(), s = ShapeID(), a = ShapeID(), b = ShapeID(), z = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p), sBoard = BoardID(owner: s)
        let file = CanvasFile(root: board(pocket(p), pocket(s, CGRect(x: 200, y: 0, width: 100, height: 100))),
                              children: [p: board(box(a), box(b, x: 100)), s: board(box(z))])
        let h = try harness(file, log)
        expect(h.enter(s))
        let before = h.file, shown = h.editor.document
        expectEqual(h.editor.transact(on: pBoard, "Move") { $0.move([a], to: .root) }, true)
        expectEqual(h.editor.board, sBoard)
        expectEqual(h.editor.document, shown, "the board shown is as it was")
        expectEqual(ids(h.file.root), [p, s, a])
        expectEqual(ids(h.file[pBoard]), [b])
        let change = try require(log.changes.last)
        expectEqual(change.shapeIDs, [])
        expectEqual(change.boardsChanged, [pBoard, .root])
        expectEqual(change.elsewhere, [a])
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.board, pBoard, "its board is shown for the step")
        try expectFile(h, before, "A back on P's board")

        let again = try harness(file, log)
        let start = again.file, heard = log.changes.count
        expectEqual(again.editor.transact(on: pBoard, "Move") { $0.move([a], to: .root) }, true, "the body's result comes back")
        expectEqual(again.file, start, "onto the board shown: nothing")
        expectEqual(log.changes.count, heard)
        expect(!again.editor.canUndo)
    },
])

@MainActor let settlingAcrossBoardsTests = Suite("Settling shapes on another board", [
    test("a shape moved where it lands mostly inside a corral goes into it there, nudged fully in; the commit says so") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), box(a, x: 476, y: 150)), children: [p: board(corral(k, pen))]), log)   // 60% in
        let before = h.file
        let settled = h.editor.transact("Move") { transaction -> Settlement in
            expect(transaction.move([a], to: pBoard))
            let settled = transaction.settle([a], on: pBoard)
            expectEqual(transaction.contents(of: pBoard).container(of: a, containingKinds: h.editor.registry.containingKinds), k)
            return settled
        }
        expectEqual(settled, .settled(nudges: [a: CGPoint(x: -32, y: 0)]), "to the gap inside the edge it hung over")
        expectEqual(h.file.record(a)?.box?.origin, CGPoint(x: 444, y: 150))
        expectEqual(holder(h, of: a, on: pBoard), k)
        expectEqual(ids(h.file[pBoard]), [k, a])
        let change = try require(log.changes.last)
        expectEqual(change.removed, [a])
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.elsewhere, [a])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "where it was, on the root")
        h.editor.redo()
        try expectFile(h, after, "and in the corral again")
    },
    test("a corral moved there takes in what it lands on there; the commit names what settling changed on that board") {
        let p = ShapeID(), k = ShapeID(), x = ShapeID(), y = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), corral(k, pen)), children: [p: board(box(x, x: 150, y: 150), box(y, x: 700))]), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            expect(transaction.move([k], to: pBoard))
            expectEqual(transaction.settle([k], on: pBoard), .settled(nudges: [:]))
        }
        expectEqual(holder(h, of: x, on: pBoard), k, "the box it landed on is in it")
        expectEqual(holder(h, of: y, on: pBoard), nil)
        expectEqual(ids(h.file[pBoard]), [y, k, x], "raised above it")
        let change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.elsewhere, [k, x], "what came, and what settling there changed")
        h.editor.undo()
        try expectFile(h, before, "the box on its own again")
    },
    test("over a locked corral there it's refused: nothing changes there, services hear it, and throwing leaves no step") {
        struct Refused: Error {}
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), log = ChangeLog(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p)
        let file = CanvasFile(root: board(pocket(p), box(a, x: 150, y: 150)), children: [p: board(corral(k, pen))])
        let h = try harness(file, log, refusals)
        freeze(h, [k], on: pBoard)
        let held = h.file, commits = log.changes.count
        do {
            try h.editor.transact("Move") { transaction in
                expect(transaction.move([a], to: pBoard))
                let settled = transaction.settle([a], on: pBoard)
                expectEqual(settled, .refused(by: k))
                expectEqual(transaction.refusedShapes, [k])
                expectEqual(transaction.contents(of: pBoard).shapes.map(\.container), [nil, nil], "nothing changed there")
                if case .refused = settled { throw Refused() }
            }
            expect(false, "it threw")
        } catch is Refused {}
        expectEqual(h.file, held, "nothing moved")
        expectEqual(log.changes.count, commits, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Freeze", "and no step was made")

        h.editor.transact("Move") { transaction in
            transaction.move([a], to: pBoard)
            transaction.settle([a], on: pBoard)
        }
        expectEqual(refusals.refusals, [[k]], "kept, the refusal is heard")
        expectEqual(h.file.board(containing: a), pBoard)
        expectEqual(holder(h, of: a, on: pBoard), nil, "and the shape is beside the corral, as it landed")
        expectEqual(h.file.record(a)?.box?.origin, CGPoint(x: 150, y: 150))
    },
    test("what the transaction brought there isn't held: a locked shape it inserted and moved is settled, as on its own board") {
        let p = ShapeID(), k = ShapeID(), n = ShapeID()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(corral(k, pen))]))
        let settled = h.editor.transact("Paste") { transaction -> Settlement in
            var record = box(n, x: 476, y: 150)
            record[Frozen.self] = true
            transaction.insert(record)
            expect(transaction.move([n], to: pBoard))
            return transaction.settle([n], on: pBoard)
        }
        expectEqual(settled, .settled(nudges: [n: CGPoint(x: -32, y: 0)]))
        expectEqual(holder(h, of: n, on: pBoard), k)
        expectEqual(h.file.record(n)?[Frozen.self], true)
    },
    test("moved onto a board, then moved there: by as much, what a corral holds with it, in the one step, whose undo puts the file back exactly") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), b = ShapeID(), log = ChangeLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p), corral(k, pen), box(a, x: 150, y: 150, in: k)), children: [p: board(box(b, x: 600))]), log)
        let before = h.file
        h.editor.transact("Move") { transaction in
            expect(transaction.move([k], to: pBoard))
            transaction.translate([k], by: CGPoint(x: 1000, y: 20), on: pBoard)
            expectEqual(transaction.contents(of: pBoard)[k]?.box?.origin, CGPoint(x: 1100, y: 120), "the transaction sees it there")
            expectEqual(transaction.refusedShapes, [])
        }
        expectEqual(ids(h.file[pBoard]), [b, k, a])
        expectEqual(h.file.record(k)?.box?.origin, CGPoint(x: 1100, y: 120))
        expectEqual(h.file.record(a)?.box?.origin, CGPoint(x: 1150, y: 170), "what it holds went with it")
        expectEqual(holder(h, of: a, on: pBoard), k)
        expectEqual(h.file.record(b), before.record(b), "what was there stays")
        let change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [pBoard])
        expectEqual(change.removed, [k, a])
        expectEqual(change.elsewhere, [k, a])
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "where they were, on the root")
        h.editor.redo()
        try expectFile(h, after, "and moved there again")
    },
    test("moved there, a read-only shape that was there stays, refused, as on the board shown; what the transaction brought there isn't held") {
        let p = ShapeID(), b = ShapeID(), refusals = RefusalLog()
        let pBoard = BoardID(owner: p)
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(box(b, x: 600))]), ChangeLog(), refusals)
        freeze(h, [b], on: pBoard)
        let start = h.file
        h.editor.transact { transaction in
            transaction.translate([b], by: CGPoint(x: 10, y: 0), on: pBoard)
            expectEqual(transaction.refusedShapes, [b])
        }
        expectEqual(h.file, start, "it stays")
        expectEqual(refusals.refusals.last, [b])
        h.editor.transact { transaction in
            var record = box(ShapeID(), x: 0, y: 500)
            record[Frozen.self] = true
            transaction.insert(record)
            expect(transaction.move([record.id], to: pBoard))
            transaction.translate([record.id], by: CGPoint(x: 0, y: 100), on: pBoard)
            expectEqual(transaction.contents(of: pBoard)[record.id]?.box?.origin, CGPoint(x: 0, y: 600), "brought there, it moves, locked or not")
        }
    },
    test("on the transaction's own board it's translate(_:by:), and a board the editor can't show moves nothing") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID()
        let file = CanvasFile(root: board(pocket(p), corral(k, pen), box(a, x: 150, y: 150, in: k)))
        let one = try harness(file), other = try harness(file)
        one.editor.transact { $0.translate([k], by: CGPoint(x: 30, y: 40), on: .root) }
        other.editor.transact { $0.translate([k], by: CGPoint(x: 30, y: 40)) }
        expectEqual(one.file, other.file)
        expectEqual(one.file.record(a)?.box?.origin, CGPoint(x: 180, y: 190))

        let log = ChangeLog()
        let h = try harness(file, log)
        let start = h.file
        h.editor.transact { $0.translate([a], by: CGPoint(x: 10, y: 0), on: BoardID(owner: ShapeID())) }
        h.editor.transact { $0.translate([a], by: CGPoint(x: 10, y: 0), on: BoardID(owner: a)) }
        expectEqual(h.file, start)
        expectEqual(log.changes.count, 0)
    },
    test("on the transaction's own board it's settle(_:), and a board the editor can't show settles nothing") {
        let p = ShapeID(), k = ShapeID(), a = ShapeID(), j = ShapeID(), b = ShapeID()
        let pBoard = BoardID(owner: p)
        let file = CanvasFile(root: board(pocket(p), corral(k, pen), box(a, x: 476, y: 150)), children: [p: board(corral(j, pen), box(b, x: 200, y: 380))])
        let one = try harness(file), other = try harness(file)
        let onBoard = one.editor.transact { $0.settle([a], on: .root) }, plain = other.editor.transact { $0.settle([a]) }
        expectEqual(onBoard, plain)
        expectEqual(onBoard, .settled(nudges: [a: CGPoint(x: -32, y: 0)]))
        expectEqual(one.file, other.file)
        expect(one.enter(p) && other.enter(p))
        expectEqual(one.editor.transact { $0.settle([b], on: pBoard) }, other.editor.transact { $0.settle([b]) })
        expectEqual(one.file, other.file, "on a pocket's board shown, too")
        expectEqual(one.editor.holder(of: b), j)

        let log = ChangeLog()
        let h = try harness(file, log)
        let start = h.file
        expectEqual(h.editor.transact { $0.settle([a], on: BoardID(owner: ShapeID())) }, .settled(nudges: [:]))
        expectEqual(h.editor.transact { $0.settle([a], on: BoardID(owner: a)) }, .settled(nudges: [:]), "a box owns no board")
        expectEqual(h.file, start)
        expectEqual(log.changes.count, 0)
    },
])
