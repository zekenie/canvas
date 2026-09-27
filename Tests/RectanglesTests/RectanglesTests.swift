import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Rectangles
import TestKit

/// Rectangles depends only on the core, and Keyboard for its R, so its tests install nothing else:
/// no Selection, so the default tool is the Hand.
@MainActor let rectanglesTests = Suite("Rectangles", [
    test("R and a press place a 160 × 100 rectangle that follows the pointer") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), RectanglesPlugin()])
        expect(h.key("r"))
        h.press(at: CGPoint(x: 300, y: 200))
        h.drag(to: CGPoint(x: 310, y: 205))
        h.release()
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(rectangle.kind, Rectangle.kind)
        expectEqual(rectangle.box, CGRect(x: 230, y: 155, width: 160, height: 100))
        expectEqual(h.editor.currentToolID, .hand)
    },
    test("hit testing comes from the frame, with nothing written for it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), RectanglesPlugin()])
        let id = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 50)))
        expectEqual(h.editor.shape(at: CGPoint(x: 90, y: 40)), id)
        expectEqual(h.editor.shape(at: CGPoint(x: 110, y: 40)), nil)
    },
])
