import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TestKit

extension Board {
    /// What's on the board so far is where it starts: nothing to undo.
    func forget() { h.editor.replaceDocument(with: h.editor.document) }
}

@MainActor let arrowUndoTests = Suite("Arrows and undo", [
    test("re-aiming an end, a precise timer firing mid-drag, is one step; undone it's as it was, redone it's the same record") {
        let board = try Board(arrow: 0)
        let id = try require(board.arrow)
        board.forget()
        let before = try require(board.h.editor.document[id])
        board.reaimEnd(via: CGPoint(x: 400, y: 170), to: CGPoint(x: 540, y: 170), speed: slow, release: false)
        board.h.wait(1000)                                          // the end, dwelling, turns precise
        board.h.drag(to: CGPoint(x: 541, y: 171))
        board.h.release()
        let drawn = try require(board.h.editor.document[id])
        expectEqual(drawn.typed(as: Arrow.self)?.props.end.binding?.shapeID, board.b)
        expectEqual(drawn.typed(as: Arrow.self)?.props.end.binding?.isPrecise, true)
        expectEqual(board.h.editor.undoHistory.undoName, "Move Arrow End")
        board.h.editor.undo()
        expectEqual(board.h.editor.document[id], before)
        expect(!board.h.editor.canUndo, "the whole drag was one step")
        board.h.editor.redo()
        expectEqual(board.h.editor.document[id], drawn)
        expectEqual(board.h.editor.selectedShapeIDs, [id])
    },
    test("dragging an end, bending and toggling an arrowhead are a step each, named for what they did") {
        let board = try Board(arrow: 0)
        let id = try require(board.arrow)
        board.forget()
        let original = try require(board.h.editor.document[id])
        board.h.editor.selection = id
        board.h.press(at: CGPoint(x: 364.125, y: 180)); board.h.drag(to: CGPoint(x: 364.125, y: 250)); board.h.release()
        expectEqual(board.h.editor.undoHistory.undoName, "Bend Arrow")
        let bent = try require(board.h.editor.document[id])
        board.h.press(at: CGPoint(x: 560, y: 180), clickCount: 2); board.h.release()
        expectEqual(board.h.editor.undoHistory.undoName, "Toggle Arrowhead")
        let toggled = try require(board.h.editor.document[id])
        board.h.press(at: CGPoint(x: 560, y: 180)); board.h.drag(to: CGPoint(x: 700, y: 500), speed: fast); board.h.release()
        expectEqual(board.h.editor.undoHistory.undoName, "Move Arrow End")
        expectEqual(board.arrows.first?.end.binding, nil)
        board.h.editor.undo()
        expectEqual(board.h.editor.document[id], toggled)
        board.h.editor.undo()
        expectEqual(board.h.editor.document[id], bent)
        board.h.editor.undo()
        expectEqual(board.h.editor.document[id], original)
        expect(!board.h.editor.canUndo)
    },
    test("moving a shape with the arrow bound to it is one step, and undoing it puts both back") {
        let board = try Board(arrow: 20)
        let id = try require(board.arrow)
        board.forget()
        let before = board.h.editor.document
        board.h.editor.selectedShapeIDs = [board.a, id]
        board.h.press(at: CGPoint(x: 100, y: 100)); board.h.drag(to: CGPoint(x: 160, y: 300), speed: fast); board.h.release()
        expect(board.h.editor.document[board.a]?.box != boxA)
        expectEqual(board.h.editor.undoHistory.undoName, "Move")
        let moved = board.h.editor.document
        board.h.editor.undo()
        expectEqual(board.h.editor.document, before)
        board.h.editor.redo()
        expectEqual(board.h.editor.document, moved)
    },
    test("deleting a shape an arrow is bound to, then undoing it, binds the arrow again as it was") {
        let board = try Board(arrow: 0)
        let id = try require(board.arrow)
        let bound = try require(board.h.editor.document[id])
        board.h.editor.selection = board.b
        board.h.key("\u{7f}")
        expectEqual(board.arrows.first?.end.binding, nil, "it let go where it was drawn")
        board.h.editor.undo()
        expectEqual(board.h.editor.document[id], bound)
        expectEqual(board.h.editor.selectedShapeIDs, [board.b])
    },
])
