@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Undo restores the selection a step began and ended with (tldraw's selection is in its history),
// and never moves the camera.

@MainActor private func harness(_ more: [any CanvasPlugin] = []) throws -> (EditorHarness, a: ShapeID, b: ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()] + more)
    let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
    let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
    h.editor.replaceDocument(with: h.editor.document)                // start with nothing to undo
    return (h, a, b)
}

@MainActor let undoTests = Suite("Undo and the selection", [
    test("undoing Delete brings the shapes back selected; redoing it leaves nothing selected") {
        let (h, a, b) = try harness()
        h.editor.selectedShapeIDs = [a, b]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes, [])
        expectEqual(h.editor.undoHistory.undoName, "Delete")
        h.editor.selection = nil
        h.hold(.command)
        expect(h.key("z"))
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.hold([.command, .shift])
        expect(h.key("Z"))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.hold([])
    },
    test("undoing a move puts the shape back, still selected, and leaves the camera where it is") {
        let (h, a, _) = try harness()
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 80, y: 90)); h.drag(to: CGPoint(x: 120, y: 130)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 70, y: 80))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        let camera = Camera(origin: CGPoint(x: -40, y: 25), zoom: 1.5)
        h.editor.camera = camera
        h.editor.selection = nil
        h.editor.undo()
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
        expectEqual(h.editor.selectedShapeIDs, [a], "what the press selected, from before it moved")
        expectEqual(h.editor.camera, camera, "the camera stays")
        h.editor.redo()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 70, y: 80))
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("a click that jitters a point on a lone box moves it (the select tool drags a lone box from its press): one step, Move") {
        let (h, a, _) = try harness()
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 51, y: 50)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 1, y: 0))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
        expect(!h.editor.canUndo)
    },
    test("undoing a shape placed with a place tool brings back the selection from before it") {
        let (h, a, _) = try harness([CardsPlugin()])
        h.editor.selection = a
        h.editor.setTool(ToolID(placing: Card.kind))
        h.click(at: CGPoint(x: 600, y: 600))
        let card = try require(h.editor.editingShapeID, "the card tool places a card to edit")
        expectEqual(h.editor.selectedShapeIDs, [card])
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Add Card")
        h.editor.undo()
        expectEqual(h.editor.document[card], nil)
        expectEqual(h.editor.selectedShapeIDs, [a], "what was selected as the place began")
        h.editor.redo()
        expectEqual(h.editor.selectedShapeIDs, [card])
    },
    test("undoing a placed card brings back what was selected before it") {
        let (h, a, _) = try harness([doubleClickCards()])
        h.editor.selection = a
        h.click(at: CGPoint(x: 600, y: 600), clickCount: 1)
        h.click(at: CGPoint(x: 600, y: 600), clickCount: 2)
        let card = try require(h.editor.editingShapeID)
        expectEqual(h.editor.selectedShapeIDs, [card])
        h.editor.endEditing()
        h.editor.undo()
        expectEqual(h.editor.document[card], nil)
        expectEqual(h.editor.selectedShapeIDs, [], "the double-click's first click deselected a, before the card came")
        h.editor.redo()
        expectEqual(h.editor.selectedShapeIDs, [card])
    },
    test("clicks, a marquee and hovering record nothing") {
        let (h, a, _) = try harness()
        h.click(at: CGPoint(x: 50, y: 50))
        h.click(at: CGPoint(x: 250, y: 50))
        h.press(at: CGPoint(x: -20, y: -20)); h.drag(to: CGPoint(x: 400, y: 200)); h.release()
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, a)
        expect(!h.editor.canUndo)
        h.key("\u{1b}")
        h.hold(.command)
        expect(h.key("a"))
        expect(!h.key("z"), "⌘A selects, which is no step, so ⌘Z has nothing to undo")
        h.hold([])
    },
    test("⌘Z in the middle of a drag does nothing, and the drag goes on") {
        let (h, a, _) = try harness()
        h.editor.transact("Nudge") { $0.update(a, as: Box.self) { $0.frame.origin.y = 1 } }
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 90, y: 50))
        h.hold(.command)
        expect(!h.key("z"))
        h.hold([])
        h.drag(to: CGPoint(x: 100, y: 50)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 50, y: 1))
        h.editor.undo()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 0, y: 1))
        h.editor.undo()
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
    },
    test("an undo's selection is an ordinary change of it: a step back when what it selects is out of the view the person had, to what was selected before the undo, and none when it's in view") {
        let (h, a, b) = try harness()
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        h.editor.selection = a
        h.editor.deleteSelection()
        h.editor.selection = b
        h.editor.undo()
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(!h.editor.canGoBack, "a came back where the person could see it")

        h.editor.deleteSelection()
        h.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))           // the person pans off…
        h.editor.selection = b                                                // …and selects b as a row does, there
        h.editor.undo()
        expectEqual(h.editor.selectedShapeIDs, [a], "back, out of the view the person has now")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [b])
    },
])
