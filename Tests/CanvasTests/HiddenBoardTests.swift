@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// What reaches boards that aren't shown: a commit on one (`transact(on:)`, what lands late, as a
// language model's answer for a card on a board left since), and what every commit says it did
// there (`ChangeSet.elsewhere`).

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(unit))) }
private func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding box A and pocket P; P's board holds box B and pocket Q; Q's holds box C.
private struct Nest {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
    var file: CanvasFile { CanvasFile(root: board(box(a), pocket(p)), children: [p: board(box(b), pocket(q)), q: board(box(c))]) }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
}

/// Every commit's change set, and every switch as it was heard (without working out its changes).
@MainActor private final class Heard {
    var changes: [ChangeSet] = []
    var switches: [BoardChange] = []
}

private final class Listener {
    let heard: Heard
    init(heard: Heard) { self.heard = heard }
}

extension Listener: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { heard.changes.append(changes) }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { heard.switches.append(change) }
}

@MainActor private func harness(_ file: CanvasFile, _ heard: Heard = Heard()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), Contributor(id: "listener") { r in r.service { _ in Listener(heard: heard) } }],
                      file: file)
}

@MainActor private func x(_ h: EditorHarness, _ id: ShapeID) -> CGFloat? { h.file.record(id)?.box?.minX }

@MainActor private func nudge(_ h: EditorHarness, _ id: ShapeID, to x: CGFloat, on board: BoardID? = nil, key: String? = nil) {
    if let board {
        h.editor.transact(on: board, "Nudge") { $0.update(id, as: Box.self) { $0.props.frame.origin.x = x } }
    } else {
        h.editor.transact("Nudge", coalescing: key) { $0.update(id, as: Box.self) { $0.props.frame.origin.x = x } }
    }
}

@MainActor let hiddenBoardTests = Suite("Commits on boards that aren't shown", [
    test("a commit on a board that isn't shown changes it in the file, not the board shown, and services hear which board and shapes") {
        let tree = Nest(), heard = Heard()
        let h = try harness(tree.file, heard)
        let shown = h.editor.document, revision = h.editor.revision, pRevision = h.file.revision(of: tree.pBoard)
        let result = h.editor.transact(on: tree.pBoard, "Nudge") { transaction -> Int in
            expectEqual(transaction.board, tree.pBoard)
            expectEqual(transaction.document, tree.file[tree.pBoard], "the board's shapes, as the file has them")
            transaction.update(tree.b, as: Box.self) { $0.props.frame.origin.x = 30 }
            return 7
        }
        expectEqual(result, 7)
        expectEqual(h.editor.board, .root, "nothing is shown")
        expectEqual(h.editor.document, shown)
        expectEqual(x(h, tree.b), 30)
        expect(h.file.revision(of: tree.pBoard) != pRevision, "the board's revision moves on")
        expect(h.editor.revision > revision)
        let changes = try require(heard.changes.last)
        expectEqual(changes.shapeIDs, [], "no shape of the board shown")
        expectEqual(changes.boardsChanged, [tree.pBoard])
        expectEqual(changes.elsewhere, [tree.b])
        expect(h.enter(tree.p))
        expectEqual(h.editor.document[tree.b]?.box?.minX, 30)
    },
    test("it's a step of its own, made on its board: undoing it from another shows that board, and redoing it too") {
        let tree = Nest()
        let h = try harness(tree.file)
        nudge(h, tree.b, to: 30, on: tree.pBoard)
        expectEqual(h.editor.undoHistory.undoName, "Nudge")
        expect(h.editor.canUndo)
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard, "its board is shown")
        expectEqual(x(h, tree.b), 0)
        expect(!h.editor.canUndo)
        expect(h.editor.showBoard(.root))
        h.editor.redo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(x(h, tree.b), 30)
    },
    test("a step open on the board shown stays open, and comes after it") {
        let tree = Nest()
        let h = try harness(tree.file)
        nudge(h, tree.a, to: 10, key: "run")
        nudge(h, tree.b, to: 30, on: tree.pBoard)
        nudge(h, tree.a, to: 20, key: "run")
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 0, "the run is one step, both of its commits")
        expectEqual(x(h, tree.b), 30)
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(x(h, tree.b), 0)
        expect(!h.editor.canUndo)
    },
    test("on the board shown it's a transaction as any; on one that can't be shown it does nothing") {
        let tree = Nest(), heard = Heard()
        let h = try harness(tree.file, heard)
        nudge(h, tree.a, to: 10, on: .root)
        expectEqual(heard.changes.last?.changed, [tree.a])
        expectEqual(h.editor.undoHistory.undoName, "Nudge")
        let count = heard.changes.count
        let nowhere: Int? = h.editor.transact(on: BoardID(owner: ShapeID())) { transaction in
            transaction.insert(box(ShapeID()))
            return 1
        }
        expect(nowhere == nil)
        expectEqual(heard.changes.count, count)
    },
    test("it can't take the board shown, or one above it, with a shape it deletes") {
        let tree = Nest()
        let h = try harness(tree.file)
        expect(h.enter(tree.p) && h.enter(tree.q))
        h.editor.transact(on: .root) { $0.delete([tree.p]) }
        expectEqual(h.editor.board, tree.qBoard)
        expect(h.file.record(tree.p) != nil, "nothing is committed")
        expect(!h.editor.canUndo)
        h.editor.transact(on: .root) { $0.delete([tree.a]) }
        expect(h.file.record(tree.a) == nil, "a shape off the path goes")

        // Q's board empty: the file lists no board of Q's to take, but Q owns the board shown.
        let empty = try harness(CanvasFile(root: board(box(tree.a), pocket(tree.p)), children: [tree.p: board(box(tree.b), pocket(tree.q))]))
        expect(empty.enter(tree.p) && empty.enter(tree.q))
        empty.editor.transact(on: tree.pBoard) { $0.delete([tree.q]) }
        expectEqual(empty.editor.board, tree.qBoard)
        expect(empty.file.record(tree.q) != nil, "nothing is committed")
        expect(empty.editor.canShow(tree.qBoard))
        empty.editor.transact(on: .root) { $0.delete([tree.p]) }
        expect(empty.file.record(tree.p) != nil, "nor above it")
        expect(!empty.editor.canUndo)
    },
    test("a deletion names the shapes of the boards it takes as elsewhere, and so does undoing it") {
        let tree = Nest(), heard = Heard()
        let h = try harness(tree.file, heard)
        h.editor.transact { $0.delete([tree.p]) }
        expectEqual(heard.changes.last?.removed, [tree.p])
        expectEqual(heard.changes.last?.elsewhere, [tree.b, tree.q, tree.c])
        h.editor.undo()
        expectEqual(heard.changes.last?.added, [tree.p])
        expectEqual(heard.changes.last?.elsewhere, [tree.b, tree.q, tree.c])
        h.editor.transact { $0.update(tree.a, as: Box.self) { $0.props.frame.origin.x = 5 } }
        expectEqual(heard.changes.last?.elsewhere, [], "an edit of the board shown alone")
    },
    test("a file put in place over the board shown names what changed on its other boards; over another, the switch says a file was") {
        let tree = Nest(), heard = Heard()
        let h = try harness(tree.file, heard)
        let inside = board(AnyShapeRecord(ShapeRecord(id: tree.b, Box(unit.offsetBy(dx: 40, dy: 0)))), pocket(tree.q))
        let moved = CanvasFile(root: tree.file.root, children: [tree.p: inside, tree.q: tree.file[tree.qBoard]])
        h.editor.replaceFile(with: moved)
        expectEqual(heard.changes.last?.replacedDocument, true)
        expectEqual(heard.changes.last?.shapeIDs, [])
        expectEqual(heard.changes.last?.elsewhere, [tree.b])
        h.editor.replaceFile(with: tree.file, showing: tree.pBoard)
        expectEqual(heard.switches.last?.isFileReplaced, true)
        expect(h.enter(tree.q))
        expectEqual(heard.switches.last?.isFileReplaced, false, "showing a board is no file put in place")
    },
])
