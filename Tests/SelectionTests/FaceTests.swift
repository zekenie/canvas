@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Faces (`ShapeFaces`): a plugin's face on every shape with a box, the 20-unit square 10 in from its
// top-left corner, which the select tool clicks on a plain press on the shape, once the shape is
// selected, and double-clicks in place of editing it.

/// The face on a shape with this frame, in world units.
func face(of frame: CGRect) -> CGRect { CGRect(x: frame.minX + 10, y: frame.minY + 10, width: 20, height: 20) }

/// What the faces plugin heard: the shapes `at` was asked about, and each click and double-click, as
/// the face's shape.
@MainActor final class FaceLog {
    var asked: [ShapeID] = []
    var clicks: [ShapeID] = []
    var doubleClicks: [ShapeID] = []
    /// The selection as each click ran.
    var selectionAtClicks: [[ShapeID]] = []
    /// The shape every face names for hover, if any.
    var names: ShapeID?
}

/// A plugin with a face on every shape with a box, known by its shape. `doubleClicks: false` leaves
/// `doubleClick` and `hovering` out.
@MainActor func facesPlugin(_ log: FaceLog, doubleClicks: Bool = true) -> Contributor {
    Contributor(id: "faces") { r in
        let find: @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> ShapeID? = { _, shape, point in
            log.asked.append(shape.id)
            return shape.box.map(face(of:))?.contains(point) == true ? shape.id : nil
        }
        let click: @MainActor (ShapeID, CanvasEditor) -> Void = { id, editor in
            log.clicks.append(id)
            log.selectionAtClicks.append(editor.selectedShapeIDs)
        }
        if doubleClicks {
            r.shapeFaces(at: find, click: click, doubleClick: { id, _ in log.doubleClicks.append(id) }, hovering: { _, _ in log.names })
        } else {
            r.shapeFaces(at: find, click: click)
        }
    }
}

/// A plugin that draws a 15-unit square over each shape's top-left corner, and says a point on it is
/// on its shape (`DecorationHits`): over the corner of the shape's own face.
@MainActor func cornersPlugin() -> Contributor {
    Contributor(id: "corners") { r in
        r.decorationHits { editor, point, include in
            editor.paintOrder().reversed().first { record in
                guard let frame = record.box else { return false }
                return CGRect(x: frame.minX, y: frame.minY, width: 15, height: 15).contains(point) && include(record)
            }?.id
        }
    }
}

@MainActor let faceTests = Suite("Faces", [
    test("a plain press on a face, released within the drag threshold, selects its shape and clicks the face; beside it, the shape is pressed as before") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its face: 110 to 130, 110 to 130
        h.click(at: CGPoint(x: 120, y: 120))
        expectEqual(log.clicks, [box])
        expectEqual(log.selectionAtClicks, [[box]], "selected first, as any press selects")
        expectEqual(h.editor.selection, box)
        h.click(at: CGPoint(x: 200, y: 150))
        expectEqual(log.clicks, [box], "beside the face, the shape")
        h.press(at: CGPoint(x: 120, y: 120))
        h.drag(to: CGPoint(x: 123, y: 121))
        h.release()
        expectEqual(log.clicks, [box, box], "selected already, and moved within the threshold: a click")
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 100, y: 100))
        let faces = h.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("faces ") }
        expectEqual(faces?.split(separator: " ").last, "ShapeFaces")
    },
    test("only a plain press asks for a face: with ⇧, ⌘ or ⌥ held the press is the shape's, and a Control-click presses nothing") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))          // its face: 10 to 30
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))        // its face: 210 to 230, 10 to 30
        /// Holds `keys` alone: past the time a key let go of still counts as held.
        @MainActor func holdOnly(_ keys: Modifiers) {
            h.hold(keys)
            h.wait(200)
        }
        h.editor.selection = a
        holdOnly(.shift)
        log.asked = []
        h.press(at: CGPoint(x: 220, y: 20))
        expectEqual(log.asked, [], "not asked with ⇧")
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [a, b], "⇧ adds the shape")
        holdOnly(.command)
        h.click(at: CGPoint(x: 220, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [a], "⌘ takes it away")
        holdOnly(.option)
        h.click(at: CGPoint(x: 220, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [b], "⌥: the shape, selected on the press")
        holdOnly(.control)
        h.click(at: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [b], "a Control-click presses nothing")
        holdOnly([])
        expectEqual(log.clicks, [])
        log.asked = []
        h.press(at: CGPoint(x: 20, y: 20))
        expectEqual(log.asked, [a])
        h.release()
        expectEqual(log.clicks, [a])
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("it's asked about the shape the select tool would press, the front one where shapes overlap, and only that one") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 200)))                  // its face: 10 to 30
        let front = h.add(Box(CGRect(x: 5, y: 5, width: 100, height: 100)))      // its face: 15 to 35
        log.asked = []
        h.press(at: CGPoint(x: 12, y: 12))
        expectEqual(log.asked, [front], "the back shape's face is under the front shape")
        h.release()
        expectEqual(log.clicks, [])
        expectEqual(h.editor.selection, front)
        h.click(at: CGPoint(x: 20, y: 20))
        expectEqual(log.clicks, [front])
    },
    test("a drag from a face past the drag threshold moves the selection from the press, and clicks nothing; Escape lets go of the press") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        h.press(at: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [a, b], "a press on a selected shape keeps the selection")
        h.drag(to: CGPoint(x: 24, y: 20))
        expectEqual(h.editor.document[a]?.box?.origin, .zero, "not past the threshold")
        h.drag(to: CGPoint(x: 30, y: 25))
        h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 10, y: 5))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 210, y: 5))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(log.clicks, [])
        h.press(at: CGPoint(x: 30, y: 25))
        h.escape()
        h.release()
        expectEqual(log.clicks, [], "let go of")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.click(at: CGPoint(x: 30, y: 25))
        expectEqual(log.clicks, [a])
        expectEqual(log.selectionAtClicks, [[a]], "a click selects its shape alone, as a click on a shape of several does")
    },
    test("a lone box pressed on a face waits for the drag threshold, though the rest of it follows the pointer at once (an intended deviation)") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its face: 110 to 130, 110 to 130
        h.press(at: CGPoint(x: 120, y: 120))
        h.drag(to: CGPoint(x: 123, y: 120))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 100, y: 100), "unselected before the press")
        h.drag(to: CGPoint(x: 130, y: 120))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 110, y: 100), "past it, from the press")
        h.release()
        h.press(at: CGPoint(x: 130, y: 120))
        h.drag(to: CGPoint(x: 133, y: 120))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 110, y: 100), "selected before the press")
        h.release()
        expectEqual(log.clicks, [box])
        h.press(at: CGPoint(x: 250, y: 150))
        h.drag(to: CGPoint(x: 253, y: 150))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 113, y: 100), "beside the face, at once")
        h.release()
    },
    test("a double-click on a face runs doubleClick in place of editing, with its shape selected alone; elsewhere on the shape, it edits") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), facesPlugin(log)])
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))   // its face: 110 to 130, 110 to 130
        let box = h.add(Box(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.click(at: CGPoint(x: 120, y: 120))
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)
        expectEqual(log.doubleClicks, [card])
        expectEqual(h.editor.editingShapeID, nil)
        h.release()
        expectEqual(log.clicks, [card], "the double-click's release clicks nothing")
        h.editor.selectedShapeIDs = [box, card]
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)
        expectEqual(h.editor.selectedShapeIDs, [card])
        expectEqual(log.doubleClicks, [card, card])
        h.release()
        h.click(at: CGPoint(x: 200, y: 150))
        h.press(at: CGPoint(x: 200, y: 150), clickCount: 2)
        expectEqual(h.editor.editingShapeID, card, "beside the face, the card's")
        expectEqual(log.doubleClicks, [card, card])
        h.release()
    },
    test("without doubleClick, a double-click on a face edits an Editable shape, and is otherwise one more click") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), facesPlugin(log, doubleClicks: false)])
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        let box = h.add(Box(CGRect(x: 400, y: 100, width: 100, height: 100)))      // its face: 410 to 430, 110 to 130
        h.click(at: CGPoint(x: 120, y: 120))
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)
        expectEqual(h.editor.editingShapeID, card)
        h.release()
        expectEqual(log.clicks, [card])
        h.click(at: CGPoint(x: 420, y: 120))
        h.click(at: CGPoint(x: 420, y: 120), clickCount: 2)
        expectEqual(log.clicks, [card, box, box])
    },
    test("a read-only shape's face still clicks and double-clicks, and a drag from it is refused as from the shape") {
        let log = FaceLog()
        let refusals = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin(), facesPlugin(log), FreezingPlugin(log: refusals)])
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))   // its face: 110 to 130, 110 to 130
        h.editor.freeze([card])
        h.click(at: CGPoint(x: 120, y: 120))
        expectEqual(h.editor.selection, card)
        expectEqual(log.clicks, [card])
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)
        h.release()
        expectEqual(log.doubleClicks, [card])
        expectEqual(refusals.refusals, [], "doubleClick, in place of editing, which a read-only card refuses")
        h.press(at: CGPoint(x: 120, y: 120))
        h.drag(to: CGPoint(x: 150, y: 120))
        h.release()
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 100, y: 100))
        expectEqual(refusals.refusals, [[card]])
        h.click(at: CGPoint(x: 200, y: 150))
        h.press(at: CGPoint(x: 200, y: 150), clickCount: 2)
        h.release()
        expectEqual(refusals.refusals, [[card], [card]], "beside the face, a double-click tries to edit it")
    },
    test("what's drawn for a shape (DecorationHits) over a face is its shape's, never the face's: another shape's, or the face's own shape's") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log), tabsPlugin(), cornersPlugin()])
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))        // its face: 110 to 130, 110 to 130
        let b = h.add(Box(CGRect(x: 100, y: 135, width: 200, height: 100)))        // its tab over a's face: 100 to 160, 105 to 125
        let target = h.add(Box(CGRect(x: 500, y: 500, width: 50, height: 50)))
        log.names = target
        h.move(to: CGPoint(x: 120, y: 120))
        expectEqual(h.editor.hovered, b, "the tab's shape")
        h.click(at: CGPoint(x: 120, y: 120))
        expectEqual(h.editor.selection, b)
        h.move(to: CGPoint(x: 120, y: 128))
        expectEqual(h.editor.hovered, target, "below the tab, the face")
        h.click(at: CGPoint(x: 112, y: 112))                                      // a's corner, over its face
        expectEqual(h.editor.selection, a)
        expectEqual(log.clicks, [])
        h.click(at: CGPoint(x: 120, y: 128))
        expectEqual(log.clicks, [a])
    },
    test("the pointer over a face hovers the shape it names; without one, or one that isn't there or can't be selected, its shape") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GhostsPlugin(), facesPlugin(log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))          // its face: 10 to 30
        let target = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let ghost = h.add(Ghost(CGRect(x: 300, y: 300, width: 100, height: 100)))
        h.move(to: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.hovered, box, "nothing named")
        log.names = target
        h.move(to: CGPoint(x: 21, y: 20))
        expectEqual(h.editor.hovered, target)
        h.hold(.shift)
        h.move(to: CGPoint(x: 22, y: 20))
        expectEqual(h.editor.hovered, target, "whatever keys are held")
        h.hold([])
        h.move(to: CGPoint(x: 60, y: 60))
        expectEqual(h.editor.hovered, box, "beside the face")
        h.click(at: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.hovered, target, "after a click, as the pointer rests there")
        log.names = ghost
        h.move(to: CGPoint(x: 21, y: 20))
        expectEqual(h.editor.hovered, box, "a ghost can't be selected")
        log.names = target
        h.editor.transact { $0.delete([target]) }
        h.move(to: CGPoint(x: 20, y: 20))
        expectEqual(h.editor.hovered, box, "gone")
    },
    test("canvas buttons and handles come before faces") {
        let log = FaceLog()
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin(), facesPlugin(log), bellPlugin(bell)])
        let box = h.add(Box(CGRect(x: 30, y: 30, width: 100, height: 100)))       // its face: 40 to 60, under the bell
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(bell.rings, ["bell"])
        expectEqual(log.clicks, [])
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.transact { $0.delete([box]) }
        let knob = h.add(Knob(CGRect(x: 240, y: 240, width: 30, height: 30)))    // its face: 250 to 270, its handle at 255
        h.click(at: CGPoint(x: 255, y: 255))
        expectEqual(log.clicks, [knob], "unselected, it has no handles")
        h.press(at: CGPoint(x: 255, y: 255))
        h.drag(to: CGPoint(x: 265, y: 255))
        expect(h.editor.session is IdleSession, "the only selected shape's handle, which the knob drags")
        h.release()
        expectEqual(log.clicks, [knob])
        expectEqual(h.editor.document[knob]?.box?.origin, CGPoint(x: 240, y: 240))
    },
])
