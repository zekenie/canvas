import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import DetailPanel
import Geometry
import Selection
import StickyNotes
import TestKit
import Validation

@MainActor let shippedTests = Suite("Shipped plugins", [
    test("the shipped plugin list registers without conflicts") {
        _ = try ShippedPlugins.registry()
    },
    test("the toolbar is Select V, Hand H, Arrow A, Note N, Ellipse O, Task T, Rectangle R, Line L, Eraser E") {
        let tools = try ShippedPlugins.registry().tools
        expectEqual(tools.map(\.help), ["Select (V)", "Hand (H)", "Arrow (A)", "Note (N)", "Ellipse (O)", "Task (T)", "Rectangle (R)", "Line (L)", "Eraser (E)"])
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry().report, """
        core                tool hand [h]
        selection           service SelectionState · tool select [v] · default tool select · outlines · overlay HandlesOverlay · command delete · command insertNewline · command selectAll
        arrows              shape arrow · service ArrowTargeting · tool arrow [a] · overlay BindingHintsOverlay · willDelete
        sticky-notes        shape sticky-note · tool sticky-note [n] · DoubleClickPlacement → sticky-note · ValidationRules → sticky-note · ShapeChecklists → sticky-note · ShapeDetails → sticky-note
        ellipses            shape ellipse · tool ellipse [o]
        task-cards          shape task-card · tool task-card [t] · ValidationRules → task-card · ShapeDetails → task-card · ShapeChecklists → task-card · ShapeDetails → task-card
        validation          service ValidationEngine · overlay ValidationOverlay
        detail-panel        service DetailPanelState · ShapeDetails
        checklists          overlay ChecklistOverlay
        validation-details  DetailStatuses
        rectangles          shape rectangle · tool rectangle [r]
        polylines           shape polyline · tool polyline [l]
        eraser              tool eraser [e]
        titles              overlay TitleOverlay
        ellipse-titles      ShapeTitles → ellipse
        """)
    },
    test("every placed kind has a panel: a note its Checklist and Arrange, a task its own tabs too, other boxes Arrange, an arrow only its header") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        let state = try require(h.editor.detailPanel)
        var panels: [String] = []
        for (shortcut, x) in [("o", 100.0), ("r", 400), ("a", 700), ("n", 1000), ("t", 1400)] {
            h.key(shortcut)
            h.press(at: CGPoint(x: x, y: 100))
            h.drag(to: CGPoint(x: x + 150, y: 300))
            h.release()
            let layout = state.layout(for: try require(h.editor.selection.flatMap { h.editor.document[$0] }))
            panels.append("\(layout.header.title): \(layout.tabs.map(\.title).joined(separator: ", "))")
        }
        expectEqual(panels, ["Ellipse: Arrange", "Rectangle: Arrange", "Arrow: ", "Note: Checklist, Arrange",
                             "New Task: Task, Checklist, Style, Arrange"])
    },
    test("a line drawn with L is a Line in the panel, with nothing but its header") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        let state = try require(h.editor.detailPanel)
        h.key("l")
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 100))
        h.release()
        h.key("v")
        h.click(at: CGPoint(x: 300, y: 100))
        let layout = state.layout(for: try require(h.editor.selection.flatMap { h.editor.document[$0] }))
        expectEqual(layout.header.title, "Line")
        expectEqual(layout.tabs.count, 0)
    },
    test("the welcome board: six notes, three arrows, no warnings") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler())
        expectEqual(editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 6)
        expectEqual(editor.document.shapes.filter { $0.kind == Arrow.kind }.count, 3)
        expectEqual(editor.validation?.results.count, 0)
    },
    test("the shipped welcome board differs from the POC's only in the third note, which mentions H and no longer says dragging the background pans") {
        let shipped = WelcomeBoard.texts
        expectEqual(shipped.count, pocWelcomeTexts.count)
        expectEqual(shipped.indices.filter { shipped[$0] != pocWelcomeTexts[$0] }, [2])
        expect(shipped[2].contains("Press H"))
        expect(!shipped[2].contains("pans too"))
        let notes = WelcomeBoard.document().shapes.compactMap { $0.typed(as: StickyNote.self)?.props.text }
        expectEqual(notes, shipped)
    },
    test("O then a drag places an ellipse and moves it into place") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0) }
        h.key("o")
        h.press(at: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 340, y: 320))
        h.release()
        expectEqual(h.editor.document.shapes.first?.box, CGRect(x: 240, y: 250, width: 200, height: 140))
        expectEqual(h.editor.currentToolID, .select)
    },
])
