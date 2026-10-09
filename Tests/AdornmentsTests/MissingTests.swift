import Adornments
import AppKit
import Canvas
import CanvasTesting
import TestKit

// A label that names what is gone (`missing()`): no fill, a dashed stroke, italic text, in the
// canvas's label colors, as a mention's pill says it. Pixels.

/// The same board with `label` and with `label.missing()` (the same place, whatever it looks like),
/// and with neither.
@MainActor func rendersMissing(_ label: AdornmentLabel) throws -> (plain: NSBitmapImageRep, filled: NSBitmapImageRep, missing: NSBitmapImageRep, frame: CGRect) {
    let (plain, filled, h) = try renders([everyShape(Caption.self) { _ in label }]) { $0.add(Box(boxFrame)) }
    let (_, missing, g) = try renders([everyShape(Caption.self) { _ in label.missing() }]) { $0.add(Box(boxFrame)) }
    let frame = try require(viewRects(h, h.editor.document.shapes[0].id).first)
    expectEqual(try require(viewRects(g, g.editor.document.shapes[0].id).first), frame, "the same place, whatever it looks like")
    return (plain, filled, missing, frame)
}

@MainActor let missingTests = Suite("A missing adornment", [
    test("a label says it's tagged and missing, and each makes it another label") {
        let label = AdornmentLabel("Person")
        expectEqual(label.tag, nil)
        expectEqual(label.isMissing, false)
        let tagged = label.tagged(AdornmentTag("a"))
        expectEqual(tagged.tag, AdornmentTag("a"))
        expect(tagged != label)
        expect(tagged.missing() != tagged)
        expectEqual(tagged.missing().isMissing, true)
        expectEqual(tagged.missing().tag, AdornmentTag("a"), "still the one it was")
        expectEqual(tagged.missing().opacity(0.5).isMissing, true)
        expectEqual(AdornmentTag(ShapeID()) != AdornmentTag(ShapeID()), true)
    },
    test("it has no fill: inside the capsule, away from the text, it's the canvas; a filled one's is dark") {
        let (plain, filled, missing, frame) = try rendersMissing(AdornmentLabel("Lobby"))
        let inside = CGPoint(x: frame.minX + 4, y: frame.midY)
        expectEqual(pixel(missing, at: inside), pixel(plain, at: inside))
        expect(pixel(filled, at: inside) != pixel(plain, at: inside), "a filled one is not")
        expect(pixel(filled, at: inside).prefix(3).allSatisfy { $0 < 100 }, "dark: \(pixel(filled, at: inside))")
    },
    test("its stroke is dashed: 2 points on, 2 off, along an edge; a filled one's edge is solid") {
        let (plain, filled, missing, frame) = try rendersMissing(AdornmentLabel("Lobby with a longer name"))
        let span = stride(from: frame.minX + 12, to: frame.maxX - 12, by: 1)
        @MainActor func share(_ drawn: NSBitmapImageRep) -> Double {
            let changed = span.filter { x in
                [frame.minY - 1, frame.minY].contains { y in pixel(drawn, at: CGPoint(x: x, y: y)) != pixel(plain, at: CGPoint(x: x, y: y)) }
            }.count
            return Double(changed) / Double(span.underestimatedCount)
        }
        expect(share(filled) > 0.95, "solid: \(share(filled))")
        let dashed = share(missing)
        expect(dashed > 0.3 && dashed < 0.8, "dashed: \(dashed)")
    },
    test("it draws far less than a filled one, and draws nowhere else; a symbol alone is a dashed ring") {
        let (plain, filled, missing, frame) = try rendersMissing(AdornmentLabel("Lobby"))
        let box = frame.insetBy(dx: -1, dy: -1).integral
        let ink = changedPixels(plain, missing, in: box)
        expect(ink > 40, "the stroke and the text: \(ink)")
        expect(ink < changedPixels(plain, filled, in: box) / 2, "less than a fill: \(ink)")
        expectEqual(changedPixels(plain, missing, in: wholeView) - ink, 0, "nowhere else")
        let (plain2, _, ring, disc) = try rendersMissing(AdornmentLabel(systemImage: "person.fill"))
        let ringBox = disc.insetBy(dx: -1, dy: -1).integral
        let ringInk = changedPixels(plain2, ring, in: ringBox)
        expect(ringInk > 20 && ringInk < 150, "a ring, not a disc: \(ringInk)")
        expectEqual(changedPixels(plain2, ring, in: wholeView) - ringInk, 0)
        expectEqual(pixel(ring, at: CGPoint(x: disc.midX, y: disc.midY)), pixel(plain2, at: CGPoint(x: disc.midX, y: disc.midY)), "its middle is the canvas, with no symbol")
    },
    test("a missing label is as wide as its text, with no symbol before it: the symbol is white") {
        let (_, _, g) = try renders([everyShape(Caption.self) { _ in AdornmentLabel("Lobby", systemImage: "person.fill").missing() }]) { $0.add(Box(boxFrame)) }
        let (_, _, h) = try renders([everyShape(Caption.self) { _ in AdornmentLabel("Lobby").missing() }]) { $0.add(Box(boxFrame)) }
        expectEqual(viewRects(g, g.editor.document.shapes[0].id).first?.width, viewRects(h, h.editor.document.shapes[0].id).first?.width)
    },
])
