@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Observation
import Selection
import TestKit

/// The Selection plugin inside an editor: pressing, placing, editing, Escape, and the state it
/// keeps as the document changes.
@MainActor let editorTests = Suite("Editor", [
    test("pressing a shape brings it to front, selects it, and dragging moves it with no threshold") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.document.shapes.map(\.id), [b, a])
        expectEqual(h.editor.selection, a)
        h.drag(to: CGPoint(x: 52, y: 51))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 2, y: 1))
        h.release()
    },
    test("pressing empty canvas deselects on press; a drag brushes and never pans") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
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
        let h = try EditorHarness(plugins: [SelectionPlugin(), doubleClickCards()])
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.kind, Card.kind)
        expectEqual(card.box, CGRect(x: 250, y: 170, width: 100, height: 60))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.selection, card.id)
    },
    test("with no claim, double-clicking empty canvas deselects; a drag brushes") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
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
            _ = try Registry(plugins: [SelectionPlugin(), doubleClickCards(), Contributor(id: "more-cards") { r in
                r.shape(BoxDefinitionForTests()) { box in box.createOnDoubleClick(box.placement(size: .zero) { Box(.zero) }) }
            }])
        }
    },
    test("double-clicking a shape edits it only if its kind is editable; Return does the same") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
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
    test("a double-click press straight onto a member of a multi-selection edits it, selected alone: what's edited is selected") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [box, card]
        h.press(at: CGPoint(x: 250, y: 50), clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.selectedShapeIDs, [card])
    },
    test("a place tool that edits: centered, selected, editing, and back to select") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), CardsPlugin()])
        expect(h.key("c"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expectEqual(h.editor.cursor, .crosshair)
        h.press(at: CGPoint(x: 100, y: 100))
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.box?.origin, CGPoint(x: 50, y: 70))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.selection, card.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a place tool that translates keeps dragging the new shape, selected, after switching to select") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), discTools()])
        h.key("d")
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.selection, h.editor.document.shapes.first?.id)
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.document.shapes.first?.box?.origin, CGPoint(x: 110, y: 90))
        h.release()
        expectEqual(h.editor.selection, h.editor.document.shapes.first?.id)
    },
    test("Escape leaves a non-select tool; in select it deselects") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), CardsPlugin()])
        h.key("c"); h.escape()
        expectEqual(h.editor.currentToolID, .select)
        h.editor.selection = h.add(Card(.zero))
        h.escape()
        expectEqual(h.editor.selection, nil)
        h.key("c")
        h.editor.selection = h.add(Card(.zero))
        h.escape()
        expectEqual(h.editor.currentToolID, .select)
        expect(h.editor.selection != nil, "leaving another tool keeps the selection")
    },
    test("hover outlines only in the select tool with no session") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.key("c")
        expectEqual(h.editor.hovered, nil)
        h.move(to: CGPoint(x: 60, y: 60))
        expectEqual(h.editor.hovered, nil)
    },
    test("the pointer leaving the canvas drops the hover") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.editor.pointerExited()
        expectEqual(h.editor.hovered, nil)
    },
    test("deleting the selection clears selection and hover") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.selection = box
        h.editor.deleteSelection()
        expect(h.editor.document.shapes.isEmpty)
        expectEqual(h.editor.selection, nil); expectEqual(h.editor.hovered, nil)
    },
    test("pressing a shape raises it, and the shapes anchored to it come along") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tagA = h.add(Tag(target: a))
        let loose = h.add(Tag(target: nil))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let tagB = h.add(Tag(target: b))
        h.press(at: CGPoint(x: 50, y: 50)); h.release()       // bring a to front: its tag comes with it
        expectEqual(h.editor.paintOrder().map(\.id), [b, tagB, a, tagA, loose])
    },
    test("any transaction that deletes a shape lets go of it: selection and hover") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.move(to: CGPoint(x: 50, y: 30))
        h.editor.selection = card
        expectEqual(h.editor.hovered, card); expectEqual(h.editor.selection, card)
        h.editor.transact { $0.delete([card]) }                 // not deleteSelection, which clears some itself
        expectEqual(h.editor.selection, nil)
        expectEqual(h.editor.hovered, nil)
    },
    test("the selection only ever names a shape that exists") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = box
        h.editor.selection = ShapeID()
        expectEqual(h.editor.selection, nil)
    },
    test("changing the selection drops the hovered handle") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        h.editor.selection = box
        expectEqual(h.editor.hoveredHandle, nil)
    },
    test("setting the selection to a shape that isn't there, when unset, changes nothing: no redraw, no notification") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.selection; _ = h.editor.selectedShapeIDs } onChange: { changed.set() }
        h.editor.selection = ShapeID()
        expectEqual(host.redraws, 0)
        expect(!changed.isSet)
    },
    test("selecting redraws and is observable") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
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
