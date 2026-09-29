@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Observation
import Selection
import TestKit

/// The Selection plugin inside an editor: pressing, placing, editing, Escape, and the state it
/// keeps as the document changes.
@MainActor let editorTests = Suite("Editor", [
    test("pressing a shape selects it without restacking it, and dragging moves it with no threshold") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        expectEqual(h.editor.selection, a)
        h.drag(to: CGPoint(x: 52, y: 51))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 2, y: 1))
        h.release()
    },
    test("pressing empty canvas deselects on press; a drag brushes and never pans") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = box
        h.press(at: CGPoint(x: 500, y: 500))
        expectEqual(h.editor.selection, nil)
        h.drag(to: CGPoint(x: 520, y: 530))
        expectEqual(h.editor.camera.origin, .zero)
        expectEqual(h.editor.brush, CGRect(x: 500, y: 500, width: 20, height: 30))
        expectEqual(h.editor.cursor, .standard)
        h.drag(to: CGPoint(x: 5, y: 5))
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.release()
        expectEqual(h.editor.camera.origin, .zero)
        expectEqual(h.editor.brush, nil)
    },
    test("double-clicking empty canvas places the claimed kind and starts editing it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), doubleClickCards()])
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        h.release()
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.kind, Card.kind)
        expectEqual(card.box, CGRect(x: 250, y: 170, width: 100, height: 60))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.selection, card.id)
    },
    test("with no claim, double-clicking empty canvas deselects; a drag brushes") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = box
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        expectEqual(h.editor.document.shapes.map(\.id), [box])
        expectEqual(h.editor.selection, nil)
        h.drag(to: CGPoint(x: 5, y: 5))
        expectEqual(h.editor.brush, CGRect(x: 5, y: 5, width: 295, height: 195))
        expectEqual(h.editor.selectedShapeIDs, [box])
        expectEqual(h.editor.camera.origin, .zero)
        h.release()
    },
    test("only one kind may claim double-clicking empty canvas") {
        expectThrows(RegistryError.conflict(point: "DoubleClickPlacement", key: "double-click on empty canvas", plugins: ["cards", "more-cards"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), doubleClickCards(), Contributor(id: "more-cards") { r in
                r.shape(BoxDefinitionForTests()) { box in box.createOnDoubleClick(box.placement(size: .zero) { Box(.zero) }) }
            }])
        }
    },
    test("double-clicking a shape edits it only if its kind is editable; Return does the same") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 50), clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, nil)
        h.press(at: CGPoint(x: 250, y: 50), clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, card)
        h.editor.endEditing()
        h.editor.selection = box; h.editor.editSelection()
        expectEqual(h.editor.editingShapeID, nil)
        h.editor.selection = card; h.editor.editSelection()
        expectEqual(h.editor.editingShapeID, card)
    },
    test("a double-click begins editing from where it's pressed, as a double-click; Return and a placement don't say where: the editing view chooses") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()])
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 250, y: 50), clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.editingStartPoint, CGPoint(x: 250, y: 50))
        expectEqual(h.editor.editingStartClickCount, 2)
        h.editor.endEditing()
        expectEqual(h.editor.editingStartClickCount, 1)
        h.editor.selection = card; h.editor.editSelection()
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.editingStartPoint, nil)
        expectEqual(h.editor.editingStartClickCount, 1)
        h.editor.endEditing()
        h.editor.setTool(ToolID(placing: Card.kind))
        h.press(at: CGPoint(x: 100, y: 300)); h.release()
        expect(h.editor.editingShapeID != nil && h.editor.editingShapeID != card)
        expectEqual(h.editor.editingStartPoint, nil)
    },
    test("a click on the only selected shape of a kind edited in place edits it from where it's released; a first click only selects; a drag moves it") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), FreezingPlugin(log: log)])
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selection, card)
        expectEqual(h.editor.editingShapeID, nil, "the first click selects it")
        h.press(at: CGPoint(x: 240, y: 40))
        h.drag(to: CGPoint(x: 242, y: 41))
        h.release()
        expectEqual(h.editor.editingShapeID, card, "a click, jitter and all, on it selected: edited")
        expectEqual(h.editor.editingStartPoint, CGPoint(x: 242, y: 41), "from where it was released")
        expectEqual(h.editor.editingStartClickCount, 1)
        expectEqual(h.editor.document[card]?.box, CGRect(x: 200, y: 0, width: 100, height: 100), "unmoved")
        h.editor.endEditing()

        h.press(at: CGPoint(x: 250, y: 50))
        h.drag(to: CGPoint(x: 252, y: 50))
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 200, y: 0), "within the threshold it waits")
        h.drag(to: CGPoint(x: 290, y: 60))
        h.release()
        expectEqual(h.editor.editingShapeID, nil, "a drag isn't a click")
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 240, y: 10), "moved with the pointer from the press")

        h.click(at: CGPoint(x: 250, y: 50), activatingWindow: true)
        expectEqual(h.editor.editingShapeID, nil, "the click that brings the window forward only brings it forward")
        expectEqual(h.editor.selection, card)
        h.click(at: CGPoint(x: 450, y: 50))
        h.click(at: CGPoint(x: 450, y: 50))
        expectEqual(h.editor.editingShapeID, nil, "a box isn't edited in place")
        h.editor.selection = card
        h.hold(.shift)
        h.click(at: CGPoint(x: 290, y: 50))
        h.hold([])
        expectEqual(h.editor.editingShapeID, nil, "⇧ takes it out of the selection instead")
        h.editor.transact { $0.update(card) { $0[Frozen.self] = true } }
        h.editor.selection = card
        h.click(at: CGPoint(x: 290, y: 50))
        expectEqual(h.editor.editingShapeID, nil, "a read-only one is only selected")
        expectEqual(log.refusals, [], "and a click on it isn't a try")
        _ = box
    },
    test("a double-click press straight onto a member of a multi-selection edits it, selected alone: what's edited is selected") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [box, card]
        h.press(at: CGPoint(x: 250, y: 50), clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.selectedShapeIDs, [card])
    },
    test("a place tool that edits: centered, selected, editing once the press is let go, and back to select") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()])
        h.editor.setTool(ToolID(placing: Card.kind))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expectEqual(h.editor.cursor, .crosshair)
        h.press(at: CGPoint(x: 100, y: 100))
        h.release()
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.box?.origin, CGPoint(x: 50, y: 70))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.selection, card.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a place tool that translates keeps dragging the new shape, selected, after switching to select") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), discTools()])
        h.editor.setTool(ToolID(placing: Disc.kind))
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.selection, h.editor.document.shapes.first?.id)
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.document.shapes.first?.box?.origin, CGPoint(x: 110, y: 90))
        h.release()
        expectEqual(h.editor.selection, h.editor.document.shapes.first?.id)
    },
    test("Escape leaves a non-select tool; in select it deselects") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()])
        h.editor.setTool(ToolID(placing: Card.kind)); h.escape()
        expectEqual(h.editor.currentToolID, .select)
        h.editor.selection = h.add(Card(.zero))
        h.escape()
        expectEqual(h.editor.selection, nil)
        h.editor.setTool(ToolID(placing: Card.kind))
        h.editor.selection = h.add(Card(.zero))
        h.escape()
        expectEqual(h.editor.currentToolID, .select)
        expect(h.editor.selection != nil, "leaving another tool keeps the selection")
    },
    test("the select tool hovers only while it is the tool, with no session") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.editor.setTool(ToolID(placing: Card.kind))
        expectEqual(h.editor.hovered, nil)
        h.move(to: CGPoint(x: 60, y: 60))
        expectEqual(h.editor.hovered, nil)
    },
    test("the pointer leaving the canvas drops the hover") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.editor.pointerExited()
        expectEqual(h.editor.hovered, nil)
    },
    test("observers of one shape's hover hear only that shape's; observers of the hover hear every change") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        /// Whether `change` reaches observers of `id`'s hover, and of the hover.
        @MainActor func reaches(_ id: ShapeID, _ change: () -> Void) -> (shape: Bool, hover: Bool) {
            let shape = Flag(), hover = Flag()
            withObservationTracking { _ = h.editor.isHovered(id) } onChange: { shape.set() }
            withObservationTracking { _ = h.editor.hovered } onChange: { hover.set() }
            change()
            return (shape.isSet, hover.isSet)
        }
        h.move(to: CGPoint(x: 50, y: 50))
        expect(h.editor.isHovered(a) && !h.editor.isHovered(b))
        let aToB = reaches(c) { h.move(to: CGPoint(x: 250, y: 50)) }
        expect(!aToB.shape && aToB.hover, "the hover moving between two other shapes")
        expect(reaches(b) { h.move(to: CGPoint(x: 450, y: 50)) }.shape, "the hover leaving")
        expect(h.editor.isHovered(c))
        expect(reaches(c) { h.editor.pointerExited() }.shape)
        let missing = reaches(a) { h.editor.hovered = ShapeID() }
        expect(!missing.shape && !missing.hover, "a shape that isn't there: no change")
    },
    test("deleting the selection clears selection and hover") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.selection = box
        h.editor.deleteSelection()
        expect(h.editor.document.shapes.isEmpty)
        expectEqual(h.editor.selection, nil); expectEqual(h.editor.hovered, nil)
    },
    test("pressing a shape leaves the paint order alone; restacking it brings the shapes anchored to it along") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tagA = h.add(Tag(target: a))
        let loose = h.add(Tag(target: nil))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let tagB = h.add(Tag(target: b))
        h.press(at: CGPoint(x: 50, y: 50)); h.release()
        expectEqual(h.editor.paintOrder().map(\.id), [a, tagA, b, tagB, loose])
        h.editor.transact { $0.bringToFront(a) }               // as a Bring to Front does: its tag comes with it
        expectEqual(h.editor.paintOrder().map(\.id), [b, tagB, a, tagA, loose])
    },
    test("any transaction that deletes a shape lets go of it: selection and hover") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.move(to: CGPoint(x: 50, y: 30))
        h.editor.selection = card
        expectEqual(h.editor.hovered, card); expectEqual(h.editor.selection, card)
        h.editor.transact { $0.delete([card]) }                 // not deleteSelection, which clears some itself
        expectEqual(h.editor.selection, nil)
        expectEqual(h.editor.hovered, nil)
    },
    test("the selection only ever names a shape that exists") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = box
        h.editor.selection = ShapeID()
        expectEqual(h.editor.selection, nil)
    },
    test("changing the selection drops the hovered handle") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        h.editor.selection = box
        expectEqual(h.editor.hoveredHandle, nil)
    },
    test("setting the selection to a shape that isn't there, when unset, changes nothing: no redraw, no notification") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.selection; _ = h.editor.selectedShapeIDs } onChange: { changed.set() }
        h.editor.selection = ShapeID()
        expectEqual(host.redraws, 0)
        expect(!changed.isSet)
    },
    test("selecting redraws and is observable") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.selectedShapeIDs } onChange: { changed.set() }
        h.editor.selection = box
        expectEqual(host.redraws, 1)
        expect(changed.isSet)
    },
])
