import AppKit
import Boards
import Canvas
import CanvasTesting
import Subboards
import TestKit
import Titles

// A card at `cardFrame` (40, 40, 240 × 160): the card itself 40 to 192 down, its two plates showing
// below it to 200; the header band 40 to 72, its symbol from x 50 and the title after it; the body
// 72 to 192, the caption in its middle, at 132.
enum Band {
    static let title = CGRect(x: 72, y: 44, width: 196, height: 24)
    static let symbol = CGRect(x: 48, y: 46, width: 22, height: 20)
    static let caption = CGRect(x: 60, y: 122, width: 200, height: 20)
    /// Above the card, where a title's pill would be (9 to 27 points up), clear of its shadow.
    static let pill = CGRect(x: 40, y: 0, width: 240, height: 33)
}

@MainActor let cardTests = Suite("The card", [
    test("a header band tinted indigo, with the symbol, over a white body, in an indigo border, on two plates") {
        let bitmap = try render(title: nil)
        expectColor(pixel(bitmap, at: CGPoint(x: 265, y: 46)), [230, 230, 250], "the header band")
        expectColor(pixel(bitmap, at: CGPoint(x: 250, y: 100)), [255, 255, 255], "the body")
        let symbol = (0..<20).flatMap { dy in (0..<22).map { dx in pixel(bitmap, at: CGPoint(x: Band.symbol.minX + CGFloat(dx), y: Band.symbol.minY + CGFloat(dy))) } }
        expect(symbol.contains { $0[2] > $0[0] + 80 }, "the symbol, in indigo")
        let border = pixel(bitmap, at: CGPoint(x: 279, y: 120))
        expect(border[2] > border[0] + 60, "the border, in indigo: \(border)")
        // Below the card, the plates' lower edges, each in indigo, lighter.
        for y: CGFloat in [195, 199] {
            let plate = pixel(bitmap, at: CGPoint(x: 160, y: y))
            expect(plate[2] > plate[0] + 20, "a plate's edge at \(y): \(plate)")
        }
    },
    test("the title, dark; while there's none, \"Untitled Subboard\", dimmed") {
        let untitled = try render(title: nil), titled = try render(title: "Kitchen")
        expect(darkest(titled, in: Band.title) < 90, "the title: \(darkest(titled, in: Band.title))")
        let placeholder = darkest(untitled, in: Band.title)
        expect(placeholder > 110 && placeholder < 200, "the placeholder, dimmed: \(placeholder)")
        expect(changedPixels(untitled, titled, in: Band.title) > 150)
        expectEqual(changedPixels(untitled, try render(title: "   "), in: Band.title), 0, "a blank title is none")
    },
    test("no pill: the card draws its title, and nothing shows above it") {
        let untitled = try render(title: nil), titled = try render(title: "Kitchen")
        expectEqual(changedPixels(untitled, titled, in: Band.pill), 0)
    },
    test("the body says what its board holds: \"Empty\", or how many shapes") {
        let empty = try render(title: nil), three = try render(title: nil, inside: 3), one = try render(title: nil, inside: 1)
        for bitmap in [empty, three, one] { expect(darkest(bitmap, in: Band.caption) < 170, "a caption") }
        expect(changedPixels(empty, three, in: Band.caption) > 50, "Empty, then 3 shapes")
        expect(changedPixels(one, three, in: Band.caption) > 5, "1 shape, then 3 shapes")
        expectEqual(changedPixels(empty, three, in: Band.title), 0, "only the caption")
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
