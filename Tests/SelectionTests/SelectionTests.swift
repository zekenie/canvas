@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Observation
import Selection
import TestKit

@MainActor let selectionTests = Suite("Selection", [
    test("selection is the only selected shape: nil with none or several; setting it selects exactly that one; nil clears a multi-selection") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10))), b = h.add(Box(CGRect(x: 20, y: 0, width: 10, height: 10)))
        expectEqual(h.editor.selection, nil)
        h.editor.selection = a
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.selection, a)
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(h.editor.selection, nil)
        expect(h.editor.isSelected(a) && h.editor.isSelected(b))
        h.editor.selection = b
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.editor.selectedShapeIDs = [a, b]
        h.editor.selection = nil
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.isSelected(a))
    },
    test("selectedShapeIDs keeps selection order and drops missing ids and repeats") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        h.editor.selectedShapeIDs = [c, a, b]
        expectEqual(h.editor.selectedShapeIDs, [c, a, b])
        h.editor.selectedShapeIDs = [b, ShapeID(), a, b, ShapeID()]
        expectEqual(h.editor.selectedShapeIDs, [b, a])
        h.editor.selectedShapeIDs = [ShapeID(), a, a]
        expectEqual(h.editor.selection, a)
    },
    test("setting the same set, or only missing ids when nothing is selected, changes nothing: no redraw, no notification") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero))
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.selection; _ = h.editor.selectedShapeIDs } onChange: { changed.set() }
        h.editor.selectedShapeIDs = [ShapeID()]
        h.editor.selection = ShapeID()
        expectEqual(host.redraws, 0)
        expect(!changed.isSet)
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(host.redraws, 1)
        let changedAgain = Flag()
        withObservationTracking { _ = h.editor.selection; _ = h.editor.selectedShapeIDs } onChange: { changedAgain.set() }
        h.editor.selectedShapeIDs = [a, b]
        h.editor.selectedShapeIDs = [a, ShapeID(), b, a]
        expectEqual(host.redraws, 1)
        expect(!changedAgain.isSet)
    },
    test("observers of selection hear only changes to the only selected shape: [a,b] → [a,b,c] fires selectedShapeIDs but not selection; [a] → [a,b] fires both") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        @MainActor func changes(_ change: () -> Void) -> (selection: Bool, set: Bool) {
            let selection = Flag(), set = Flag()
            withObservationTracking { _ = h.editor.selection } onChange: { selection.set() }
            withObservationTracking { _ = h.editor.selectedShapeIDs } onChange: { set.set() }
            change()
            return (selection.isSet, set.isSet)
        }
        h.editor.selectedShapeIDs = [a, b]
        let grown = changes { h.editor.selectedShapeIDs = [a, b, c] }
        expect(!grown.selection && grown.set)
        h.editor.selection = a
        let added = changes { h.editor.selectedShapeIDs = [a, b] }
        expect(added.selection && added.set)
    },
    test("selectionRevision counts changes to the selection, and only those") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10))), b = h.add(Box(CGRect(x: 20, y: 0, width: 10, height: 10)))
        expectEqual(h.editor.selectionRevision, 0)
        h.editor.selectedShapeIDs = [a]
        h.editor.selectedShapeIDs = [a]
        expectEqual(h.editor.selectionRevision, 1, "the same selection again isn't a change")
        h.editor.selectedShapeIDs = [a, b]
        h.editor.selectedShapeIDs = []
        h.editor.selectedShapeIDs = [a]
        expectEqual(h.editor.selectionRevision, 4, "back to [a] is a fourth change")
        h.editor.transact { $0.update(b, as: Box.self) { $0.props.frame.origin.x += 5 } }
        expectEqual(h.editor.selectionRevision, 4, "a document change leaving the selection alone")
        h.editor.transact { $0.delete([a]) }
        expectEqual(h.editor.selectionRevision, 5, "deleting the selected shape empties the selection")
        let bare = try EditorHarness(plugins: [FixturesPlugin()])
        bare.editor.selectedShapeIDs = [bare.add(Box(.zero))]
        expectEqual(bare.editor.selectionRevision, 0, "without the Selection plugin")
    },
    test("a transaction deleting one selected shape keeps the others selected") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        h.editor.selectedShapeIDs = [a, b, c]
        h.editor.transact { $0.delete([b]) }
        expectEqual(h.editor.selectedShapeIDs, [a, c])
        expectEqual(h.editor.selection, nil)
        h.editor.transact { $0.delete([c]) }
        expectEqual(h.editor.selection, a, "down to one, it's the only selected shape")
    },
    test("changing the only selected shape drops the hovered handle; adding a second drops it too") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let other = h.add(Knob(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        h.editor.selection = other
        expectEqual(h.editor.hoveredHandle, nil)
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 51))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        h.editor.selectedShapeIDs = [knob, other]
        expectEqual(h.editor.hoveredHandle, nil)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, nil, "several selected have no handles")
    },
    test("Delete deletes every selected shape in one commit and clears selection and hover") {
        let deleted = DeletionLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "log") { r in r.willDelete { ids, _ in deleted.batches.append(ids) } }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.selectedShapeIDs = [c, a]
        let revision = h.editor.revision
        h.editor.deleteSelection()
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(deleted.batches, [[a, c]])
        expectEqual(h.editor.document.shapes.map(\.id), [b])
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.hovered, nil)
        h.editor.deleteSelection()
        expectEqual(h.editor.revision, revision + 1, "nothing selected: nothing to do")
    },
    test("selectAll ends editing, switches to select and selects every shape in document order; mid-gesture it does nothing") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 60)))
        h.editor.beginEditing(card)
        h.editor.setTool(ToolID(placing: Card.kind))
        h.editor.selectAll()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.selectedShapeIDs, [box, card])
        h.editor.selection = nil
        h.press(at: CGPoint(x: 50, y: 50))                      // moving the box
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.release()
    },
    test("Delete can run while something's selected (a locked shape too, which refuses), and Select All while the board has shapes; else their keys pass") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin()])
        expect(!h.editor.canPerform(.delete))
        expect(!h.editor.canPerform(.selectAll))
        expect(!h.key("\u{7f}"), "Delete with nothing selected passes")
        h.hold(.command)
        expect(!h.key("a"), "⌘A on an empty board passes")
        h.hold([])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(h.editor.canPerform(.selectAll))
        expect(!h.editor.canPerform(.delete))
        let frozen = h.add(Box(CGRect(x: 200, y: 0, width: 50, height: 50)))
        h.editor.freeze([frozen])
        h.editor.selection = frozen
        expect(h.editor.canPerform(.delete), "read-only: it runs, and the shape refuses")
        h.editor.selection = box
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[box], nil)
    },
    test("Escape in select with several selected selects none") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.editor.selectedShapeIDs = [h.add(Box(.zero)), h.add(Box(.zero))]
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("selectionBounds is the union of geometry bounds, ignoring shapes with no outline") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 10, y: 20, width: 10, height: 10)))
        let b = h.add(Box(CGRect(x: 100, y: 50, width: 20, height: 20)))
        let tag = h.add(Tag(target: nil))                       // bounds .zero, which would reach the origin
        expectEqual(h.editor.selectionBounds, nil)
        h.editor.selection = tag
        expectEqual(h.editor.selectionBounds, nil)
        h.editor.selectedShapeIDs = [tag, a]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 10, height: 10))
        h.editor.selectedShapeIDs = [tag, a, b]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 110, height: 50))
    },
])

final class DeletionLog {
    var batches: [Set<ShapeID>] = []
}
