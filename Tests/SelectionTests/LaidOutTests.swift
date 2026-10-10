@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// A shape laid out larger than it stores (CanvasTesting's stretch, laid out by the gauge it names) is
// selected, boxed and brushed by the frame it is laid out in; the select tool resizes only what is
// stored.

@MainActor private func selectionHarness() throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), StretchesPlugin()])
}

@MainActor let laidOutSelectionTests = Suite("Selecting laid-out frames", [
    test("the selection's bounds are worked out again when shapes are laid out again with no commit, and not otherwise") {
        #if DEBUG
        let h = try selectionHarness()
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 200, height: 90))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        h.editor.selectedShapeIDs = [stretch]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 200, height: 90), "the frame it is laid out in")
        let worked = h.editor.selectionBoundsWorkedOut
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 200, height: 90))
        expectEqual(h.editor.selectionBoundsWorkedOut, worked, "kept through a frame and a read")
        let revision = h.editor.revision
        h.editor.shapesDidChangeLayout([stretch])
        expectEqual(h.editor.revision, revision, "no commit")
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 200, height: 90))
        expectEqual(h.editor.selectionBoundsWorkedOut, worked + 1, "worked out again")
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 300 } }
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 300, height: 90), "and with the gauge's commit")
        #endif
    },
    test("the marquee takes a stretch by its grown part, which its stored box doesn't reach") {
        let h = try selectionHarness()
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 400, height: 60))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 0, width: 100, height: 60), gauge: gauge))
        h.press(at: CGPoint(x: 350, y: 150))
        h.drag(to: CGPoint(x: 320, y: 30))
        expectEqual(h.editor.selectedShapeIDs, [stretch])
        h.release()
    },
    test("a stretch has no handles: a press at its stored corner presses the shape, and the drag moves it") {
        let h = try selectionHarness()
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 400, height: 60))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 0, width: 100, height: 60), gauge: gauge))
        h.editor.selectedShapeIDs = [stretch]
        h.press(at: CGPoint(x: 99, y: 59))
        h.drag(to: CGPoint(x: 129, y: 59))
        h.release()
        expectEqual(h.editor.document[stretch]?.box, CGRect(x: 30, y: 0, width: 100, height: 60))
    },
])
