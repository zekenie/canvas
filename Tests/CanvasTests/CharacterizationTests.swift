@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// Pins how a lone box moves: the press commits nothing, each drag commits once, with no threshold,
// and the box lands bitwise where the POC put it. Don't edit these to make a change pass.
@MainActor let characterizationTests = Suite("Characterization", [
    test("a lone box press commits nothing and hides its outline at once; each drag event commits once, with no threshold") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 20, y: 20, width: 60, height: 60)))
        let size = CGSize(width: 100, height: 100)
        let plain = renderBitmap(h.editor, size: size)
        h.editor.selection = box
        let outlined = renderBitmap(h.editor, size: size)
        expect(changedPixels(plain, outlined, in: CGRect(origin: .zero, size: size)) > 0, "a selected box is outlined")
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.selection, box)
        expectEqual(changedPixels(plain, renderBitmap(h.editor, size: size), in: CGRect(origin: .zero, size: size)), 0)
        h.drag(to: CGPoint(x: 51, y: 50))
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 21, y: 20))
        h.drag(to: CGPoint(x: 51, y: 52))
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 21, y: 22))
        h.release()
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.selection, box)
    },
    test("a fractional, zoomed lone-box move lands bitwise on pointer.world − grab offset") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let origin = CGPoint(x: 100, y: 100)
        let box = h.add(Box(CGRect(origin: origin, size: CGSize(width: 200, height: 200))))
        h.editor.camera = Camera(origin: .zero, zoom: 0.6)
        let press = CGPoint(x: 101.25, y: 99.5)
        let grabOffset = h.editor.camera.toWorld(press) - origin
        h.press(at: press)
        // At the last point, origin + (pointer.world − press.world) differs in the last bit on both axes.
        for point in [CGPoint(x: 143.7, y: 151.3), CGPoint(x: 157.9, y: 172.1), CGPoint(x: 0.1, y: 0.7)] {
            h.drag(to: point)
            expectEqual(h.editor.document[box]?.box?.origin, h.editor.camera.toWorld(point) - grabOffset)
        }
        h.release()
    },
    test("the cursor stays standard while moving a box") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .standard)
        h.press()
        expectEqual(h.editor.cursor, .standard)
        h.drag(to: CGPoint(x: 70, y: 60))
        expectEqual(h.editor.cursor, .standard)
        h.release()
        expectEqual(h.editor.cursor, .standard)
    },
])
