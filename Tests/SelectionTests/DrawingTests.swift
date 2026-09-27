@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

@MainActor let drawingTests = Suite("Drawing", [
    test("two selected shapes are both outlined, with the selection box around them") {
        let (h, disc, box, _) = try selectables()
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        for edge in [CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 80)] {          // the disc's right, the box's left
            expect(pixel(selected, at: edge) != pixel(unselected, at: edge), "outlined at \(edge)")
        }
        // The union of their bounds, (20, 20)–(140, 100), where neither shape is.
        for edge in [CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 100), CGPoint(x: 20, y: 80)] {
            expect(pixel(selected, at: edge) != pixel(unselected, at: edge), "the box at \(edge)")
        }
        expectEqual(pixel(selected, at: CGPoint(x: 80, y: 60)), pixel(unselected, at: CGPoint(x: 80, y: 60)), "it's a box, not a fill")
    },
    test("one selected shape is outlined, with no box") {
        let (h, disc, _, _) = try selectables()
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selection = disc
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        expect(pixel(selected, at: CGPoint(x: 60, y: 40)) != pixel(unselected, at: CGPoint(x: 60, y: 40)))
        let frameCorner = CGRect(x: 18, y: 18, width: 5, height: 5)             // clear of the disc's outline
        expectEqual(changedPixels(unselected, selected, in: frameCorner), 0)
        expectEqual(changedPixels(unselected, selected, in: CGRect(x: 64, y: 0, width: 136, height: 120)), 0)
        expectEqual(changedPixels(unselected, selected, in: CGRect(x: 0, y: 64, width: 200, height: 56)), 0)
    },
    test("a session that hides outlines hides the selection's outlines and box, not the hint") {
        let (h, disc, box, hinted) = try selectables()
        h.editor.hintedShapeID = hinted
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        h.editor.session = OutlineHidingSession()
        expectEqual(changedPixels(unselected, renderBitmap(h.editor, size: selectablesCanvas), in: CGRect(origin: .zero, size: selectablesCanvas)), 0)
    },
    test("translating and brushing keep the outlines and the box") {
        let (h, disc, box, _) = try selectables()
        let everywhere = CGRect(origin: .zero, size: selectablesCanvas)
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        // Empty space in the selection box: past the threshold and back, so nothing has moved.
        h.press(at: CGPoint(x: 80, y: 60)); h.drag(to: CGPoint(x: 90, y: 60))
        let reference = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()], document: h.editor.document)
        reference.editor.selectedShapeIDs = [disc, box]
        expectEqual(changedPixels(renderBitmap(reference.editor, size: selectablesCanvas), renderBitmap(h.editor, size: selectablesCanvas), in: everywhere), 0,
                    "moved, outlines and all")
        h.drag(to: CGPoint(x: 80, y: 60))
        expectEqual(changedPixels(selected, renderBitmap(h.editor, size: selectablesCanvas), in: everywhere), 0)
        expect(changedPixels(unselected, selected, in: everywhere) > 0)
        h.release()
        h.hold(.shift)
        h.press(at: CGPoint(x: 195, y: 115)); h.drag(to: CGPoint(x: 190, y: 110))
        expect(h.editor.brush != nil)
        expectEqual(changedPixels(selected, renderBitmap(h.editor, size: selectablesCanvas), in: CGRect(x: 0, y: 0, width: 185, height: 105)), 0)
        h.release()
    },
    test("the brush fills tldraw's gray at 0.102 and strokes it at 0.251, 1 view point wide at zoom 1 and 2") {
        for zoom: CGFloat in [1, 2] {
            let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin()])
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let size = CGSize(width: 100, height: 100)
            let background = renderBitmap(h.editor, size: size, scale: 2)
            h.press(at: CGPoint(x: 20, y: 20)); h.drag(to: CGPoint(x: 80, y: 70))
            let brushed = renderBitmap(h.editor, size: size, scale: 2)
            h.release()
            // Device pixels at 2×: the left edge's 1 pt stroke covers x 19.5–20.5, the fill x ≥ 20.
            func blend(_ under: [Int], _ alpha: CGFloat) -> [Int] {
                under.prefix(3).map { Int((CGFloat($0) + (0.56 * 255 - CGFloat($0)) * alpha).rounded()) } + [255]
            }
            @MainActor func expectNear(_ point: CGPoint, _ expected: [Int], _ what: String) {
                let actual = pixel(brushed, at: point, scale: 2)
                expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(what) at zoom \(zoom): \(actual), not \(expected)")
            }
            let bg = pixel(background, at: CGPoint(x: 21, y: 45), scale: 2)
            expectEqual(pixel(brushed, at: CGPoint(x: 19.25, y: 45), scale: 2), pixel(background, at: CGPoint(x: 19.25, y: 45), scale: 2), "outside at zoom \(zoom)")
            expectNear(CGPoint(x: 19.75, y: 45), blend(bg, 0.251), "stroke")
            expectNear(CGPoint(x: 20.25, y: 45), blend(blend(bg, 0.102), 0.251), "fill and stroke")
            expectNear(CGPoint(x: 21, y: 45), blend(bg, 0.102), "fill")
        }
    },
])

let selectablesCanvas = CGSize(width: 200, height: 120)

/// A disc in (20, 20, 40, 40), a box at (100, 60, 40, 40), and a small box at (160, 10, 20, 20).
@MainActor func selectables() throws -> (EditorHarness, ShapeID, ShapeID, ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
    let disc = h.add(Disc(CGRect(x: 20, y: 20, width: 40, height: 40)))
    let box = h.add(Box(CGRect(x: 100, y: 60, width: 40, height: 40)))
    let small = h.add(Box(CGRect(x: 160, y: 10, width: 20, height: 20)))
    return (h, disc, box, small)
}
