@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// An editor's rehearsal (`rehearsal()`): a copy of its file showing the same board through the same view, named
// alike, whose commits reach nothing of the editor and whose clock never fires; and the editor taking what one did in
// as one step (`adopt`).

@MainActor let rehearsalTests = Suite("a rehearsal of an editor", [
    test("it shows the same board of the same file through the same view, where the camera is headed, and calls the root the same") {
        let pocket = ShapeID(), inside = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inside, Box(CGRect(x: 10, y: 10, width: 40, height: 40))))])])
        let editor = CanvasEditor(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin()]), file: file, showing: BoardID(owner: pocket))
        editor.viewportDidResize(to: CGSize(width: 900, height: 700))
        editor.coveredEdges = CoveredEdges(top: 40, right: 300)
        editor.camera = Camera(origin: CGPoint(x: -50, y: 20), zoom: 2)
        editor.nameRoot("Plans")
        let copy = editor.rehearsal()
        expectEqual(copy.board, editor.board)
        expectEqual(copy.file, editor.file)
        expectEqual(copy.viewportSize, editor.viewportSize)
        expectEqual(copy.unobscuredViewport, editor.unobscuredViewport)
        expectEqual(copy.camera, editor.cameraTarget)
        expectEqual(copy.rootName, "Plans")
    },
    test("what it commits reaches nothing of the editor, and nothing it schedules ever runs") {
        let editor = CanvasEditor(registry: try Registry(plugins: [FixturesPlugin()]))
        let before = editor.file, revision = editor.revision
        let copy = editor.rehearsal()
        copy.transact("Add") { $0.insert(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))) }
        expectEqual(copy.document.shapes.count, 1)
        expectEqual(editor.file, before)
        expectEqual(editor.revision, revision)
        expect(!editor.canUndo, "no step here")
        var ran = false
        _ = copy.scheduler.schedule(after: .zero) { ran = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(!ran, "its clock stands still")
        expectEqual(copy.scheduler.now, .zero)
    },
])

/// An editor on the root of a file with a box and a pocket whose board holds a box, the commits services hear logged.
@MainActor private func pocketed(_ log: ChangeLog) throws -> (editor: CanvasEditor, box: ShapeID, pocket: ShapeID, inner: ShapeID) {
    let box = ShapeID(), pocket = ShapeID(), inner = ShapeID()
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: box, Box(CGRect(x: 0, y: 0, width: 40, height: 40)))),
                                                        AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 100, y: 0, width: 100, height: 100))))]),
                          children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Box(CGRect(x: 10, y: 10, width: 40, height: 40))))])])
    let editor = CanvasEditor(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), LetterheadPlugin(), recordingChanges(log)]), file: file)
    return (editor, box, pocket, inner)
}

@MainActor let adoptTests = Suite("an editor taking in what a rehearsal did", [
    test("what it did on every board and to the file's values is one commit and one step, undone and redone whole") {
        let log = ChangeLog()
        let (editor, box, pocket, inner) = try pocketed(log)
        let before = editor.file
        let copy = editor.rehearsal()
        let added = ShapeRecord(Box(CGRect(x: 300, y: 0, width: 40, height: 40)))
        let far = ShapeRecord(Box(CGRect(x: 60, y: 60, width: 20, height: 20)))
        copy.transact("One") { tx in
            tx.insert(added)
            tx.update(box, as: Box.self) { $0.frame.origin.x = 7 }
            tx.setFileValue(Letterhead.self, to: "Acme")
        }
        copy.transact(on: BoardID(owner: pocket), "Two") { tx in
            tx.insert(far)
            tx.delete([inner])
        }
        let after = copy.file
        log.changes = []
        expect(editor.adopt(copy, named: "Draw"), "taken in")
        expectEqual(editor.file, after)
        expectEqual(editor.file[Letterhead.self], "Acme")
        expectEqual(log.changes.count, 1, "one commit")
        let heard = log.changes.first
        expectEqual(heard?.added, [added.id])
        expectEqual(heard?.changed, [box])
        expectEqual(heard?.boardsChanged, [BoardID(owner: pocket)])
        expectEqual(heard?.fileValues, [Letterhead.key])
        expectEqual(heard?.byAgent, true, "an agent's change")
        expectEqual(heard?.restoredStep, false, "no step undone or redone")
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.file, before, "one undo takes all of it back")
        expect(!editor.canUndo, "and it was one step")
        editor.redo()
        expectEqual(editor.file, after)
        expectEqual(editor.board, .root, "no board was shown for it")
    },
    test("a board the rehearsal made comes whole, and goes whole with the undo") {
        let log = ChangeLog()
        let (editor, _, _, _) = try pocketed(log)
        let copy = editor.rehearsal()
        let made = ShapeRecord(Pocket(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let held = ShapeRecord(Box(CGRect(x: 5, y: 5, width: 10, height: 10)))
        copy.transact { $0.insert(AnyShapeRecord(made), contents: [made.id: CanvasDocument(shapes: [AnyShapeRecord(held)])]) }
        expect(editor.adopt(copy, named: "Draw"))
        expectEqual(editor.file[BoardID(owner: made.id)].shapes.map(\.id), [held.id])
        expect(editor.canShow(BoardID(owner: made.id)), "its board can be shown")
        editor.undo()
        expect(editor.file.record(held.id) == nil, "gone with it")
        expect(editor.file.record(made.id) == nil)
    },
    test("with another board shown, the step is made there, and the root comes whole") {
        let log = ChangeLog()
        let (editor, box, pocket, _) = try pocketed(log)
        expect(editor.showBoard(BoardID(owner: pocket)))
        let before = editor.file
        let copy = editor.rehearsal()
        copy.transact(on: .root, "Far") { $0.update(box, as: Box.self) { $0.frame.origin.y = 30 } }
        expect(editor.adopt(copy, named: "Draw"))
        expectEqual(editor.file, copy.file)
        expectEqual(editor.board, BoardID(owner: pocket))
        editor.undo()
        expectEqual(editor.file, before)
    },
    test("once the file has changed since, or for another editor's rehearsal, it takes nothing") {
        let log = ChangeLog()
        let (editor, box, _, _) = try pocketed(log)
        let copy = editor.rehearsal()
        copy.transact { $0.insert(ShapeRecord(Box(.zero))) }
        editor.transact("Mine") { $0.update(box, as: Box.self) { $0.frame.origin.x = 3 } }
        let now = editor.file
        expect(!editor.adopt(copy, named: "Draw"), "the file moved on")
        expectEqual(editor.file, now)
        expectEqual(editor.undoHistory.undoName, "Mine", "no step")
        let other = CanvasEditor(registry: editor.registry)
        expect(!other.adopt(editor.rehearsal(), named: "Draw"), "not its own rehearsal")
        expect(!editor.adopt(other, named: "Draw"), "not a rehearsal at all")
    },
    test("a rehearsal that did nothing is taken in as nothing: no commit, no step") {
        let log = ChangeLog()
        let (editor, _, _, _) = try pocketed(log)
        let copy = editor.rehearsal()
        log.changes = []
        expect(editor.adopt(copy, named: "Draw"))
        expect(log.changes.isEmpty)
        expect(!editor.canUndo)
    },
])
