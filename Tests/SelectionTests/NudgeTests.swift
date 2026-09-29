@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

private let left = "\u{F702}", right = "\u{F703}", up = "\u{F700}", down = "\u{F701}"

@MainActor let nudgeTests = Suite("Nudging", [
    test("the arrow keys nudge the selection a world unit, and ten with ⇧, whatever the zoom") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.editor.camera.zoom = 4
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        expect(h.key(right))
        expect(h.key(down))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 1, y: 1))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 201, y: 1))
        h.hold(.shift)
        expect(h.key(left))
        expect(h.key(up))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: -9, y: -9))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expectEqual(h.editor.selectedShapeIDs, [a, b], "still selected")
    },
    test("with nothing selected, a press under way or a shape being edited, the arrow keys pass") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!h.key(right), "nothing selected")
        h.editor.selection = box
        h.press(at: CGPoint(x: 50, y: 50))
        expect(!h.key(right), "mid-press")
        h.release()
        let card = h.add(Card(CGRect(x: 300, y: 0, width: 100, height: 60)))
        h.editor.selection = card
        h.editor.beginEditing(card)
        expect(!h.key(right), "editing")
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 300, y: 0))
    },
    test("a held arrow key's nudges are one undo step; pressed again, another") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.key(right)
        for _ in 0..<9 { expect(h.key(right, isRepeat: true), "repeats nudge again") }
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 0))
        h.key(right)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 11, y: 0))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 0))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin, .zero, "the held key's ten, one step")
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("a read-only shape in the selection stays, refused, and the rest move") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin(log: log)])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let frozen = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([frozen])
        h.editor.selectedShapeIDs = [a, frozen]
        expect(h.key(right))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 1, y: 0))
        expectEqual(h.editor.document[frozen]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(log.refusals, [[frozen]], "refused, so a lock shakes")
    },
])
