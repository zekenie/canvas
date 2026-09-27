@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

@MainActor let selectToolTests = Suite("Select tool", [
    // Pressing shapes

    test("a Control-click is the secondary click: it doesn't select, move or deselect; a click just after letting go of ⌃ does") {
        let (h, a, b, _) = try threeBoxes()
        h.editor.selection = b
        h.hold(.control)
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 90, y: 90)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [b])
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
        h.click(at: CGPoint(x: 150, y: 400))
        expectEqual(h.editor.selectedShapeIDs, [b], "nor does one on empty canvas")
        h.hold([])
        h.click(at: CGPoint(x: 50, y: 50))           // ⌃ still counts as held for 150 ms, but not as a Control-click
        expectEqual(h.editor.selectedShapeIDs, [a])
    },

    test("pressing an unselected shape selects only it and raises it; ⇧-pressing adds it without raising") {
        let (h, a, b, c) = try threeBoxes()
        h.editor.selection = c
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.document.shapes.map(\.id), [b, c, a])
        h.hold(.shift)
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(h.editor.document.shapes.map(\.id), [b, c, a])
    },
    test("⇧-click on a selected shape removes it on release; ⇧-dragging it moves the whole selection and keeps it") {
        let (h, a, b, _) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, b]
        h.hold(.shift)
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, b], "not on the press")
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [], "a lone selected shape too")

        h.editor.selectedShapeIDs = [a, b]
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 60, y: 70)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 10, y: 20))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 210, y: 20))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
    test("⌘-press doesn't select or raise; ⌘-click adds on release, and removes a selected shape; ⌘-drag from a shape brushes from the press, enclosing only") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 150, y: 40, width: 20, height: 20)))
        let c = h.add(Box(CGRect(x: 250, y: 0, width: 100, height: 100)))
        h.editor.selection = c
        h.hold(.command)
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [c])
        expectEqual(h.editor.document.shapes.map(\.id), [a, b, c])
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [c, a])
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [c])

        h.editor.selection = a
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 40, y: 45))
        expectEqual(h.editor.document[a]?.box?.origin, .zero, "a lone selected shape too: it brushes")
        expectEqual(h.editor.brush, CGRect(x: 40, y: 45, width: 10, height: 5))
        h.release()
        h.editor.selection = c

        let before = h.editor.document
        h.press(at: CGPoint(x: 90, y: 30))
        h.drag(to: CGPoint(x: 200, y: 80))
        expectEqual(h.editor.brush, CGRect(x: 90, y: 30, width: 110, height: 50))
        expectEqual(h.editor.selectedShapeIDs, [b], "A is only crossed")
        h.release()
        expectEqual(h.editor.brush, nil)
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, [b])
    },
    test("pressing a member of a multi-selection keeps it; release without a drag collapses to that member without raising it; a drag past 4 pt moves them all") {
        let (h, a, b, c) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, c]
        h.press(at: CGPoint(x: 450, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [c])
        expectEqual(h.editor.document.shapes.map(\.id), [a, b, c])
        h.editor.selectedShapeIDs = [c, a]
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 50, y: 60)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 0, y: 10))
        expectEqual(h.editor.document[c]?.box?.origin, CGPoint(x: 400, y: 10))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(h.editor.selectedShapeIDs, [c, a])
        expectEqual(h.editor.document.shapes.map(\.id), [a, b, c])
    },
    test("a 4 pt drag on a multi-selection member moves nothing; just past 4 pt moves") {
        let (h, a, b, _) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, b]
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 54, y: 50))
        expectEqual(h.editor.revision, revision)
        h.drag(to: CGPoint(x: 54.01, y: 50))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: CGFloat(54.01) - 50, y: 0))
        h.release()
    },
    test("pressing an unselected shape inside the selection box: a drag moves the old selection, not it; a release selects it alone (⇧: adds it)") {
        let (h, a, b, c) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, c]
        h.press(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.drag(to: CGPoint(x: 260, y: 60)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 10, y: 10))
        expectEqual(h.editor.document[c]?.box?.origin, CGPoint(x: 410, y: 10))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [b])
        expectEqual(h.editor.document.shapes.map(\.id), [a, b, c], "not raised")
        h.editor.selectedShapeIDs = [a, c]
        h.hold(.shift)
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, c, b])
    },
    test("the release is hit-tested again: pressing A in a multi-selection and releasing over overlapping B collapses to B; with ⇧, adds B") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 97, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, c]
        h.press(at: CGPoint(x: 95, y: 50)); h.move(to: CGPoint(x: 99, y: 50)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.editor.selectedShapeIDs = [a, c]
        h.hold(.shift)
        h.press(at: CGPoint(x: 95, y: 50)); h.move(to: CGPoint(x: 99, y: 50)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [a, c, b])
    },
    test("Escape while pointing a shape ends the press; a later drag does nothing") {
        let (h, a, b, _) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, b]
        h.hold(.shift)
        h.press(at: CGPoint(x: 50, y: 50))
        h.escape()
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 90, y: 90)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the ⇧-click's release never came")
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
    },

    // Empty canvas and the selection box

    test("pressing empty canvas deselects on press; a click leaves nothing selected; the camera never moves") {
        let (h, a, _, _) = try threeBoxes()
        h.editor.selection = a
        h.press(at: CGPoint(x: 700, y: 500))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.selection = a
        h.press(at: CGPoint(x: 700, y: 500)); h.drag(to: CGPoint(x: 703, y: 500)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.brush, nil)
        expectEqual(h.editor.camera, Camera())
    },
    test("⇧ or ⌘ on empty canvas keeps the selection on press and on release; a ⇧ let go 100 ms before the release still counts, 200 ms doesn't") {
        let (h, a, _, _) = try threeBoxes()
        h.editor.selection = a
        for modifier in [Modifiers.shift, .command] {
            h.hold(modifier)
            h.press(at: CGPoint(x: 700, y: 500))
            expectEqual(h.editor.selectedShapeIDs, [a])
            h.release()
            expectEqual(h.editor.selectedShapeIDs, [a])
        }
        h.hold(.shift)
        h.press(at: CGPoint(x: 700, y: 500)); h.hold([]); h.release(after: 100)
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.hold(.shift)
        h.press(at: CGPoint(x: 700, y: 500)); h.hold([]); h.release(after: 200)
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("pressing empty space inside a multi-selection's box drags the selection; a click there deselects; a ⇧-click keeps it") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, c]
        h.press(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.drag(to: CGPoint(x: 252, y: 50))
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
        h.drag(to: CGPoint(x: 270, y: 80)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 20, y: 30))
        expectEqual(h.editor.document[c]?.box?.origin, CGPoint(x: 420, y: 30))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.press(at: CGPoint(x: 122, y: 60)); h.move(to: CGPoint(x: 119, y: 60)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [a, c], "released over A, already selected")
        h.press(at: CGPoint(x: 250, y: 60))
        h.escape()
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 290, y: 60)); h.release()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 20, y: 30))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.hold(.shift)
        h.click(at: CGPoint(x: 250, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        h.hold([])
        h.wait(200)
        h.click(at: CGPoint(x: 250, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("panned and zoomed, dragging a multi-selection by its box's empty space and ⌘-brushing from a shape both start at the press's world point") {
        let (h, a, _, c) = try threeBoxes()
        let camera = Camera(origin: CGPoint(x: 37, y: -12), zoom: 0.6)
        h.editor.camera = camera
        h.editor.selectedShapeIDs = [a, c]
        let press = CGPoint(x: 70, y: 40), drag = CGPoint(x: 82, y: 58)     // world (153.7, 54.7): the box's empty space
        h.press(at: press); h.drag(to: drag); h.release()
        let delta = camera.toWorld(drag) - camera.toWorld(press)
        expectEqual(h.editor.document[a]?.box?.origin, delta)
        expectEqual(h.editor.document[c]?.box?.origin, CGPoint(x: 400, y: 0) + delta)

        let onA = camera.toView(CGPoint(x: 40, y: 50)), past = onA + CGPoint(x: 40, y: 30)
        h.hold(.command)
        h.press(at: onA); h.drag(to: past)
        expectEqual(h.editor.brush, CGRect(enclosing: [camera.toWorld(onA), camera.toWorld(past)]))
        h.release()
    },
    test("Escape while pointing empty canvas does nothing: the press goes on, and a drag brushes") {
        let (h, a, _, _) = try threeBoxes()
        h.editor.selection = a
        h.hold(.shift)
        h.press(at: CGPoint(x: 150, y: 150))
        h.escape()
        expect(h.editor.session != nil)
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.drag(to: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.brush, CGRect(x: 150, y: 50, width: 100, height: 100))
        h.release()
    },

    // Double-click, handles, editing

    test("double-clicking empty canvas places the claimed kind; with ⇧ it doesn't") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), doubleClickCards()])
        h.hold(.shift)
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        expect(h.editor.document.shapes.isEmpty)
        h.drag(to: CGPoint(x: 320, y: 220))
        expectEqual(h.editor.brush, CGRect(x: 300, y: 200, width: 20, height: 20))
        h.release()
        h.hold([])
        h.wait(200)
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        let card = try require(h.editor.document.shapes.first)
        expectEqual(h.editor.editingShapeID, card.id)
    },
    test("double-clicking an editable member of a multi-selection edits it and selects only it") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [card, box]
        h.click(at: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50), clickCount: 2)
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.selectedShapeIDs, [card])
        h.release()
    },
    test("a multi-selection shows no handles; pressing where a handle would be presses the shape") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 50, y: 50)), AnyHashable(0))
        h.editor.selectedShapeIDs = [knob, box]
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 50, y: 50)), nil)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, nil)
        expectEqual(h.editor.cursor, .standard)
        h.press()
        expectEqual(h.editor.cursor, .standard, "not a handle press, whose cursor is the closed hand")
        h.drag(to: CGPoint(x: 60, y: 50)); h.release()
        expectEqual(h.editor.document[knob]?.box?.origin, CGPoint(x: 10, y: 0))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 210, y: 0))
    },

    // Hover

    test("hover outlines only unselected shapes, in select, with no session") {
        let (h, disc, box, _) = try selectables()
        h.editor.selection = disc
        h.move(to: CGPoint(x: 190, y: 110))
        let base = renderBitmap(h.editor, size: selectablesCanvas)
        let everywhere = CGRect(origin: .zero, size: selectablesCanvas)
        h.move(to: CGPoint(x: 40, y: 40))
        expectEqual(changedPixels(base, renderBitmap(h.editor, size: selectablesCanvas), in: everywhere), 0, "the disc is selected")
        h.move(to: CGPoint(x: 120, y: 80))
        expectEqual(h.editor.hovered, box)
        expect(changedPixels(base, renderBitmap(h.editor, size: selectablesCanvas), in: everywhere) > 0)
        h.hold(.shift)
        h.press(at: CGPoint(x: 190, y: 110)); h.drag(to: CGPoint(x: 150, y: 110))
        expectEqual(h.editor.hovered, nil, "none while brushing")
        h.release()
    },
])

/// Boxes A, B and C at x = 0, 200 and 400, each 100 × 100, in that order.
@MainActor func threeBoxes() throws -> (EditorHarness, ShapeID, ShapeID, ShapeID) {
    let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
    let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
    let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
    let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
    return (h, a, b, c)
}
