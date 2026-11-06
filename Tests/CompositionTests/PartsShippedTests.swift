import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Locking
import Publishing
import Selection
import ShippedTesting
import TestKit

// A shape's parts as the app ships them, walked with the keys a keyboard sends: a locked private note's two
// chips (and the arrow joining it to the other note), reached with ⌥Tab with no key code in Locking or Publishing (principle 2), and the lock's click,
// Unlock, done with Return.

extension NestedWindow {
    /// A walk of the canvas whose keyboard can be on a selected shape's focused part, named by its title.
    func partsWalk(names: [ShapeID: String]) -> KeyWalk {
        window.makeFirstResponder(canvas)
        let walk = KeyWalk(window, editor: editor, readers: [.canvas(canvas, editor: editor, names: names, part: { [editor] in editor.focusedPart?.title }),
                                                             .panel(of: canvas)])
        return walk
    }
}

@MainActor let partsShippedTests = Suite("Parts of a shape, shipped", [
    test("on a locked private note ⌥Tab reaches both chips, round and back, and Return on the lock unlocks the note, which stays selected") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (note, other) = w.nest.notes(on: 1)
        w.editor.makePrivate([note])
        w.editor.lock([note])
        let walk = w.partsWalk(names: [note: "note", other: "other"])
        w.editor.selection = note
        expectEqual(walk.press(.optionTab).id, "canvas/note/Private", "the row's right end: the crossed eye, then the lock, nearest the end")
        // The note is joined to the other by an arrow, which is a part too (Connections hands every shape its arrows).
        walk.expectCycle(["canvas/note/Private", "canvas/note/Locked", "canvas/note/Arrow to Note"], forward: .optionTab, back: .optionBackTab)
        walk.go("canvas/note/Locked", by: .optionTab)
        expectEqual(walk.press(.return).id, "canvas/note", "the lock opens and fades, a part no more")
        expect(!w.editor.isLocked(note))
        expectEqual(w.editor.undoHistory.undoName, "Unlock")
        expectEqual(walk.press(.optionTab).id, "canvas/note/Private")
        expectEqual(walk.press(.escape).id, "canvas/note")
    },
    test("an arrow's part is the stretch of it where it leaves the shape, not the half of it up to its middle") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (note, _) = w.nest.notes(on: 1)
        let part = try require(w.editor.shapeParts(of: note).first { $0.title == "Arrow to Note" })
        let outline = try require(w.editor.shapeContext.geometry(of: try require(part.id.base as? ShapeID))?.outline)
        let start = try require(outline.first), end = try require(outline.last)
        let length = hypot(end.x - start.x, end.y - start.y)
        expect(length > 150, "an arrow long enough to tell: \(length)")
        expect(part.rect.insetBy(dx: -8, dy: -8).contains(start), "it sits where the arrow leaves: \(part.rect) for \(start)")
        expect(hypot(part.rect.width, part.rect.height) < length / 2, "a stretch of it: \(part.rect) of \(length)")
    },
])
