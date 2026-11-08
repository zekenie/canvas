@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// What a commit says, and what undo and redo put back, when a delete or a move reaches boards other than the
// one shown, through handlers that write back across boards: the change set, where each shape is, and the file
// before and after as a whole.

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

@MainActor private final class Tally {
    var seen: [ShapeID: Int] = [:]
    var calls = 0
}

@MainActor private func slide(_ tx: inout Transaction, _ id: ShapeID, on board: BoardID, to x: CGFloat) {
    tx.update(id, on: board, as: Box.self) { $0.props.frame.origin.x = x }
}

@MainActor private func orphans(_ h: EditorHarness) -> [ShapeID] { h.file.children.keys.filter { h.file.record($0) == nil } }

@MainActor private func expectPaintsTheBoard(_ h: EditorHarness, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    expectEqual(h.editor.paintOrder().map(\.id), h.editor.document.shapes.map(\.id), message, file: file, line: line)
}

/// Undoes everything, checking each state on the way back, then redoes everything, checking each on the way forward.
@MainActor private func roundTrip(_ h: EditorHarness, _ states: [CanvasFile], _ what: String, file: StaticString = #fileID, line: UInt = #line) throws {
    h.editor.undoHistory.seal()
    for index in stride(from: states.count - 2, through: 0, by: -1) {
        expect(h.editor.canUndo, "\(what): a step to undo back to state \(index)", file: file, line: line)
        h.editor.undo()
        try expectFile(h, states[index], "\(what): undone to state \(index)", file: file, line: line)
    }
    expect(!h.editor.canUndo, "\(what): nothing more to undo", file: file, line: line)
    for index in 1..<states.count {
        expect(h.editor.canRedo, "\(what): a step to redo to state \(index)", file: file, line: line)
        h.editor.redo()
        try expectFile(h, states[index], "\(what): redone to state \(index)", file: file, line: line)
    }
    expect(!h.editor.canRedo, "\(what): nothing more to redo", file: file, line: line)
}

@MainActor let acrossBoardsCommitTests = Suite("Across boards: what the commit says", [
    // MARK: The change set

    test("a board written to, whose owner is then moved onto the board shown and deleted there, is removed, not changed too") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { tx in
            slide(&tx, tree.c, on: tree.qBoard, to: 500)
            _ = tx.move([tree.q], from: tree.pBoard, to: .root)
            tx.delete([tree.q])
        }
        expect(h.file.record(tree.q) == nil && h.file.record(tree.c) == nil)
        let change = try require(log.changes.last)
        expectEqual(change.boardsRemoved, [tree.qBoard])
        expect(!change.boardsChanged.contains(tree.qBoard), "Q's board went: it is not also changed (boardsChanged holds Q's board: \(change.boardsChanged.contains(tree.qBoard)), boardsRemoved holds it: \(change.boardsRemoved.contains(tree.qBoard)))")
        expectEqual(change.boardsChanged.subtracting([tree.qBoard]), [tree.pBoard])
        expectEqual(change.boardsAdded, [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a board written to, whose owner is moved onto a far board and deleted there, is removed, not changed too") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { tx in
            slide(&tx, tree.c, on: tree.qBoard, to: 500)
            _ = tx.move([tree.q], from: tree.pBoard, to: tree.wBoard)
            tx.delete([tree.q], on: tree.wBoard)
        }
        expect(h.file.record(tree.q) == nil && h.file.record(tree.c) == nil)
        let change = try require(log.changes.last)
        expectEqual(change.boardsRemoved, [tree.qBoard])
        expect(!change.boardsChanged.contains(tree.qBoard), "Q's board went: it is not also changed")
        expect(change.boardsChanged.contains(tree.pBoard))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a far delete's handler that moves a shape off the board shown and back: it was there before, so it is changed, not added") {
        let tree = Isles(), log = ChangeLog()
        let moving = Contributor(id: "moves") { r in
            r.willDelete { deleted, tx in
                guard deleted.contains(tree.r) else { return }
                _ = tx.move([tree.a], from: .root, to: tree.wBoard)
                _ = tx.move([tree.a], from: tree.wBoard, to: .root)
            }
        }
        let h = try harness(tree.file, [moving, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.r], on: tree.pBoard) }
        expectEqual(h.file.board(containing: tree.a), .root)
        let change = try require(log.changes.last)
        expectEqual(change.added, [], "A was on the board shown before the commit")
        expectEqual(change.changed, [tree.a], "it is on top now: changed")
        expectEqual(change.removed, [])
        expect(change.reordered)
        expectPaintsTheBoard(h, "painted")
        // The same two moves with no handler say changed.
        let g = try harness(tree.file, [recordingChanges(log)])
        g.editor.transact("Move") { tx in
            _ = tx.move([tree.a], to: tree.wBoard)
            _ = tx.move([tree.a], from: tree.wBoard, to: .root)
        }
        expectEqual(log.changes.last?.added, [], "with no handler")
        expectEqual(log.changes.last?.changed, [tree.a], "with no handler")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a far delete's handler that deletes a shape the transaction put in, writes one it changed and moves one off: the change set says what happened") {
        let tree = Isles(), log = ChangeLog(), fresh = ShapeID()
        let writing = Contributor(id: "writer") { r in
            r.willDelete { deleted, tx in
                guard deleted.contains(tree.r) else { return }
                tx.delete(inFile: [fresh])
                slide(&tx, tree.a, on: .root, to: 700)
                _ = tx.move([tree.b], from: .root, to: tree.wBoard)
            }
        }
        let h = try harness(tree.file, [writing, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { tx in
            tx.insert(box(fresh, x: 900))
            tx.moveBox(tree.a, to: CGPoint(x: 5, y: 5))
            tx.delete([tree.r], on: tree.pBoard)
            expectEqual(tx.board(containing: fresh), nil)
            expectEqual(tx.board(containing: tree.b), tree.wBoard)
        }
        let change = try require(log.changes.last)
        expectEqual(change.added, [], "put in and deleted: never seen")
        expectEqual(change.removed, [tree.b])
        expectEqual(change.changed, [tree.a])
        expectEqual(change.moved, [])
        expect(h.file.record(fresh) == nil)
        expectPaintsTheBoard(h, "painted")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: Boards and their owners

    test("a far delete's handler that moves a pocket off the far board onto the board shown, then the far board's owner deleted: the pocket keeps its board") {
        let tree = Isles()
        let moving = Contributor(id: "moves") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.m) { _ = tx.move([tree.q], to: .root) }
            }
        }
        let h = try harness(tree.file, [moving])
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.delete([tree.m], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.q), .root, "the handler moved Q onto the board shown")
            tx.delete([tree.p])
            expectEqual(tx.board(containing: tree.c), tree.qBoard, "Q's board is Q's still")
        }
        expectEqual(h.file.board(containing: tree.q), .root)
        expectEqual(h.file.board(containing: tree.c), tree.qBoard, "what Q's board held is still on it")
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a handler on the far board that deletes a pocket beside the far board's owner: it goes with its board") {
        let tree = Isles(), log = ChangeLog()
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.w]) }
            }
        }
        let h = try harness(tree.file, [taking, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.m], on: tree.pBoard) }
        expect(h.file.record(tree.w) == nil && h.file.record(tree.d) == nil, "W went with its board")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [tree.w])
        expectEqual(change.boardsRemoved, [tree.wBoard])
        expectEqual(change.boardsChanged, [tree.pBoard])
        expectPaintsTheBoard(h, "painted")
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("kept through three boards: Q's board shown, a delete on W whose handler deletes on the root, whose handler deletes on P, whose handler asks for Q and P") {
        let tree = Isles(), tally = Tally()
        let chain = Contributor(id: "chain") { r in
            r.willDelete { deleted, tx in
                for id in deleted { tally.seen[id, default: 0] += 1 }
                if deleted.contains(tree.d) { tx.delete([tree.a], on: .root) }
                if deleted.contains(tree.a) { tx.delete([tree.m], on: tree.pBoard) }
                if deleted.contains(tree.m) {
                    tx.delete([tree.q])
                    tx.delete(inFile: [tree.p, tree.q])
                    tx.delete([tree.p, tree.b], on: .root)
                }
            }
        }
        let h = try harness(tree.file, [chain])
        let before = h.file
        expect(h.enter(tree.p) && h.enter(tree.q))
        h.editor.transact("Remove") { $0.delete([tree.d], on: tree.wBoard) }
        expect(h.file.record(tree.d) == nil && h.file.record(tree.a) == nil && h.file.record(tree.m) == nil && h.file.record(tree.b) == nil)
        expect(h.file.record(tree.q) != nil && h.file.record(tree.p) != nil, "the owners of the board shown stay")
        expect(h.editor.canShow(h.editor.board))
        expectEqual(tally.seen[tree.q], nil, "no handler ran for an owner kept")
        expectEqual(tally.seen[tree.p], nil)
        expectEqual(tally.seen.values.max(), 1, "each shape's handlers once")
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    test("Q's board shown, a delete on W whose handler asks for P, the owner of the board above the board shown, on the root: P stays") {
        let tree = Isles(), tally = Tally()
        let reaching = Contributor(id: "reaches") { r in
            r.willDelete { deleted, tx in
                for id in deleted { tally.seen[id, default: 0] += 1 }
                if deleted.contains(tree.d) { tx.delete([tree.p, tree.a], on: .root) }
            }
        }
        let h = try harness(tree.file, [reaching])
        let before = h.file
        expect(h.enter(tree.p) && h.enter(tree.q))
        h.editor.transact("Remove") { $0.delete([tree.d], on: tree.wBoard) }
        expect(h.file.record(tree.d) == nil && h.file.record(tree.a) == nil, "what was asked for beside it went")
        expect(h.file.record(tree.p) != nil && h.file.record(tree.q) != nil, "the owner above the board shown stays")
        expect(h.editor.canShow(h.editor.board))
        expectEqual(tally.seen[tree.p], nil, "no handler ran for it")
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: Handlers once, however the boards cross

    test("a delete that crosses root, P, root, P, each handler deleting on the board the one before came from, the last asking for all of them: once each, exact") {
        let tree = Isles(), tally = Tally(), log = ChangeLog()
        let crossing = Contributor(id: "crosses") { r in
            r.willDelete { deleted, tx in
                tally.calls += 1
                for id in deleted { tally.seen[id, default: 0] += 1 }
                if deleted.contains(tree.a) { tx.delete([tree.m], on: tree.pBoard) }
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.b]) }
                if deleted.contains(tree.b) { tx.delete(inFile: [tree.z]) }
                if deleted.contains(tree.z) { tx.delete(inFile: [tree.a, tree.m, tree.b, tree.z]) }
            }
        }
        let h = try harness(tree.file, [crossing, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        @MainActor func check(_ what: String) throws {
            expectEqual(tally.seen, [tree.a: 1, tree.m: 1, tree.b: 1, tree.z: 1], "\(what): each once")
            expect(h.file.record(tree.a) == nil && h.file.record(tree.b) == nil && h.file.record(tree.m) == nil && h.file.record(tree.z) == nil)
            expectEqual(h.file.record(tree.l)?.typed(as: Link.self)?.props, Link(from: nil, to: tree.r), "\(what): L let go of M")
            expectEqual(h.file.record(tree.l2)?.typed(as: Link.self)?.props, Link(from: nil, to: tree.r), "\(what): L2 let go of Z")
        }
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        try check("from the root")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [tree.a, tree.b])
        expectEqual(change.boardsChanged, [tree.pBoard])
        expect(change.elsewhere.isSuperset(of: [tree.m, tree.z, tree.l, tree.l2]))
        expectPaintsTheBoard(h, "painted")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()

        // From the far end, and from a transaction on a third board.
        tally.seen = [:]
        h.editor.transact("Delete") { $0.delete([tree.z], on: tree.pBoard) }
        expectEqual(tally.seen[tree.z], 1)
        expect(h.file.record(tree.z) == nil)
        h.editor.undo()
        try expectFile(h, before, "undo from the far end")

        tally.seen = [:]
        h.editor.transact(on: tree.wBoard, "Delete") { $0.delete(inFile: [tree.m]) }
        try expectFile(h, before, "from a third board, reaching the board shown: nothing committed")

        expect(h.enter(tree.e))
        tally.seen = [:]
        h.editor.transact("Delete") { $0.delete(inFile: [tree.b]) }
        expectEqual(tally.seen.values.max(), 1)
        expect(h.file.record(tree.b) == nil && h.file.record(tree.z) == nil)
        let below = h.file
        h.editor.undo()
        try expectFile(h, before, "undo from E's board")
        h.editor.redo()
        try expectFile(h, below, "redo from E's board")
    },
    test("a far board entered twice while its first delete is under way, a link bound to both shapes: it lets go of both, exact") {
        let m = ShapeID(), z = ShapeID(), k = ShapeID(), p = ShapeID(), a = ShapeID(), tally = Tally()
        let file = CanvasFile(root: board(box(a), pocket(p)), children: [p: board(box(m), box(z, x: 100), link(k, m, z))])
        let crossing = Contributor(id: "crosses") { r in
            r.willDelete { deleted, tx in
                for id in deleted { tally.seen[id, default: 0] += 1 }
                if deleted.contains(m) { tx.delete(inFile: [a]) }
                if deleted.contains(a) { tx.delete(inFile: [z]) }
            }
        }
        let h = try harness(file, [crossing])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([m], on: BoardID(owner: p)) }
        expectEqual(tally.seen, [m: 1, a: 1, z: 1])
        expectEqual(h.file.record(k)?.typed(as: Link.self)?.props, Link(from: nil, to: nil), "the link let go of both")
        expectEqual(ids(h, BoardID(owner: p)), [k])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    test("delete(inFile:) of a pocket and a box on its board: the box's handlers run every time, whatever the ids are (the deepest board goes first)") {
        var ran = 0, skipped = 0
        for _ in 0..<60 {
            let tree = Isles(), tally = Tally()
            let writing = Contributor(id: "writer") { r in
                r.willDelete { deleted, tx in
                    if deleted.contains(tree.m) {
                        tally.calls += 1
                        slide(&tx, tree.d, on: tree.wBoard, to: 500)
                    }
                }
            }
            let h = try harness(tree.file, [writing])
            let before = h.file
            h.editor.transact("Delete") { $0.delete(inFile: [tree.p, tree.m]) }
            expect(h.file.record(tree.p) == nil && h.file.record(tree.m) == nil)
            if tally.calls == 1 { ran += 1 } else { skipped += 1 }
            expectEqual(h.file.record(tree.d)?.box?.minX, tally.calls == 1 ? 500 : 0)
            h.editor.undo()
            try expectFile(h, before, "undo")
        }
        expectEqual(ran, 60, "the same call on the same file ran the box's handler \(ran) times of 60 and skipped it \(skipped) times: what it wrote on a third board is there every time, never by the order of a dictionary")
    },
    test("a far delete whose handler asks for the far board's owner (passed over), then the owner deleted by name on the board shown: it goes with its boards") {
        let tree = Isles(), log = ChangeLog()
        let asking = Contributor(id: "asks") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.p]) }
            }
        }
        let h = try harness(tree.file, [asking, recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.delete([tree.m], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.p), .root, "passed over while its board was being deleted from")
            tx.delete([tree.p])
            expectEqual(tx.board(containing: tree.p), nil)
        }
        expect(h.file.record(tree.p) == nil && h.file.record(tree.c) == nil)
        expectEqual(log.changes.last?.boardsRemoved, [tree.pBoard, tree.qBoard])
        expectEqual(log.changes.last?.boardsChanged, [])
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: deleted

    test("a shape deleted on a far board, put in again, moved to a third board, deleted there, put in again: where it is at each step, exact both ways") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        h.editor.transact("Replace") { tx in
            tx.delete([tree.l], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.l), nil)
            tx.insert(link(tree.l, nil, nil))
            expectEqual(tx.board(containing: tree.l), .root)
            expect(tx.move([tree.l], to: tree.wBoard))
            expectEqual(tx.board(containing: tree.l), tree.wBoard)
            tx.delete([tree.l], on: tree.wBoard)
            expectEqual(tx.board(containing: tree.l), nil)
            expect(tx.contents(of: tree.wBoard)[tree.l] == nil)
            tx.insert(link(tree.l, nil, nil))
            expect(tx.move([tree.l], to: tree.eBoard))
            expectEqual(tx.board(containing: tree.l), tree.eBoard)
            tx.update(inFile: tree.m) { $0.box?.origin.x = 44 }
        }
        expectEqual(h.file.board(containing: tree.l), tree.eBoard)
        expectEqual(h.file.record(tree.m)?.box?.minX, 44)
        let change = try require(log.changes.last)
        expectEqual(change.boardsAdded, [tree.eBoard])
        expect(change.boardsChanged.contains(tree.pBoard))
        expectEqual(change.shapeIDs, [], "nothing of the board shown")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("after a far delete of a pocket: its board's shapes are on no board, a write there does nothing, the far board still moves and settles") {
        let tree = Isles()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.delete([tree.q, tree.l], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.c), nil)
            expectEqual(tx.contents(of: tree.qBoard).shapes.count, 0)
            slide(&tx, tree.c, on: tree.qBoard, to: 9)
            tx.update(inFile: tree.c) { $0.box?.origin.x = 9 }
            tx.delete(inFile: [tree.c, tree.q, tree.l])
            tx.translate([tree.m, tree.q], by: CGPoint(x: 7, y: 0), on: tree.pBoard)
            _ = tx.settle([tree.m], on: tree.pBoard)
            expect(tx.move([tree.a], to: tree.pBoard))
            expect(tx.move([tree.m], from: tree.pBoard, to: tree.wBoard))
            tx.move(tree.z, above: tree.a, on: tree.pBoard)
        }
        expectEqual(h.file.record(tree.m)?.box?.minX, 7)
        expectEqual(h.file.board(containing: tree.m), tree.wBoard)
        expectEqual(ids(h, tree.pBoard), [tree.r, tree.l2, tree.a, tree.z])
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: Boards that end empty

    test("an empty board moved onto, written, emptied by a delete, moved onto again, and one a paste brought emptied: what the commit says, exact both ways") {
        let tree = Isles(), log = ChangeLog()
        let h = try harness(tree.file, [recordingChanges(log)])
        let before = h.file
        h.editor.transact("Move") { tx in
            expect(tx.move([tree.a], to: tree.eBoard))
            slide(&tx, tree.a, on: tree.eBoard, to: 60)
            tx.delete([tree.a], on: tree.eBoard)
            expectEqual(tx.contents(of: tree.eBoard).shapes.count, 0)
            expect(tx.move([tree.b], to: tree.eBoard))
        }
        var change = try require(log.changes.last)
        expectEqual(change.boardsAdded, [tree.eBoard])
        expectEqual(change.removed, [tree.a, tree.b])
        expectEqual(ids(h, tree.eBoard), [tree.b])
        var after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
        h.editor.undo()

        // A pocket put in with a board of one shape, which is then deleted there: the pocket comes alone.
        let fresh = ShapeID(), inside = ShapeID()
        h.editor.transact("Paste") { tx in
            tx.insert(pocket(fresh), contents: [fresh: board(box(inside))])
            tx.delete([inside], on: BoardID(owner: fresh))
            expectEqual(tx.board(containing: inside), nil)
        }
        change = try require(log.changes.last)
        expectEqual(change.added, [fresh])
        expectEqual(change.boardsAdded, [], "its board ended empty")
        expect(h.file.children[fresh] == nil)
        after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo the paste")
        h.editor.redo()
        try expectFile(h, after, "redo the paste")
        h.editor.undo()

        // A far delete empties W's board, then a shape moves onto it: changed, not added.
        h.editor.transact("Swap") { tx in
            tx.delete([tree.d, tree.d2], on: tree.wBoard)
            expect(tx.move([tree.a], to: tree.wBoard))
        }
        change = try require(log.changes.last)
        expectEqual(change.boardsChanged, [tree.wBoard])
        expectEqual(change.boardsAdded, [])
        expectEqual(ids(h, tree.wBoard), [tree.a])
        after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo the swap")
        h.editor.redo()
        try expectFile(h, after, "redo the swap")
    },
    test("a pocket put in with its board, moved onto a far board with a box, deleted there by the box's handler: it never was") {
        let tree = Isles(), log = ChangeLog(), fresh = ShapeID(), inside = ShapeID(), deeper = ShapeID(), bottom = ShapeID()
        let cascading = Contributor(id: "cascades") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a), tx.document[fresh] != nil { tx.delete([fresh]) }
            }
        }
        let h = try harness(tree.file, [cascading, recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { tx in
            tx.insert(pocket(fresh), contents: [fresh: board(box(inside), pocket(deeper)), deeper: board(box(bottom))])
            expect(tx.move([tree.a, fresh], to: tree.pBoard))
            tx.delete([tree.a], on: tree.pBoard)
            expectEqual(tx.board(containing: fresh), nil)
            expectEqual(tx.board(containing: bottom), nil)
        }
        expect(h.file.record(fresh) == nil && h.file.record(inside) == nil && h.file.record(bottom) == nil)
        let change = try require(log.changes.last)
        expectEqual(change.boardsAdded, [])
        expectEqual(change.boardsRemoved, [])
        expectEqual(change.removed, [tree.a])
        expectEqual(ids(h, tree.pBoard), before[tree.pBoard].shapes.map(\.id))
        expectEqual(orphans(h), [])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    // MARK: The open step and a step on another board

    test("inside a group: a write that holds W, a step on P that deletes on W, another write: every step back and forward is exact") {
        let tree = Isles()
        let h = try harness(tree.file)
        var states = [h.file]
        h.editor.undoHistory.group("Press") {
            h.editor.transact { slide(&$0, tree.d, on: tree.wBoard, to: 5) }
            states.append(h.file)
            h.editor.transact(on: tree.pBoard, "Elsewhere") { $0.delete([tree.d2], on: tree.wBoard) }
            states.append(h.file)
            h.editor.transact { tx in
                slide(&tx, tree.d, on: tree.wBoard, to: 6)
                tx.update(tree.a, as: Box.self) { $0.props.frame.origin.x = 8 }
            }
            states.append(h.file)
        }
        try roundTrip(h, states, "in a group")
    },
    test("a run that empties W's board, then a step on P that moves a shape onto W (a board added that the run holds): exact") {
        let tree = Isles()
        let h = try harness(tree.file)
        var states = [h.file]
        h.editor.transact("Run", coalescing: "k") { $0.delete([tree.d, tree.d2], on: tree.wBoard) }
        states.append(h.file)
        h.editor.transact(on: tree.pBoard, "Elsewhere") { _ = $0.move([tree.m], to: tree.wBoard) }
        states.append(h.file)
        expectEqual(h.file.board(containing: tree.m), tree.wBoard)
        try roundTrip(h, states, "a board added")
    },
    test("a run that holds Q's board, then a step on W that takes P from the root: exact") {
        let tree = Isles()
        let h = try harness(tree.file)
        expect(h.enter(tree.e))
        var states = [h.file]
        h.editor.transact("Run", coalescing: "k") { slide(&$0, tree.c, on: tree.qBoard, to: 5) }
        states.append(h.file)
        h.editor.transact(on: tree.wBoard, "Elsewhere") { $0.delete([tree.p], on: .root) }
        states.append(h.file)
        expect(h.file.record(tree.c) == nil)
        try roundTrip(h, states, "a board taken from a third board")
    },
    test("a run stays one step when a step on another board reaches nothing it holds") {
        let tree = Isles()
        let h = try harness(tree.file)
        var states = [h.file]
        h.editor.transact("Run", coalescing: "k") { slide(&$0, tree.d, on: tree.wBoard, to: 5) }
        h.editor.transact(on: tree.pBoard, "Elsewhere") { tx in
            tx.update(tree.m, as: Box.self) { $0.props.frame.origin.x = 9 }
            tx.delete([tree.c], on: tree.qBoard)
        }
        states.append(h.file)   // After the step on P: undone last, since the run is still open above it.
        h.editor.transact("Run", coalescing: "k") { slide(&$0, tree.d, on: tree.wBoard, to: 6) }
        h.editor.undoHistory.seal()
        let final = h.file
        expectEqual(h.editor.undoHistory.undoName, "Run")
        h.editor.undo()
        expectEqual(h.file.record(tree.d)?.box?.minX, 0, "the run's two commits are one step")
        expectEqual(h.editor.undoHistory.undoName, "Elsewhere")
        h.editor.undo()
        try expectFile(h, states[0], "all undone")
        expect(!h.editor.canUndo)
        h.editor.redo()
        h.editor.redo()
        try expectFile(h, final, "all redone")
    },
    test("a run on Q's board that holds the root, then a step on W that moves a shape onto the root; and one that deletes on the root: exact") {
        let tree = Isles()
        for deleting in [false, true] {
            let h = try harness(tree.file)
            expect(h.enter(tree.p) && h.enter(tree.q))
            var states = [h.file]
            h.editor.transact("Run", coalescing: "k") { tx in
                slide(&tx, tree.a, on: .root, to: 5)
                tx.update(tree.c, as: Box.self) { $0.props.frame.origin.x = 3 }
            }
            states.append(h.file)
            h.editor.transact(on: tree.wBoard, "Elsewhere") { tx in
                if deleting { tx.delete([tree.b], on: .root) } else { _ = tx.move([tree.d], to: .root) }
            }
            states.append(h.file)
            expect(states[1] != states[2])
            h.editor.transact("Run", coalescing: "k") { slide(&$0, tree.a, on: .root, to: 6) }
            states.append(h.file)
            try roundTrip(h, states, deleting ? "a delete on the root" : "a move onto the root")
        }
    },

    // MARK: transact(on:)

    test("from a board that isn't shown, a delete on a third board whose handler deletes the owner of the (empty) board shown: nothing committed") {
        let tree = Isles()
        let cascading = Contributor(id: "cascades") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.a) { tx.delete([tree.e]) }
            }
        }
        let h = try harness(tree.file, [cascading])
        expect(h.enter(tree.e))
        let before = h.file
        h.editor.transact(on: tree.wBoard, "Remove") { $0.delete([tree.a], on: .root) }
        try expectFile(h, before, "nothing committed")
        expect(h.editor.canShow(h.editor.board))
        expect(!h.editor.canUndo)
        // Q's board shown: Q moved under W and deleted there takes the board shown.
        let g = try harness(tree.file)
        expect(g.enter(tree.p) && g.enter(tree.q))
        g.editor.transact(on: tree.wBoard, "Remove") { tx in
            _ = tx.move([tree.q], from: tree.pBoard, to: tree.wBoard)
            tx.delete([tree.q])
        }
        try expectFile(g, before, "nothing committed")
        expect(g.editor.canShow(g.editor.board))
    },

    // MARK: What a handler puts on the board shown

    test("a far delete whose handler deletes on the board shown, whose handler puts a shape in there: the commit names it added, and undo takes it out") {
        let tree = Isles(), log = ChangeLog(), fresh = ShapeID()
        let leaving = Contributor(id: "leaves a mark") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.b]) }
                if deleted.contains(tree.b) { tx.insert(box(fresh, x: 900)) }
            }
        }
        let h = try harness(tree.file, [leaving, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.m], on: tree.pBoard) }
        expect(h.file.record(tree.m) == nil && h.file.record(tree.b) == nil)
        expectEqual(h.file.board(containing: fresh), .root, "the handler's shape is on the board shown")
        let change = try require(log.changes.last)
        expectEqual(change.removed, [tree.b])
        expectEqual(change.added, [fresh], "the commit names the shape that came")
        expectPaintsTheBoard(h, "painted")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a shape put in by a handler on the board shown, with no board crossed (B deleted on the board shown), is exact") {
        let tree = Isles(), log = ChangeLog(), fresh = ShapeID()
        let leaving = Contributor(id: "leaves a mark") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.b) { tx.insert(box(fresh, x: 900)) }
            }
        }
        let h = try harness(tree.file, [leaving, recordingChanges(log)])
        let before = h.file
        h.editor.transact("Remove") { $0.delete([tree.b]) }
        expectEqual(log.changes.last?.added, [fresh])
        h.editor.undo()
        try expectFile(h, before, "undo")
    },
    test("from transact(on:): a delete on a third board whose handler deletes on the transaction's board, whose handler puts a shape in there: undo takes it out") {
        let tree = Isles(), fresh = ShapeID()
        let leaving = Contributor(id: "leaves a mark") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.d) { tx.delete(inFile: [tree.m]) }
                if deleted.contains(tree.m) { tx.insert(box(fresh, x: 900)) }
            }
        }
        let h = try harness(tree.file, [leaving])
        let before = h.file
        h.editor.transact(on: tree.pBoard, "Remove") { $0.delete([tree.d], on: tree.wBoard) }
        expect(h.file.record(tree.m) == nil && h.file.record(tree.d) == nil)
        expectEqual(h.file.board(containing: fresh), tree.pBoard)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("a shape moved onto a far board, moved back by a far delete's handler, then deleted on the board shown: it is on no board, and can be put in again") {
        let tree = Isles()
        let returning = Contributor(id: "returns") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.r) { _ = tx.move([tree.a], to: .root) }
            }
        }
        let h = try harness(tree.file, [returning])
        let before = h.file
        h.editor.transact("Remove") { tx in
            expect(tx.move([tree.a], to: tree.pBoard))
            tx.delete([tree.r], on: tree.pBoard)
            expectEqual(tx.board(containing: tree.a), .root, "the handler brought it back")
            tx.delete([tree.a])
            expectEqual(tx.board(containing: tree.a), nil, "deleted: on no board")
        }
        expect(h.file.record(tree.a) == nil)
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },

    test("a far delete whose handler deletes on the board shown, whose handler moves a shape from the far board onto the board shown: the commit names it added, the file knows where it is, undo exact") {
        let tree = Isles(), log = ChangeLog()
        let bringing = Contributor(id: "brings") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.m) { tx.delete(inFile: [tree.b]) }
                if deleted.contains(tree.b) { _ = tx.move([tree.z], from: tree.pBoard, to: .root) }
            }
        }
        let h = try harness(tree.file, [bringing, recordingChanges(log)])
        let before = h.file
        _ = h.editor.paintOrder()
        h.editor.transact("Remove") { $0.delete([tree.m], on: tree.pBoard) }
        expect(h.editor.document[tree.z] != nil, "Z is in the document of the board shown")
        expectEqual(h.file.board(containing: tree.z), .root, "and the file knows it is there")
        let change = try require(log.changes.last)
        expectEqual(change.added, [tree.z], "the commit names the shape that came")
        expectPaintsTheBoard(h, "painted")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
    test("Delete Hidden Shapes whose handler deletes a pocket on another board: the pocket goes, and its board with it") {
        func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
        func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } },
          "shapes" : [ { "id" : "\(uuid(1))", "kind" : "gadget", "index" : "a0", "props" : { } },
                       { "id" : "\(uuid(2))", "kind" : "pocket", "index" : "a1", "props" : { "frame" : [[0, 0], [10, 10]] } } ],
          "boards" : {
            "\(uuid(2))" : { "shapes" : [ { "id" : "\(uuid(3))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [1, 1]] } },
                                         { "id" : "\(uuid(4))", "kind" : "pocket", "index" : "a1", "props" : { "frame" : [[0, 0], [10, 10]] } } ] },
            "\(uuid(4))" : { "shapes" : [ { "id" : "\(uuid(5))", "kind" : "box", "index" : "a0", "props" : { "frame" : [[0, 0], [1, 1]] } } ] }
          } }
        """
        let gadget = id(1), p = id(2), q = id(4), c = id(5)
        let taking = Contributor(id: "takes") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(gadget) { tx.delete([q], on: BoardID(owner: p)) }
            }
        }
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), taking])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        expectEqual(Set(loaded.report.keptAside.map(\.id)), [gadget])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), taking], file: loaded.file)
        let before = h.file
        expect(h.editor.discardKeptAside(shapes: [gadget], boards: []))
        expect(h.file.record(gadget) == nil, "the gadget went")
        expect(h.file.record(q) == nil, "the pocket the handler deleted on another board went")
        expect(h.file.record(c) == nil, "and what its board held went with it")
        h.editor.undo()
        try expectFile(h, before, "undo")
    },

    // MARK: What rides along

    test("rodeAlong after a refused move, after two moves, and with a corral that moves with the boxes a link joins") {
        let m = ShapeID(), n = ShapeID(), x = ShapeID(), y = ShapeID(), l = ShapeID(), lx = ShapeID(), p = ShapeID(), w = ShapeID(), f = ShapeID()
        let k = ShapeID(), i1 = ShapeID(), i2 = ShapeID(), li = ShapeID(), lo = ShapeID()
        var frozenBox = box(f, x: 400)
        frozenBox[Frozen.self] = true
        let corral = AnyShapeRecord(ShapeRecord(id: k, Corral(CGRect(x: 0, y: 500, width: 300, height: 300))))
        var in1 = AnyShapeRecord(ShapeRecord(id: i1, Box(CGRect(x: 10, y: 510, width: 40, height: 30))))
        in1 = in1.copy(as: i1, container: k)
        var in2 = AnyShapeRecord(ShapeRecord(id: i2, Box(CGRect(x: 100, y: 510, width: 40, height: 30))))
        in2 = in2.copy(as: i2, container: k)
        let file = CanvasFile(root: board(box(m), box(n, x: 100), box(x, x: 200), box(y, x: 300), frozenBox, corral, in1, in2,
                                          link(l, m, n), link(lx, x, nil), link(li, i1, i2), link(lo, i1, m), pocket(p), pocket(w)))
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin(), CorralsPlugin(), FreezingPlugin()], file: file)
        let before = h.file
        expectEqual(before.record(i1)?.container, k, "the fixture: in the corral")
        h.editor.transact("Move") { tx in
            expect(!tx.move([m, n, f], to: BoardID(owner: p)), "refused whole")
            expectEqual(tx.rodeAlong, [], "a refused move took nothing along")
        }
        try expectFile(h, before, "nothing")
        h.editor.transact("Move") { tx in
            expect(tx.move([m, n], to: BoardID(owner: p)))
            expectEqual(tx.rodeAlong, [l])
            expect(tx.move([x], to: BoardID(owner: w)))
            expectEqual(tx.rodeAlong, [l, lx], "both moves'")
            expect(tx.move([k], to: BoardID(owner: w)))
            expectEqual(tx.rodeAlong, [l, lx, li, lo], "the link between two boxes the corral holds rides with it, and the one that let go of M at the first move")
        }
        expectEqual(h.file.board(containing: li), BoardID(owner: w))
        expectEqual(h.file.record(li)?.typed(as: Link.self)?.props, Link(from: i1, to: i2))
        expectEqual(h.file.record(i1)?.container, k, "still in the corral there")
        expectEqual(h.file.board(containing: lo), BoardID(owner: w), "bound only to a box in the corral once it let go of M: it rides")
        expectEqual(h.file.record(lo)?.typed(as: Link.self)?.props, Link(from: i1, to: nil))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "undo")
        h.editor.redo()
        try expectFile(h, after, "redo")
    },
])
