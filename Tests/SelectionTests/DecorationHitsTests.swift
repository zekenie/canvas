@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// What a plugin draws for a shape outside it (`DecorationHits`): here a tab above a shape's top-left
// corner, 60 by 20 world units and 10 above it, which the select tool takes as the shape.

/// The tab a plugin draws above a shape with this frame.
func tab(of frame: CGRect) -> CGRect { CGRect(x: frame.minX, y: frame.minY - 30, width: 60, height: 20) }

/// A plugin that draws a tab above each shape `shows` picks, and says a point on one is on its shape:
/// front to back, the first whose tab is there that `include` accepts.
@MainActor func tabsPlugin(_ id: PluginID = "tabs", on shows: @escaping @MainActor (AnyShapeRecord) -> Bool = { _ in true }) -> Contributor {
    Contributor(id: id) { r in
        r.decorationHits { editor, point, include in
            editor.paintOrder().reversed().first { record in
                guard let frame = record.box, shows(record), tab(of: frame).contains(point) else { return false }
                return include(record)
            }?.id
        }
    }
}

@MainActor let decorationHitsTests = Suite("Decoration hits", [
    test("a press on what a plugin draws for a shape outside it selects the shape, a drag from it moves the shape, and a hover hovers it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), tabsPlugin()])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))      // its tab: 100 to 160, 70 to 90
        h.move(to: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.hovered, box)
        h.move(to: CGPoint(x: 200, y: 80))
        expectEqual(h.editor.hovered, nil, "beside the tab, the canvas")
        h.press(at: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.drag(to: CGPoint(x: 150, y: 120))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 130, y: 140), "a lone box follows from the press")
    },
    test("with several selected, a click on one's tab, drawn over another shape, selects just it, and with ⇧ takes it away: the release is hit again") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), tabsPlugin()])
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))       // its tab: 100 to 160, 70 to 90
        let b = h.add(Box(CGRect(x: 50, y: 60, width: 300, height: 30)))          // in front, under the tab
        h.editor.selectedShapeIDs = [a, b]
        h.click(at: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.editor.selectedShapeIDs = [a, b]
        h.hold(.shift)
        h.click(at: CGPoint(x: 120, y: 80))
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [b], "the tab's shape taken away")
    },
    test("it's asked before shapes: a tab drawn over another shape's body is its own shape's") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), tabsPlugin()])
        let back = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its tab: 100 to 160, 70 to 90
        let front = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 85)))         // over the tab's top 15
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 120, y: 80)), back)
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 200, y: 80)), front, "beside the tab, the shape in front")
        h.click(at: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.selectedShapeIDs, [back])
    },
    test("`include` is the select tool's rule: an unselectable shape's tab is seen through, to what's beneath it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GhostsPlugin(), tabsPlugin()])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.add(Ghost(CGRect(x: 100, y: 100, width: 200, height: 100)))              // in front of the box, its tab over the box's
        h.add(Ghost(CGRect(x: 400, y: 100, width: 200, height: 100)))              // alone: its tab 400 to 460, 70 to 90
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 120, y: 80)), box, "the box's tab, beneath the ghost's")
        h.move(to: CGPoint(x: 420, y: 80))
        expectEqual(h.editor.hovered, nil)
        h.press(at: CGPoint(x: 420, y: 80))
        h.drag(to: CGPoint(x: 380, y: 60))
        expectEqual(h.editor.brush, CGRect(x: 380, y: 60, width: 40, height: 20), "a press there is on the canvas: a drag, a marquee")
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("a canvas button wins over it, as over a shape") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), tabsPlugin(),
                                            bellPlugin(bell, at: CGRect(x: 100, y: 70, width: 20, height: 20))])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.click(at: CGPoint(x: 110, y: 80))
        expectEqual(bell.rings, ["bell"])
        expectEqual(h.editor.selectedShapeIDs, [])
        h.click(at: CGPoint(x: 140, y: 80))
        expectEqual(h.editor.selectedShapeIDs, [box], "beside the button, the tab's shape")
    },
    test("the last plugin's is asked first, as its drawing is over the others'") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            tabsPlugin("box-tabs") { $0.kind == Box.kind }, tabsPlugin("disc-tabs") { $0.kind == Disc.kind }])
        let disc = h.add(Disc(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))                   // in front of the disc, its tab where the disc's is
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 120, y: 80)), disc)
    },
    test("a double-click there edits an editable shape as with no press (it isn't in the shape's text), and places nothing") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), doubleClickCards(), tabsPlugin()])
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.click(at: CGPoint(x: 120, y: 80))
        h.press(at: CGPoint(x: 120, y: 80), clickCount: 2)
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.editingStartPoint, nil, "the view puts the caret where it would with no press")
        expectEqual(h.editor.editingStartClickCount, 1, "and selects no word there")
        expectEqual(h.editor.document.shapes.map(\.id), [card], "no card placed on the tab")
        h.release()
    },
    test("a click there on the only selected shape doesn't edit it: it's no click in its text; a drag from it moves the shape") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin(), tabsPlugin()])
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.editor.selection = card
        h.click(at: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selection, card)
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 100, y: 100))
        h.editor.beginEditing(card)
        h.click(at: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.editingShapeID, nil, "while it's edited, a click there ends editing, and begins none")
        expectEqual(h.editor.selection, card)
        h.press(at: CGPoint(x: 120, y: 80)); h.drag(to: CGPoint(x: 160, y: 90)); h.release()
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 140, y: 110))
    },
    test("only the select tool's hit rule counts it: the core's `shape(at:)`, which other tools hit-test with, and the marquee go by shapes alone") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), tabsPlugin()])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        expectEqual(h.editor.selectableShape(at: CGPoint(x: 120, y: 80)), box)
        expectEqual(h.editor.shape(at: CGPoint(x: 120, y: 80)), nil, "the core's hit test: nothing on the tab")
        h.press(at: CGPoint(x: 90, y: 60))
        h.drag(to: CGPoint(x: 170, y: 95))
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [], "a marquee over the tab alone")
        let tabs = h.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("tabs ") }
        expectEqual(tabs?.split(separator: " ").last, "DecorationHits")
    },
])
