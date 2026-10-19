import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// ⇧⌘V and Edit › Paste at Pointer paste as ⌘V does, but centered on the pointer while it's over the
// canvas; and the file Copy as Image draws, which is what a copy would put on the pasteboard.

extension EditorHarness {
    /// ⇧⌘V on the canvas: whether a shortcut took it.
    @discardableResult
    func pasteAtPointerKey() -> Bool {
        hold([.shift, .command])
        defer { hold([]) }
        return key("v")
    }
}

@MainActor let pointerPasteTests = Suite("Paste at Pointer", [
    test("⇧⌘V puts what was copied centered on the pointer while it's over the canvas, in one step, selected; ⌘V keeps its place") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        h.editor.copySelection()
        h.move(to: CGPoint(x: 500, y: 300))
        var before = h.editor.document
        expect(h.pasteAtPointerKey())
        let pasted = try require(h.editor.shapes(since: before).first)
        expectEqual(pasted.box, CGRect(x: 450, y: 250, width: 100, height: 100), "its middle on the pointer")
        expectEqual(pasted.copiedFrom, box)
        expectEqual(h.editor.selectedShapeIDs, [pasted.id])
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        before = h.editor.document
        expect(h.command("v"))
        expectEqual(h.editor.shapes(since: before).first?.box, slot(0), "⌘V: where it was copied from")
    },
    test("several shapes keep their places among themselves, their middle on the pointer, and the camera's zoom and pan count") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 100, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        h.editor.copySelection()
        h.editor.camera = Camera(origin: CGPoint(x: 1000, y: 1000), zoom: 2)
        h.move(to: CGPoint(x: 400, y: 300))      // the world's (1000 + 400 / 2, 1000 + 300 / 2)
        let before = h.editor.document
        expect(h.pasteAtPointerKey())
        // The two boxes' middle is (150, 100), so each is 1050 right and down of where it was.
        expectEqual(h.editor.shapes(since: before).map(\.box), [CGRect(x: 1050, y: 1050, width: 100, height: 100),
                                                                CGRect(x: 1250, y: 1150, width: 100, height: 100)])
    },
    test("with the pointer off the canvas it pastes as ⌘V does: where it was copied from, or centered in the view when that's out of view") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        h.editor.copySelection()
        expect(!h.editor.isPointerOverCanvas, "never seen on it")
        var before = h.editor.document
        expect(h.pasteAtPointerKey())
        expectEqual(h.editor.shapes(since: before).first?.box, slot(0), "no pointer: in place")
        h.move(to: CGPoint(x: 500, y: 300))
        h.editor.pointerExited()                      // onto the minimap, the inspector, out of the window
        before = h.editor.document
        expect(h.pasteAtPointerKey())
        expectEqual(h.editor.shapes(since: before).first?.box, slot(0), "left the canvas: in place")
        h.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        before = h.editor.document
        expect(h.pasteAtPointerKey())
        expectEqual(h.editor.shapes(since: before).first?.box, CGRect(x: 5350, y: 5250, width: 100, height: 100), "centered in the view, as ⌘V does")
    },
    test("it's off as ⌘V is: nothing to paste, mid-gesture, on a board that takes no shapes; the key passes then") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let box = h.add(Box(slot(0)))
        h.move(to: CGPoint(x: 500, y: 300))
        expect(!h.editor.canPerform(.pasteAtPointer))
        expect(!h.pasteAtPointerKey(), "nothing on the pasteboard")
        h.editor.selection = box
        h.editor.copySelection()
        expect(h.editor.canPerform(.pasteAtPointer))
        h.press(at: CGPoint(x: 500, y: 300))
        expect(!h.editor.canPerform(.pasteAtPointer), "mid-gesture")
        h.release()
        expectEqual(h.editor.document.shapes.count, 1)
    },
    test("it's a command with a title, its key and its place in the registry: Clipboard's, after Paste") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        expectEqual(h.editor.registry.title(of: .pasteAtPointer), "Paste at Pointer")
        expectEqual(h.editor.registry.shortcut(forCommand: .pasteAtPointer)?.chord, KeyChord("v", [.command, .shift]))
        expectEqual(h.editor.registry.shortcut(forCommand: .pasteAtPointer)?.chord.description, "⇧⌘V")
    },
])

@MainActor let imageFileTests = Suite("The shapes Copy as Image draws", [
    test("it's what a copy of the selection would put on the pasteboard, without touching it: the copyable shapes, back to front") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0)))
        let b = h.add(Disc(slot(1)))
        h.add(Box(slot(2)))
        h.add(Ticket(frame: slot(3)))
        expect(h.editor.canCopyAsImage, "with nothing selected: the board")
        h.editor.selectedShapeIDs = [b, a]
        let count = pasteboard.changeCount
        expectEqual(h.editor.imageShapes(), [a, b], "back to front, as a copy puts them")
        expectEqual(pasteboard.changeCount, count)
        expectEqual(h.editor.document.shapes.count, 4)
        expectEqual(h.editor.undoHistory.undoName, nil, "no step")
    },
    test("with nothing selected it's every shape of the board that can be copied: a ticket, which opts out, is left out; an empty board has none") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        expect(!h.editor.canCopyAsImage)
        expectEqual(h.editor.imageShapes(), [])
        h.add(Ticket(frame: slot(3)))
        expect(!h.editor.canCopyAsImage, "only a shape that can't be copied")
        expectEqual(h.editor.imageShapes(), [])
        let a = h.add(Box(slot(0)))
        let b = h.add(Box(slot(1)))
        expect(h.editor.canCopyAsImage)
        expectEqual(h.editor.imageShapes(), [a, b])
    },
    test("a selection of shapes that can't be copied has none, though the board has others") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.add(Box(slot(0)))
        let ticket = h.add(Ticket(frame: slot(3)))
        h.editor.selection = ticket
        expect(!h.editor.canCopyAsImage)
        expectEqual(h.editor.imageShapes(), [])
    },
    test("without the Clipboard plugin there is nothing to draw") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.add(Box(slot(0)))
        expect(!h.editor.canCopyAsImage)
        expectEqual(h.editor.imageShapes(), [])
        expect(h.editor.registry.imageSource == nil)
    },
    test("Clipboard gives the host's slot: available as the editor says, the shapes as imageShapes gives them") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let source = try require(h.editor.registry.imageSource)
        expect(!source.isAvailable(h.editor))
        expectEqual(source.shapes(for: h.editor), [])
        let box = h.add(Box(slot(0)))
        expect(source.isAvailable(h.editor))
        expectEqual(source.shapes(for: h.editor), [box])
    },
])
