import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Selection
import TestKit

/// A board with a box at (0, 0) and, at (100, 0), a shape of a kind nobody installs.
@MainActor func boardWithKeptAsideShape(_ registry: Registry) throws -> (document: CanvasDocument, box: ShapeID, kept: ShapeID) {
    let box = ShapeID(), kept = ShapeID()
    let json = """
    { "format" : 1, "schema" : { "box" : 0 }, "shapes" : [
      { "id" : "\(box)", "index" : "a0", "kind" : "box", "props" : { "frame" : [[0, 0], [40, 40]] } },
      { "id" : "\(kept)", "index" : "a1", "kind" : "gadget", "props" : { "frame" : [[100, 0], [40, 40]] } } ] }
    """
    let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
    expect(try require(loaded.document[kept]).isOpaque)
    return (loaded.document, box, kept)
}

@MainActor let keptAsideTests = Suite("Kept-aside shapes", [
    test("a shape the board keeps aside is never selected: not by a click, the marquee, select all, or code") {
        let registry = try Registry(plugins: [SelectionPlugin(), FixturesPlugin()])
        let (document, box, kept) = try boardWithKeptAsideShape(registry)
        let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.click(at: CGPoint(x: 120, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.press(at: CGPoint(x: -10, y: -10))
        h.drag(to: CGPoint(x: 200, y: 100), speed: 1)
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.editor.selectedShapeIDs = [kept]
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.isSelectable(kept))
    },
])
