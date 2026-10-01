import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Eraser
import Keyboard
import Reordering
import Selection
import TableOfContents
import TestKit

/// The examples' tests: each works on CanvasTesting's boxes, so none depends on a shipped kind.
@MainActor let examplesTests = Suite("Examples", [
    test("Eraser: dragging across shapes deletes them, and an arrow lets go of what was erased") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), FixturesPlugin(), EraserPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
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
        expect(start.binding == nil, "the arrow let go of the erased box")
        expectEqual(h.editor.currentToolID, .eraser)
    },
    test("Eraser: a stroke is one step, however many shapes it takes as it goes; undoing it puts them back where they were, and the arrow bound again") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), FixturesPlugin(), EraserPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
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
    test("Eraser: a quick stroke erases what it crosses between two events, even a thin arrow") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), FixturesPlugin(), EraserPlugin()])
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 300, y: 300))))
        let thin = h.add(Box(CGRect(x: 391, y: 0, width: 4, height: 100)))
        expect(h.key("e"))
        h.press(at: CGPoint(x: 200, y: 250))
        h.drag(to: CGPoint(x: 200, y: 350), speed: 1)       // events land 14 pt apart, either side of the arrow
        h.release()
        expectEqual(h.editor.document[arrow], nil)
        h.press(at: CGPoint(x: 300, y: 50))
        h.drag(to: CGPoint(x: 500, y: 50), speed: 3)       // 48 pt apart, jumping the 4 pt box
        h.release()
        expectEqual(h.editor.document[thin], nil)
    },
    test("the examples' report: who contributes what") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), EraserPlugin()])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        keyboard      service KeyboardState · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit
        selection     service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · command openSelection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge
        eraser        tool eraser · shortcut E → tool eraser
        """)
    },
    test("Reordering: every kind but those painted by anchor gets Arrange; to front and to back keep the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ArrowsPlugin(), TableOfContentsPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [c, a]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        expectEqual(menu.outline, ["Arrange ▸", "  Bring to Front", "  Bring Forward", "  Send Backward", "  Send to Back", "—", "Delete"])
        try menu.choose("Arrange", "Send to Back")
        expectEqual(h.editor.document.shapes.map(\.id), [a, c, b])
        try require(h.secondaryClick()).choose("Arrange", "Bring to Front")
        expectEqual(h.editor.document.shapes.map(\.id), [b, a, c])
        // An arrow, drawn just above what it joins, doesn't.
        h.add(Arrow(start: .free(CGPoint(x: 0, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 500))).outline, ["Delete"], "no Arrange for an arrow")
    },
    test("Reordering: Bring Forward and Send Backward step past the next shape each overlaps, keeping the selection's order") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))      // overlaps a
        let c = h.add(Box(CGRect(x: 500, y: 0, width: 100, height: 100)))     // overlaps nothing
        let d = h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))      // overlaps a and b
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
    test("Reordering: a container steps past the next shape it overlaps that it doesn't hold, what it holds going with it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), CorralsPlugin(), ReorderingPlugin()])
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 200)))
        let held = h.add(Box(CGRect(x: 20, y: 20, width: 100, height: 100)))
        h.editor.put([held], in: corral)
        let over = h.add(Box(CGRect(x: 250, y: 50, width: 100, height: 100)))       // overlaps the corral, above it
        @MainActor func order() -> [ShapeID] { h.editor.document.shapes.map(\.id) }
        expectEqual(order(), [corral, held, over])
        h.editor.selection = corral
        try require(h.secondaryClick(at: CGPoint(x: 290, y: 190))).choose("Arrange", "Bring Forward")
        expectEqual(order(), [over, corral, held], "past the box above it, not its own box, which goes with it")
        try require(h.secondaryClick(at: CGPoint(x: 290, y: 190))).choose("Arrange", "Send Backward")
        expectEqual(order(), [corral, held, over])
    },
    test("Reordering: each Arrange item is one step, and undoing it puts back the order and every stacking key") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), ReorderingPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))
        h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))
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
