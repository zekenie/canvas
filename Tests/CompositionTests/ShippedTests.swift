import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Geometry
import StickyNotes
import TestKit
import Validation

@MainActor let shippedTests = Suite("Shipped plugins", [
    test("the shipped plugin list registers without conflicts") {
        _ = try ShippedPlugins.registry()
    },
    test("the toolbar is Select V, Arrow A, Note N, Ellipse O, Rectangle R, Eraser E") {
        let tools = try ShippedPlugins.registry().tools
        expectEqual(tools.map(\.help), ["Select (V)", "Arrow (A)", "Note (N)", "Ellipse (O)", "Rectangle (R)", "Eraser (E)"])
    },
    test("the registry report: who contributes what") {
        expectEqual(try ShippedPlugins.registry().report, """
        core            tool select [v]
        arrows          shape arrow · service ArrowTargeting · tool arrow [a] · overlay BindingHintsOverlay · willDelete
        sticky-notes    shape sticky-note · tool sticky-note [n] · double-click sticky-note · ValidationRules → sticky-note
        ellipses        shape ellipse · tool ellipse [o]
        validation      service ValidationEngine · overlay ValidationOverlay
        rectangles      shape rectangle · tool rectangle [r]
        eraser          tool eraser [e]
        titles          overlay TitleOverlay
        ellipse-titles  ShapeTitles → ellipse
        """)
    },
    test("the welcome board: six notes, three arrows, no warnings") {
        let editor = ShippedPlugins.makeEditor(scheduler: ManualScheduler())
        expectEqual(editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 6)
        expectEqual(editor.document.shapes.filter { $0.kind == Arrow.kind }.count, 3)
        expectEqual(editor.validation?.results.count, 0)
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
