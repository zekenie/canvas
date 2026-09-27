@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Observation
import TestKit

@MainActor let editorTests = Suite("Editor", [
    test("pressing a shape brings it to front, selects it, and dragging moves it with no threshold") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
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
        let h = try EditorHarness(plugins: [FixturesPlugin()])
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
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.kind, Card.kind)
        expectEqual(card.box, CGRect(x: 250, y: 170, width: 100, height: 60))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.selection, card.id)
    },
    test("with no claim, double-clicking empty canvas deselects; a drag brushes") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
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
    test("double-clicking a shape edits it only if its kind is editable; Return does the same") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin()])
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
    test("a place tool that edits: centered, selected, editing, and back to select") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        expect(h.key("c"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expectEqual(h.editor.cursor, .crosshair)
        h.press(at: CGPoint(x: 100, y: 100))
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.box?.origin, CGPoint(x: 50, y: 70))
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a place tool that translates keeps dragging the new shape after switching to select") {
        let h = try EditorHarness(plugins: [Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", shortcut: "d", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
            }
        }])
        h.key("d")
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .select)
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.document.shapes.first?.box?.origin, CGPoint(x: 110, y: 90))
        h.release()
        expectEqual(h.editor.selection, h.editor.document.shapes.first?.id)
    },
    test("tool switches made on the canvas are observable, so the toolbar needs no callback") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let changed = Flag()
        withObservationTracking { _ = h.editor.currentToolID } onChange: { changed.set() }
        h.key("c")
        expect(changed.isSet)
    },
    test("Escape leaves a non-select tool; in select it deselects") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.key("c"); h.escape()
        expectEqual(h.editor.currentToolID, .select)
        h.editor.selection = h.add(Card(.zero))
        h.escape()
        expectEqual(h.editor.selection, nil)
    },
    test("shortcuts are case-insensitive; other keys fall through") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        expect(h.key("C")); expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expect(h.key("v")); expectEqual(h.editor.currentToolID, .select)
        expect(!h.key("q")); expect(!h.key("cv"))
    },
    test("hover outlines only in the select tool with no session") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hovered, box)
        h.key("c")
        expectEqual(h.editor.hovered, nil)
        h.move(to: CGPoint(x: 60, y: 60))
        expectEqual(h.editor.hovered, nil)
    },
    test("deleting the selection clears selection and hover") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        h.editor.selection = box
        h.editor.deleteSelection()
        expect(h.editor.document.shapes.isEmpty)
        expectEqual(h.editor.selection, nil); expectEqual(h.editor.hovered, nil)
    },
    test("an anchored shape paints just above its anchor, or on top without one, and isn't raised when pressed") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tagA = h.add(Tag(target: a))
        let loose = h.add(Tag(target: nil))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let tagB = h.add(Tag(target: b))
        expectEqual(h.editor.paintOrder().map(\.id), [a, tagA, b, tagB, loose])
        h.press(at: CGPoint(x: 50, y: 50)); h.release()       // bring a to front: its tag comes with it
        expectEqual(h.editor.paintOrder().map(\.id), [b, tagB, a, tagA, loose])
    },
    test("an editing view's context writes through a transaction and ends editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        field.context.update { $0.text = "hi" }
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "hi")
        field.context.end()
        expectEqual(h.editor.editingShapeID, nil)
        expect(h.editor.makeEditingView() == nil)
    },
    test("any transaction that deletes a shape lets go of it: selection, hover, hint and editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.move(to: CGPoint(x: 50, y: 30))
        h.editor.hintedShapeID = card
        h.editor.beginEditing(card)
        expectEqual(h.editor.hovered, card); expectEqual(h.editor.selection, card); expectEqual(h.editor.hintedShapeID, card)
        h.editor.transact { $0.delete([card]) }                 // not deleteSelection, which clears some itself
        expectEqual(h.editor.selection, nil)
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("pressing the canvas ends editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.editor.beginEditing(card)
        h.press(at: CGPoint(x: 500, y: 500)); h.release()
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("selection and hint only ever name a shape that exists") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = box
        h.editor.selection = ShapeID()
        expectEqual(h.editor.selection, nil)
        h.editor.hintedShapeID = box
        h.editor.hintedShapeID = ShapeID()
        expectEqual(h.editor.hintedShapeID, nil)
    },
    test("changing the selection drops the hovered handle") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        h.editor.selection = box
        expectEqual(h.editor.hoveredHandle, nil)
    },
    test("setting the selection or hint to a shape that isn't there, when unset, changes nothing: no redraw, no notification") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.selection; _ = h.editor.hintedShapeID } onChange: { changed.set() }
        h.editor.selection = ShapeID()
        h.editor.hintedShapeID = ShapeID()
        expectEqual(host.redraws, 0)
        expect(!changed.isSet)
    },
    test("switching tools redraws, since handles and binding hints depend on the tool") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        h.key("c")
        let afterSwitch = host.redraws
        expect(afterSwitch >= 1)
        h.escape()
        expect(host.redraws > afterSwitch)
    },
    test("setNeedsDisplay reaches the hosting view") {
        let h = try EditorHarness(plugins: [])
        let host = DisplayCounter()
        h.editor.delegate = host
        h.editor.setNeedsDisplay()
        expectEqual(host.redraws, 1)
    },
    test("a kind can have two place tools, each with its own id") {
        let h = try EditorHarness(plugins: [Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", shortcut: "d", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
                disc.tool("small-disc", label: "Small disc", systemImage: "circle.fill", shortcut: "s",
                          placing: disc.placement(size: CGSize(width: 10, height: 10)) { Disc(.zero) })
            }
        }])
        expectEqual(h.editor.registry.tools.map(\.id), [.select, .hand, ToolID(placing: Disc.kind), "small-disc"])
        h.key("s"); h.press(at: CGPoint(x: 100, y: 100)); h.release()
        h.key("d"); h.press(at: CGPoint(x: 300, y: 300)); h.release()
        expectEqual(h.editor.document.shapes.map(\.box), [CGRect(x: 95, y: 95, width: 10, height: 10), CGRect(x: 280, y: 280, width: 40, height: 40)])
    },
])

/// A box with one handle, at its center.
struct Knob: BoxShapeProps {
    static let kind: ShapeKind = "knob"
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

struct KnobDefinition: ShapeDefinition, HandleProviding {
    func render(_ shape: ShapeRecord<Knob>, in context: RenderContext) {}
    func handles(of shape: ShapeRecord<Knob>, in context: ShapeContext) -> [HandleLocation<Int>] {
        [HandleLocation(0, at: CGPoint(x: shape.frame.midX, y: shape.frame.midY))]
    }
    func pressHandle(_ handle: Int, of shape: ShapeRecord<Knob>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress { .drag }
    func dragSession(for handle: Int, of shape: ShapeRecord<Knob>, from origin: CGPoint, in editor: CanvasEditor) -> any Session { IdleSession() }
}

final class IdleSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

struct KnobsPlugin: CanvasPlugin {
    var id: PluginID { "knobs" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(KnobDefinition()) }
}

/// Counts what the editor tells its view.
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

struct DiscDefinitionForTests: ShapeDefinition {
    func render(_ shape: ShapeRecord<Disc>, in context: RenderContext) {}
}

final class Flag: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}
