import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import TestKit

// A connection drawn from a port is one undo step, named for what it adds, and none at all when
// nothing's drawn.

@MainActor let connectionUndoTests = Suite("Connections and undo", [
    test("a connection drawn from a port is one step, Add Arrow; undoing it takes the arrow away, redoing it brings it back exactly") {
        let board = try PortBoard()
        board.h.editor.replaceDocument(with: board.h.editor.document)
        let start = board.h.editor.document
        board.connect(to: boxB.center)
        let arrow = try require(board.arrows.first)
        expectEqual(arrow[ChannelProperty.self], Wire.id)
        expectEqual(board.h.editor.undoHistory.undoName, "Add Arrow")
        let drawn = board.h.editor.document
        board.h.editor.undo()
        expectEqual(board.h.editor.document, start)
        expect(!board.h.editor.canUndo, "one step")
        board.h.editor.redo()
        expectEqual(board.h.editor.document, drawn)
    },
    test("a connection released on nothing, or let go of with Escape, records nothing") {
        let board = try PortBoard()
        board.h.editor.replaceDocument(with: board.h.editor.document)
        board.connect(to: CGPoint(x: 360, y: 700))
        expectEqual(board.arrows.count, 0)
        board.connect(to: boxB.center, release: false)
        board.h.key("\u{1b}")
        board.h.release()
        expectEqual(board.arrows.count, 0)
        expect(!board.h.editor.canUndo)
    },
])
