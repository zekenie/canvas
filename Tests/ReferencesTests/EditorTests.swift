import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import References
import TestKit
import TextEditing

// What a pill is as it's typed into: as wide as what it says with each keystroke (a dynamic one
// keeping room for its count), clamped, growing rightward; and its editing view's text falling where
// the render draws the label, so nothing moves when editing starts. The render, while it's edited,
// draws the capsule and the symbol and leaves the label to the view.

@MainActor private func width(_ h: EditorHarness, _ id: ShapeID) -> CGFloat { h.editor.document[id]?.box?.width ?? 0 }

@MainActor let editorTests = Suite("The pill's field", [
    test("the width follows each keystroke, from the pill's left edge: a dynamic pill reserves room for its count, so it's the fit of its text and 36 more") {
        let h = try referenceHarness()
        let field = try h.placeReference(at: CGPoint(x: 300, y: 300))
        defer { field.close() }
        let left = try require(h.editor.document[field.id]?.box).minX
        var widths: [CGFloat] = []
        for character in "payment notes about launch" {
            field.type(String(character))
            widths.append(width(h, field.id))
            expectEqual(try require(h.editor.document[field.id]?.box).minX, left, "it grows rightward")
        }
        expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 }, "never narrower as it's typed: \(widths)")
        expect(widths.last! > widths.first! + 60, "and it grows: \(widths)")
        var words = Reference()
        words.words = "payment notes about launch"
        var direct = Reference()
        direct.target = ReferenceTarget(id: ShapeID(), label: "payment notes about launch")
        expectEqual(ReferenceEdits.width(of: words), ReferenceEdits.width(of: direct) + 36 - 17, "the reserved count, where a direct pill keeps its glyph's")
        expectEqual(widths.last, ReferenceEdits.width(of: words))
        expectEqual(try require(h.editor.document[field.id]?.box).height, 32)
    },

    test("never under 64 or over 280: no name is 64, 200 characters is 280, and the text past it scrolls with the caret") {
        let h = try referenceHarness()
        let tiny = h.addBox("a")
        let pill = h.addReference(to: tiny, label: "")
        expectEqual(width(h, pill), 64)
        let field = try h.placeReference(at: CGPoint(x: 300, y: 500))
        defer { field.close() }
        field.textView.insertText(String(repeating: "wide ", count: 40), replacementRange: NSRange(location: 0, length: 0))
        field.layout()
        expectEqual((field.textView.string as NSString).length, 200)
        expectEqual(width(h, field.id), 280)
        let editor = field.editing.view
        field.textView.setSelectedRange(NSRange(location: 200, length: 0))
        field.layout()
        let caret = try require(field.textView.caretFrame)
        let scrolled = field.textView.frame.minX
        expect(scrolled < 0, "scrolled to the caret: \(scrolled)")
        // The caret, in the pill's coordinates, is inside the label's room (the pill, less the trailing pad and the count's room).
        let inPill = editor.convert(caret, from: field.textView)
        expect(inPill.maxX <= 280 - 14 - 36 + 0.5, "caret at \(inPill.maxX)")
        field.textView.setSelectedRange(NSRange(location: 0, length: 0))
        field.layout()
        expectEqual(field.textView.frame.minX, 0, "back to the start, the text is too")
    },

    test("a pick fits the width to the shape's name alone: no room for a count") {
        let h = try referenceHarness()
        h.addBox("Pricing and plans")
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pri")
        let typed = width(h, field.id)
        field.returnKey()
        let picked = width(h, field.id)
        var direct = Reference()
        direct.target = ReferenceTarget(id: ShapeID(), label: "Pricing and plans")
        expectEqual(picked, ReferenceEdits.width(of: direct))
        expect(picked > typed, "its name is longer than what was typed: \(typed) then \(picked)")
    },

    test("while it's edited the pill draws its capsule and its symbol, and leaves the label to the view") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        let frame = try require(h.editor.document[id]?.box)
        let plain = render(h.editor)
        expect(h.editor.beginEditing(id))
        let editing = render(h.editor)
        let symbol = CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
        expectEqual(changedPixels(plain, editing, in: symbol), 0, "the symbol is as it was")
        let label = CGRect(x: frame.minX + 32, y: frame.midY - 8, width: 20, height: 16)
        expect(changedPixels(plain, editing, in: label) > 0, "the label isn't drawn")
        expectEqual(changedPixels(plain, editing, in: CGRect(x: frame.minX, y: frame.minY - 2, width: frame.width, height: 4)), 0, "the border is")
    },

    test("once only the words row is left, the pill leads with the magnifier as it's edited, and the text starts where a symbol leaves it; while shapes match, there's no symbol") {
        let h = try referenceHarness()
        h.addBox("Plan B")
        let field = try h.placeReference(at: CGPoint(x: 300, y: 300))
        defer { field.close() }
        let frame = try require(h.editor.document[field.id]?.box)
        let symbol = CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
        let blank = render(h.editor)
        field.type("pla")
        let matching = render(h.editor)
        expectEqual(changedPixels(blank, matching, in: symbol), 0, "shapes match: nothing leads")
        expectEqual(field.textView.textContainerInset.width, 10)
        field.type("zz")
        expectEqual(field.titles, ["plazz"])
        let handedOff = render(h.editor)
        expect(changedPixels(blank, handedOff, in: symbol) > 40, "the magnifier")
        expectEqual(field.textView.textContainerInset.width, 10 + 16 + 6)
        field.textView.deleteBackward(nil)
        field.textView.deleteBackward(nil)
        expectEqual(h.editor.references?.isHandingOff(field.id), false, "shapes match again")
        expectEqual(changedPixels(blank, render(h.editor), in: symbol), 0)
        expectEqual(field.textView.textContainerInset.width, 10)
    },

    test("the editor's text falls where the render's label does, pixel for pixel but anti-aliasing, at 1× and 2× device pixels, zoomed 100% and 200%") {
        var worst = 0
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 2)] as [(CGFloat, CGFloat)] {
            let h = try referenceHarness()
            h.editor.camera.setZoom(zoom, around: .zero)
            let box = h.addBox("Pricing and plans")
            let id = h.addReference(to: box, label: "Pricing and plans", at: CGPoint(x: 40, y: 30))
            let size = CGSize(width: 330 * zoom, height: 110 * zoom)
            let inView = h.editor.camera.toView(try require(h.editor.document[id]?.box))
            let drawn = renderBitmap(h.editor, size: size, scale: scale)
            expect(h.editor.beginEditing(id))
            let view = try require(h.editor.makeEditingView())
            try require(view.firstResponder as? NSTextView).setSelectedRange(NSRange(location: 0, length: 0))
            let edited = renderBitmap(h.editor, size: size, scale: scale, editing: view)
            let difference = largestDifference(drawn, edited, in: inView.insetBy(dx: 1, dy: 1), scale: scale)
            worst = max(worst, difference)
            expect(difference <= 1, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
        }
        expect(worst <= 1, "\(worst)")
    },

    test("on a pill at a fraction of a point, where TextKit 2 sets text on the nearest device pixel and string drawing between, the editor's line starts on the render's") {
        for (scale, zoom, origin) in [(2, 1, CGPoint(x: 40.4, y: 30.3)), (1, 2, CGPoint(x: 40.5, y: 30.5)), (2, 2, CGPoint(x: 40.3, y: 30.7))] as [(CGFloat, CGFloat, CGPoint)] {
            let h = try referenceHarness()
            h.editor.camera.setZoom(zoom, around: .zero)
            let box = h.addBox("Pricing and plans")
            let id = h.addReference(to: box, label: "Pricing and plans", at: origin)
            let size = CGSize(width: 330 * zoom, height: 110 * zoom)
            let inView = h.editor.camera.toView(try require(h.editor.document[id]?.box))
            let text = CGRect(x: inView.minX + 32 * zoom, y: inView.minY + 4 * zoom, width: inView.width - 50 * zoom, height: inView.height - 8 * zoom)
            let drawn = renderBitmap(h.editor, size: size, scale: scale)
            expect(h.editor.beginEditing(id))
            let fill = renderBitmap(h.editor, size: size, scale: scale)
            let view = try require(h.editor.makeEditingView())
            try require(view.firstResponder as? NSTextView).setSelectedRange(NSRange(location: 0, length: 0))
            let edited = renderBitmap(h.editor, size: size, scale: scale, editing: view)
            let tops = lineTops(drawn, over: fill, in: text, scale: scale)
            expectEqual(tops.count, 1, "at \(scale)×, zoom \(zoom): the render's line")
            let there = lineTops(edited, over: fill, in: text, scale: scale)
            expect(there.count == 1 && abs(there[0] - tops[0]) <= 1 / scale + 1e-9, "at \(scale)×, zoom \(zoom): \(there) for \(tops)")
        }
    },
])
