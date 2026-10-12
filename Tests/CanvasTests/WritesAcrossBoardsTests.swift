@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A transaction writes to shapes on other boards of the file in the same step as its own board's
// edit (`update(_:on:)`), and a `willDelete` handler does it inside the delete's own step: one undo
// puts every board back, exactly, and one redo does it all again.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID(), _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID, _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding box A and pocket P; P's board holds box B and pocket Q; Q's holds box C.
private struct Stack {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
    var file: CanvasFile { file(frozen: []) }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }

    /// The file, with these shapes frozen (read-only, with `FreezingPlugin`).
    func file(frozen: Set<ShapeID>) -> CanvasFile {
        func shape(_ record: AnyShapeRecord) -> AnyShapeRecord {
            var record = record
            if frozen.contains(record.id) { record[Frozen.self] = true }
            return record
        }
        return CanvasFile(root: board(shape(box(a)), shape(pocket(p, CGRect(x: 200, y: 0, width: 100, height: 100)))),
                          children: [p: board(shape(box(b)), shape(pocket(q))), q: board(shape(box(c)))])
    }
}

/// Deleting A (or P, or B) puts B at x 500 and C at x 700, whichever board each is on: what a plugin
/// does to the shapes elsewhere that depended on what's deleted.
private func takingBack(_ tree: Stack, whenDeleting trigger: ShapeID) -> Contributor {
    Contributor(id: "takes-back") { r in
        r.willDelete { deleted, tx in
            guard deleted.contains(trigger) else { return }
            tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = 500 }
            tx.update(tree.c, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 700 }
        }
    }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()] + more, file: file)
}

@MainActor private func x(_ h: EditorHarness, _ id: ShapeID) -> CGFloat? { h.file.record(id)?.box?.minX }

/// The file, and the file as a board file's bytes: what a round trip must come back to.
@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

@MainActor private final class Steps {
    var began = 0
}

/// A cheap way to count the undo steps a body opens.
@MainActor private func steps(_ h: EditorHarness, _ body: () -> Void) -> Int {
    let steps = Steps()
    h.editor.undoHistory.didChange = { if $0 == .began { steps.began += 1 } }
    defer { h.editor.undoHistory.didChange = { _ in } }
    body()
    return steps.began
}

@MainActor let writesAcrossBoardsTests = Suite("Writes across boards", [
    test("a willDelete handler's writes on two other boards are in the delete's own step: one undo puts every board back, one redo does them again") {
        let tree = Stack(), log = ChangeLog()
        let h = try harness(tree.file, [takingBack(tree, whenDeleting: tree.a), recordingChanges(log)])
        let before = h.file
        let opened = steps(h) { h.editor.transact("Delete") { $0.delete([tree.a]) } }
        expectEqual(opened, 1, "one step")
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        expectEqual(h.file.record(tree.a), nil)
        expectEqual(x(h, tree.b), 500, "P's board")
        expectEqual(x(h, tree.c), 700, "Q's, under it")
        expectEqual(h.file.record(tree.p)?.box?.minX, 200, "what the handler didn't write is as it was")
        let after = h.file

        h.editor.undo()
        try expectFile(h, before, "undoing it puts back all three boards")
        expect(!h.editor.canUndo, "and there was no other step to undo")
        h.editor.redo()
        try expectFile(h, after, "redoing it does all three again")
        expect(!h.editor.canRedo)
        h.editor.undo()
        try expectFile(h, before, "and back")
    },
    test("services hear every board it wrote to: on the commit, on the undo and on the redo") {
        let tree = Stack(), log = ChangeLog()
        let h = try harness(tree.file, [takingBack(tree, whenDeleting: tree.a), recordingChanges(log)])
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        var heard = log.changes.last!
        expectEqual(heard.removed, [tree.a])
        expectEqual(heard.boardsChanged, [tree.pBoard, tree.qBoard])
        expectEqual(heard.boardsRemoved, [])
        expect(heard.elsewhere.isSuperset(of: [tree.b, tree.c]), "the shapes it touched on them")
        expect(!heard.elsewhere.contains(tree.p), "and only those")
        expect(!heard.restoredStep)

        h.editor.undo()
        heard = log.changes.last!
        expect(heard.restoredStep)
        expectEqual(heard.added, [tree.a])
        expectEqual(heard.boardsChanged, [tree.pBoard, tree.qBoard])
        expect(heard.elsewhere.isSuperset(of: [tree.b, tree.c]))

        h.editor.redo()
        heard = log.changes.last!
        expect(heard.restoredStep)
        expectEqual(heard.removed, [tree.a])
        expectEqual(heard.boardsChanged, [tree.pBoard, tree.qBoard])
        expect(heard.elsewhere.isSuperset(of: [tree.b, tree.c]))
    },
    test("a board shown before is shown again as the write left it, and as undo left it: nothing kept of it is stale") {
        let tree = Stack()
        let h = try harness(tree.file, [takingBack(tree, whenDeleting: tree.a)])
        expect(h.enter(tree.p))
        let boundsBefore = h.editor.shapeContext.bounds(of: [tree.b])
        expect(h.editor.showBoard(.root))
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expect(h.enter(tree.p))
        expectEqual(h.editor.document[tree.b]?.box?.minX, 500)
        expectEqual(h.editor.shapeContext.bounds(of: [tree.b])?.minX, 500, "its index follows")
        expect(h.editor.showBoard(.root))
        h.editor.undo()
        expect(h.enter(tree.p))
        expectEqual(h.editor.document[tree.b]?.box?.minX, 0)
        expectEqual(h.editor.shapeContext.bounds(of: [tree.b]), boundsBefore)
    },
    test("the board shown can be the one below, writing above it: the same step, the same undo") {
        let tree = Stack()
        let up = Contributor(id: "up") { r in
            r.willDelete { deleted, tx in
                if deleted.contains(tree.b) { tx.update(tree.a, on: .root, as: Box.self) { $0.props.frame.origin.x = 40 } }
            }
        }
        let h = try harness(tree.file, [up])
        let before = h.file
        expect(h.enter(tree.p))
        let opened = steps(h) { h.editor.transact("Delete") { $0.delete([tree.b]) } }
        expectEqual(opened, 1)
        expectEqual(x(h, tree.a), 40)
        expectEqual(h.file.record(tree.b), nil)
        h.editor.undo()
        try expectFile(h, before, "both boards back")
        expectEqual(h.editor.board, tree.pBoard, "on the board the step was made on")
    },
    test("a write to a shape that isn't on that board, or to a board with no shapes, does nothing, and opens no step") {
        let tree = Stack()
        let h = try harness(tree.file)
        let before = h.file
        let opened = steps(h) {
            h.editor.transact("Nothing") { tx in
                tx.update(tree.c, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = 9 }    // C is on Q's
                tx.update(tree.c, on: BoardID(owner: tree.a), as: Box.self) { $0.props.frame.origin.x = 9 }    // A owns none
                tx.update(ShapeID(), on: tree.qBoard) { _ in }
            }
        }
        expectEqual(opened, 0)
        try expectFile(h, before, "nothing changed")
        expect(!h.editor.canUndo)
    },
    test("a board the editor can't show takes no write: its owner isn't of a kind that owns boards") {
        let a = ShapeID(), x = ShapeID(), other = ShapeID()
        let file = CanvasFile(root: board(box(a)), children: [a: board(box(x))])
        let h = try harness(file)
        expect(!h.editor.canShow(BoardID(owner: a)))
        let before = h.file
        let wrote = h.editor.transact("Nothing") { tx in
            tx.update(x, on: BoardID(owner: a), as: Box.self) { $0.props.frame.origin.x = 9 }
            tx.update(other, on: BoardID(owner: other)) { _ in }
            return tx.board(containing: x)
        }
        expectEqual(wrote, BoardID(owner: a), "it's found where it is")
        try expectFile(h, before, "and unchanged")
    },
    test("any transaction can write elsewhere: its own board's edit and the others' are one step, and undo and redo take them together") {
        let tree = Stack()
        let h = try harness(tree.file)
        let before = h.file
        let opened = steps(h) {
            h.editor.transact("Tidy") { tx in
                tx.update(tree.a, as: Box.self) { $0.props.frame.origin.x = 11 }
                tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = 22 }
                tx.update(inFile: tree.c) { $0.box = CGRect(x: 33, y: 0, width: 100, height: 100) }
                expectEqual(tx.board(containing: tree.c), tree.qBoard)
                expectEqual(tx.contents(of: tree.pBoard)[tree.b]?.box?.minX, 22, "and read back as the transaction leaves it")
            }
        }
        expectEqual(opened, 1)
        expectEqual(h.editor.undoHistory.undoName, "Tidy")
        expectEqual([x(h, tree.a), x(h, tree.b), x(h, tree.c)], [11, 22, 33])
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "one undo")
        h.editor.redo()
        try expectFile(h, after, "one redo")
    },
    test("a shape moved onto a board in the same transaction is found there, and written there") {
        let tree = Stack()
        let h = try harness(tree.file)
        h.editor.transact("Move and write") { tx in
            expect(tx.move([tree.a], to: tree.qBoard))
            expectEqual(tx.board(containing: tree.a), tree.qBoard)
            tx.update(tree.a, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 77 }
        }
        expectEqual(h.file.board(containing: tree.a), tree.qBoard)
        expectEqual(x(h, tree.a), 77)
        h.editor.undo()
        expectEqual(h.file.board(containing: tree.a), .root)
        expectEqual(x(h, tree.a), 0)
    },
    test("a shape deleted in the transaction, or on a board it took, takes no write") {
        let tree = Stack()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact("Delete P") { tx in
            tx.delete([tree.p])
            expectEqual(tx.board(containing: tree.c), nil, "its boards went with it")
            tx.update(tree.c, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 9 }
            tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = 9 }
        }
        expectEqual(h.file.children, [:])
        expectEqual(h.file.shapeCount, 1)
        h.editor.undo()
        try expectFile(h, before, "back as it was, the writes that found nothing there left no trace")
    },
    test("a handler writing to a board that goes with the same delete leaves that board gone, and undo brings it back as it was") {
        let tree = Stack(), log = ChangeLog()
        let h = try harness(tree.file, [takingBack(tree, whenDeleting: tree.p), recordingChanges(log)])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(h.file.children, [:], "no board is left behind by the write")
        expectEqual(log.changes.last?.boardsRemoved, [tree.pBoard, tree.qBoard])
        expectEqual(log.changes.last?.boardsChanged, [], "and none is also changed")
        h.editor.undo()
        try expectFile(h, before, "every id as it was, the writes undone with the boards")
        h.editor.redo()
        expectEqual(h.file.children, [:])
    },
    test("a handler may delete a shape that owns a board above the one it wrote to, in the same delete") {
        let tree = Stack()
        let both = Contributor(id: "both") { r in
            r.willDelete { deleted, tx in
                guard deleted.contains(tree.a) else { return }
                tx.update(tree.c, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 700 }
                tx.delete([tree.p])
            }
        }
        let h = try harness(tree.file, [both])
        let before = h.file
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expectEqual(h.file.record(tree.p), nil)
        expectEqual(h.file.children, [:], "Q's board went with P's, and the write with it")
        h.editor.undo()
        try expectFile(h, before, "back")
    },
    test("two handlers writing to the same board both land, in plugin order") {
        let tree = Stack()
        func writer(_ id: PluginID, _ value: CGFloat, only: Bool = false) -> Contributor {
            Contributor(id: id) { r in
                r.willDelete { deleted, tx in
                    guard deleted.contains(tree.a) else { return }
                    tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = value }
                    if !only { tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.size.width += 1 } }
                }
            }
        }
        let h = try harness(tree.file, [writer("first", 5), writer("second", 6, only: true)])
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expectEqual(h.file.record(tree.b)?.box, CGRect(x: 6, y: 0, width: 101, height: 100))
        h.editor.undo()
        expectEqual(h.file.record(tree.b)?.box, unit)
    },
    test("a hidden-board transaction writes to a third board in its own step, on its board") {
        let tree = Stack()
        let h = try harness(tree.file)
        let before = h.file
        let opened = steps(h) {
            h.editor.transact(on: tree.pBoard, "Hidden") { tx in
                tx.update(tree.b, as: Box.self) { $0.props.frame.origin.x = 8 }
                tx.update(tree.c, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 9 }
            }
        }
        expectEqual(opened, 1)
        expectEqual([x(h, tree.b), x(h, tree.c)], [8, 9])
        h.editor.undo()
        try expectFile(h, before, "one undo for both")
        expectEqual(h.editor.board, tree.pBoard, "shown for its step")
    },
    test("a hidden-board transaction reaching the board shown commits nothing, as moving shapes onto it does") {
        let tree = Stack()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact(on: tree.pBoard, "Reach") { tx in
            tx.update(tree.b, as: Box.self) { $0.props.frame.origin.x = 8 }
            tx.update(tree.a, on: .root, as: Box.self) { $0.props.frame.origin.x = 8 }
        }
        try expectFile(h, before, "nothing was written")
        expect(!h.editor.canUndo)
    },
])

@MainActor let writesAcrossReadOnlyTests = Suite("Writes across read-only boards", [
    test("the delete's own writes go through a read-only shape, and a board that's read-only, as its handlers' writes on its board do") {
        let tree = Stack(), log = RefusalLog()
        // B is frozen, and so is Q, which makes its board (C's) read-only.
        let file = tree.file(frozen: [tree.b, tree.q])
        let h = try harness(file, [FreezingPlugin(log: log), takingBack(tree, whenDeleting: tree.a)])
        expect(h.editor.isReadOnly(inFile: tree.b) && h.editor.isReadOnly(inFile: tree.c) && h.editor.isReadOnly(board: tree.qBoard))
        h.editor.transact("Delete") { $0.delete([tree.a]) }
        expectEqual([x(h, tree.b), x(h, tree.c)], [500, 700])
        expectEqual(log.refusals, [], "nothing was refused: the handler keeps the board whole")
        h.editor.undo()
        try expectFile(h, file, "and undone whole")
    },
    test("any other write refuses a read-only shape or board, as it does on the board shown: it stays, and services hear it") {
        let tree = Stack(), log = RefusalLog()
        let file = tree.file(frozen: [tree.b, tree.q])
        let h = try harness(file, [FreezingPlugin(log: log)])
        var refused: Set<ShapeID> = []
        let opened = steps(h) {
            h.editor.transact("Write") { tx in
                tx.update(tree.b, on: tree.pBoard, as: Box.self) { $0.props.frame.origin.x = 5 }
                tx.update(tree.c, on: tree.qBoard, as: Box.self) { $0.props.frame.origin.x = 6 }
                refused = tx.refusedShapes
            }
        }
        try expectFile(h, file, "unchanged")
        expectEqual(opened, 0, "and it is no step")
        expectEqual(refused, [tree.b, tree.c])
        expectEqual(log.refusals, [[tree.b, tree.c]])
    },
    test("a write that leaves a shape no longer read-only goes through: it thaws") {
        let tree = Stack(), log = RefusalLog()
        let h = try harness(tree.file(frozen: [tree.b]), [FreezingPlugin(log: log)])
        h.editor.transact("Thaw") { $0.update(tree.b, on: tree.pBoard) { $0[Frozen.self] = nil } }
        expectEqual(h.file.record(tree.b)?[Frozen.self], nil)
        expectEqual(log.refusals, [])
        h.editor.undo()
        expectEqual(h.file.record(tree.b)?[Frozen.self], true)
    },
])
