import Adornments
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import DetailPanel
import Eraser
import Keyboard
import Polylines
import RectangleTitles
import Rectangles
import Reordering
import Selection
import TableOfContents
import TestKit
import Titles

/// Rectangles' own tests are in RectanglesTests; these use it as a shape to work with.
@MainActor let examplesTests = Suite("Examples", [
    test("Rectangles: placed with Selection installed, a new rectangle is selected") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), RectanglesPlugin()])
        expect(h.key("r"))
        h.click(at: CGPoint(x: 300, y: 200))
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(h.editor.selection, rectangle.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("Polylines: L and a drag draw a line through every point dragged; a click draws nothing") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
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
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
        expect(h.key("l"))
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 150, y: 120))
        h.escape()
        h.release()
        expect(h.editor.document.shapes.isEmpty)
    },
    test("Polylines: a line is hit near its stroke only, never inside the loop it draws") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0)]
        let id = h.add(Polyline(points: triangle))
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: 4)), id, "within 3 pt of the 3 pt stroke")
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: 6)), nil)
        expectEqual(h.editor.shape(at: CGPoint(x: 150, y: 50)), nil, "inside the loop")
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: -4)), id, "above it: past its points' bounds, within its hit margin")
        expectEqual(h.editor.shape(at: CGPoint(x: -4, y: -1)), id, "past its end")
    },
    test("Polylines: the select tool moves a line by its own translation, and Escape puts it back") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
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
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
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
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), PolylinesPlugin()])
        h.add(Polyline(points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]))
        let id = h.add(Arrow(start: .free(CGPoint(x: 200, y: 500)), end: .free(CGPoint(x: 200, y: 300))))
        h.editor.selection = id
        h.press(at: CGPoint(x: 200, y: 300))                            // its end's handle
        h.drag(to: CGPoint(x: 200, y: 101))
        h.release()
        let arrow = try require(h.editor.document[id]?.typed(as: Arrow.self))
        expectEqual(arrow.props.end, .free(CGPoint(x: 200, y: 101)), "the end stays free")
    },
    test("Eraser: dragging across shapes deletes them, and an arrow lets go of what was erased") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), RectanglesPlugin(), EraserPlugin()])
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
    test("Eraser: a stroke is one step, however many shapes it takes as it goes; undoing it puts them back where they were, and the arrow bound again") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), RectanglesPlugin(), EraserPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Rectangle(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.add(Rectangle(frame: CGRect(x: 400, y: 0, width: 100, height: 100)))
        let bound = ArrowBinding(shapeID: b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)
        h.add(Arrow(start: .bound(bound), end: .free(CGPoint(x: 250, y: 300))))
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        expect(h.key("e"))
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 150, y: 50))
        expectEqual(h.editor.document[a], nil, "gone mid-stroke")
        h.drag(to: CGPoint(x: 250, y: 50))
        h.release()
        expectEqual(h.editor.document[b], nil)
        expectEqual(h.editor.undoHistory.undoName, "Erase")
        h.editor.undo()
        expectEqual(h.editor.document, before)
        expect(!h.editor.canUndo, "one step")
    },
    test("Polylines: a line is one step, Draw Line, from its first point to its last") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
        expect(h.key("l"))
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 150, y: 120)); h.drag(to: CGPoint(x: 200, y: 100)); h.drag(to: CGPoint(x: 250, y: 140))
        h.release()
        let line = try require(h.editor.document.shapes.first)
        expectEqual(h.editor.undoHistory.undoName, "Draw Line")
        h.editor.undo()
        expect(h.editor.document.shapes.isEmpty)
        expect(!h.editor.canUndo)
        h.editor.redo()
        expectEqual(h.editor.document.shapes, [line])
    },
    test("Polylines: drawn as a skeleton, zoomed out, a line is a view point wide, in its own indigo") {
        // The camera is Geometry's, which these tests don't import, so the level moves instead:
        // skeletons at 100%, where the render's 3 units are 3 points.
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
        let size = CGSize(width: 600, height: 300), scale: CGFloat = 4
        let blank = renderBitmap(h.editor, size: size, scale: scale)
        h.add(Polyline(points: [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), CGPoint(x: 500, y: 200)]))
        let full = renderBitmap(h.editor, size: size, scale: scale)
        h.editor.skeletonZoom = 1.01
        let skeleton = renderBitmap(h.editor, size: size, scale: scale)
        let middle = CGPoint(x: 200, y: 200), aside = CGPoint(x: 200, y: 201)
        expectEqual(pixel(skeleton, at: middle, scale: scale), pixel(full, at: middle, scale: scale), "its own indigo, not the core's gray")
        expectEqual(pixel(skeleton, at: aside, scale: scale), pixel(blank, at: aside, scale: scale), "a point wide: nothing a point from its middle")
        expectEqual(pixel(full, at: aside, scale: scale), pixel(full, at: middle, scale: scale), "where the render's 3 points are")
    },
    test("Eraser: a quick stroke erases what it crosses between two events, even a thin arrow") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), RectanglesPlugin(), EraserPlugin()])
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
    test("RectangleTitles: a bridge of one line lets rectangles be named, as notes are, though Rectangles and Titles don't know each other") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), RectanglesPlugin(), AdornmentsPlugin(), TitlesPlugin(), TableOfContentsPlugin(),
                                            DetailPanelPlugin(), RectangleTitlesPlugin()])
        let registry = h.editor.registry
        expectEqual(registry.properties(for: Rectangle.kind), [TitleProperty.key])
        expectEqual(registry.schema(for: Rectangle.kind)?.json["properties"]?["title"]?["maxLength"], 80)
        expect(!registry.titleIsDerived(Rectangle.kind), "named only")
        let empty = renderBitmap(h.editor, size: CGSize(width: 300, height: 240))
        let rectangle = h.add(Rectangle(frame: CGRect(x: 40, y: 60, width: 200, height: 140)))
        expectEqual(h.editor.document[rectangle].flatMap(registry.title(of:)), nil, "unnamed: no title")
        expectEqual(h.editor.tableOfContents?.entries.first?.label?.text, "Rectangle", "its tool's label")
        let unnamed = renderBitmap(h.editor, size: CGSize(width: 300, height: 240))
        h.editor.transact { $0.update(rectangle) { $0[TitleProperty.self] = "Server room" } }
        expectEqual(h.editor.document[rectangle].flatMap(registry.title(of:)), "Server room")
        expectEqual(h.editor.tableOfContents?.entries.first?.label?.text, "Server room")
        let named = renderBitmap(h.editor, size: CGSize(width: 300, height: 240))
        let pill = CGRect(x: 40, y: 35, width: 100, height: 12)
        expectEqual(changedPixels(empty, unnamed, in: pill), 0, "no pill without a name")
        expect(changedPixels(unnamed, named, in: pill) > 300, "the pill")
    },
    test("RectangleTitles: needs both plugins it connects, and the table of contents") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: "rectangle-titles")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), DetailPanelPlugin(), RectanglesPlugin(), TableOfContentsPlugin(), RectangleTitlesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: "rectangle-titles")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), RectanglesPlugin(), AdornmentsPlugin(), TitlesPlugin(), TableOfContentsPlugin(),
                                       RectangleTitlesPlugin()])
        }
        expectThrows(RegistryError.unknownKind("rectangle", point: "PropertyOptIns", contributor: "rectangle-titles")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), DetailPanelPlugin(), AdornmentsPlugin(), TitlesPlugin(), TableOfContentsPlugin(),
                                       RectangleTitlesPlugin()])
        }
    },
    test("the examples' report: who contributes what") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), RectanglesPlugin(), EraserPlugin(), PolylinesPlugin(),
                                              AdornmentsPlugin(), TitlesPlugin(), TableOfContentsPlugin(), DetailPanelPlugin(), RectangleTitlesPlugin()])
        expectEqual(registry.report, """
        core               tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        keyboard           service KeyboardState · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit
        selection          service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · command openSelection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge
        rectangles         shape rectangle · tool rectangle · shortcut R → tool rectangle
        eraser             tool eraser · shortcut E → tool eraser
        polylines          shape polyline · tool polyline · shortcut L → tool polyline
        adornments         service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        titles             property title · adornment TitlePill → every shape
        table-of-contents  service ContentsState
        detail-panel       service DetailPanelState
        rectangle-titles   property title → rectangle · ShapeTitles → rectangle · ContentsTitles → rectangle · ShapeDetails → rectangle
        """)
    },
    test("Reordering: every kind but those painted by anchor gets Arrange; to front and to back keep the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), RectanglesPlugin(),
                                            PolylinesPlugin(), ReorderingPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Rectangle(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Rectangle(frame: CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [c, a]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        expectEqual(menu.outline, ["Arrange ▸", "  Bring to Front", "  Bring Forward", "  Send Backward", "  Send to Back", "—", "Delete"])
        try menu.choose("Arrange", "Send to Back")
        expectEqual(h.editor.document.shapes.map(\.id), [a, c, b])
        try require(h.secondaryClick()).choose("Arrange", "Bring to Front")
        expectEqual(h.editor.document.shapes.map(\.id), [b, a, c])
        // A line has no frame, and gets it too; an arrow, drawn just above what it joins, doesn't.
        let line = h.add(Polyline(points: [CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)]))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 301))).outline.first, "Arrange ▸")
        expectEqual(h.editor.selectedShapeIDs, [line])
        h.add(Arrow(start: .free(CGPoint(x: 0, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 500))).outline, ["Delete"], "no Arrange for an arrow")
    },
    test("Reordering: Bring Forward and Send Backward step past the next shape each overlaps, keeping the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), RectanglesPlugin(), ReorderingPlugin()])
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
    test("Reordering: each Arrange item is one step, and undoing it puts back the order and every stacking key") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), RectanglesPlugin(), ReorderingPlugin()])
        let a = h.add(Rectangle(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Rectangle(frame: CGRect(x: 50, y: 0, width: 100, height: 100)))
        h.add(Rectangle(frame: CGRect(x: 60, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [b, a]
        var documents = [h.editor.document]
        for title in ["Bring to Front", "Send Backward", "Send to Back", "Bring Forward"] {
            try require(h.secondaryClick(at: CGPoint(x: 10, y: 50))).choose("Arrange", title)
            expectEqual(h.editor.undoHistory.undoName, title)
            documents.append(h.editor.document)
        }
        for expected in documents.dropLast().reversed() {
            h.editor.undo()
            expectEqual(h.editor.document, expected)
            expectEqual(h.editor.document.shapes.map(\.stackingKey), expected.shapes.map(\.stackingKey))
        }
        for expected in documents.dropFirst() {
            h.editor.redo()
            expectEqual(h.editor.document, expected)
        }
    },
])
