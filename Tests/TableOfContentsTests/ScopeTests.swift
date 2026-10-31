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
    test("every shape is listed, in document order, whatever is selected") {
        let editor = try contentsEditor()
        let (a, _, c) = threeWidgets(editor)
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
        editor.selectedShapeIDs = [c, a]
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
        editor.selectedShapeIDs = []
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
    },
    test("a selection made with the select tool leaves the list whole: a click, then a marquee") {
        let h = try EditorHarness { try contentsEditor(scheduler: $0) }
        _ = threeWidgets(h.editor)
        h.click(at: CGPoint(x: 250, y: 30))
        expectEqual(h.editor.selectedShapeIDs.count, 1)
        expectEqual(h.editor.contents.entries.outline, ["A", "B", "C"])
        h.press(at: CGPoint(x: 150, y: -20))
        h.drag(to: CGPoint(x: 600, y: 100))
        h.release()
        expectEqual(h.editor.selectedShapeIDs.count, 2)
        expectEqual(h.editor.contents.entries.outline, ["A", "B", "C"])
    },
    test("a nested row stays under its shape whatever is selected") {
        let editor = try contentsEditor()
        let board = editor.add(Widget(name: "Board"))
        let pin = editor.add(Pin("pin", on: board))
        editor.selectedShapeIDs = [pin]
        expectEqual(editor.contents.entries.outline, ["Board", "  pin"])
        editor.selectedShapeIDs = [pin, board]
        expectEqual(editor.contents.entries.outline, ["Board", "  pin"])
    },
    test("selecting rows selects their shapes, in document order, and keeps every row") {
        let editor = try contentsEditor()
        let (a, b, c) = threeWidgets(editor)
        editor.selectedShapeIDs = [a, b, c]
        editor.contents.select([b])
        expectEqual(editor.selectedShapeIDs, [b])
        editor.contents.select([c, a])
        expectEqual(editor.selectedShapeIDs, [a, c])
        editor.contents.select([])
        expectEqual(editor.selectedShapeIDs, [])
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
    },
    test("a selection changing makes no row: the list is kept, and follows only what commits change") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        _ = editor.contents.entries
        let made = editor.contents.rowsMade
        editor.selectedShapeIDs = [a]
        _ = editor.contents.entries
        editor.selectedShapeIDs = [a, b]
        _ = editor.contents.entries
        editor.selectedShapeIDs = []
        _ = editor.contents.entries
        expectEqual(editor.contents.rowsMade, made)
    },
    test("a shape placed with a tool is listed among the rest") {
        let h = try EditorHarness { try contentsEditor(scheduler: $0) }
        _ = threeWidgets(h.editor)
        expect(h.key("w"))
        h.click(at: CGPoint(x: 700, y: 300))
        expectEqual(h.editor.contents.entries.outline, ["A", "B", "C", "Unnamed"])
    },
])
