@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// One history for every board of a file: a step is made on the board shown, and undoing or redoing
// it from another board shows that board first.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID(), _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID, _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding box A and pocket P; P's board holds box B and pocket Q; Q's holds box C.
private struct PocketTree {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p, CGRect(x: 200, y: 0, width: 100, height: 100))),
                   children: [p: board(box(b), pocket(q)), q: board(box(c))])
    }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()] + more, file: file)
}

@MainActor private func x(_ h: EditorHarness, _ id: ShapeID) -> CGFloat? { h.file.record(id)?.box?.minX }

/// A root holding box A and pocket P; P's board holds box B and pocket Q; Q's holds box C and pocket
/// R; R's holds box D: three levels of boards under P.
private struct Deep {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID(), r = ShapeID(), d = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p)),
                   children: [p: board(box(b), pocket(q)), q: board(box(c), pocket(r)), r: board(box(d))])
    }
    var boards: [BoardID] { [BoardID(owner: p), BoardID(owner: q), BoardID(owner: r)] }
}

/// The file, and the file as a board file's bytes: what a round trip must come back to.
@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

@MainActor private func nudge(_ h: EditorHarness, _ id: ShapeID, to x: CGFloat, key: String = "nudge") {
    h.editor.transact("Nudge", coalescing: key) { $0.update(id, as: Box.self) { $0.props.frame.origin.x = x } }
}

/// What services hear, in order, of switches and commits.
@MainActor private final class HeardLog {
    var events: [String] = []
}

private final class Hearing {
    let log: HeardLog
    init(log: HeardLog) { self.log = log }
}

extension Hearing: EditorService {
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) { log.events.append("will show") }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { log.events.append("did show") }
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { log.events.append("changed \(changes.shapeIDs.count)") }
}

/// A service that, armed, moves a box as the board it's on is left, as the panel commits a number
/// being typed.
@MainActor private final class LeavingSaver {
    var armed: (id: ShapeID, x: CGFloat)?
}

extension LeavingSaver: EditorService {
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard let armed, editor.document[armed.id] != nil else { return }
        self.armed = nil
        editor.transact("Save") { $0.update(armed.id, as: Box.self) { $0.props.frame.origin.x = armed.x } }
    }
}

@MainActor let undoAcrossBoardsTests = Suite("Undo across boards", [
    test("undoing a step made on the root, from a board inside it, shows the root first; redoing it from another board does too") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        nudge(h, tree.a, to: 10)
        expect(h.enter(tree.p) && h.enter(tree.q))
        expect(h.editor.canUndo, "the root's step is undone from Q")
        expectEqual(h.editor.undoHistory.undoName, "Nudge")
        let revision = h.editor.revision
        h.editor.undo()
        expectEqual(h.editor.board, .root, "the step's board is shown")
        expectEqual(h.editor.boardPath, [.root])
        expectEqual(x(h, tree.a), 0)
        expect(h.editor.revision > revision)
        expect(!h.editor.canUndo)

        expect(h.enter(tree.p))
        expect(h.editor.canRedo)
        expectEqual(h.editor.undoHistory.redoName, "Nudge")
        h.editor.redo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 10)
        expect(!h.editor.canRedo)
        expectEqual(x(h, tree.b), 0, "the board left is as it was")
    },
    test("a switch closes the step under way: an edit on the root, one on P under the same key, and two undos") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        nudge(h, tree.a, to: 10)
        nudge(h, tree.a, to: 20)
        expect(h.enter(tree.p))
        nudge(h, tree.b, to: 30)
        nudge(h, tree.b, to: 40)
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard, "P's step is on P: nothing to show")
        expectEqual(x(h, tree.b), 0, "P's run is one step")
        expectEqual(x(h, tree.a), 20, "the root's is another")
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 0)
        expect(!h.editor.canUndo)

        h.editor.redo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 20)
        h.editor.redo()
        expectEqual(h.editor.board, tree.pBoard, "shown for its step")
        expectEqual(x(h, tree.b), 40)
        expect(!h.editor.canRedo)
    },
    test("services hear the switch, then the step; the board shown keeps the camera it was left with") {
        let tree = PocketTree(), log = HeardLog()
        let h = try harness(tree.file, [Contributor(id: "hearing") { r in r.service { _ in Hearing(log: log) } }])
        h.editor.camera = Camera(origin: CGPoint(x: 5, y: 5), zoom: 2)
        nudge(h, tree.a, to: 10)
        expect(h.enter(tree.p))
        h.editor.camera = Camera(origin: CGPoint(x: 70, y: 70), zoom: 1)
        log.events = []
        h.editor.undo()
        expectEqual(log.events, ["will show", "did show", "changed 1"])
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 5, y: 5), zoom: 2), "the root's camera, as it was left")
    },
    test("what a board commits as it's left is a step of its own, on it: an undo from there stops at showing the step's board") {
        let tree = PocketTree(), saver = LeavingSaver()
        let h = try harness(tree.file, [Contributor(id: "saver") { r in r.service { _ in saver } }])
        nudge(h, tree.a, to: 10)
        expect(h.enter(tree.p))
        saver.armed = (tree.b, 55)
        h.editor.undo()
        expectEqual(h.editor.board, .root, "shown")
        expectEqual(x(h, tree.a), 10, "but the newest step is now P's save")
        expectEqual(x(h, tree.b), 55)
        expectEqual(h.editor.undoHistory.undoName, "Save")
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(x(h, tree.b), 0)
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 0)
    },
    test("what a board commits as it's left is an edit like any other: a redo from there shows the step's board, and has nothing left to redo") {
        let tree = PocketTree(), saver = LeavingSaver()
        let h = try harness(tree.file, [Contributor(id: "saver") { r in r.service { _ in saver } }])
        nudge(h, tree.a, to: 10, key: "first")
        nudge(h, tree.a, to: 20, key: "second")
        h.editor.undo()
        h.editor.undo()
        expect(h.enter(tree.p))
        saver.armed = (tree.b, 55)
        expect(h.editor.canRedo)
        h.editor.redo()
        expectEqual(h.editor.board, .root, "shown")
        expectEqual(x(h, tree.a), 0, "nothing redone")
        expectEqual(x(h, tree.b), 55, "P's save is the newest step")
        expect(!h.editor.canRedo, "which, as any edit, leaves nothing to redo")
        expectEqual(h.editor.undoHistory.undoName, "Save")
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(x(h, tree.b), 0)
    },
    test("while a press runs, no board is shown for a step, so there's nothing to undo or redo") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        nudge(h, tree.a, to: 10)
        expect(h.enter(tree.p))
        h.editor.session = TranslatingSession(ids: [tree.b], from: .zero, in: h.editor)
        expect(!h.editor.canUndo)
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard, "nothing shown")
        expectEqual(x(h, tree.a), 10, "nothing undone")
        h.editor.session = nil
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expectEqual(x(h, tree.a), 0)
    },
    test("putting a file in place forgets every board's steps") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        nudge(h, tree.a, to: 10)
        expect(h.enter(tree.p))
        nudge(h, tree.b, to: 10)
        h.editor.undo()
        h.editor.replaceFile(with: h.file)
        expect(!h.editor.canUndo && !h.editor.canRedo)
        expectEqual(h.editor.board, tree.pBoard, "the board shown stays")
        h.editor.showBoard(.root)
        expect(!h.editor.canUndo, "the root's too")
    },
    test("undoing the deletion of a shape with three levels of boards under it puts every board back, every id; redo takes them again") {
        let deep = Deep()
        let h = try harness(deep.file)
        let before = h.file
        let revisions = deep.boards.map { h.file.revision(of: $0) }
        h.editor.transact("Delete") { $0.delete([deep.p]) }
        let after = h.file
        expectEqual(after.children, [:])
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        try expectFile(h, before, "the file as it was, with one step")
        for id in [deep.b, deep.q, deep.c, deep.r, deep.d] { expect(h.file.board(containing: id) != nil) }
        expectEqual(h.file.board(containing: deep.d), BoardID(owner: deep.r))
        for (board, old) in zip(deep.boards, revisions) { expect(h.file.revision(of: board) > old, "\(board) has a revision it never had") }
        expect(!h.editor.canUndo)
        expect(h.enter(deep.p) && h.enter(deep.q) && h.enter(deep.r), "every board can be shown again")
        expectEqual(h.editor.document.shapes.map(\.id), [deep.d])

        h.editor.redo()
        expectEqual(h.editor.board, .root, "shown for the step")
        try expectFile(h, after, "the boards taken again")
        for id in [deep.b, deep.q, deep.c, deep.r, deep.d] { expectEqual(h.file.board(containing: id), nil) }
        h.editor.undo()
        try expectFile(h, before, "and back once more")
    },
    test("undoing the deletion of a pocket on a board three levels down puts its board back, from the root") {
        let deep = Deep()
        let h = try harness(deep.file)
        let before = h.file
        expect(h.enter(deep.p) && h.enter(deep.q))
        h.editor.transact("Delete") { $0.delete([deep.r]) }
        expectEqual(h.file.children[deep.r], nil)
        h.editor.showBoard(.root)
        h.editor.undo()
        expectEqual(h.editor.board, BoardID(owner: deep.q))
        expectEqual(h.editor.boardPath, [.root, BoardID(owner: deep.p), BoardID(owner: deep.q)])
        try expectFile(h, before, "R and its board")
    },
    test("undoing a shape put in with its boards (a paste) takes the boards out; redo brings them back, the same ids") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        let before = h.file
        let n = ShapeID(), inside = ShapeID(), m = ShapeID(), deeper = ShapeID()
        h.editor.transact("Paste") {
            $0.insert(pocket(n, CGRect(x: 500, y: 0, width: 100, height: 100)),
                      contents: [n: board(box(inside), pocket(m)), m: board(box(deeper))])
        }
        let after = h.file
        expectEqual(h.file.board(containing: deeper), BoardID(owner: m))
        expect(h.enter(tree.p))
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        try expectFile(h, before, "no pocket, and no board left without its owner")
        for id in [n, inside, m, deeper] { expectEqual(h.file.board(containing: id), nil) }
        h.editor.redo()
        try expectFile(h, after, "the pocket, and its boards")
        expectEqual(h.file.board(containing: deeper), BoardID(owner: m))
        expect(h.enter(n) && h.enter(m))
        expectEqual(h.editor.document.shapes.map(\.id), [deeper])
    },
    test("undoing a paste forgets the camera its boards were left with: redone, a board is shown as on a first visit") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let n = ShapeID()
        h.editor.transact("Paste") {
            $0.insert(pocket(n, CGRect(x: 500, y: 0, width: 100, height: 100)),
                      contents: [n: board(box(ShapeID(), CGRect(x: 40, y: 40, width: 300, height: 200)))])
        }
        expect(h.enter(n))
        let firstVisit = h.editor.camera
        h.editor.camera = Camera(origin: CGPoint(x: -250, y: 120), zoom: 3)
        h.editor.showBoard(.root)
        expectEqual(h.editor.boardCameras[BoardID(owner: n)], Camera(origin: CGPoint(x: -250, y: 120), zoom: 3))
        h.editor.undo()
        expectEqual(h.editor.boardCameras[BoardID(owner: n)], nil, "gone with its board")
        h.editor.redo()
        expect(h.enter(n))
        expectEqual(h.editor.camera, firstVisit, "fitted, not the camera it was left with before the undo")
    },
    test("a shape one transaction takes off its board and puts in with another's board goes back, and comes again") {
        let tree = PocketTree()
        let h = try harness(tree.file)
        let before = h.file
        let n = ShapeID()
        h.editor.transact("Pocket It") { tx in
            let a = tx.document[tree.a]!
            tx.delete([tree.a])
            tx.insert(pocket(n, CGRect(x: 500, y: 0, width: 100, height: 100)), contents: [n: board(a)])
        }
        let after = h.file
        expectEqual(h.file.board(containing: tree.a), BoardID(owner: n))
        h.editor.undo()
        try expectFile(h, before, "A back on the root")
        expectEqual(h.file.board(containing: tree.a), .root)
        h.editor.redo()
        try expectFile(h, after, "A in the new pocket")
    },
    test("a step that changes a board gives it a new revision: what was kept of it isn't taken back, what wasn't changed is") {
        let deep = Deep()
        let h = try harness(deep.file)
        let pBoard = BoardID(owner: deep.p)
        expect(h.enter(deep.p))
        let kept = h.editor.damageMark
        h.editor.showBoard(.root)
        expect(h.enter(deep.p))
        expect(h.editor.isCurrent(kept), "unchanged: P's index is taken back")
        h.editor.showBoard(.root)
        var stash = BoardStash<String>()
        stash.keep("P as it was", for: pBoard, in: h.editor)
        let revision = h.file.revision(of: pBoard), rootRevision = h.file.revision(of: .root)

        h.editor.transact("Delete") { $0.delete([deep.p]) }
        h.editor.undo()
        expect(h.file.revision(of: pBoard) > revision, "put back: a new revision")
        expect(h.file.revision(of: .root) > rootRevision, "the board shown too")
        expectEqual(stash.take(for: pBoard, in: h.editor), nil, "what was kept of P isn't taken for it")
        expect(h.enter(deep.p))
        expect(!h.editor.isCurrent(kept), "P's index is worked out afresh")
        expectEqual(h.editor.document.shapes.map(\.id), [deep.b, deep.q])
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)), deep.q, "and hit testing finds its shapes")

        let now = h.file.revision(of: pBoard), qRevision = h.file.revision(of: BoardID(owner: deep.q))
        h.editor.showBoard(.root)
        h.editor.redo()
        expect(h.file.revision(of: pBoard) > now)
        h.editor.undo()
        expect(h.file.revision(of: BoardID(owner: deep.q)) > qRevision, "every board it reached")
    },
])
