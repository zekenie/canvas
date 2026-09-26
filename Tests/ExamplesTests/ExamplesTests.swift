import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import EllipseTitles
import Ellipses
import Eraser
import Rectangles
import TestKit
import Titles

/// A vertical that opts into titles itself, as a feature plugin would.
struct Label: BoxShapeProps {
    static let kind: ShapeKind = "label"
    var frame: CGRect
    var text: String
}

struct LabelDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Label>, in context: RenderContext) {}
}

struct LabelsPlugin: CanvasPlugin {
    var id: PluginID = "labels"
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LabelDefinition()) { label in label.title { $0.props.text } }
    }
}

struct MoreLabelTitles: CanvasPlugin {
    var id: PluginID { "more" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.title(Label.self) { _ in "another" }
    }
}

@MainActor let examplesTests = Suite("Examples", [
    test("Rectangles: R and a press place a 160 × 100 rectangle that follows the pointer") {
        let h = try EditorHarness(plugins: [RectanglesPlugin()])
        expect(h.key("r"))
        h.press(at: CGPoint(x: 300, y: 200))
        h.drag(to: CGPoint(x: 310, y: 205))
        h.release()
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(rectangle.kind, Rectangle.kind)
        expectEqual(rectangle.box, CGRect(x: 230, y: 155, width: 160, height: 100))
        expectEqual(h.editor.selection, rectangle.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("Rectangles: hit testing comes from the frame, with nothing written for it") {
        let h = try EditorHarness(plugins: [RectanglesPlugin()])
        let id = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 50)))
        expectEqual(h.editor.shape(at: CGPoint(x: 90, y: 40)), id)
        expectEqual(h.editor.shape(at: CGPoint(x: 110, y: 40)), nil)
    },
    test("Eraser: dragging across shapes deletes them, and an arrow lets go of what was erased") {
        let h = try EditorHarness(plugins: [ArrowsPlugin(), RectanglesPlugin(), EraserPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Rectangle(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Rectangle(frame: CGRect(x: 400, y: 0, width: 100, height: 100)))
        let bound = ArrowBinding(shapeID: b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)
        let arrow = h.add(Arrow(start: .bound(bound), end: .free(CGPoint(x: 250, y: 300))))
        expect(h.key("e"))
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 250, y: 50))
        h.release()
        expectEqual(h.editor.document[a], nil)
        expectEqual(h.editor.document[b], nil)
        expect(h.editor.document[c] != nil)
        let start = try require(h.editor.document[arrow]?.typed(as: Arrow.self)?.props.start)
        expect(start.binding == nil, "the arrow let go of the erased rectangle")
        expectEqual(h.editor.currentToolID, .eraser)
    },
    test("Eraser: a quick stroke erases what it crosses between two events, even a thin arrow") {
        let h = try EditorHarness(plugins: [ArrowsPlugin(), RectanglesPlugin(), EraserPlugin()])
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 300, y: 300))))
        let thin = h.add(Rectangle(frame: CGRect(x: 391, y: 0, width: 4, height: 100)))
        expect(h.key("e"))
        h.press(at: CGPoint(x: 200, y: 250))
        h.drag(to: CGPoint(x: 200, y: 350), speed: 1)       // events land 14 pt apart, either side of the arrow
        h.release()
        expectEqual(h.editor.document[arrow], nil)
        h.press(at: CGPoint(x: 300, y: 50))
        h.drag(to: CGPoint(x: 500, y: 50), speed: 3)       // 48 pt apart, jumping the 4 pt rectangle
        h.release()
        expectEqual(h.editor.document[thin], nil)
    },
    test("Titles: a kind opts in with one line; kinds that don't have no title") {
        let h = try EditorHarness(plugins: [TitlesPlugin(), LabelsPlugin(), RectanglesPlugin()])
        let label = h.add(Label(frame: CGRect(x: 0, y: 0, width: 100, height: 40), text: "Hello"))
        let rectangle = h.add(Rectangle(frame: CGRect(x: 200, y: 0, width: 100, height: 40)))
        expectEqual(h.editor.registry.title(of: try require(h.editor.document[label])), "Hello")
        expectEqual(h.editor.registry.title(of: try require(h.editor.document[rectangle])), nil)
    },
    test("Titles: one title per kind; a second plugin titling the same kind is an error") {
        expectThrows(RegistryError.conflict(point: "ShapeTitles", key: "label", plugins: ["labels", "more"])) {
            _ = try Registry(plugins: [TitlesPlugin(), LabelsPlugin(), MoreLabelTitles()])
        }
    },
    test("Titles: hovering a titled shape draws its title below it") {
        let h = try EditorHarness(plugins: [TitlesPlugin(), LabelsPlugin()])
        h.add(Label(frame: CGRect(x: 20, y: 20, width: 100, height: 40), text: "Hello"))
        h.move(to: CGPoint(x: 300, y: 300))
        let before = renderBitmap(h.editor, size: CGSize(width: 200, height: 120))
        h.move(to: CGPoint(x: 50, y: 40))
        let after = renderBitmap(h.editor, size: CGSize(width: 200, height: 120))
        var changed = 0
        for y in stride(from: 62, to: 84, by: 1) {
            for x in stride(from: 20, to: 60, by: 1) where pixel(before, at: CGPoint(x: x, y: y)) != pixel(after, at: CGPoint(x: x, y: y)) {
                changed += 1
            }
        }
        expect(changed > 20, "title pixels below the label: \(changed)")
    },
    test("EllipseTitles: a bridge titles ellipses, though Ellipses and Titles don't know each other") {
        let h = try EditorHarness(plugins: [EllipsesPlugin(), TitlesPlugin(), EllipseTitlesPlugin()])
        let ellipse = h.add(Ellipse(frame: CGRect(x: 0, y: 0, width: 200, height: 140)))
        expectEqual(h.editor.registry.title(of: try require(h.editor.document[ellipse])), "Ellipse, 200 × 140")
    },
    test("EllipseTitles: needs both plugins it connects") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: "ellipse-titles")) {
            _ = try Registry(plugins: [EllipsesPlugin(), EllipseTitlesPlugin()])
        }
        expectThrows(RegistryError.unknownKind("ellipse", point: "ShapeTitles", contributor: "ellipse-titles")) {
            _ = try Registry(plugins: [TitlesPlugin(), EllipseTitlesPlugin()])
        }
    },
    test("the examples' report: who contributes what") {
        let registry = try Registry(plugins: [RectanglesPlugin(), EraserPlugin(), EllipsesPlugin(), TitlesPlugin(), EllipseTitlesPlugin()])
        expectEqual(registry.report, """
        core            tool select [v]
        rectangles      shape rectangle · tool rectangle [r]
        eraser          tool eraser [e]
        ellipses        shape ellipse · tool ellipse [o]
        titles          overlay TitleOverlay
        ellipse-titles  ShapeTitles → ellipse
        """)
    },
])
