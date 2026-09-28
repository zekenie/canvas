@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import Selection
import TestKit

// Undo goes below the lock: it puts back what the board was, whatever's locked now. Every lock and
// unlock is a step of its own, so undoing one always passes back through it.

@MainActor let undoTests = Suite("Locking and undo", [
    test("Lock is one step; undoing it unlocks the shape, with no shake, and redoing it locks it again") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.replaceDocument(with: h.editor.document)
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 150))).choose("Lock")
        expect(h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.undo()
        expect(!h.editor.isLocked(box))
        h.wait(16)
        expectEqual(h.editor.drawingOffset(of: box), .zero, "nothing was refused, so nothing shakes")
        h.editor.redo()
        expect(h.editor.isLocked(box))
        expect(!h.editor.canRedo)
    },
    test("a click on the chip is one step, Unlock, and undoing it locks the shape again") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        h.click(at: chipCenter)
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Unlock")
        h.editor.undo()
        expect(h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.redo()
        expect(!h.editor.isLocked(box))
    },
    test("a drag or a Delete a lock refuses records nothing: the next undo undoes what came before") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        h.editor.lock([box])
        h.press(at: CGPoint(x: 150, y: 150)); h.drag(to: CGPoint(x: 250, y: 200)); h.release()
        h.editor.selection = box
        expect(h.key("\u{7f}"))
        expect(h.editor.document[box] != nil)
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.undo()
        expect(!h.editor.isLocked(box))
        expectEqual(h.editor.document[box]?.box, chipBox)
    },
    test("a locked tag let go of a deleted shape; undoing the delete puts it back as it was, locked and naming the shape") {
        let h = try lockingHarness()
        let box = h.add(Box(chipBox))
        let tag = h.add(Tag(target: box))
        h.editor.lock([tag])
        let before = h.editor.document
        h.editor.selection = box
        h.editor.deleteSelection()
        expectEqual(h.editor.document[tag]?.typed(as: Tag.self)?.props.target, nil)
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expect(h.editor.isLocked(tag))
        h.editor.redo()
        expectEqual(h.editor.document[box], nil)
        expectEqual(h.editor.document[tag]?.typed(as: Tag.self)?.props.target, nil)
    },
])
