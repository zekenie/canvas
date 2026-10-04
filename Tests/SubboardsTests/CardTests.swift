import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Selection
import Subboards
import TestKit
import Titles

// A card at `cardFrame` (40, 40, 240 × 160), the whole frame: while it shows no preview, its caption
// in its middle (112 to 128 down), or for an empty board the kind's symbol above "Empty", which is
// about 126 to 142 down.
enum Band {
    static let symbol = CGRect(x: 140, y: 94, width: 40, height: 18)
    static let caption = CGRect(x: 60, y: 110, width: 200, height: 36)
    /// Above the card, where a title's pill is (9 to 27 points up), clear of the card's shadow.
    static let pill = CGRect(x: 40, y: 4, width: 240, height: 26)
}

@MainActor let cardTests = Suite("The card", [
    test("a card the whole frame, in an indigo border: no header band, no plates below it") {
        let bitmap = try render(title: nil)
        for point in [CGPoint(x: 265, y: 46), CGPoint(x: 250, y: 100), CGPoint(x: 160, y: 190)] {
            expectColor(pixel(bitmap, at: point), cardFill, "the card at \(point)", within: 2)
        }
        for point in [CGPoint(x: 279, y: 120), CGPoint(x: 160, y: 199), CGPoint(x: 160, y: 40), CGPoint(x: 40, y: 120)] {
            let border = pixel(bitmap, at: point)
            expect(border[2] > border[0] + 60, "the border at \(point), in indigo: \(border)")
        }
    },
    test("its title is Titles' pill above it, the card unchanged; none while it has none, nor for a blank title") {
        let untitled = try render(title: nil), titled = try render(title: "Kitchen")
        expect(changedPixels(untitled, titled, in: Band.pill) > 150, "the pill")
        expectEqual(changedPixels(untitled, titled, in: cardFrame.insetBy(dx: 2, dy: 2)), 0, "the card draws no title")
        expectEqual(changedPixels(untitled, try render(title: "   "), in: Band.pill), 0, "a blank title is none")
    },
    test("while it shows no preview, what its board holds: how many shapes, or the kind's symbol over \"Empty\"") {
        let empty = try render(title: nil), three = try render(title: nil, inside: 3), one = try render(title: nil, inside: 1)
        for bitmap in [empty, three, one] { expect(darkest(bitmap, in: Band.caption) < 170, "a caption") }
        expect(hasIndigo(empty, in: Band.symbol), "the symbol, in indigo")
        expect(changedPixels(empty, three, in: Band.caption) > 50, "Empty, then 3 shapes")
        expect(changedPixels(one, three, in: Band.caption) > 5, "1 shape, then 3 shapes")
        expect(!hasIndigo(three, in: Band.symbol) && !hasIndigo(one, in: Band.symbol), "the symbol only for an empty board")
    },
    test("in the dark, a dark card in a lighter indigo, with the symbol and the caption light on it") {
        let dark = try render(title: nil, dark: true)
        let card = pixel(dark, at: CGPoint(x: 250, y: 100))
        expect(card.prefix(3).allSatisfy { $0 < 60 } && card[2] > card[0], "the card, dark and a little indigo: \(card)")
        let border = pixel(dark, at: CGPoint(x: 279, y: 120))
        expect(border[2] > border[0] + 60 && border[2] > 200, "the border, in indigo: \(border)")
        let brightest = (0..<Int(Band.caption.height)).flatMap { dy in (0..<Int(Band.caption.width)).map { dx in
            pixel(dark, at: CGPoint(x: Band.caption.minX + CGFloat(dx), y: Band.caption.minY + CGFloat(dy)))[0] } }.max() ?? 0
        expect(brightest > 140, "the caption, light: \(brightest)")
    },
    test("the count follows its board: a shape added inside shows on the card once it's back in view") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let size = CGSize(width: 320, height: 240)
        let before = renderBitmap(h.editor, size: size)
        expect(h.enter(nest.s))
        h.add(Box(CGRect(x: 0, y: -200, width: 50, height: 50)))
        h.editor.goToEnclosingBoard()
        expect(changedPixels(before, renderBitmap(h.editor, size: size), in: Band.caption) > 5, "3 shapes, then 4")
    },
    test("selected or hovered, the core's outline stands 4 points off its edge, a gap of the canvas between it and the indigo border, and never over the card") {
        let h = try EditorHarness(plugins: subboardPlugins())
        h.editor.outlineStandoff = Style.outlineStandoff          // what ships: EditorHarness outlines on the edge
        let id = h.add(Subboard(frame: cardFrame))
        let size = CGSize(width: 320, height: 240)
        let rest = renderBitmap(h.editor, size: size)
        // Its right edge, at 280, clear of the corners (the outline's arcs run from 50 down to 190):
        // the line, 1.5 points centered 4 out, covers columns 283 and 284; the faint one, 2.5 points,
        // 283 and 284 and a quarter of 282 and 285. Its corners hang past the card's: the outline's
        // arc, 14 points round where the card's is 10, crosses the corner of its box, so the card is
        // looked at 6 points in, and its edge where it's straight.
        let line = CGRect(x: 283, y: 60, width: 2, height: 120)
        let card = cardFrame.insetBy(dx: 6, dy: 6)

        let shape = try require(h.editor.document[id])
        let outline = try require(h.editor.outlinePath(of: shape))
        let box = outline.boundingBoxOfPath, grown = cardFrame.insetBy(dx: -4, dy: -4)
        expect(box.insetBy(dx: -0.01, dy: -0.01).contains(grown) && grown.insetBy(dx: -0.01, dy: -0.01).contains(box),
               "the card's edge grown by 4 view points, which are 4 units at 100%: \(box)")
        // The card's corners are 10 about (50, 50); its outline's, 14 about the same center: (41, 41)
        // is inside it and (39, 39) outside, where a rect grown by 4 with the card's own 10, or with
        // square corners, would hold it.
        expect(outline.contains(CGPoint(x: 41, y: 41)) && !outline.contains(CGPoint(x: 39, y: 39)), "its corners concentric with the card's")

        h.editor.selection = id
        let selected = renderBitmap(h.editor, size: size)
        expectEqual(changedPixels(rest, selected, in: card), 0, "the card as it was")
        expectEqual(changedPixels(rest, selected, in: CGRect(x: 276, y: 60, width: 7, height: 120)), 0, "its border, and the gap to the line, as they were")
        expect(changedPixels(rest, selected, in: line) > 200, "the selection's line")

        h.editor.selection = nil
        h.editor.hovered = id
        let hovered = renderBitmap(h.editor, size: size)
        expectEqual(changedPixels(rest, hovered, in: card), 0, "the card, hovered")
        expectEqual(changedPixels(rest, hovered, in: CGRect(x: 276, y: 60, width: 6, height: 120)), 0, "its border and the gap, hovered")
        expect(changedPixels(rest, hovered, in: line) > 200, "the hover's line")
    },
    test("a card sized small still draws, never outside its frame and its shadow") {
        let blank = renderBitmap(try CanvasEditor(registry: Registry(plugins: subboardPlugins()), scheduler: ManualScheduler()),
                                 size: CGSize(width: 320, height: 240))
        for size in [CGSize(width: 30, height: 12), CGSize(width: 8, height: 4), CGSize(width: 240, height: 20)] {
            let h = try EditorHarness(plugins: subboardPlugins())
            let frame = CGRect(origin: CGPoint(x: 40, y: 40), size: size)
            h.add(Subboard(frame: frame))
            let bitmap = renderBitmap(h.editor, size: CGSize(width: 320, height: 240))
            let reach = frame.insetBy(dx: -8, dy: -8)
            expectEqual(changedPixels(blank, bitmap, in: CGRect(x: reach.maxX, y: 0, width: 320 - reach.maxX, height: 240)), 0, "\(size)")
            expectEqual(changedPixels(blank, bitmap, in: CGRect(x: 0, y: reach.maxY, width: 320, height: 240 - reach.maxY)), 0, "\(size)")
            expect(changedPixels(blank, bitmap, in: frame) > 0, "\(size) draws")
        }
    },
])
