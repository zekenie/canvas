import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Selection
import TestKit

@MainActor let undoTests = Suite("Cut, paste and undo", [
    test("Cut is one step: undoing it brings the shapes back, selected, and redoing it takes them again") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0))), b = h.add(Disc(slot(1)))
        let link = h.add(Link(from: a, to: b))
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        h.editor.selectedShapeIDs = [a, b]
        expect(h.command("x"))
        expectEqual(h.editor.document.shapes.map(\.id), [link])
        expectEqual(h.editor.undoHistory.undoName, "Cut")
        h.editor.undo()
        expectEqual(h.editor.document, before, "the link names them again")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.editor.redo()
        expectEqual(h.editor.document.shapes.map(\.id), [link])
        // From the menu, the same.
        h.editor.undo()
        try require(h.secondaryClick(at: middle(0))).choose("Cut")
        expectEqual(h.editor.undoHistory.undoName, "Cut")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expect(!h.editor.canUndo)
    },
    test("Paste is one step: undoing it brings back what was selected; redoing it, the same copies, naming their originals") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1)))
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        h.editor.selection = a
        expect(h.command("c"))
        h.editor.selection = b
        expect(h.command("v"))
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        expectEqual(h.editor.selectedShapeIDs, [copy.id])
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.editor.redo()
        expectEqual(h.editor.document[copy.id], copy)
        expectEqual(h.editor.document[copy.id]?.copiedFrom, a)
        expectEqual(h.editor.selectedShapeIDs, [copy.id])
        // From the menu, the same.
        h.editor.undo()
        try require(h.secondaryClick(at: CGPoint(x: 700, y: 400))).choose("Paste")
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expect(!h.editor.canUndo)
    },
    test("a move's paste undone takes the shapes out and frees their ids, so pasting again, in a pocket, still moves them; redone, the same ids; the cut undone after it, the shapes are back where they were") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [PocketsPlugin()])
        let pocket = h.add(Pocket(slot(0))), box = h.add(Box(slot(1)))
        let original = h.file
        h.editor.selection = box
        expect(h.command("x"))
        expect(h.command("v"))
        expectEqual(h.editor.document[box]?.box, slot(1))
        h.editor.undo()
        expectEqual(h.editor.document[box], nil)
        expect(h.enter(pocket))
        expect(h.command("v"))
        expectEqual(h.file.board(containing: box), BoardID(owner: pocket), "moved again, into the pocket")
        let moved = h.file
        h.editor.undo()
        expectEqual(h.file.record(box), nil)
        h.editor.redo()
        expectEqual(h.file, moved, "the same ids")
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.board, .root, "the cut was made there")
        expectEqual(h.file, original)
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.editor.board, BoardID(owner: pocket))
        expectEqual(h.file, moved)
    },
])
