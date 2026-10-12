@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// A drag of the selection with ⌥ held, where a plugin claims `copiesOnDrag`: the drag moves what the plugin
// put down in place, and the claim is the plugin's alone (Selection copies nothing itself).

/// Claims the ⌥ drag with copies of the shapes it is given (a box per shape, under a new id), or with none.
private struct CopiersPlugin: CanvasPlugin {
    var id: PluginID { "copiers" }
    let copies: Bool
    func register(into registrar: inout PluginRegistrar) {
        registrar.copiesOnDrag { editor, ids in
            guard copies else { return [] }
            let made = ids.compactMap { editor.document[$0]?.copy() }
            editor.transact("Copy") { transaction in made.forEach { transaction.insert($0) } }
            return made.map(\.id)
        }
    }
}

@MainActor private func copyDragHarness(_ copies: Bool?) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()] + (copies.map { [CopiersPlugin(copies: $0)] } ?? []))
}

@MainActor let copyDragTests = Suite("Dragging with ⌥ held", [
    test("copies the plugin made follow the pointer in place of the shapes, are selected, and are one step with the drag") {
        let h = try copyDragHarness(true)
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.hold(.option)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 90), speed: 4)
        h.release()
        h.hold([])
        let copy = try require(h.editor.selectedShapeIDs.first)
        expect(copy != box)
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(h.editor.document[copy]?.box?.origin, CGPoint(x: 30, y: 40))
        expectEqual(h.editor.undoHistory.undoName, "Copy")
        h.editor.undo()
        expectEqual(h.editor.document.shapes.map(\.id), [box])
    },
    test("Escape takes the copies away and selects what was selected; no step is left") {
        let h = try copyDragHarness(true)
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        let before = h.editor.document
        h.hold(.option)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 90), speed: 4)
        expectEqual(h.editor.document.shapes.count, 2)
        h.escape()
        h.release()
        h.hold([])
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("a plugin that makes none, or no plugin, leaves the drag moving the shapes; so does a drag without ⌥") {
        for copies in [false, nil] {
            let h = try copyDragHarness(copies)
            let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
            h.editor.selection = box
            h.hold(.option)
            h.press(at: CGPoint(x: 50, y: 50))
            h.drag(to: CGPoint(x: 80, y: 90), speed: 4)
            h.release()
            h.hold([])
            expectEqual(h.editor.document.shapes.count, 1)
            expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 30, y: 40))
        }
        let h = try copyDragHarness(true)
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 90), speed: 4)
        h.release()
        expectEqual(h.editor.document.shapes.count, 1)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 30, y: 40))
    },
])
