import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Mentions
import Selection
import TableOfContents
import TestKit
import TextEditing

// An arrow's label (tldraw's): text set on its body, which gives way to it; placed by tldraw's
// rules, edited in place, and dragged along the arrow.

/// A free arrow from (100, 200) to (500, 200), its head at its end.
@MainActor private func labelHarness(_ text: MentionText, at position: CGFloat = 0.5, bend: CGFloat = 0) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: arrowsPlugins())
    let id = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), bend: bend,
                         text: text, labelPosition: position))
    return (h, id)
}

@MainActor private func arrow(_ h: EditorHarness, _ id: ShapeID) throws -> Arrow {
    try require(h.editor.document[id]?.typed(as: Arrow.self)?.props)
}

/// The label editor's text view, while the arrow is edited.
@MainActor private func labelTextView(_ view: EditingView) throws -> EditingTextView {
    try require(view.firstResponder as? EditingTextView)
}

@MainActor private func isInked(_ color: [Int]) -> Bool { color.prefix(3).allSatisfy { $0 < 100 } }

private let straight = ArrowBody(start: .zero, end: CGPoint(x: 400, y: 0), arc: nil)
private let size = CGSize(width: 40, height: 26)

@MainActor let labelLayoutTests = Suite("Arrow labels: where they go", [
    test("centered on the body at its position, as a fraction of its length") {
        for position: CGFloat in [0.5, 0.25, 0.8] {
            let frame = ArrowLabelLayout.frame(size: size, at: position, on: straight, clearance: 23, clearsStart: true, clearsEnd: true)
            expectEqual(frame.center, CGPoint(x: 400 * position, y: 0), "at \(position)")
            expectEqual(frame.size, size)
        }
    },
    test("kept clear of an end with a head or a binding, as far as it reaches past the clearance; a free end without one, not") {
        // Centered 23 along, a 40-wide label crosses the body 43 along: as near the end as it may come.
        let atStart = ArrowLabelLayout.frame(size: size, at: 0, on: straight, clearance: 23, clearsStart: true, clearsEnd: true)
        expectClose(atStart.midX, 43, within: 1e-9)
        let atEnd = ArrowLabelLayout.frame(size: size, at: 1, on: straight, clearance: 23, clearsStart: true, clearsEnd: true)
        expectClose(atEnd.midX, 357, within: 1e-9)
        let free = ArrowLabelLayout.frame(size: size, at: 0, on: straight, clearance: 23, clearsStart: false, clearsEnd: true)
        expectClose(free.midX, 0, within: 1e-9)
    },
    test("on a body too short for it, halfway, wherever it's asked for") {
        let short = ArrowBody(start: .zero, end: CGPoint(x: 60, y: 0), arc: nil)
        let frame = ArrowLabelLayout.frame(size: CGSize(width: 80, height: 20), at: 0, on: short, clearance: 23, clearsStart: true, clearsEnd: true)
        expectClose(frame.midX, 30, within: 1e-9)
    },
    test("on an arc, that far along the arc") {
        let arc = try require(Arc(from: .zero, through: CGPoint(x: 200, y: -80), to: CGPoint(x: 400, y: 0)))
        let body = ArrowBody(start: .zero, end: CGPoint(x: 400, y: 0), arc: arc)
        let frame = ArrowLabelLayout.frame(size: size, at: 0.3, on: body, clearance: 23, clearsStart: true, clearsEnd: true)
        expect(frame.center.distance(to: arc.point(at: 0.3)) < 1e-9)
        let off = arc.point(at: 0.3) + (arc.point(at: 0.3) - arc.center).normalized * 5
        expectClose(body.fraction(nearest: off), 0.3, within: 1e-9, "the nearest point's fraction, off the arc")
        expectClose(straight.fraction(nearest: CGPoint(x: 100, y: 30)), 0.25, within: 1e-9)
        expectEqual(straight.fraction(nearest: CGPoint(x: -50, y: 0)), 0, "past its start, its start")
    },
    test("a label on a body wider than it's tall is squeezed to the body's width less 64, and wraps; on a tall one, to 16 ems") {
        let long: MentionText = "reads from the cache when it misses and the token is still fresh, then writes back"
        let (h, wide) = try labelHarness(long)
        let frame = try require(h.editor.arrowLabelFrame(of: wide))
        expect(frame.width <= 400 - 64 + 8.5, "\(frame)")
        expect(frame.height > 2 * 18, "wraps: \(frame)")
        let tall = h.add(Arrow(start: .free(CGPoint(x: 800, y: 100)), end: .free(CGPoint(x: 800, y: 900)), text: long))
        let tallFrame = try require(h.editor.arrowLabelFrame(of: tall))
        expect(tallFrame.width <= 16 * 15 + 8.5, "\(tallFrame)")
        expect(tallFrame.height > 2 * 18, "wraps: \(tallFrame)")
        let short = h.add(Arrow(start: .free(CGPoint(x: 100, y: 600)), end: .free(CGPoint(x: 500, y: 600)), text: "scall"))
        let shortFrame = try require(h.editor.arrowLabelFrame(of: short))
        expect(shortFrame.width < 60 && shortFrame.height < 30, "one short line, as wide as it is: \(shortFrame)")
        expectClose(shortFrame.center.x, 300, within: 0.5, "halfway, its frame on whole points")
        expectClose(shortFrame.center.y, 600, within: 0.5)
        expectEqual(shortFrame.origin, CGPoint(x: shortFrame.minX.rounded(), y: shortFrame.minY.rounded()))
    },
    test("no text is no label, nor is text that's all spaces and line breaks; its bounds are its body's") {
        for text: MentionText in ["", "  \n "] {
            let (h, id) = try labelHarness(text)
            expectEqual(h.editor.arrowLabelFrame(of: id), nil, "\(text.stored.debugDescription)")
            let bounds = try require(h.editor.shapeContext.geometry(of: id)).bounds
            expect(bounds.height < 20, "\(text.stored.debugDescription): \(bounds)")
        }
    },
])

@MainActor let labelHitTests = Suite("Arrow labels: hit and brushed", [
    test("its bounds hold its label, and a press anywhere on the label is on the arrow") {
        let (h, id) = try labelHarness("two\nlines")
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        let bounds = try require(h.editor.shapeContext.geometry(of: id)).bounds
        expect(bounds.contains(frame), "\(bounds) holds \(frame)")
        let offBody = CGPoint(x: frame.midX, y: frame.minY + 2)
        expectEqual(h.editor.shape(at: offBody), id)
        expectEqual(h.editor.shape(at: CGPoint(x: frame.midX, y: frame.minY - 20)), nil, "above it, nothing")
    },
    test("a marquee that reaches only its label selects it") {
        let (h, id) = try labelHarness("two\nlines")
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        h.press(at: h.view(CGPoint(x: frame.midX - 4, y: frame.minY - 30)))
        h.drag(to: h.view(CGPoint(x: frame.midX + 4, y: frame.minY + 3)))
        expectEqual(h.editor.selectedShapeIDs, [id])
        h.release()
    },
])

@MainActor let labelEditingTests = Suite("Arrow labels: editing", [
    test("a double-click on the arrow's body edits its label, all its text selected") {
        let (h, id) = try labelHarness("scall")
        h.click(at: h.view(CGPoint(x: 150, y: 200)))
        h.click(at: h.view(CGPoint(x: 150, y: 200)), clickCount: 2)
        expectEqual(h.editor.editingShapeID, id)
        let view = try require(h.editor.makeEditingView())
        expectEqual(try labelTextView(view).selectedRange(), NSRange(location: 0, length: 5))
        expectEqual(h.editor.editingFrame, h.editor.arrowLabelFrame(of: id), "laid over the label")
    },
    test("Return with the arrow selected edits its label") {
        let (h, id) = try labelHarness("scall")
        h.editor.selection = id
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, id)
    },
    test("Tab and ⇧Tab in a label end editing, change nothing in its text, type no tab, and leave the arrow selected") {
        for back in [false, true] {
            let (h, id) = try labelHarness("scall")
            h.editor.selection = id
            expect(h.key("\r"))
            let view = try require(h.editor.makeEditingView())
            let textView = try labelTextView(view)
            expect(textView.tabBehavior == .host)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(view.view)
            window.makeFirstResponder(textView)
            _ = KeyDriver(window).send(back ? .backTab : .tab)
            expectEqual(h.editor.editingShapeID, nil, "editing ended")
            expectEqual(h.editor.selectedShapeIDs, [id], "the arrow stays selected")
            expectEqual(textView.string, "scall", "no tab typed")
            expectEqual(try arrow(h, id).text, "scall")
        }
    },
    test("the label's editor checks the spelling of what's typed as the app does (Edit › Spelling and Grammar)") {
        let (h, id) = try labelHarness("scall")
        h.editor.selection = id
        expect(h.key("\r"))
        let textView = try labelTextView(try require(h.editor.makeEditingView()))
        expect(textView.spelling === Spelling.app)
        expectEqual(textView.isContinuousSpellCheckingEnabled, Spelling.app.checksWhileTyping)
    },
    test("a click on the label of the only selected arrow edits it; on its body, it's only selected") {
        let (h, id) = try labelHarness("scall", at: 0.3)
        h.editor.selection = id
        h.click(at: h.view(CGPoint(x: 150, y: 200)))
        expectEqual(h.editor.editingShapeID, nil, "the body")
        expectEqual(h.editor.selectedShapeIDs, [id])
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        h.wait(500)
        h.click(at: h.view(frame.center))
        expectEqual(h.editor.editingShapeID, id, "the label")
        expectEqual(h.editor.editingStartPoint, frame.center, "from where it's clicked")
    },
    test("halfway, the bend handle is on the label and takes a click, as tldraw's does; a double-click on it edits the label") {
        let (h, id) = try labelHarness("scall")
        h.editor.selection = id
        let middle = h.view(try require(h.editor.arrowGeometry(of: id)).middle)
        h.click(at: middle)
        expectEqual(h.editor.editingShapeID, nil)
        h.wait(500)
        h.click(at: middle)
        h.click(at: middle, clickCount: 2)
        expectEqual(h.editor.editingShapeID, id)
        expectEqual(try arrow(h, id).bend, 0, "nothing bent")
    },
    test("an empty label shows halfway, as wide as an i, and edited without typing changes nothing") {
        let (h, id) = try labelHarness("", at: 0.3)
        let before = h.editor.undoHistory.undoName
        h.editor.selection = id
        expect(h.editor.beginEditing(id))
        _ = try require(h.editor.makeEditingView())
        let empty = try require(h.editor.editingFrame)
        expectClose(empty.center.x, 300, within: 0.5, "halfway")
        h.editor.endEditing()
        expectEqual(try arrow(h, id).labelPosition, 0.3, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, before, "no step")
    },
    test("an empty label's first text puts it halfway, in the editing's step, and grows it; undo takes it all back") {
        let (h, id) = try labelHarness("", at: 0.3)
        expectEqual(h.editor.editingFrame, nil)
        h.editor.selection = id
        expect(h.editor.beginEditing(id))
        let view = try require(h.editor.makeEditingView())
        let empty = try require(h.editor.editingFrame)
        expectClose(empty.center.x, 300, within: 0.5)
        expect(empty.width < 16, "an i wide: \(empty)")
        try labelTextView(view).insertText("depends on", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(try arrow(h, id).text, "depends on")
        expectEqual(try arrow(h, id).labelPosition, 0.5, "halfway")
        let typed = try require(h.editor.editingFrame)
        expect(typed.width > 60, "grown with it: \(typed)")
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.undo()
        expectEqual(try arrow(h, id).text, "")
        expectEqual(try arrow(h, id).labelPosition, 0.3)
    },
    test("while it's edited, the arrow shows no handles: the editing view is over them") {
        let (h, id) = try labelHarness("scall")
        h.editor.selection = id
        let middle = h.view(try require(h.editor.arrowGeometry(of: id)).middle)
        expect(h.editor.handle(atViewPoint: middle) != nil)
        expect(h.editor.beginEditing(id))
        expectEqual(h.editor.handle(atViewPoint: middle), nil)
    },
    test("its editing view's text falls where the canvas draws it, at 1× and 2×") {
        for scale: CGFloat in [1, 2] {
            let (h, id) = try labelHarness("scall the\nservice", at: 0.3)
            let frame = try require(h.editor.arrowLabelFrame(of: id))
            let canvas = CGSize(width: 600, height: 400)
            let drawn = renderBitmap(h.editor, size: canvas, scale: scale)
            expect(h.editor.beginEditing(id))
            let view = try require(h.editor.makeEditingView())
            try labelTextView(view).setSelectedRange(NSRange(location: 0, length: 0))
            let edited = renderBitmap(h.editor, size: canvas, scale: scale, editing: view)
            let difference = largestDifference(drawn, edited, in: frame.insetBy(dx: 1, dy: 1), scale: scale)
            expect(difference <= 16, "at \(scale)×: \(difference)")
        }
    },
])

@MainActor let labelDragTests = Suite("Arrow labels: dragged", [
    test("a drag from an unselected arrow's label slides the label along it, the arrow staying put, selected alone; one step") {
        let (h, id) = try labelHarness("scall")
        let other = h.add(Box(CGRect(x: 100, y: 400, width: 100, height: 100)))
        h.editor.selection = other
        let before = try arrow(h, id)
        h.press(at: h.view(CGPoint(x: 300, y: 200)))
        h.drag(to: h.view(CGPoint(x: 360, y: 230)))
        h.drag(to: h.view(CGPoint(x: 400, y: 240)))
        h.release()
        let after = try arrow(h, id)
        expectClose(after.labelPosition, 0.75, within: 1e-9, "the point of the arrow nearest the pointer")
        expectEqual(after.start, before.start)
        expectEqual(after.end, before.end)
        expectEqual(h.editor.selectedShapeIDs, [id])
        expectEqual(h.editor.undoHistory.undoName, "Move Label")
        h.editor.undo()
        expectEqual(try arrow(h, id).labelPosition, 0.5)
    },
    test("it keeps where it was grabbed, snaps to halfway within 10 view points of it, and Escape puts it back") {
        let (h, id) = try labelHarness("scall", at: 0.25)
        h.press(at: h.view(CGPoint(x: 205, y: 200)))
        h.drag(to: h.view(CGPoint(x: 260, y: 200)))
        expectClose(try arrow(h, id).labelPosition, 0.3875, within: 1e-9, "its center 5 left of the pointer, as grabbed")
        h.drag(to: h.view(CGPoint(x: 297, y: 200)))
        expectEqual(try arrow(h, id).labelPosition, 0.5, "within 10 of halfway, halfway")
        h.escape()
        expectEqual(try arrow(h, id).labelPosition, 0.25)
        h.release()
    },
    test("a locked arrow's label doesn't move: the drag is the selection's, refused") {
        let h = try EditorHarness(plugins: arrowsPlugins(more: [FreezingPlugin()]))
        var record = ShapeRecord(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), text: "scall"))
        record[Frozen.self] = true
        h.editor.transact { $0.insert(record) }
        h.press(at: h.view(CGPoint(x: 300, y: 200)))
        h.drag(to: h.view(CGPoint(x: 400, y: 260)))
        h.release()
        expectEqual(try arrow(h, record.id).labelPosition, 0.5)
        expectEqual(try arrow(h, record.id).start, .free(CGPoint(x: 100, y: 200)))
    },
    test("⌘ pressed on a label brushes, as on the arrow: nothing moves") {
        let (h, id) = try labelHarness("scall")
        h.hold(.command)
        h.press(at: h.view(CGPoint(x: 300, y: 200)))
        h.drag(to: h.view(CGPoint(x: 360, y: 240)))
        expect(h.editor.session != nil && !(h.editor.session is TranslatingSession), "a marquee")
        h.release()
        h.hold([])
        expectEqual(try arrow(h, id).labelPosition, 0.5)
        expectEqual(try arrow(h, id).start, .free(CGPoint(x: 100, y: 200)))
    },
    test("a drag from its body still moves the arrow") {
        let (h, id) = try labelHarness("scall")
        h.press(at: h.view(CGPoint(x: 150, y: 200)))
        h.drag(to: h.view(CGPoint(x: 150, y: 260)))
        h.release()
        expectEqual(try arrow(h, id).start, .free(CGPoint(x: 100, y: 260)))
        expectEqual(try arrow(h, id).labelPosition, 0.5)
    },
])

@MainActor let labelRowTests = Suite("Arrow labels: rows", [
    test("an arrow's row is its label's first line that says something, else Arrow, dimmed") {
        let (h, id) = try labelHarness("\n  scall  \nthe service")
        @MainActor func row() -> ContentsLabel? { h.editor.tableOfContents?.entries.first { $0.id == id }?.label }
        expectEqual(row()?.text, "scall")
        expectEqual(row()?.isPlaceholder, false)
        h.editor.transact { $0.update(id, as: Arrow.self) { $0.props.text = " " } }
        expectEqual(row()?.text, "Arrow")
        expectEqual(row()?.isPlaceholder, true)
    },
])

@MainActor let labelDrawingTests = Suite("Arrow labels: drawn", [
    test("the body is cut where the label is, and its text drawn there; zoomed out, it runs whole and the label is left off") {
        let (h, id) = try labelHarness("scall")
        let frame = try require(h.editor.arrowLabelFrame(of: id))
        let drawn = renderBitmap(h.editor, size: CGSize(width: 600, height: 400), scale: 2)
        expect(isInked(pixel(drawn, at: CGPoint(x: frame.minX - 6, y: 200), scale: 2)), "the body, before the label")
        expect(!isInked(pixel(drawn, at: CGPoint(x: frame.minX + 1, y: 200), scale: 2)), "cut at the label's edge")
        expect(inkedPixels(drawn, in: frame.insetBy(dx: 4.25, dy: 4.25), scale: 2) > 20, "its text")

        // A cut that far out reads as a gap in the arrow, so there the body is whole, and the
        // label no more than a label-less arrow's: nothing of it drawn.
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let farSize = CGSize(width: 180, height: 120)
        let far = renderBitmap(h.editor, size: farSize, scale: 4)
        @MainActor func at(_ world: CGPoint) -> [Int] { pixel(far, at: CGPoint(x: world.x * 0.3, y: world.y * 0.3), scale: 4) }
        for x: CGFloat in [frame.minX - 10, frame.minX + 2, frame.midX, frame.maxX - 2, frame.maxX + 10] {
            expect(isInked(at(CGPoint(x: x, y: 200))), "the body, whole at \(x)")
        }
        let (bare, _) = try labelHarness("")
        bare.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(largestDifference(far, renderBitmap(bare.editor, size: farSize, scale: 4), in: CGRect(origin: .zero, size: farSize), scale: 4), 0,
                    "no different from the arrow without a label")
    },
])

@MainActor private func expectClose(_ value: CGFloat, _ expected: CGFloat, within tolerance: CGFloat, _ message: String = "",
                                    file: StaticString = #fileID, line: UInt = #line) {
    expect(abs(value - expected) <= tolerance, "\(value) is not \(expected) \(message)", file: file, line: line)
}

/// How many pixels in a rect of view points are inked (dark), at `scale` pixels a point.
@MainActor private func inkedPixels(_ rep: NSBitmapImageRep, in rect: CGRect, scale: CGFloat) -> Int {
    var count = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1 / scale) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1 / scale) where isInked(pixel(rep, at: CGPoint(x: x, y: y), scale: scale)) {
            count += 1
        }
    }
    return count
}
