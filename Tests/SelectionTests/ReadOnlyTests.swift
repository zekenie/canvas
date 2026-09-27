@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Read-only shapes (`registrar.readOnlyShapes`), with CanvasTesting's `Frozen` flag: they're
// selected as any other shape, and every try to change one through the selection is refused.

@MainActor let readOnlyTests = Suite("Read-only shapes in the selection", [
    test("a read-only shape is pressed, hovered and selected as any other, and a drag leaves it where it is") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin(log: log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.freeze([box])
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 90, y: 70))
        h.release()
        expectEqual(h.editor.selection, box)
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(log.refusals, [[box]])
    },
    test("a read-only shape has no handles: a press where one would be presses the shape") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin(), FreezingPlugin(log: log)])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))   // its handle is at (50, 50)
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 50))
        expect(h.editor.hoveredHandle != nil)
        h.editor.freeze([knob])
        expectEqual(h.editor.hoveredHandle, nil, "the change that froze it took the handle away")
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 50, y: 50)), nil)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 90, y: 50))
        expect(h.editor.session is TranslatingSession, "a press on the shape, not its handle")
        h.release()
        expectEqual(log.refusals, [[knob]])
        h.editor.freeze([knob], false)
        expect(h.editor.handle(atViewPoint: CGPoint(x: 50, y: 50)) != nil, "back when it can change")
    },
    test("Delete takes the selection but its read-only shapes, which stay selected; Return doesn't edit a read-only shape") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), FreezingPlugin(log: log)])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([card])
        h.editor.selectedShapeIDs = [card, box]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [card])
        expectEqual(h.editor.selectedShapeIDs, [card])
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.refusals, [[card], [card]])
    },
])
