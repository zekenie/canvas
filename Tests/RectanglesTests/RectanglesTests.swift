@_spi(Host) import Canvas
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
    test("drawn as a skeleton, zoomed out, it's its teal with no shadow; at the level, drawn as ever") {
        // The camera is Geometry's, which these tests don't import, so the level moves instead:
        // skeletons at 100%, while it's under `skeletonZoom`.
        let h = try EditorHarness(plugins: [KeyboardPlugin(), RectanglesPlugin()])
        let size = CGSize(width: 240, height: 180)
        let blank = renderBitmap(h.editor, size: size)
        h.add(Rectangle(frame: CGRect(x: 40, y: 40, width: 160, height: 100)))
        let full = renderBitmap(h.editor, size: size)
        h.editor.skeletonZoom = 1.01
        let skeleton = renderBitmap(h.editor, size: size)
        let middle = CGPoint(x: 120, y: 90)
        expectEqual(pixel(skeleton, at: middle), pixel(full, at: middle), "its own teal")
        let halo = CGRect(x: 200, y: 50, width: 3, height: 80)
        expectEqual(changedPixels(blank, skeleton, in: halo), 0, "no shadow")
        expect(changedPixels(blank, full, in: halo) > 0, "where the render's is")
        h.editor.skeletonZoom = 1
        expectEqual(changedPixels(full, renderBitmap(h.editor, size: size), in: CGRect(origin: .zero, size: size)), 0, "at the level, in full")
    },
])
