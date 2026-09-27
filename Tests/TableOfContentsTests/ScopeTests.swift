@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TableOfContents
import TestKit

/// Three named widgets side by side, and their ids.
@MainActor func threeWidgets(_ editor: CanvasEditor) -> (a: ShapeID, b: ShapeID, c: ShapeID) {
    (editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "A")),
     editor.add(Widget(CGRect(x: 200, y: 0, width: 100, height: 60), name: "B")),
     editor.add(Widget(CGRect(x: 400, y: 0, width: 100, height: 60), name: "C")))
}

@MainActor let scopeTests = Suite("Table of contents: what's listed", [
    test("with nothing selected every shape is listed; selecting shapes lists just them, in document order") {
        let editor = try contentsEditor()
        let (a, _, c) = threeWidgets(editor)
        expectEqual(editor.contents.scope, nil)
        expect(!editor.contents.isFiltered)
        editor.selectedShapeIDs = [c, a]
        expectEqual(editor.contents.scope, [c, a])
        expectEqual(editor.contents.entries.outline, ["A", "C"])
        editor.selectedShapeIDs = []
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
    },
    test("a selection made with the select tool filters the list: a click, then a marquee") {
        let h = try EditorHarness { try contentsEditor(scheduler: $0) }
        _ = threeWidgets(h.editor)
        h.click(at: CGPoint(x: 250, y: 30))
        expectEqual(h.editor.contents.entries.outline, ["B"])
        h.click(at: CGPoint(x: 150, y: 300))
        expectEqual(h.editor.contents.entries.outline, ["A", "B", "C"], "a click on empty canvas deselects; pressing B didn't restack it")
        h.press(at: CGPoint(x: 150, y: -20))
        h.drag(to: CGPoint(x: 600, y: 100))
        h.release()
        expectEqual(h.editor.contents.entries.outline, ["B", "C"])
    },
    test("a nested row is listed at the top when only it is selected, and under its shape when both are") {
        let editor = try contentsEditor()
        let board = editor.add(Widget(name: "Board"))
        let pin = editor.add(Pin("pin", on: board))
        editor.selectedShapeIDs = [pin]
        expectEqual(editor.contents.entries.outline, ["pin"])
        editor.selectedShapeIDs = [pin, board]
        expectEqual(editor.contents.entries.outline, ["Board", "  pin"])
    },
    test("selecting rows selects their shapes, in document order, and keeps listing what was listed") {
        let editor = try contentsEditor()
        let (a, b, c) = threeWidgets(editor)
        editor.selectedShapeIDs = [a, b, c]
        editor.contents.select([b])
        expectEqual(editor.selectedShapeIDs, [b])
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"], "picking one of three leaves all three")
        editor.contents.select([c, a])
        expectEqual(editor.selectedShapeIDs, [a, c])
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
    },
    test("selecting rows from the whole board keeps the whole board listed") {
        let editor = try contentsEditor()
        let (_, b, _) = threeWidgets(editor)
        editor.contents.select([b])
        expectEqual(editor.selection, b)
        expect(!editor.contents.isFiltered)
        editor.contents.select([])
        expectEqual(editor.selectedShapeIDs, [])
        expect(!editor.contents.isFiltered)
    },
    test("the list follows the selection again as soon as it changes some other way, even to the same shapes") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        editor.contents.select([a])
        expect(!editor.contents.isFiltered)
        editor.selectedShapeIDs = []
        editor.selectedShapeIDs = [a]
        expectEqual(editor.contents.scope, [a], "selected again from the canvas: filtered to it")
        editor.selectedShapeIDs = [a, b]
        editor.contents.select([b])
        editor.transact { $0.delete([b]) }         // drops it from the selection
        expectEqual(editor.contents.scope, nil, "nothing is selected now")
    },
    test("Show All lists every shape and keeps the selection, until the selection changes") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        editor.selectedShapeIDs = [a]
        editor.contents.showAll()
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
        expectEqual(editor.selectedShapeIDs, [a])
        editor.selectedShapeIDs = [b]
        expectEqual(editor.contents.entries.outline, ["B"])
    },
    test("a shape placed with a tool is selected, so it's listed alone") {
        let h = try EditorHarness { try contentsEditor(scheduler: $0) }
        _ = threeWidgets(h.editor)
        expect(h.key("w"))
        h.click(at: CGPoint(x: 700, y: 300))
        expectEqual(h.editor.contents.entries.outline, ["Unnamed"])
    },
])
