@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Shapes deleted on a board that isn't shown (`Transaction.delete(_:on:)`, `delete(inFile:)`), inside the
// step of the board that is: what the commit says, what a handler sees, what a lock refuses, the boards
// that go with an owner, and that undo and redo bring the whole file back exactly. CanvasTesting's
// pockets and links stand in for subboards and arrows.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID, x: CGFloat = 0) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: 0, width: 40, height: 30))))
}
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit))) }
private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding box A, box B and pockets P, W and E (E's board empty). P's board holds box M, box R, link L
/// (M to R), box Z, link L2 (Z to R) and pocket Q. Q's board holds box C. W's holds box D and box D2.
private struct Isles {
    let a = ShapeID(), b = ShapeID(), p = ShapeID(), w = ShapeID(), e = ShapeID()
    let m = ShapeID(), r = ShapeID(), l = ShapeID(), z = ShapeID(), l2 = ShapeID()
    let q = ShapeID(), c = ShapeID(), d = ShapeID(), d2 = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
    var wBoard: BoardID { BoardID(owner: w) }
    var eBoard: BoardID { BoardID(owner: e) }
    var file: CanvasFile { file(frozen: []) }

    func file(frozen: Set<ShapeID>) -> CanvasFile {
        func shape(_ record: AnyShapeRecord) -> AnyShapeRecord {
            var record = record
            if frozen.contains(record.id) { record[Frozen.self] = true }
            return record
        }
        return CanvasFile(root: board(shape(box(a)), shape(box(b, x: 300)), shape(pocket(p)), shape(pocket(w)), shape(pocket(e))),
                          children: [p: board(shape(box(m)), shape(box(r, x: 100)), shape(link(l, m, r)), shape(box(z, x: 200)),
                                              shape(link(l2, z, r)), shape(pocket(q))),
                                     q: board(shape(box(c))),
                                     w: board(shape(box(d)), shape(box(d2, x: 100)))])
    }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = [], refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin(), FreezingPlugin(log: refusals)] + more, file: file)
}

@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

@MainActor private func ids(_ h: EditorHarness, _ board: BoardID) -> [ShapeID] { h.file[board].shapes.map(\.id) }
@MainActor private func x(_ h: EditorHarness, _ id: ShapeID) -> CGFloat? { h.file.record(id)?.box?.minX }

@MainActor private final class Counted {
    var began = 0
}

/// The undo steps a body opens.
@MainActor private func steps(_ h: EditorHarness, _ body: () -> Void) -> Int {
    let counted = Counted()
    h.editor.undoHistory.didChange = { if $0 == .began { counted.began += 1 } }
    defer { h.editor.undoHistory.didChange = { _ in } }
    body()
    return counted.began
}

private struct Refused: Error {}

/// What a handler saw: the board its transaction was on, and the link as it was there.
@MainActor private final class Seen {
    var boards: [BoardID] = []
    var links: [Link?] = []
}

@MainActor private final class Calls {
    var count = 0
}

@MainActor private func slide(_ tx: inout Transaction, _ id: ShapeID, on board: BoardID, to x: CGFloat) {
    tx.update(id, on: board, as: Box.self) { $0.props.frame.origin.x = x }
}

/// The boards the file keeps that no shape owns.
@MainActor private func orphans(_ h: EditorHarness) -> [ShapeID] { h.file.children.keys.filter { h.file.record($0) == nil } }

/// What the editor paints is what is on the board shown, in its order: a paint list kept from before a
/// commit that changed the stack would read past the board's shapes.
@MainActor private func expectPaintsTheBoard(_ h: EditorHarness, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    expectEqual(h.editor.paintOrder().map(\.id), h.editor.document.shapes.map(\.id), message, file: file, line: line)
}

@MainActor let deletingAcrossBoardsTests = Suite("Deleting across boards", [
    test("a link and a box deleted on a pocket's board from the root: one commit, one step, the link on the other end let go; undo and redo exact") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file, rootBefore = h.editor.document
        let count = log.changes.count
        let opened = steps(h) {
            h.editor.transact("Remove") { $0.delete([tree.l, tree.r], on: tree.pBoard) }
        }
        expectEqual(opened, 1, "one step")
        expectEqual(h.editor.undoHistory.undoName, "Remove")
        expectEqual(ids(h, tree.pBoard), [tree.m, tree.z, tree.l2, tree.q], "the two are gone from the pocket's board")
        expectEqual(h.file.record(tree.l2)?.typed(as: Link.self)?.props, Link(from: tree.z, to: nil), "what was bound to the box lets go")
        expectEqual(h.editor.document, rootBefore, "the board shown as it was")
        expectEqual(log.changes.count, count + 1, "one commit")
        let change = try require(log.changes.last)
        expectEqual(change.shapeIDs, [], "no shape of the board shown")
        expectEqual(change.boardsChanged, [tree.pBoard])
        expectEqual(change.elsewhere, [tree.l, tree.r, tree.l2], "what it touched there")
        expect(!change.reordered, "the board shown's stack is as it was")
        expect(change.boardsRemoved.isEmpty && change.boardsAdded.isEmpty)
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "undo puts them back, bound, in their place")
        expectEqual(h.editor.board, .root)
        expect(!h.editor.canUndo)
        h.editor.redo()
        try expectFile(h, after, "redo does it again")
        h.editor.undo()
        try expectFile(h, before, "and back")
    },
    test("from below: the board shown is a pocket's, deleting on the root: one step, and undo stays on the board shown") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        expect(h.enter(tree.p))
        let opened = steps(h) { h.editor.transact("Remove") { $0.delete([tree.a, tree.d], on: .root) } }
        expectEqual(opened, 1)
        expectEqual(ids(h, .root), [tree.b, tree.p, tree.w, tree.e], "A is gone from the root")
        expectEqual(h.file.record(tree.d)?.box?.minX, 0, "D is on a board nothing here named, untouched")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        expectEqual(h.editor.board, tree.pBoard, "the board shown stays")
        h.editor.redo()
        try expectFile(h, after, "redo")
        expectEqual(h.editor.board, tree.pBoard)
    },
    test("a willDelete handler sees the far board as the transaction's board, and the link still bound at both ends") {
        let tree = Isles(), seen = Seen()
        let watching = Contributor(id: "watches") { r in
            r.willDelete { deleted, tx in
                guard deleted.contains(tree.r) else { return }
                seen.boards.append(tx.board)
                seen.links.append(tx.document[tree.l]?.typed(as: Link.self)?.props)
                seen.links.append(tx.document[tree.l2]?.typed(as: Link.self)?.props)
            }
        }
        let h = try harness(tree.file, [watching])
        h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) }
        expectEqual(seen.boards, [tree.pBoard])
        expectEqual(seen.links, [Link(from: tree.m, to: tree.r), Link(from: tree.z, to: tree.r)], "every shape as it was")
        let after = h.file
        h.editor.undo()
        try expectFile(h, tree.file, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a handler that writes a third board and one that writes the board shown: both land, in the one step") {
        let tree = Isles(), log = ChangeLog()
        let writing = Contributor(id: "writer") { r in
            r.willDelete { deleted, tx in
                guard deleted.contains(tree.r) else { return }
                tx.update(tree.d, on: tree.wBoard, as: Box.self) { $0.props.frame.origin.x = 500 }
                tx.update(tree.a, on: .root, as: Box.self) { $0.props.frame.origin.x = 700 }
            }
        }
        let h = try harness(tree.file, [writing, recordingChanges(log)])
        let before = h.file
        let opened = steps(h) { h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) } }
        expectEqual(opened, 1)
        expectEqual(x(h, tree.d), 500, "the third board")
        expectEqual(x(h, tree.a), 700, "the board shown")
        expect(h.editor.document[tree.a]?.box?.minX == 700, "and its document is current")
        expect(!ids(h, tree.pBoard).contains(tree.r))
        let change = try require(log.changes.last)
        expectEqual(change.changed, [tree.a], "services hear the write on the board shown")
        expectEqual(change.boardsChanged, [tree.pBoard, tree.wBoard])
        expect(change.elsewhere.isSuperset(of: [tree.r, tree.d]))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "one undo puts every board back")
        expect(!h.editor.canUndo)
        h.editor.redo()
        try expectFile(h, after, "one redo does them all again")
    },
    test("the cascade: deleting a pocket there takes its boards, undo brings back every id; a pocket whose board holds a frozen shape stays, refused") {
        let tree = Isles(), log = ChangeLog(), refusals = RefusalLog()
        let h = try harness(tree.file(frozen: []), [recordingChanges(log)], refusals: refusals)
        let before = h.file
        h.editor.transact("Remove") { $0.delete([tree.q], on: tree.pBoard) }
        expect(h.file.record(tree.q) == nil && h.file.record(tree.c) == nil, "the pocket and what its board held")
        expectEqual(log.changes.last?.boardsRemoved, [tree.qBoard])
        expectEqual(log.changes.last?.elsewhere, [tree.q, tree.c])
        expectEqual(log.changes.last?.removed, [], "none of them is on the board shown")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo brings back every id")
        h.editor.redo()
        try expectFile(h, after, "redo takes them again")

        let frozen = Isles()
        let k = try harness(frozen.file(frozen: [frozen.c]), refusals: refusals)
        let kept = k.file
        k.editor.transact("Remove") { $0.delete([frozen.q], on: frozen.pBoard) }
        try expectFile(k, kept, "it stays")
        expectEqual(refusals.refusals.last, [frozen.q], "refused")
        expect(!k.editor.canUndo, "no step")
    },
    test("read-only: a frozen link stays and is in refusedShapes, the body throws and no step opens; inside a handler it goes") {
        let tree = Isles(), refusals = RefusalLog()
        let h = try harness(tree.file(frozen: [tree.l]), refusals: refusals)
        let before = h.file
        var refused: Set<ShapeID> = []
        do {
            try h.editor.transact("Remove") { tx in
                tx.delete([tree.l, tree.r], on: tree.pBoard)
                refused = tx.refusedShapes
                if !refused.isEmpty { throw Refused() }
            }
            expect(false, "it throws")
        } catch is Refused {}
        expectEqual(refused, [tree.l])
        try expectFile(h, before, "nothing committed")
        expect(!h.editor.canUndo, "and no step opened")
        expect(refusals.refusals.isEmpty, "nothing heard refused: the body threw")

        h.editor.transact("Remove") { $0.delete([tree.l], on: tree.pBoard) }
        try expectFile(h, before, "left alone, it stays")
        expectEqual(refusals.refusals.last, [tree.l], "and services hear it refused")

        // A handler deleting on a board keeps it whole, through a lock.
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a) { tx.delete([tree.l], on: tree.pBoard) }
            }
        }
        let g = try harness(tree.file(frozen: [tree.l]), [taking])
        g.editor.transact("Delete") { $0.delete([tree.a]) }
        expect(g.file.record(tree.l) == nil, "gone, frozen as it was")
        let gone = g.file
        g.editor.undo()
        try expectFile(g, tree.file(frozen: [tree.l]), "undo")
        g.editor.redo()
        try expectFile(g, gone, "redo")
    },
    test("the owner of the board shown, or of one above it, is not deleted, with a board that has shapes and with an empty one") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        expect(h.enter(tree.p) && h.enter(tree.q))
        h.editor.transact("Remove") { $0.delete([tree.q], on: tree.pBoard) }
        h.editor.transact("Remove") { $0.delete([tree.p], on: .root) }
        try expectFile(h, before, "neither is deleted")
        expect(!h.editor.canUndo, "no step")
        h.editor.transact("Remove") { $0.delete([tree.p, tree.a], on: .root) }
        expect(h.file.record(tree.a) == nil, "what's beside them goes")
        expect(h.file.record(tree.p) != nil)
        let beside = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, beside, "redo")

        // Q's board empty: the file keeps no board of Q's to take, but Q owns the board shown.
        let empty = try harness(CanvasFile(root: board(box(tree.a), pocket(tree.p)), children: [tree.p: board(box(tree.m), pocket(tree.q))]))
        let emptyBefore = empty.file
        expect(empty.enter(tree.p) && empty.enter(tree.q))
        empty.editor.transact("Remove") { $0.delete([tree.q], on: tree.pBoard) }
        empty.editor.transact("Remove") { $0.delete([tree.p], on: .root) }
        try expectFile(empty, emptyBefore, "neither is deleted")
        expect(empty.editor.canShow(tree.qBoard))
        expect(!empty.editor.canUndo)
    },
    test("in a handler of a delete that also takes the far board's owner: the board goes whole, no board is left with no owner, undo is exact") {
        let tree = Isles(), log = ChangeLog()
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.p) { tx.delete([tree.l], on: tree.pBoard) }
            }
        }
        let h = try harness(tree.file, [taking, recordingChanges(log)])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expect(h.file.record(tree.p) == nil)
        expect(h.file.children.keys.allSatisfy { h.file.record($0) != nil }, "every board has its owner")
        expectEqual(h.file.record(tree.m), nil, "P's board went whole")
        expectEqual(log.changes.last?.boardsRemoved, [tree.pBoard, tree.qBoard])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo puts every board back as it was")
        h.editor.redo()
        try expectFile(h, after, "redo")
        expect(h.file.children[tree.p] == nil && h.file.children[tree.q] == nil, "and the boards stay gone")
    },
    test("a shape moved onto the far board and deleted there; a board the editor can't show; a board that goes with an earlier delete") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        // Put in, moved there and deleted there: never was.
        let fresh = ShapeID()
        do {
            h.editor.transact("Remove") { tx in
                tx.insert(box(fresh))
                tx.move([fresh], to: tree.pBoard)
                tx.delete([fresh], on: tree.pBoard)
            }
        }
        expect(!h.editor.canUndo, "no step")
        try expectFile(h, before, "nothing")

        // Moved there from the board shown, then deleted: gone from where it was.
        h.editor.transact("Remove") { tx in
            tx.move([tree.a], to: tree.pBoard)
            tx.delete([tree.a], on: tree.pBoard)
        }
        expect(h.file.record(tree.a) == nil)
        expectEqual(ids(h, tree.pBoard), before[tree.pBoard].shapes.map(\.id), "the pocket's board is as it was")
        let moved = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, moved, "redo")
        h.editor.undo()

        let nowhere = steps(h) { h.editor.transact("Remove") { $0.delete([tree.m], on: BoardID(owner: ShapeID())) } }
        expectEqual(nowhere, 0, "a board that can't be shown")
        try expectFile(h, before, "nothing")

        let taken = steps(h) {
            h.editor.transact("Delete") { tx in
                tx.delete([tree.p])
                tx.delete([tree.m, tree.c], on: tree.pBoard)
                tx.delete([tree.c], on: tree.qBoard)
            }
        }
        expectEqual(taken, 1)
        expect(h.file.record(tree.p) == nil && h.file.record(tree.c) == nil, "the earlier delete took the boards")
        let taking = h.file
        h.editor.undo()
        try expectFile(h, before, "and undo is exact")
        h.editor.redo()
        try expectFile(h, taking, "and redo")
    },
    test("from transact(on:): a third board in its own step; the board shown and a path owner on a third board commit nothing") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact(on: tree.pBoard, "Remove") { $0.delete([tree.d], on: tree.wBoard) }
        expect(h.file.record(tree.d) == nil, "a third board")
        let after = h.file
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard, "its own step, made on that board")
        try expectFile(h, before, "undone")
        h.editor.redo()
        try expectFile(h, after, "redone")
        h.editor.undo()
        expect(h.editor.showBoard(.root))

        h.editor.transact(on: tree.pBoard, "Remove") { $0.delete([tree.a], on: .root) }
        try expectFile(h, before, "the board shown: nothing committed")

        // Shown: Q's board (empty or not), whose owners are Q and P.
        let g = try harness(tree.file)
        expect(g.enter(tree.p) && g.enter(tree.q))
        g.editor.transact(on: tree.wBoard, "Remove") { $0.delete([tree.p], on: .root) }
        g.editor.transact(on: tree.wBoard, "Remove") { $0.delete([tree.q], on: tree.pBoard) }
        try expectFile(g, before, "a path owner on a third board: nothing committed")
        let empty = try harness(CanvasFile(root: board(pocket(tree.p), pocket(tree.w)),
                                           children: [tree.p: board(box(tree.m), pocket(tree.q)), tree.w: board(box(tree.d))]))
        let emptyBefore = empty.file
        expect(empty.enter(tree.p) && empty.enter(tree.q))
        empty.editor.transact(on: tree.wBoard, "Remove") { $0.delete([tree.q], on: tree.pBoard) }
        try expectFile(empty, emptyBefore, "nor the owner of an empty board")
    },
    test("delete(inFile:) over shapes on three boards is one step") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        let opened = steps(h) {
            h.editor.transact("Remove") { $0.delete(inFile: [tree.a, tree.m, tree.d, ShapeID()]) }
        }
        expectEqual(opened, 1)
        expect(h.file.record(tree.a) == nil && h.file.record(tree.m) == nil && h.file.record(tree.d) == nil)
        expectEqual(h.file.record(tree.l)?.typed(as: Link.self)?.props, Link(from: nil, to: tree.r), "a link to a box deleted lets go of it")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "one undo")
        h.editor.redo()
        try expectFile(h, after, "one redo")
    },

    // MARK: What a handler does to the board shown

    test("a handler of a far delete that deletes a shape on the board shown: the commit says the stack changed, the paint order is the board's, undo and redo exact") {
        let tree = Isles(), log = ChangeLog()
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.r) { tx.delete([tree.a], on: .root) }
            }
        }
        let h = try harness(tree.file, [taking, recordingChanges(log)])
        let before = h.file
        expectPaintsTheBoard(h, "before")
        h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) }
        let change = try require(log.changes.last)
        expect(h.file.record(tree.a) == nil, "the handler's delete on the board shown landed")
        expectEqual(change.removed, [tree.a])
        expect(change.added.isEmpty && change.changed.isEmpty)
        expect(change.reordered, "a shape went from the board shown")
        expectPaintsTheBoard(h, "after: painted is what is on the board")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        expectPaintsTheBoard(h, "after undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        expectPaintsTheBoard(h, "after redo")
    },
    test("a delete made on the board shown itself says the stack changed too") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.a]) }
        expect(try require(log.changes.last).reordered)
        expectPaintsTheBoard(h, "painted")
    },
    test("a handler of a far delete that moves a shape off the board shown, or restacks one on it: the stack changed, the paint order follows, undo and redo exact") {
        let tree = Isles(), log = ChangeLog()
        let moving = Contributor(id: "moves") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.r) { _ = tx.move([tree.a], from: .root, to: tree.wBoard) }
                if deleted.contains(tree.m) { tx.move(tree.a, above: tree.b, on: .root) }
            }
        }
        let h = try harness(tree.file, [moving, recordingChanges(log)])
        let before = h.file
        expectPaintsTheBoard(h, "before")
        h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) }
        var change = try require(log.changes.last)
        expectEqual(change.removed, [tree.a])
        expect(change.reordered, "a shape went from the board shown")
        expectEqual(h.file.board(containing: tree.a), tree.wBoard)
        expectPaintsTheBoard(h, "after a move off")
        let moved = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, moved, "redo")
        h.editor.undo()

        expectEqual(Array(h.editor.document.shapes.map(\.id).prefix(2)), [tree.a, tree.b])
        h.editor.transact("Remove") { $0.delete([tree.m], on: tree.pBoard) }
        change = try require(log.changes.last)
        expectEqual(Array(h.editor.document.shapes.map(\.id).prefix(2)), [tree.b, tree.a], "the handler's restack landed")
        expect(change.reordered, "the stack changed")
        expect(change.added.isEmpty && change.removed.isEmpty)
        expectPaintsTheBoard(h, "painted in the board's order")
        let restacked = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, restacked, "redo")
    },
    test("a handler of a far delete that moves a shape from the far board onto the board shown and one from it onto a third: the change set is right, undo and redo exact") {
        let tree = Isles(), log = ChangeLog()
        let moving = Contributor(id: "moves") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.r) {
                    _ = tx.move([tree.z], to: .root)
                    _ = tx.move([tree.a], from: .root, to: tree.wBoard)
                }
            }
        }
        let h = try harness(tree.file, [moving, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) }
        expectEqual(h.file.board(containing: tree.z), .root)
        expectEqual(h.file.board(containing: tree.a), tree.wBoard)
        let change = try require(log.changes.last)
        expectEqual(change.added, [tree.z])
        expectEqual(change.removed, [tree.a])
        expect(change.reordered)
        expectPaintsTheBoard(h, "painted")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: What a delete may not take

    test("a handler on the far board that deletes the owner of the board shown, empty or not, or of one above it: it stays, and no board is left without an owner") {
        let tree = Isles()
        let cascading = Contributor(id: "cascades") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a) { tx.delete([tree.e]) }
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.q, tree.p]) }
            }
        }
        // Empty: nothing in the file to take with it.
        let h = try harness(tree.file, [cascading])
        let before = h.file
        expect(h.enter(tree.e), "E's board, empty, is shown")
        h.editor.transact("Remove") { $0.delete([tree.a], on: .root) }
        expect(h.file.record(tree.a) == nil)
        expect(h.file.record(tree.e) != nil, "the owner of the board shown is still in the file")
        expect(h.editor.canShow(h.editor.board), "and the board shown can still be shown")
        let removed = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, removed, "redo")

        // With shapes, and an owner above.
        let g = try harness(tree.file, [cascading])
        expect(g.enter(tree.p) && g.enter(tree.q), "Q's board is shown")
        g.editor.transact("Remove") { $0.delete([tree.m], on: tree.pBoard) }
        expect(g.file.record(tree.m) == nil)
        expect(g.file.record(tree.q) != nil && g.file.record(tree.p) != nil, "the owners of the board shown and of the board above it stay")
        expectEqual(orphans(g), [], "no board without an owner")
        let after = g.file
        g.editor.undo()
        try expectFile(g, before, "undo")
        g.editor.redo()
        try expectFile(g, after, "redo")
    },
    test("a pocket brought onto the far board and deleted there by a handler, not by name: it goes with its board, and no board is left without an owner") {
        let tree = Isles()
        let cascading = Contributor(id: "cascades") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a), tx.document[tree.w] != nil { tx.delete([tree.w]) }
            }
        }
        let h = try harness(tree.file, [cascading])
        let before = h.file
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.a, tree.w], to: tree.pBoard)
            tx.delete([tree.a], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.w), nil, "the pocket is on no board as the transaction leaves the file")
        }
        expect(h.file.record(tree.w) == nil && h.file.record(tree.d) == nil, "the pocket went, and what its board held")
        expectEqual(orphans(h), [], "and its board with it")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a pocket brought onto a board and deleted there by name goes with its board, on the board shown or on a far one; one put in with its board and deleted never was") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        // Moved here from P's board, then deleted here.
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.q], from: tree.pBoard, to: .root)
            tx.delete([tree.q])
        }
        expect(h.file.record(tree.q) == nil && h.file.record(tree.c) == nil)
        expectEqual(orphans(h), [])
        expectEqual(log.changes.last?.boardsRemoved, [tree.qBoard])
        var after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()

        // Moved onto the far board, then deleted there.
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.w], to: tree.pBoard)
            tx.delete([tree.w], on: tree.pBoard)
        }
        expect(h.file.record(tree.w) == nil && h.file.record(tree.d) == nil && h.file.record(tree.d2) == nil)
        expectEqual(orphans(h), [])
        expectEqual(log.changes.last?.boardsRemoved, [tree.wBoard])
        after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()

        // A pocket put in with its board, moved onto the far board, deleted there: never was.
        let fresh = ShapeID(), inside = ShapeID()
        h.editor.transact("Remove") { tx in
            tx.insert(pocket(fresh), contents: [fresh: board(box(inside))])
            _ = tx.move([fresh], to: tree.pBoard)
            tx.delete([fresh], on: tree.pBoard)
        }
        expect(!h.editor.canUndo, "no step")
        try expectFile(h, before, "nothing")
        expect(h.file.children[fresh] == nil)
        expectEqual(log.changes.last?.boardsAdded, [], "no board came into the file")
    },
    test("a pocket brought onto the far board whose board holds a frozen shape is not deleted there") {
        let tree = Isles(), refusals = RefusalLog()
        let h = try harness(tree.file(frozen: [tree.d]), refusals: refusals)
        let before = h.file
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.w], to: tree.pBoard)
            tx.delete([tree.w], on: tree.pBoard)
            expectEqual(tx.refusedShapes, [tree.w])
        }
        expect(h.file.record(tree.d) != nil, "the frozen box stays")
        expectEqual(h.file.board(containing: tree.w), tree.pBoard, "so does its pocket, where it was moved")
        expectEqual(orphans(h), [])
        h.editor.undo()
        try expectFile(h, before, "undo")
    },
    test("a transaction on a board that isn't shown that moves the owner of the (empty) board shown to another board and deletes it there, or on its own board, commits nothing") {
        let tree = Isles()
        let h = try harness(tree.file)
        expect(h.enter(tree.e), "E's board, empty, is shown")
        let before = h.file
        h.editor.transact(on: tree.wBoard, "Remove") { tx in
            _ = tx.move([tree.e], from: .root, to: tree.pBoard)
            tx.delete([tree.e], on: tree.pBoard)
        }
        expect(h.file.record(tree.e) != nil, "the owner of the board shown is still in the file")
        expect(h.editor.canShow(h.editor.board), "and the board shown can still be shown")
        try expectFile(h, before, "nothing committed")
        expect(!h.editor.canUndo)

        h.editor.transact(on: tree.wBoard, "Remove") { tx in
            _ = tx.move([tree.e], from: .root, to: tree.wBoard)
            tx.delete([tree.e])
        }
        expect(h.file.record(tree.e) != nil)
        try expectFile(h, before, "nor on its own board")
        expect(!h.editor.canUndo)
    },

    // MARK: Each shape's handlers once

    test("two shapes on two boards, each deleting the other when it goes: each one's handlers run once, both go, undo and redo exact") {
        let tree = Isles(), calls = Calls()
        let paired = Contributor(id: "pairs") { r in
            r.willDelete { deleted, tx in
                calls.count += 1
                if deleted.contains(tree.a) { tx.delete(inFile: [tree.m]) }
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.a]) }
            }
        }
        let h = try harness(tree.file, [paired])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expectEqual(calls.count, 2, "once for each")
        expect(h.file.record(tree.a) == nil && h.file.record(tree.m) == nil)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("three shapes on three boards deleting round, from a transaction on one of them: each one's handlers run once, all go, undo and redo exact") {
        let tree = Isles(), calls = Calls()
        let circling = Contributor(id: "circles") { r in
            r.willDelete { deleted, tx in
                calls.count += 1
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.d]) }
                if deleted.contains(tree.d) { tx.delete(inFile: [tree.c]) }
                if deleted.contains(tree.c) { tx.delete(inFile: [tree.m, tree.d]) }
            }
        }
        let h = try harness(tree.file, [circling])
        let before = h.file
        h.editor.transact(on: tree.wBoard, "Delete") { $0.delete(inFile: [tree.c]) }
        expectEqual(calls.count, 3)
        expect(h.file.record(tree.m) == nil && h.file.record(tree.d) == nil && h.file.record(tree.c) == nil)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("two shapes on one board, each deleting the other when it goes: each one's handlers run once") {
        let tree = Isles(), calls = Calls()
        let paired = Contributor(id: "pairs") { r in
            r.willDelete { deleted, tx in
                calls.count += 1
                if deleted.contains(tree.a) { tx.delete(inFile: [tree.b]) }
                if deleted.contains(tree.b) { tx.delete(inFile: [tree.a]) }
            }
        }
        let h = try harness(tree.file, [paired])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expectEqual(calls.count, 2)
        expect(h.file.record(tree.a) == nil && h.file.record(tree.b) == nil)
        h.editor.undo()
        try expectFile(h, before, "undo")
    },

    // MARK: Reading the file mid-transaction

    test("board(containing:) is nil for a shape the transaction deleted on another board, as for one it deleted on its own; one deleted can be put in again") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.delete([tree.a])
            expectEqual(tx.board(containing: tree.a), nil, "deleted on this board")
            tx.delete([tree.l], on: tree.pBoard)
            expect(tx.contents(of: tree.pBoard)[tree.l] == nil, "gone from the far board as the transaction leaves it")
            expectEqual(tx.board(containing: tree.l), nil, "deleted on another board")
            expectEqual(tx.board(containing: tree.m), tree.pBoard, "what it didn't delete is where it was")
            tx.delete(inFile: [tree.l])
            tx.delete([tree.p])
            expectEqual(tx.board(containing: tree.q), nil, "taken with its owner's board")
            expectEqual(tx.board(containing: tree.p), nil)
        }
        expect(h.file.record(tree.l) == nil && h.file.record(tree.q) == nil)
        h.editor.undo()
        try expectFile(h, before, "undo")

        // Put in again on the board shown, as one deleted there can be.
        h.editor.transact("Replace") { tx in
            tx.delete([tree.l], on: tree.pBoard)
            tx.insert(link(tree.l, nil, nil))
            expectEqual(tx.board(containing: tree.l), .root)
        }
        expectEqual(h.file.board(containing: tree.l), .root)
        expect(!ids(h, tree.pBoard).contains(tree.l))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: What the change set says

    test("a far delete that empties a board, and a shape moved onto an empty board and deleted there or moved off again: undo and redo exact, no board added") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { $0.delete([tree.d, tree.d2], on: tree.wBoard) }
        expect(h.file.children[tree.w] == nil, "the board holds nothing")
        expectEqual(log.changes.last?.boardsChanged, [tree.wBoard])
        var after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")

        // Moved onto E's empty board, deleted there.
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.a], to: tree.eBoard)
            tx.delete([tree.a], on: tree.eBoard)
        }
        expect(h.file.record(tree.a) == nil)
        expect(h.file.children[tree.e] == nil)
        let change = try require(log.changes.last)
        expectEqual(change.removed, [tree.a])
        expectEqual(change.boardsAdded, [], "no board came into the file")
        expectEqual(change.boardsReached, [], "nor changed")
        after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")

        // Moved onto the empty board and off it again.
        h.editor.transact("Remove") { tx in
            _ = tx.move([tree.a], to: tree.eBoard)
            _ = tx.move([tree.a], from: tree.eBoard, to: .root)
        }
        expectEqual(log.changes.last?.boardsAdded, [], "no board came into the file")
        expect(h.file.children[tree.e] == nil)
    },

    // MARK: Many things in the one step

    test("a press of own deletes, an update and a move, far deletes with a handler that writes the far board, a third and the board shown, and delete(inFile:) over three boards: one step, exact both ways") {
        let tree = Isles(), log = ChangeLog()
        let writing = Contributor(id: "writer") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.r) {
                    slide(&tx, tree.d, on: tree.wBoard, to: 500)
                    slide(&tx, tree.b, on: .root, to: 700)
                    slide(&tx, tree.z, on: tree.pBoard, to: 900)
                    tx.delete([tree.c], on: tree.qBoard)
                }
            }
        }
        let h = try harness(tree.file, [writing, recordingChanges(log)])
        let before = h.file
        let opened = steps(h) {
            h.editor.undoHistory.group("All") {
                h.editor.transact { tx in
                    tx.update(tree.a, as: Box.self) { $0.props.frame.size.width = 77 }
                    tx.moveBox(tree.b, to: CGPoint(x: 1, y: 1))
                    tx.delete([tree.r], on: tree.pBoard)
                    tx.update(tree.a, as: Box.self) { $0.props.frame.size.height = 78 }
                }
                let change = log.changes.last
                expectEqual(change?.changed, [tree.a, tree.b])
                expectEqual(change?.moved, [], "B was moved, then written by the handler: no longer only moved")
                expectEqual(change?.boardsChanged, [tree.pBoard, tree.wBoard, tree.qBoard])
                h.editor.transact { $0.delete(inFile: [tree.d2, tree.m, tree.a]) }
                h.editor.transact { tx in
                    _ = tx.move([tree.b], to: tree.wBoard)
                    tx.delete([tree.d], on: tree.wBoard)
                    tx.delete([tree.p])
                }
            }
        }
        expectEqual(opened, 1, "one step")
        let after = h.file
        expectEqual(orphans(h), [])
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")
    },
    test("from transact(on:), delete(inFile:) over the board and two more with a handler writing back on it: its own step, exact, the board shown untouched") {
        let tree = Isles(), log = ChangeLog()
        let writing = Contributor(id: "writer") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.d) {
                    slide(&tx, tree.z, on: tree.pBoard, to: 900)
                    tx.delete([tree.l2], on: tree.pBoard)
                }
            }
        }
        let h = try harness(tree.file, [writing, recordingChanges(log)])
        let before = h.file, shown = h.editor.document
        h.editor.transact(on: tree.pBoard, "Remove") { $0.delete(inFile: [tree.m, tree.d, tree.c]) }
        expectEqual(h.editor.document, shown)
        expect(h.file.record(tree.m) == nil && h.file.record(tree.d) == nil && h.file.record(tree.c) == nil && h.file.record(tree.l2) == nil)
        expectEqual(h.file.record(tree.z)?.box?.minX, 900)
        let change = try require(log.changes.last)
        expect(change.shapeIDs.isEmpty, "nothing on the board shown")
        expect(change.elsewhere.isSuperset(of: [tree.m, tree.d, tree.c, tree.l2, tree.z, tree.l]))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")
    },
    test("a far delete, then the far board's owner deleted, with a handler that wrote a board under it and one beside it: exact") {
        let tree = Isles()
        let writing = Contributor(id: "writer") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.l) {
                    slide(&tx, tree.c, on: tree.qBoard, to: 500)
                    slide(&tx, tree.d, on: tree.wBoard, to: 600)
                }
            }
        }
        let h = try harness(tree.file, [writing])
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.delete([tree.l], on: tree.pBoard)
            tx.delete([tree.p])
        }
        expect(h.file.record(tree.p) == nil && h.file.record(tree.c) == nil)
        expectEqual(h.file.record(tree.d)?.box?.minX, 600)
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a read-only far board (its owner frozen): each shape asked for is refused, no step; a cascade from a handler goes through") {
        let tree = Isles(), refusals = RefusalLog()
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a) { tx.delete([tree.m], on: tree.pBoard) }
            }
        }
        let h = try harness(tree.file(frozen: [tree.p]), [taking], refusals: refusals)
        let before = h.file
        var refused: Set<ShapeID> = []
        h.editor.transact("Remove") { tx in
            tx.delete([tree.m, tree.l], on: tree.pBoard)
            tx.delete([tree.c], on: tree.qBoard)
            refused = tx.refusedShapes
        }
        expectEqual(refused, [tree.m, tree.l, tree.c])
        try expectFile(h, before, "nothing")
        expect(!h.editor.canUndo)

        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expect(h.file.record(tree.a) == nil && h.file.record(tree.m) == nil, "inside a deletion keeping the board whole, a lock stands in no one's way")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a container deleted on a far board lets go of what it holds there, then a translate and a settle there, a sibling pocket deleted from below, and a press of three commits: each one step, exact both ways") {
        let k = ShapeID(), inK = ShapeID(), out = ShapeID(), p = ShapeID(), w = ShapeID(), d = ShapeID(), a = ShapeID(), l = ShapeID()
        let held = box(inK, x: 10).copy(as: inK, container: k)
        let file = CanvasFile(root: board(box(a), pocket(p), pocket(w)),
                              children: [p: board(AnyShapeRecord(ShapeRecord(id: k, Corral(CGRect(x: 0, y: 0, width: 300, height: 300)))), held,
                                                  box(out, x: 600), link(l, inK, out)),
                                         w: board(box(d))])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin(), CorralsPlugin(), FreezingPlugin()], file: file)
        let before = h.file, pBoard = BoardID(owner: p)
        expectEqual(before.record(inK)?.container, k, "the fixture: the box is in the corral")
        h.editor.transact("Remove") { tx in
            tx.delete([k], on: pBoard)
            tx.translate([out], by: CGPoint(x: -550, y: 0), on: pBoard)
            tx.settle([out], on: pBoard)
            tx.delete([l], on: pBoard)
        }
        expect(h.file.record(k) == nil && h.file.record(l) == nil)
        expectEqual(h.file.record(inK)?.container, nil, "let go onto the board")
        expectEqual(h.file.record(out)?.box?.minX, 50)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()
        try expectFile(h, before, "and back")

        // From below, a sibling pocket and a shape beside it, with the owner of the board shown named too.
        expect(h.enter(p))
        h.editor.transact("Remove") { $0.delete([w, a, p], on: .root) }
        expect(h.file.record(w) == nil && h.file.record(d) == nil && h.file.record(a) == nil && h.file.record(p) != nil)
        let below = h.file
        h.editor.undo()
        try expectFile(h, before, "undo from below")
        h.editor.redo()
        try expectFile(h, below, "redo from below")
        h.editor.undo()

        // In a group with a commit before and one after.
        expect(h.editor.showBoard(.root))
        h.editor.undoHistory.group("Press") {
            h.editor.transact { $0.update(a, as: Box.self) { $0.props.frame.origin.x = 33 } }
            h.editor.transact { $0.delete(inFile: [inK, d]) }
            h.editor.transact { $0.delete([p]) }
        }
        let pressed = h.file
        expectEqual(h.editor.undoHistory.undoName, "Press")
        h.editor.undo()
        try expectFile(h, before, "undo the group")
        expect(!h.editor.canUndo)
        h.editor.redo()
        try expectFile(h, pressed, "redo the group")
    },
])
