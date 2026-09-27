import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import EllipseTitles
import Ellipses
import Eraser
import Polylines
import Rectangles
import Reordering
import Selection
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

/// Rectangles' own tests are in RectanglesTests; these use it as a shape to work with.
@MainActor let examplesTests = Suite("Examples", [
    test("Rectangles: placed with Selection installed, a new rectangle is selected") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), RectanglesPlugin()])
        expect(h.key("r"))
        h.click(at: CGPoint(x: 300, y: 200))
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(h.editor.selection, rectangle.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("Polylines: L and a drag draw a line through every point dragged; a click draws nothing") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), PolylinesPlugin()])
        expect(h.key("l"))
        h.click(at: CGPoint(x: 50, y: 50))
        expect(h.editor.document.shapes.isEmpty, "a click draws nothing")
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 150, y: 120))
        h.drag(to: CGPoint(x: 200, y: 100))
        h.release()
        let line = try require(h.editor.document.shapes.first?.typed(as: Polyline.self))
        expectEqual(line.props.points, [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 120), CGPoint(x: 200, y: 100)])
        expectEqual(h.editor.currentToolID, ToolID(placing: Polyline.kind), "the tool stays current")
    },
    test("Polylines: Escape takes back the line being drawn") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), PolylinesPlugin()])
        expect(h.key("l"))
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 150, y: 120))
        h.escape()
        h.release()
        expect(h.editor.document.shapes.isEmpty)
    },
    test("Polylines: a line is hit near its stroke only, never inside the loop it draws") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), PolylinesPlugin()])
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0)]
        let id = h.add(Polyline(points: triangle))
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: 4)), id, "within 3 pt of the 3 pt stroke")
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: 6)), nil)
        expectEqual(h.editor.shape(at: CGPoint(x: 150, y: 50)), nil, "inside the loop")
    },
    test("Polylines: the select tool moves a line by its own translation, and Escape puts it back") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), PolylinesPlugin()])
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]
        let id = h.add(Polyline(points: points))
        h.press(at: CGPoint(x: 150, y: 101))
        h.drag(to: CGPoint(x: 180, y: 141))
        expectEqual(h.editor.selection, id)
        expectEqual(h.editor.document[id]?.typed(as: Polyline.self)?.props.points, [CGPoint(x: 130, y: 140), CGPoint(x: 230, y: 140)])
        h.escape()
        expectEqual(h.editor.document[id]?.typed(as: Polyline.self)?.props.points, points)
    },
    test("Polylines: the marquee selects a line it crosses, but not from inside the loop") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), PolylinesPlugin()])
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0)]
        let id = h.add(Polyline(points: triangle))
        h.press(at: CGPoint(x: 120, y: 20))
        h.drag(to: CGPoint(x: 160, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [], "a brush in the loop crosses no segment")
        h.drag(to: CGPoint(x: 160, y: -20))
        expectEqual(h.editor.selectedShapeIDs, [id])
        h.release()
    },
    test("Polylines: arrows don't bind to a line, since it's open") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), ArrowsPlugin(), PolylinesPlugin()])
        h.add(Polyline(points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]))
        expect(h.key("a"))
        h.press(at: CGPoint(x: 200, y: 300))
        h.drag(to: CGPoint(x: 200, y: 101))
        h.release()
        let arrow = try require(h.editor.document.shapes.last?.typed(as: Arrow.self))
        expect(arrow.props.end.binding == nil, "the end stays free")
    },
    test("Eraser: dragging across shapes deletes them, and an arrow lets go of what was erased") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), ArrowsPlugin(), RectanglesPlugin(), EraserPlugin()])
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
        let h = try EditorHarness(plugins: [SelectionPlugin(), ArrowsPlugin(), RectanglesPlugin(), EraserPlugin()])
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
        let h = try EditorHarness(plugins: [SelectionPlugin(), TitlesPlugin(), LabelsPlugin(), RectanglesPlugin()])
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
        let h = try EditorHarness(plugins: [SelectionPlugin(), TitlesPlugin(), LabelsPlugin()])
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
        let h = try EditorHarness(plugins: [SelectionPlugin(), EllipsesPlugin(), TitlesPlugin(), EllipseTitlesPlugin()])
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
        let registry = try Registry(plugins: [RectanglesPlugin(), EraserPlugin(), PolylinesPlugin(), EllipsesPlugin(), TitlesPlugin(), EllipseTitlesPlugin()])
        expectEqual(registry.report, """
        core            tool hand [h]
        rectangles      shape rectangle · tool rectangle [r]
        eraser          tool eraser [e]
        polylines       shape polyline · tool polyline [l]
        ellipses        shape ellipse · tool ellipse [o]
        titles          overlay TitleOverlay
        ellipse-titles  ShapeTitles → ellipse
        """)
    },
    test("Reordering: every kind but those painted by anchor gets Arrange; to front and to back keep the selection's order") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), ContextMenusPlugin(), ArrowsPlugin(), EllipsesPlugin(), RectanglesPlugin(),
                                            PolylinesPlugin(), ReorderingPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Ellipse(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Rectangle(frame: CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [c, a]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        expectEqual(menu.outline, ["Arrange ▸", "  Bring to Front", "  Bring Forward", "  Send Backward", "  Send to Back"])
        try menu.choose("Arrange", "Send to Back")
        expectEqual(h.editor.document.shapes.map(\.id), [a, c, b])
        try require(h.secondaryClick()).choose("Arrange", "Bring to Front")
        expectEqual(h.editor.document.shapes.map(\.id), [b, a, c])
        // A line has no frame, and gets it too; an arrow, drawn just above what it joins, doesn't.
        let line = h.add(Polyline(points: [CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)]))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 301))).outline.first, "Arrange ▸")
        expectEqual(h.editor.selectedShapeIDs, [line])
        h.add(Arrow(start: .free(CGPoint(x: 0, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        expect(h.secondaryClick(at: CGPoint(x: 200, y: 500)) == nil)
    },
    test("Reordering: Bring Forward and Send Backward step past the next shape each overlaps, keeping the selection's order") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), ContextMenusPlugin(), RectanglesPlugin(), ReorderingPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Rectangle(frame: CGRect(x: 50, y: 0, width: 100, height: 100)))      // overlaps a
        let c = h.add(Rectangle(frame: CGRect(x: 500, y: 0, width: 100, height: 100)))     // overlaps nothing
        let d = h.add(Rectangle(frame: CGRect(x: 60, y: 0, width: 100, height: 100)))      // overlaps a and b
        @MainActor func order() -> [ShapeID] { h.editor.document.shapes.map(\.id) }
        @MainActor func choose(_ title: String, on point: CGPoint = CGPoint(x: 10, y: 50)) throws {
            try require(h.secondaryClick(at: point)).choose("Arrange", title)
        }
        try choose("Bring Forward")
        expectEqual(order(), [b, a, c, d])
        try choose("Bring Forward")
        expectEqual(order(), [b, c, d, a], "past c, which it doesn't overlap, to above d")
        let revision = h.editor.revision
        try choose("Bring Forward")
        expectEqual(h.editor.revision, revision, "nothing above it: nothing to do")
        try choose("Send Backward")
        expectEqual(order(), [b, c, a, d])
        try choose("Send Backward")
        expectEqual(order(), [a, b, c, d], "past c again, to below b")

        h.editor.selectedShapeIDs = [b, a]
        try choose("Bring Forward")
        expectEqual(order(), [c, d, a, b], "each past d, the next it overlaps, a still below b")
        try choose("Send Backward")
        expectEqual(order(), [c, a, b, d])
    },
])
